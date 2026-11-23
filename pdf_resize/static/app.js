(() => {
  const state = {
    system: null,
    sourceMode: "local", // local | upload
    outputMode: "inplace", // inplace | output_dir
    selectedPreset: "balanced",
    localSourceDirs: [], // string[]
    folderScanStats: {}, // path -> { total_files, total_bytes, pending_count }
    lastScanSummary: null,
    uploadQueue: [], // [{ file, relPath }]
    previewViewMode: "split", // split | side
    previewTotalPages: null,
    previewLastUploadFile: null,
    activeJobId: null,
    activeJobDetail: null,
    jobsCache: [],
    jobsListSeq: 0,
    eventSource: null,
    pollTimer: null,
    sidebarSyncTimer: null,
    fileFilter: "all",
    fileSearch: "",
    fileSort: "id:asc",
    filePage: 1,
    folderModalTargetInput: null,
    folderModalAppendSource: false,
    folderCurrentPath: "",
    folderParentPath: null,
  };

  const PRESET_META = {
    lossless: { bars: 1, saving: "约省 5%–25%", short: "不降图片画质，仅结构与流优化" },
    light: { bars: 2, saving: "约省 25%–50%", short: "200 DPI · 质量 82%，高清打印" },
    balanced: { bars: 3, saving: "约省 45%–75%", short: "150 DPI · 质量 70%，清晰兼顾体积", recommended: true },
    extreme: { bars: 4, saving: "约省 65%–88%", short: "100 DPI · 质量 50%，极致省空间" },
  };

  const $ = (id) => document.getElementById(id);

  function fmtSize(bytes) {
    if (bytes === null || bytes === undefined) return "-";
    let val = Number(bytes);
    const units = ["B", "KB", "MB", "GB", "TB"];
    let i = 0;
    while (Math.abs(val) >= 1024 && i < units.length - 1) {
      val /= 1024;
      i++;
    }
    return `${val.toFixed(i === 0 ? 0 : 2)} ${units[i]}`;
  }

  function fmtEta(sec) {
    if (sec === null || sec === undefined) return "计算中...";
    if (sec < 60) return `${sec} 秒`;
    const m = Math.floor(sec / 60);
    const s = sec % 60;
    if (m < 60) return `${m} 分 ${s} 秒`;
    const h = Math.floor(m / 60);
    return `${h} 小时 ${m % 60} 分`;
  }

  function statusLabel(st) {
    const map = {
      created: "已创建",
      running: "压缩中",
      paused: "已暂停",
      completed: "已完成",
      cancelled: "已取消",
      failed: "失败",
      pending: "等待中",
      processing: "处理中",
      done: "已优化",
      skipped_no_gain: "已是最优",
      skipped_small: "过小跳过",
      skipped_encrypted: "加密跳过",
      skipped_empty: "空文件",
      skipped_already_done: "历史已优化",
    };
    return map[st] || st;
  }

  function statusClass(st) {
    if (st && st.startsWith("skipped_")) return "status-skipped";
    return `status-${st || "pending"}`;
  }

  function toast(msg, type = "info") {
    const container = $("toastContainer");
    if (!container) return;
    const el = document.createElement("div");
    el.className = `toast ${type}`;
    el.textContent = msg;
    container.appendChild(el);
    setTimeout(() => el.remove(), 4200);
  }

  function showConfirm(message, title = "请确认操作") {
    const modal = $("confirmModal");
    if (!modal) return Promise.resolve(window.confirm(message));
    return new Promise((resolve) => {
      $("confirmModalTitle").textContent = title;
      $("confirmModalBody").textContent = message;
      modal.classList.remove("hidden");
      let settled = false;
      const cleanup = (val) => {
        if (settled) return;
        settled = true;
        modal.classList.add("hidden");
        $("confirmOkBtn").removeEventListener("click", onOk);
        $("confirmCancelBtn").removeEventListener("click", onCancel);
        $("closeConfirmModalBtn").removeEventListener("click", onCancel);
        modal.removeEventListener("click", onBackdrop);
        window.removeEventListener("keydown", onKey);
        resolve(val);
      };
      const onOk = () => cleanup(true);
      const onCancel = () => cleanup(false);
      const onBackdrop = (ev) => {
        if (ev.target === modal) cleanup(false);
      };
      const onKey = (ev) => {
        if (ev.key === "Escape") cleanup(false);
      };
      $("confirmOkBtn").addEventListener("click", onOk);
      $("confirmCancelBtn").addEventListener("click", onCancel);
      $("closeConfirmModalBtn").addEventListener("click", onCancel);
      modal.addEventListener("click", onBackdrop);
      window.addEventListener("keydown", onKey);
    });
  }

  window.addEventListener("error", (ev) => {
    toast(`页面脚本异常: ${ev.message || "未知错误"}`, "error");
  });
  window.addEventListener("unhandledrejection", (ev) => {
    const reason = ev.reason?.message || String(ev.reason || "请求失败");
    toast(`操作失败: ${reason}`, "error");
  });

  async function api(url, opts = {}) {
    const res = await fetch(url, opts);
    if (!res.ok) {
      let detail = `HTTP ${res.status}`;
      try {
        const body = await res.json();
        if (body.detail) detail = body.detail;
      } catch {}
      throw new Error(detail);
    }
    return res.json();
  }

  // ---------- THEME SWITCHER ----------
  function applyTheme(theme) {
    const t = theme === "light" ? "light" : "dark";
    document.documentElement.setAttribute("data-theme", t);
    try {
      localStorage.setItem("pdf_resize_theme", t);
    } catch {}
    $("themeIconDark").classList.toggle("hidden", t === "light");
    $("themeIconLight").classList.toggle("hidden", t !== "light");
    $("themeToggleLabel").textContent = t === "light" ? "深色模式" : "浅色模式";
  }

  $("themeToggleBtn").addEventListener("click", () => {
    const cur = document.documentElement.getAttribute("data-theme") || "dark";
    applyTheme(cur === "dark" ? "light" : "dark");
  });

  try {
    const savedTheme = localStorage.getItem("pdf_resize_theme");
    if (savedTheme) applyTheme(savedTheme);
  } catch {}

  // ---------- NAVIGATION ----------
  function switchTab(tabName, opts = {}) {
    document.querySelectorAll(".nav-item").forEach((b) => {
      b.classList.toggle("active", b.dataset.tab === tabName);
    });
    document.querySelectorAll(".tab-panel").forEach((p) => {
      p.classList.toggle("active", p.id === `tab-${tabName}`);
    });
    if (tabName === "jobs" && !opts.skipLoad) {
      loadJobsList();
    }
  }

  document.querySelectorAll(".nav-item").forEach((btn) => {
    btn.addEventListener("click", () => switchTab(btn.dataset.tab));
  });

  // ---------- LIVE SUMMARY & STEPPER ----------
  function updateWorkbenchSummary() {
    const cfg = getCurrentConfig();
    const presetInfo = state.system?.presets?.[state.selectedPreset];
    const presetLabel = presetInfo ? presetInfo.label.split("（")[0] : `自定义 (${cfg.target_dpi} DPI / ${cfg.jpeg_quality}%)`;

    // Advanced drawer summary
    const advParts = [`${cfg.workers} 进程`, `最小节省 ${cfg.min_saving_percent}%`];
    if (cfg.grayscale) advParts.push("灰度");
    if (cfg.strip_metadata) advParts.push("清元数据");
    if (cfg.skip_already_optimized) advParts.push("跳过已优化");
    $("advancedSummaryText").textContent = advParts.join(" · ");

    // Preview readout
    $("previewConfigReadout").textContent = cfg.compress_images
      ? `${cfg.downsample_images ? `${cfg.target_dpi} DPI` : "原分辨率"} · 质量 ${cfg.jpeg_quality}%${cfg.grayscale ? " · 灰度" : ""}`
      : "无损结构优化";

    const hasSource =
      state.sourceMode === "local"
        ? state.localSourceDirs.length > 0 || $("localSourceDir").value.trim().length > 0
        : state.uploadQueue.length > 0;

    // Stepper highlights
    $("stepPill1").classList.toggle("done", hasSource);
    $("stepPill1").classList.toggle("active", !hasSource);
    $("stepPill2").classList.toggle("active", hasSource);
    $("stepPill3").classList.toggle("active", hasSource);

    const limitVal = $("localLimitFiles").value.trim();
    const limitNum = limitVal ? Number(limitVal) : null;

    if (state.sourceMode === "upload") {
      if (!state.uploadQueue.length) {
        $("launchSummaryMain").textContent = "请拖入或选择要上传的 PDF 文件";
        $("launchSummarySub").textContent = `压缩强度：${presetLabel} · 4 路并发流式上传`;
      } else {
        const totalBytes = state.uploadQueue.reduce((acc, it) => acc + (it.file.size || 0), 0);
        $("launchSummaryMain").textContent = `准备上传并压缩 ${state.uploadQueue.length.toLocaleString()} 个 PDF (${fmtSize(totalBytes)})`;
        $("launchSummarySub").textContent = `压缩强度：${presetLabel} · 完成后可一键打开目录或打包 ZIP`;
      }
      $("startJobBtnText").textContent = "开始上传并压缩";
      return;
    }

    const modeDesc = state.outputMode === "inplace" ? "原地覆盖优化" : "输出到新目录";
    const backupDir = $("localBackupDir").value.trim();
    const safetyExtra =
      state.outputMode === "inplace"
        ? backupDir
          ? "已开启原文件备份 · 原子替换"
          : "原子替换 · 页数校验 · 变大自动放弃"
        : "保留原文件不动 · 保持原目录结构";

    if (!hasSource) {
      $("launchSummaryMain").textContent = "请先添加至少一个本地 PDF 文件夹";
      $("launchSummarySub").textContent = `${presetLabel} · ${modeDesc} · ${safetyExtra}`;
    } else {
      const dirCount = Math.max(1, state.localSourceDirs.length);
      const scanInfo = state.lastScanSummary
        ? ` · ${state.lastScanSummary.pending_count.toLocaleString()} 个待压缩 (${fmtSize(state.lastScanSummary.total_bytes)})`
        : "";
      const limitDesc = limitNum ? ` · 仅试跑前 ${limitNum} 个` : "";
      $("launchSummaryMain").textContent = `已选 ${dirCount} 个文件夹${scanInfo}${limitDesc}`;
      $("launchSummarySub").textContent = `${presetLabel} · ${modeDesc} · ${safetyExtra}`;
    }

    if (limitNum) {
      $("startJobBtnText").textContent = `试跑前 ${limitNum} 个 PDF`;
    } else if (state.outputMode === "inplace") {
      $("startJobBtnText").textContent = "开始原地批量优化";
    } else {
      $("startJobBtnText").textContent = "开始批量压缩到新目录";
    }
  }

  // ---------- CONFIG & PRESETS ----------
  function getCurrentConfig() {
    return {
      preset: state.selectedPreset,
      compress_images: $("cfgCompressImages").checked,
      downsample_images: $("cfgDownsample").checked,
      target_dpi: Number($("cfgTargetDpi").value),
      jpeg_quality: Number($("cfgJpegQuality").value),
      grayscale: $("cfgGrayscale").checked,
      optimize_transparent: $("cfgOptimizeTransparent").checked,
      subset_fonts: $("cfgSubsetFonts").checked,
      strip_metadata: $("cfgStripMetadata").checked,
      clean_streams: true,
      use_qpdf: $("cfgUseQpdf").checked,
      min_saving_percent: Number($("cfgMinSaving").value) || 0,
      skip_smaller_than_kb: Number($("cfgSkipSmallKb").value) || 0,
      skip_already_optimized: $("cfgSkipAlready").checked,
      preserve_mtime: $("cfgPreserveMtime").checked,
      workers: Number($("cfgWorkers").value),
    };
  }

  function applyConfigToUI(cfg, presetKey) {
    state.selectedPreset = presetKey || "custom";
    $("cfgCompressImages").checked = !!cfg.compress_images;
    $("cfgDownsample").checked = !!cfg.downsample_images;
    $("cfgTargetDpi").value = cfg.target_dpi;
    $("cfgTargetDpiVal").textContent = cfg.target_dpi;
    $("cfgJpegQuality").value = cfg.jpeg_quality;
    $("cfgJpegQualityVal").textContent = cfg.jpeg_quality;
    $("cfgGrayscale").checked = !!cfg.grayscale;
    $("cfgOptimizeTransparent").checked = !!cfg.optimize_transparent;
    $("cfgSubsetFonts").checked = !!cfg.subset_fonts;
    $("cfgStripMetadata").checked = !!cfg.strip_metadata;
    $("cfgUseQpdf").checked = !!cfg.use_qpdf;
    if (cfg.min_saving_percent !== undefined) $("cfgMinSaving").value = cfg.min_saving_percent;

    syncImageControlsDisabled();
    updatePresetHighlight();
    updateWorkbenchSummary();
  }

  function syncImageControlsDisabled() {
    const imgEnabled = $("cfgCompressImages").checked;
    const dsEnabled = $("cfgDownsample").checked;
    $("cfgDownsample").disabled = !imgEnabled;
    $("cfgTargetDpi").disabled = !imgEnabled || !dsEnabled;
    $("cfgJpegQuality").disabled = !imgEnabled;
    $("dpiRow").style.opacity = imgEnabled && dsEnabled ? "1" : "0.45";
    $("qualityRow").style.opacity = imgEnabled ? "1" : "0.45";
  }

  function updatePresetHighlight() {
    document.querySelectorAll(".preset-card").forEach((c) => {
      c.classList.toggle("active", c.dataset.preset === state.selectedPreset);
    });
    document.querySelectorAll("#previewPresetPills .pill-chip").forEach((c) => {
      c.classList.toggle("active", c.dataset.preset === state.selectedPreset);
    });
    const presetInfo = state.system?.presets?.[state.selectedPreset];
    $("currentPresetChip").textContent = presetInfo ? presetInfo.label : "自定义参数";
  }

  function markCustomPreset() {
    state.selectedPreset = "custom";
    updatePresetHighlight();
    updateWorkbenchSummary();
  }

  function renderPresets(presets) {
    const grid = $("presetGrid");
    const previewPills = $("previewPresetPills");
    grid.innerHTML = "";
    previewPills.innerHTML = "";

    Object.entries(presets).forEach(([key, info]) => {
      const meta = PRESET_META[key] || { bars: 2, saving: "", short: info.description };
      const titleShort = info.label.split("（")[0];
      const barsHtml = [1, 2, 3, 4]
        .map((n) => `<i class="${n <= meta.bars ? "on" : ""}"></i>`)
        .join("");

      const btn = document.createElement("button");
      btn.type = "button";
      btn.className = `preset-card ${key === state.selectedPreset ? "active" : ""}`;
      btn.dataset.preset = key;
      btn.innerHTML = `
        <div class="preset-card-top">
          <strong>${titleShort}</strong>
          ${meta.recommended ? '<span class="preset-rec">推荐</span>' : ""}
        </div>
        <div class="preset-bars">${barsHtml}</div>
        <span class="preset-desc">${meta.short}</span>
        <span class="preset-saving">${meta.saving}</span>
      `;
      btn.addEventListener("click", () => applyConfigToUI(info.config, key));
      grid.appendChild(btn);

      // Sync quick pill inside Preview tab
      const pill = document.createElement("button");
      pill.type = "button";
      pill.className = `pill-chip ${key === state.selectedPreset ? "active" : ""}`;
      pill.dataset.preset = key;
      pill.textContent = titleShort;
      pill.addEventListener("click", () => {
        applyConfigToUI(info.config, key);
        if ($("previewLocalPath").value.trim()) {
          runLocalPreview();
        } else if (state.previewLastUploadFile) {
          runUploadPreview(state.previewLastUploadFile);
        }
      });
      previewPills.appendChild(pill);
    });
  }

  // Slider & setting listeners
  $("cfgTargetDpi").addEventListener("input", (e) => {
    $("cfgTargetDpiVal").textContent = e.target.value;
    markCustomPreset();
  });
  $("cfgJpegQuality").addEventListener("input", (e) => {
    $("cfgJpegQualityVal").textContent = e.target.value;
    markCustomPreset();
  });
  $("cfgWorkers").addEventListener("input", (e) => {
    $("cfgWorkersVal").textContent = e.target.value;
    updateWorkbenchSummary();
  });
  ["cfgMinSaving", "cfgSkipSmallKb", "localBackupDir", "localSourceDir"].forEach((id) => {
    $(id).addEventListener("input", updateWorkbenchSummary);
  });
  ["cfgCompressImages", "cfgDownsample", "cfgGrayscale", "cfgOptimizeTransparent", "cfgSubsetFonts", "cfgStripMetadata", "cfgUseQpdf"].forEach((id) => {
    $(id).addEventListener("change", () => {
      syncImageControlsDisabled();
      markCustomPreset();
    });
  });
  ["cfgPreserveMtime", "cfgSkipAlready"].forEach((id) => {
    $(id).addEventListener("change", updateWorkbenchSummary);
  });

  // ---------- TRIAL QUICK CHIPS ----------
  function syncTrialChips(val) {
    const str = val === null || val === undefined ? "" : String(val).trim();
    document.querySelectorAll("#trialQuickChips .pill-chip").forEach((c) => {
      c.classList.toggle("active", c.dataset.limit === str);
    });
  }

  document.querySelectorAll("#trialQuickChips .pill-chip").forEach((btn) => {
    btn.addEventListener("click", () => {
      $("localLimitFiles").value = btn.dataset.limit;
      syncTrialChips(btn.dataset.limit);
      updateWorkbenchSummary();
    });
  });

  $("localLimitFiles").addEventListener("input", (e) => {
    syncTrialChips(e.target.value);
    updateWorkbenchSummary();
  });

  // ---------- SOURCE & OUTPUT SWITCH ----------
  $("sourceModeSwitch").querySelectorAll(".seg-btn").forEach((btn) => {
    btn.addEventListener("click", () => {
      state.sourceMode = btn.dataset.mode;
      $("sourceModeSwitch").querySelectorAll(".seg-btn").forEach((b) => b.classList.toggle("active", b === btn));
      $("sourceLocalPanel").classList.toggle("hidden", state.sourceMode !== "local");
      $("sourceUploadPanel").classList.toggle("hidden", state.sourceMode !== "upload");
      $("step3OutputCard").classList.toggle("hidden", state.sourceMode !== "local");
      updateWorkbenchSummary();
    });
  });

  document.querySelectorAll(".mode-card").forEach((card) => {
    card.addEventListener("click", () => {
      state.outputMode = card.dataset.output;
      document.querySelectorAll(".mode-card").forEach((c) => c.classList.toggle("active", c === card));
      card.querySelector("input").checked = true;
      $("backupDirGroup").classList.toggle("hidden", state.outputMode !== "inplace");
      $("outputDirGroup").classList.toggle("hidden", state.outputMode !== "output_dir");
      updateWorkbenchSummary();
    });
  });

  // ---------- MULTI-FOLDER SOURCE LIST ----------
  function addLocalSourceDirs(rawPaths) {
    let added = 0;
    for (const raw of rawPaths) {
      const cleaned = (raw || "").trim().replace(/^["']|["']$/g, "");
      if (!cleaned) continue;
      if (!state.localSourceDirs.includes(cleaned)) {
        state.localSourceDirs.push(cleaned);
        added++;
      }
    }
    if (added > 0) state.lastScanSummary = null;
    renderLocalSourceDirs();
    updateWorkbenchSummary();
    return added;
  }

  function removeLocalSourceDir(idx) {
    const [removed] = state.localSourceDirs.splice(idx, 1);
    if (removed) delete state.folderScanStats[removed];
    if (!state.localSourceDirs.length) {
      state.lastScanSummary = null;
      $("scanResultBox").classList.add("hidden");
    }
    renderLocalSourceDirs();
    updateWorkbenchSummary();
  }

  function collectLocalSourceDirs() {
    const inputVal = $("localSourceDir").value.trim();
    if (inputVal) {
      const parts = inputVal.split(/\r?\n/).map((s) => s.trim()).filter(Boolean);
      addLocalSourceDirs(parts);
      $("localSourceDir").value = "";
    }
    return [...state.localSourceDirs];
  }

  function renderLocalSourceDirs() {
    const count = state.localSourceDirs.length;
    $("clearSourceDirsBtn").classList.toggle("hidden", count === 0);
    $("sourceDirsCount").textContent =
      count > 0
        ? `已添加 ${count} 个文件夹（自动递归子目录与去重）`
        : "尚未添加文件夹 — 点击上方「选择文件夹」可一次选择多个目录";

    const list = $("sourceDirsList");
    list.innerHTML = "";
    state.localSourceDirs.forEach((dirPath, idx) => {
      const st = state.folderScanStats[dirPath];
      const metaText = st ? `${st.total_files.toLocaleString()} 个 PDF · ${fmtSize(st.total_bytes)}` : "";
      const folderName = dirPath.replace(/[\\/]+$/, "").split(/[\\/]/).pop() || dirPath;
      const row = document.createElement("div");
      row.className = "source-dir-item";
      row.innerHTML = `
        <span class="source-dir-icon">
          <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.9" stroke-linecap="round" stroke-linejoin="round"><path d="M22 19a2 2 0 0 1-2 2H4a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h5l2 3h9a2 2 0 0 1 2 2z"/></svg>
        </span>
        <div class="source-dir-info">
          <span class="source-dir-name">${folderName}</span>
          <span class="source-dir-path" title="${dirPath}">${dirPath}</span>
        </div>
        ${metaText ? `<span class="source-dir-meta">${metaText}</span>` : ""}
        <button type="button" class="source-dir-remove" title="移除该文件夹">✕</button>
      `;
      row.querySelector(".source-dir-remove").addEventListener("click", () => removeLocalSourceDir(idx));
      list.appendChild(row);
    });
  }

  $("addSourceDirBtn").addEventListener("click", () => {
    const val = $("localSourceDir").value.trim();
    if (!val) {
      toast("请先输入或粘贴文件夹路径", "error");
      return;
    }
    const parts = val.split(/\r?\n/).map((s) => s.trim()).filter(Boolean);
    const added = addLocalSourceDirs(parts);
    $("localSourceDir").value = "";
    if (added > 0) toast(`已添加 ${added} 个文件夹到列表`, "success");
  });

  $("localSourceDir").addEventListener("keydown", (e) => {
    if (e.key === "Enter") {
      e.preventDefault();
      $("addSourceDirBtn").click();
    }
  });

  $("clearSourceDirsBtn").addEventListener("click", () => {
    state.localSourceDirs = [];
    state.folderScanStats = {};
    state.lastScanSummary = null;
    renderLocalSourceDirs();
    $("scanResultBox").classList.add("hidden");
    updateWorkbenchSummary();
  });

  // ---------- FOLDER BROWSER MODAL ----------
  async function openFolderModal(targetInputEl, appendToSourceList = false) {
    state.folderModalTargetInput = targetInputEl;
    state.folderModalAppendSource = appendToSourceList;
    $("confirmFolderBtn").textContent = appendToSourceList ? "添加当前目录到列表" : "选择当前目录";
    $("folderModal").classList.remove("hidden");
    const initPath = appendToSourceList
      ? $("localSourceDir").value.trim()
      : (targetInputEl?.value || "").trim();
    await loadFolderListing(initPath);
  }

  async function loadFolderListing(path) {
    try {
      const data = await api(`/api/fs/list?path=${encodeURIComponent(path || "")}`);
      state.folderCurrentPath = data.current;
      state.folderParentPath = data.parent;
      $("folderCurrentInput").value = data.current || "";
      $("folderUpBtn").disabled = data.parent === null;
      $("folderPdfHint").textContent = data.current
        ? `当前目录直接包含 ${data.pdf_count_here || 0} 个 PDF 文件（子目录将按需递归扫描）`
        : "请选择磁盘或常用文件夹";

      const list = $("folderList");
      list.innerHTML = "";
      if (!data.entries.length) {
        list.innerHTML = `<div class="empty-state">该目录下没有子文件夹</div>`;
        return;
      }
      data.entries.forEach((ent) => {
        const div = document.createElement("div");
        div.className = "folder-entry";
        const icon = ent.is_drive
          ? `<svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8"><rect x="2" y="4" width="20" height="16" rx="2"/><line x1="6" y1="12" x2="6.01" y2="12"/><line x1="10" y1="12" x2="10.01" y2="12"/></svg>`
          : `<svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8"><path d="M22 19a2 2 0 0 1-2 2H4a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h5l2 3h9a2 2 0 0 1 2 2z"/></svg>`;
        div.innerHTML = `<span class="text-accent" style="display:flex;">${icon}</span><span>${ent.name}</span>`;
        div.addEventListener("click", () => loadFolderListing(ent.path));
        list.appendChild(div);
      });
    } catch (err) {
      toast(err.message, "error");
    }
  }

  $("browseSourceBtn").addEventListener("click", () => openFolderModal($("localSourceDir"), true));
  $("browseBackupBtn").addEventListener("click", () => openFolderModal($("localBackupDir"), false));
  $("browseOutputBtn").addEventListener("click", () => openFolderModal($("localOutputDir"), false));
  $("browseUploadOutBtn").addEventListener("click", () => openFolderModal($("uploadOutputDir"), false));
  $("folderUpBtn").addEventListener("click", () => {
    if (state.folderParentPath !== null) loadFolderListing(state.folderParentPath);
  });
  $("folderGoBtn").addEventListener("click", () => loadFolderListing($("folderCurrentInput").value.trim()));
  $("confirmFolderBtn").addEventListener("click", () => {
    if (state.folderCurrentPath) {
      if (state.folderModalAppendSource) {
        const added = addLocalSourceDirs([state.folderCurrentPath]);
        if (added > 0) toast("已添加文件夹，可继续添加更多目录", "success");
      } else if (state.folderModalTargetInput) {
        state.folderModalTargetInput.value = state.folderCurrentPath;
        updateWorkbenchSummary();
      }
    }
    $("folderModal").classList.add("hidden");
  });
  $("closeFolderModalBtn").addEventListener("click", () => $("folderModal").classList.add("hidden"));
  $("cancelFolderModalBtn").addEventListener("click", () => $("folderModal").classList.add("hidden"));

  $("nativePickSourceBtn").addEventListener("click", async () => {
    try {
      $("nativePickSourceBtn").disabled = true;
      let picked = [];
      if (window.pywebview?.api?.pick_folders) {
        const res = await window.pywebview.api.pick_folders(true);
        picked = Array.isArray(res) ? res : [];
      } else {
        const res = await api("/api/fs/pick-folder?multiple=true", { method: "POST" });
        picked = res.paths && res.paths.length ? res.paths : res.path ? [res.path] : [];
      }
      if (picked.length) {
        const added = addLocalSourceDirs(picked);
        if (added > 0) toast(`已添加 ${added} 个文件夹`, "success");
        scanLocalDirectory();
      }
    } catch (err) {
      toast(err.message, "error");
    } finally {
      $("nativePickSourceBtn").disabled = false;
    }
  });

  // ---------- SCAN DIRECTORY ----------
  async function scanLocalDirectory() {
    const paths = collectLocalSourceDirs();
    if (!paths.length) {
      toast("请先添加或输入至少一个 PDF 文件夹路径", "error");
      return;
    }
    $("scanDirBtn").disabled = true;
    try {
      const cfg = getCurrentConfig();
      const data = await api("/api/scan", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          paths,
          recursive: $("localRecursive").checked,
          skip_smaller_than_kb: cfg.skip_smaller_than_kb,
          skip_already_optimized: cfg.skip_already_optimized,
        }),
      });
      if (Array.isArray(data.folders) && data.folders.length) {
        state.localSourceDirs = data.folders.map((f) => f.path);
        state.folderScanStats = {};
        data.folders.forEach((f) => {
          state.folderScanStats[f.path] = f;
        });
        renderLocalSourceDirs();
      }

      state.lastScanSummary = data;
      $("scanTotalFiles").textContent = data.total_files.toLocaleString();
      $("scanTotalBytes").textContent = fmtSize(data.total_bytes);
      $("scanPendingFiles").textContent = data.pending_count.toLocaleString();
      $("scanSkippedFiles").textContent = (data.already_optimized_count + data.too_small_count).toLocaleString();

      const sel = $("scanSampleSelect");
      sel.innerHTML = "";
      data.sample_files.forEach((f) => {
        const opt = document.createElement("option");
        opt.value = f.src_path;
        opt.textContent = `${f.rel_path} (${fmtSize(f.orig_size)})`;
        sel.appendChild(opt);
      });
      $("scanResultBox").classList.remove("hidden");
      updateWorkbenchSummary();
      toast(
        `扫描完成：${data.folders?.length || paths.length} 个目录共发现 ${data.total_files} 个 PDF（${fmtSize(data.total_bytes)}）`,
        "success"
      );
    } catch (err) {
      toast(err.message, "error");
    } finally {
      $("scanDirBtn").disabled = false;
    }
  }

  $("scanDirBtn").addEventListener("click", scanLocalDirectory);
  $("quickPreviewSampleBtn").addEventListener("click", () => {
    const sample = $("scanSampleSelect").value;
    if (!sample) return;
    $("previewLocalPath").value = sample;
    state.previewLastUploadFile = null;
    switchTab("preview");
    runLocalPreview();
  });

  // ---------- DRAG & DROP / FILE UPLOAD QUEUE ----------
  function addFilesToUploadQueue(items) {
    let added = 0;
    for (const item of items) {
      const name = item.file.name || "";
      if (!name.toLowerCase().endsWith(".pdf")) continue;
      state.uploadQueue.push(item);
      added++;
    }
    renderUploadQueue();
    updateWorkbenchSummary();
    if (added > 0) toast(`已添加 ${added} 个 PDF 到待上传队列`, "success");
  }

  function renderUploadQueue() {
    const total = state.uploadQueue.length;
    if (total === 0) {
      $("uploadQueueSummary").classList.add("hidden");
      return;
    }
    const totalBytes = state.uploadQueue.reduce((acc, it) => acc + (it.file.size || 0), 0);
    $("uploadFileCount").textContent = total.toLocaleString();
    $("uploadTotalBytes").textContent = fmtSize(totalBytes);
    $("uploadProgressText").textContent = "准备就绪";
    $("uploadQueueSummary").classList.remove("hidden");
  }

  $("pickFilesBtn").addEventListener("click", () => $("uploadFilesInput").click());
  $("pickFolderUploadBtn").addEventListener("click", () => $("uploadFolderInput").click());
  $("uploadFilesInput").addEventListener("change", (e) => {
    const items = Array.from(e.target.files || []).map((f) => ({ file: f, relPath: f.name }));
    addFilesToUploadQueue(items);
    e.target.value = "";
  });
  $("uploadFolderInput").addEventListener("change", (e) => {
    const items = Array.from(e.target.files || []).map((f) => ({
      file: f,
      relPath: f.webkitRelativePath || f.name,
    }));
    addFilesToUploadQueue(items);
    e.target.value = "";
  });
  $("clearUploadQueueBtn").addEventListener("click", () => {
    state.uploadQueue = [];
    renderUploadQueue();
    updateWorkbenchSummary();
  });

  async function readEntryRecursively(entry, prefix = "") {
    if (entry.isFile) {
      return new Promise((resolve) => {
        entry.file(
          (file) => resolve([{ file, relPath: prefix ? `${prefix}/${file.name}` : file.name }]),
          () => resolve([])
        );
      });
    }
    if (entry.isDirectory) {
      const reader = entry.createReader();
      const all = [];
      while (true) {
        const batch = await new Promise((resolve) => reader.readEntries(resolve, () => resolve([])));
        if (!batch.length) break;
        for (const child of batch) {
          const sub = await readEntryRecursively(child, prefix ? `${prefix}/${entry.name}` : entry.name);
          all.push(...sub);
        }
      }
      return all;
    }
    return [];
  }

  const dropZone = $("dropZone");
  dropZone.addEventListener("dragover", (e) => {
    e.preventDefault();
    dropZone.classList.add("dragover");
  });
  dropZone.addEventListener("dragleave", () => dropZone.classList.remove("dragover"));
  dropZone.addEventListener("drop", async (e) => {
    e.preventDefault();
    dropZone.classList.remove("dragover");
    const dtItems = Array.from(e.dataTransfer.items || []);
    const entries = [];
    const directFiles = [];
    for (const item of dtItems) {
      const entry = item.webkitGetAsEntry ? item.webkitGetAsEntry() : null;
      if (entry) {
        entries.push(entry);
      } else if (item.getAsFile) {
        const f = item.getAsFile();
        if (f) directFiles.push({ file: f, relPath: f.name });
      }
    }
    if (!entries.length && !directFiles.length && e.dataTransfer.files?.length) {
      for (const f of Array.from(e.dataTransfer.files)) {
        directFiles.push({ file: f, relPath: f.name });
      }
    }

    const collected = [...directFiles];
    for (const entry of entries) {
      const res = await readEntryRecursively(entry, "");
      collected.push(...res);
    }
    addFilesToUploadQueue(collected);
  });

  // ---------- START JOB ----------
  $("startJobBtn").addEventListener("click", async () => {
    if (state.sourceMode === "local") {
      await startLocalJob();
    } else {
      await startUploadJob();
    }
  });

  async function startLocalJob() {
    const sourceDirs = collectLocalSourceDirs();
    if (!sourceDirs.length) {
      toast("请先添加或输入至少一个本地 PDF 文件夹", "error");
      return;
    }
    const outputDir = $("localOutputDir").value.trim() || null;
    const backupDir = $("localBackupDir").value.trim() || null;
    if (state.outputMode === "output_dir" && !outputDir) {
      toast("请选择或填写压缩后的输出目录", "error");
      return;
    }
    const limitVal = $("localLimitFiles").value.trim();
    const limitFiles = limitVal ? Number(limitVal) : null;

    if (state.outputMode === "inplace" && !backupDir) {
      const scopeHint = limitFiles ? `前 ${limitFiles} 个待优化` : "全部待优化";
      const ok = await showConfirm(
        `即将以【原地覆盖】模式直接优化 ${sourceDirs.length} 个目录中的${scopeHint} PDF 文件（未设置备份目录）。\n\n程序已启用同盘原子写入与页数完整性校验，压缩后变大或未达阈值会自动保留原文件。\n确定开始吗？`,
        "确认原地覆盖优化"
      );
      if (!ok) return;
    }

    $("startJobBtn").disabled = true;
    closeStream();
    try {
      const job = await api("/api/jobs/local", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          name: $("localJobName").value.trim() || null,
          source_dirs: sourceDirs,
          recursive: $("localRecursive").checked,
          output_mode: state.outputMode,
          output_dir: outputDir,
          backup_dir: backupDir,
          config: getCurrentConfig(),
          limit_files: limitFiles,
        }),
      });
      toast(`批量压缩任务已启动（共 ${job.stats.total_files} 个 PDF）`, "success");
      switchTab("jobs", { skipLoad: true });
      await selectJob(job.id);
    } catch (err) {
      toast(err.message, "error");
    } finally {
      $("startJobBtn").disabled = false;
    }
  }

  async function startUploadJob() {
    if (!state.uploadQueue.length) {
      toast("请先拖入或选择至少一个 PDF 文件", "error");
      return;
    }
    $("startJobBtn").disabled = true;
    closeStream();
    $("uploadBarWrap").classList.remove("hidden");
    $("uploadBarFill").style.width = "0%";
    $("uploadProgressText").textContent = `正在上传 0 / ${state.uploadQueue.length} ...`;
    try {
      const job = await api("/api/jobs/upload/init", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          name: `批量上传 (${state.uploadQueue.length} 个 PDF)`,
          output_dir: $("uploadOutputDir").value.trim() || null,
          config: getCurrentConfig(),
        }),
      });

      const queue = [...state.uploadQueue];
      const total = queue.length;
      let done = 0;
      let startedCompressing = false;
      const concurrency = 4;
      let cursor = 0;

      async function worker() {
        while (cursor < queue.length) {
          const item = queue[cursor++];
          const fd = new FormData();
          fd.append("file", item.file, item.file.name);
          fd.append("relative_path", item.relPath);
          await api(`/api/jobs/${job.id}/upload`, { method: "POST", body: fd });
          done++;
          const pct = Math.round((done / total) * 100);
          $("uploadBarFill").style.width = `${pct}%`;
          $("uploadProgressText").textContent = `已上传 ${done} / ${total} (${pct}%)`;
          if (!startedCompressing && done >= Math.min(4, total)) {
            startedCompressing = true;
            await api(`/api/jobs/${job.id}/start`, { method: "POST" });
          }
        }
      }

      await Promise.all(Array.from({ length: Math.min(concurrency, total) }, worker));
      await api(`/api/jobs/${job.id}/start`, { method: "POST" });

      state.uploadQueue = [];
      renderUploadQueue();
      updateWorkbenchSummary();
      toast(`全部 ${total} 个 PDF 上传完成，正在全力压缩中`, "success");
      switchTab("jobs", { skipLoad: true });
      await selectJob(job.id);
    } catch (err) {
      toast(`上传失败: ${err.message}`, "error");
    } finally {
      $("startJobBtn").disabled = false;
      $("uploadBarWrap").classList.add("hidden");
    }
  }

  // ---------- SINGLE FILE PREVIEW & SPLIT CURTAIN ----------
  function syncPreviewViewMode() {
    $("previewSplitView").classList.toggle("hidden", state.previewViewMode !== "split");
    $("previewSideView").classList.toggle("hidden", state.previewViewMode !== "side");
  }

  $("previewViewModeSwitch").querySelectorAll(".seg-btn").forEach((btn) => {
    btn.addEventListener("click", () => {
      state.previewViewMode = btn.dataset.view;
      $("previewViewModeSwitch").querySelectorAll(".seg-btn").forEach((b) => b.classList.toggle("active", b === btn));
      syncPreviewViewMode();
    });
  });

  function setSplitPercent(pct) {
    const clamped = Math.max(0, Math.min(100, Number(pct)));
    $("splitOverlay").style.clipPath = `inset(0 ${100 - clamped}% 0 0)`;
    $("splitHandle").style.left = `${clamped}%`;
  }

  $("splitRange").addEventListener("input", (e) => setSplitPercent(e.target.value));

  function showPreviewResult(data) {
    state.previewTotalPages = data.pages || 1;
    $("previewEmptyState").classList.add("hidden");
    $("previewTotalPagesText").textContent = `/ ${data.pages} 页`;
    $("previewPageNum").value = String(data.rendered_page + 1);
    $("previewPageNum").max = String(data.pages);

    $("prevOrigSize").textContent = fmtSize(data.orig_size);
    $("prevNewSize").textContent = fmtSize(data.new_size);
    $("prevSaved").textContent = `${fmtSize(data.saved_bytes)} (-${data.saving_percent}%)`;
    $("prevMeta").textContent = `${statusLabel(data.status)} · ${data.duration_ms}ms · 优化 ${data.images_optimized} 图`;

    const pText = `第 ${data.rendered_page + 1} / ${data.pages} 页`;
    $("prevPageLabelOrig").textContent = pText;
    $("prevPageLabelComp").textContent = pText;
    $("splitPageOrig").textContent = pText;
    $("splitPageComp").textContent = pText;

    $("prevImgOrig").src = data.orig_image_url;
    $("prevImgComp").src = data.comp_image_url;
    $("splitImgOrig").src = data.orig_image_url;
    $("splitImgComp").src = data.comp_image_url;
    $("prevImgOrig").classList.remove("zoomed");
    $("prevImgComp").classList.remove("zoomed");
    $("splitRange").value = "50";
    setSplitPercent(50);

    syncPreviewViewMode();
    $("previewResultArea").classList.remove("hidden");
  }

  async function runLocalPreview() {
    const filePath = $("previewLocalPath").value.trim();
    if (!filePath) {
      toast("请输入本地 PDF 路径", "error");
      return;
    }
    const page = Math.max(0, (Number($("previewPageNum").value) || 1) - 1);
    $("runLocalPreviewBtn").disabled = true;
    $("previewEmptyState").classList.add("hidden");
    $("previewLoading").classList.remove("hidden");
    $("previewResultArea").classList.add("hidden");
    try {
      const data = await api("/api/preview/local", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ file_path: filePath, page, config: getCurrentConfig() }),
      });
      showPreviewResult(data);
    } catch (err) {
      toast(err.message, "error");
      $("previewEmptyState").classList.remove("hidden");
    } finally {
      $("runLocalPreviewBtn").disabled = false;
      $("previewLoading").classList.add("hidden");
    }
  }

  async function runUploadPreview(file) {
    if (!file) return;
    state.previewLastUploadFile = file;
    const page = Math.max(0, (Number($("previewPageNum").value) || 1) - 1);
    $("previewEmptyState").classList.add("hidden");
    $("previewLoading").classList.remove("hidden");
    $("previewResultArea").classList.add("hidden");
    try {
      const fd = new FormData();
      fd.append("file", file, file.name);
      fd.append("config_json", JSON.stringify(getCurrentConfig()));
      fd.append("page", String(page));
      const data = await api("/api/preview/upload", { method: "POST", body: fd });
      showPreviewResult(data);
    } catch (err) {
      toast(err.message, "error");
      $("previewEmptyState").classList.remove("hidden");
    } finally {
      $("previewLoading").classList.add("hidden");
    }
  }

  function rerunCurrentPreview() {
    if ($("previewLocalPath").value.trim()) {
      runLocalPreview();
    } else if (state.previewLastUploadFile) {
      runUploadPreview(state.previewLastUploadFile);
    }
  }

  $("runLocalPreviewBtn").addEventListener("click", () => {
    state.previewLastUploadFile = null;
    runLocalPreview();
  });
  $("previewUploadInput").addEventListener("change", async (e) => {
    const file = e.target.files?.[0];
    e.target.value = "";
    if (!file) return;
    $("previewLocalPath").value = "";
    await runUploadPreview(file);
  });
  $("previewPrevPageBtn").addEventListener("click", () => {
    const cur = Number($("previewPageNum").value) || 1;
    if (cur > 1) {
      $("previewPageNum").value = String(cur - 1);
      rerunCurrentPreview();
    }
  });
  $("previewNextPageBtn").addEventListener("click", () => {
    const cur = Number($("previewPageNum").value) || 1;
    const maxP = state.previewTotalPages || 9999;
    if (cur < maxP) {
      $("previewPageNum").value = String(cur + 1);
      rerunCurrentPreview();
    }
  });
  $("previewPageNum").addEventListener("keydown", (e) => {
    if (e.key === "Enter") rerunCurrentPreview();
  });

  ["prevImgOrig", "prevImgComp"].forEach((id) => {
    $(id).addEventListener("click", () => {
      const zoomed = !$(id).classList.contains("zoomed");
      $("prevImgOrig").classList.toggle("zoomed", zoomed);
      $("prevImgComp").classList.toggle("zoomed", zoomed);
    });
  });

  // ---------- JOBS MONITOR & SSE ----------
  function updateSidebarGlobalStats() {
    const runningCount = state.jobsCache.filter((j) => j.status === "running").length;
    const totalSaved = state.jobsCache.reduce((acc, j) => acc + (j.stats?.saved_bytes || 0), 0);
    const totalDoneFiles = state.jobsCache.reduce((acc, j) => acc + (j.stats?.done || 0), 0);

    $("runningBadge").textContent = String(runningCount);
    $("runningBadge").classList.toggle("hidden", runningCount === 0);
    $("jobsCountPill").textContent = String(state.jobsCache.length);
    $("totalSavedHero").textContent = fmtSize(totalSaved);
    $("totalJobsMeta").textContent = state.jobsCache.length
      ? `${state.jobsCache.length} 个任务 · 已优化 ${totalDoneFiles.toLocaleString()} 个 PDF`
      : "暂无历史任务";

    if (runningCount > 0) {
      ensureSidebarSyncTimer();
    } else {
      stopSidebarSyncTimer();
    }
  }

  function ensureSidebarSyncTimer() {
    if (state.sidebarSyncTimer) return;
    state.sidebarSyncTimer = setInterval(() => {
      if (state.jobsCache.some((j) => j.status === "running" || j.status === "created")) {
        loadJobsList({ skipAutoSelect: true, silent: true });
      } else {
        stopSidebarSyncTimer();
      }
    }, 2500);
  }

  function stopSidebarSyncTimer() {
    if (state.sidebarSyncTimer) {
      clearInterval(state.sidebarSyncTimer);
      state.sidebarSyncTimer = null;
    }
  }

  function syncSidebarItemFromDetail(job) {
    if (!job || !job.id) return;
    const st = job.stats || {};
    const idx = state.jobsCache.findIndex((j) => j.id === job.id);
    if (idx >= 0) {
      state.jobsCache[idx] = { ...state.jobsCache[idx], status: job.status, name: job.name, stats: st };
    }
    const item = $("jobsList")?.querySelector(`.job-item[data-job-id="${job.id}"]`);
    if (item) {
      const pill = item.querySelector(".js-job-status");
      if (pill) {
        pill.textContent = statusLabel(job.status);
        pill.className = `status-pill js-job-status ${statusClass(job.status)}`;
      }
      const cnt = item.querySelector(".js-job-count");
      if (cnt) {
        cnt.textContent = `${st.completed_files || 0}/${st.total_files || 0} 文件`;
      }
      const saved = item.querySelector(".js-job-saved");
      if (saved) {
        saved.textContent = `省 ${fmtSize(st.saved_bytes || 0)}`;
      }
      const bar = item.querySelector(".js-job-bar");
      if (bar) {
        bar.style.width = `${Math.min(100, st.progress_bytes_pct || 0)}%`;
      }
    }
    updateSidebarGlobalStats();
  }

  async function loadJobsList(opts = {}) {
    const reqSeq = ++state.jobsListSeq;
    try {
      const data = await api("/api/jobs?limit=50");
      if (reqSeq !== state.jobsListSeq) return;
      state.jobsCache = data.jobs || [];

      const list = $("jobsList");
      list.innerHTML = "";

      if (!state.jobsCache.length) {
        list.innerHTML = `<div class="empty-state">暂无任务</div>`;
        updateSidebarGlobalStats();
        return;
      }

      state.jobsCache.forEach((j) => {
        const el = document.createElement("div");
        el.className = `job-item ${j.id === state.activeJobId ? "active" : ""}`;
        el.dataset.jobId = j.id;
        const st = j.stats || {};
        const pct = Math.min(100, st.progress_bytes_pct || 0);
        el.innerHTML = `
          <div class="job-item-top">
            <span class="job-item-name" title="${j.name}">${j.name}</span>
            <span class="status-pill js-job-status ${statusClass(j.status)}">${statusLabel(j.status)}</span>
          </div>
          <div class="job-item-sub">
            <span class="js-job-count">${st.completed_files || 0}/${st.total_files || 0} 文件</span>
            <span class="text-success js-job-saved">省 ${fmtSize(st.saved_bytes || 0)}</span>
          </div>
          <div class="mini-progress">
            <div class="mini-progress-fill js-job-bar" style="width: ${pct}%"></div>
          </div>
        `;
        el.addEventListener("click", () => selectJob(j.id));
        list.appendChild(el);
      });

      updateSidebarGlobalStats();

      if (!opts.skipAutoSelect && !state.activeJobId && state.jobsCache.length > 0) {
        selectJob(state.jobsCache[0].id);
      }
    } catch (err) {
      if (!opts.silent) toast(err.message, "error");
    }
  }

  function closeStream() {
    if (state.eventSource) {
      state.eventSource.close();
      state.eventSource = null;
    }
    if (state.pollTimer) {
      clearTimeout(state.pollTimer);
      state.pollTimer = null;
    }
  }

  async function selectJob(jobId) {
    closeStream();
    state.activeJobId = jobId;
    state.filePage = 1;
    document.querySelectorAll(".job-item").forEach((el) => {
      el.classList.toggle("active", el.dataset.jobId === jobId);
    });

    try {
      const [detail] = await Promise.all([
        api(`/api/jobs/${jobId}`),
        loadJobsList({ skipAutoSelect: true }),
      ]);
      if (state.activeJobId !== jobId) return;
      renderJobDetail(detail);
      loadJobFiles();

      if (["running", "created"].includes(detail.status)) {
        connectJobStream(jobId);
      }
    } catch (err) {
      toast(err.message, "error");
    }
  }

  let lastTableRefresh = 0;
  let lastSidebarRefresh = 0;

  function startFallbackPolling(jobId) {
    if (state.pollTimer) clearTimeout(state.pollTimer);
    const poll = async () => {
      if (state.activeJobId !== jobId) return;
      try {
        const detail = await api(`/api/jobs/${jobId}`);
        if (state.activeJobId !== jobId) return;
        renderJobDetail(detail);
        loadJobFiles();
        if (["completed", "cancelled", "failed", "paused"].includes(detail.status)) {
          closeStream();
          loadJobsList({ skipAutoSelect: true });
          return;
        }
      } catch {}
      if (state.activeJobId === jobId) {
        state.pollTimer = setTimeout(poll, 1200);
      }
    };
    state.pollTimer = setTimeout(poll, 800);
  }

  function connectJobStream(jobId) {
    closeStream();
    const es = new EventSource(`/api/jobs/${jobId}/stream`);
    state.eventSource = es;
    es.onmessage = (ev) => {
      if (state.activeJobId !== jobId) {
        closeStream();
        return;
      }
      try {
        const detail = JSON.parse(ev.data);
        renderJobDetail(detail);
        const now = Date.now();
        if (now - lastTableRefresh > 1500 || detail.status !== "running") {
          lastTableRefresh = now;
          loadJobFiles();
        }
        if (now - lastSidebarRefresh > 2500) {
          lastSidebarRefresh = now;
          loadJobsList({ skipAutoSelect: true, silent: true });
        }
        if (["completed", "cancelled", "failed", "paused"].includes(detail.status)) {
          closeStream();
          loadJobsList({ skipAutoSelect: true });
          loadJobFiles();
        }
      } catch {}
    };
    es.onerror = () => {
      if (state.eventSource === es) {
        es.close();
        state.eventSource = null;
        if (state.activeJobId === jobId) {
          startFallbackPolling(jobId);
        }
      }
    };
  }

  function renderJobDetail(job) {
    state.activeJobDetail = job;
    syncSidebarItemFromDetail(job);
    $("jobEmptyState").classList.add("hidden");
    $("jobDetailContent").classList.remove("hidden");

    const st = job.stats || {};
    const live = job.live || {};

    $("jdName").textContent = job.name;
    $("jdStatusBadge").textContent = statusLabel(job.status);
    $("jdStatusBadge").className = `status-pill ${statusClass(job.status)}`;
    $("jdModeBadge").textContent =
      job.source_type === "upload"
        ? "批量上传"
        : job.output_mode === "inplace"
        ? "原地覆盖优化"
        : "输出到新目录";

    const pathParts = [`源: ${job.source_dir}`];
    if (job.output_dir) pathParts.push(`输出: ${job.output_dir}`);
    if (job.backup_dir) pathParts.push(`备份: ${job.backup_dir}`);
    $("jdPaths").textContent = pathParts.join("  |  ");

    $("jdPauseBtn").classList.toggle("hidden", job.status !== "running");
    $("jdResumeBtn").classList.toggle("hidden", !["paused", "created"].includes(job.status));
    $("jdRetryBtn").classList.toggle("hidden", !(st.failed > 0 && job.status !== "running"));
    $("jdCancelBtn").classList.toggle("hidden", !["running", "paused", "created"].includes(job.status));
    $("jdDeleteBtn").classList.toggle("hidden", job.status === "running");

    const showZip = job.source_type === "upload" && st.done + st.skipped > 0;
    $("jdDownloadZipBtn").classList.toggle("hidden", !showZip);
    if (showZip) $("jdDownloadZipBtn").href = `/api/jobs/${job.id}/download-zip`;

    $("jdPctBytes").textContent = `${st.progress_bytes_pct ?? 0}%`;
    $("jdFileProgress").textContent = `${(st.completed_files || 0).toLocaleString()} / ${(st.total_files || 0).toLocaleString()}`;
    $("jdProgressBar").style.width = `${Math.min(100, st.progress_bytes_pct || 0)}%`;

    $("jdSavedBytes").textContent = fmtSize(st.saved_bytes || 0);
    $("jdSavedPct").textContent = `压缩率 -${st.saving_percent || 0}%`;
    $("jdProcessedSize").textContent = `${fmtSize(st.processed_orig_bytes || 0)} → ${fmtSize(st.processed_new_bytes || 0)}`;
    $("jdTotalOrigSize").textContent = `总计 ${fmtSize(st.total_orig_bytes || 0)}`;
    $("jdSpeed").textContent = `${fmtSize(live.bytes_per_sec || 0)}/s`;
    $("jdEta").textContent = job.status === "running" ? `预计剩余: ${fmtEta(live.eta_seconds)}` : `状态: ${statusLabel(job.status)}`;
    $("jdDoneCount").textContent = (st.done || 0).toLocaleString();
    $("jdSkipCount").textContent = (st.skipped || 0).toLocaleString();
    $("jdImagesCount").textContent = `优化图片: ${(st.images_optimized || 0).toLocaleString()} 张`;
    $("jdPendingCount").textContent = (st.pending || 0).toLocaleString();
    $("jdFailedCount").textContent = (st.failed || 0).toLocaleString();
    $("jdProcessingCount").textContent = `处理中: ${st.processing || 0}`;

    const active = live.active_files || [];
    $("jdActiveFilesWrap").classList.toggle("hidden", active.length === 0);
    if (active.length) {
      $("jdActiveFilesList").innerHTML = active
        .slice(0, 8)
        .map((f) => `<span class="chip chip-accent" title="${f}">${f.split(/[\\/]/).pop()}</span>`)
        .join("");
    }
  }

  async function loadJobFiles() {
    if (!state.activeJobId) return;
    const [sortBy, sortDir] = state.fileSort.split(":");
    const params = new URLSearchParams({
      status: state.fileFilter,
      search: state.fileSearch,
      sort_by: sortBy,
      sort_dir: sortDir,
      page: String(state.filePage),
      page_size: "50",
    });
    try {
      const data = await api(`/api/jobs/${state.activeJobId}/files?${params}`);
      const tbody = $("filesTableBody");
      tbody.innerHTML = "";
      if (!data.items.length) {
        tbody.innerHTML = `<tr><td colspan="7" class="empty-state">暂无匹配文件</td></tr>`;
      } else {
        data.items.forEach((f) => {
          const pct =
            f.orig_size > 0 && f.saved_bytes > 0
              ? `-${((f.saved_bytes / f.orig_size) * 100).toFixed(1)}%`
              : "-";
          const tr = document.createElement("tr");
          tr.innerHTML = `
            <td class="file-path-cell" title="${f.rel_path}">${f.rel_path}</td>
            <td>${fmtSize(f.orig_size)}</td>
            <td>${f.new_size !== null ? fmtSize(f.new_size) : "-"}</td>
            <td class="${f.saved_bytes > 0 ? "text-success" : "text-muted"}">${f.saved_bytes > 0 ? `${fmtSize(f.saved_bytes)} (${pct})` : "-"}</td>
            <td>${f.duration_ms !== null ? `${(f.duration_ms / 1000).toFixed(2)}s` : "-"}</td>
            <td>
              <span class="status-pill ${statusClass(f.status)}" title="${f.error || ""}">${statusLabel(f.status)}</span>
              ${f.error ? `<div class="text-danger small-text" title="${f.error}">${f.error.slice(0, 40)}</div>` : ""}
            </td>
            <td>
              <a class="btn btn-ghost btn-sm" href="/api/jobs/${state.activeJobId}/files/${f.id}/download" target="_blank">下载</a>
            </td>
          `;
          tbody.appendChild(tr);
        });
      }
      $("filesPageInfo").textContent = `第 ${data.page} / ${data.total_pages} 页（共 ${data.total.toLocaleString()} 条）`;
      $("prevPageBtn").disabled = data.page <= 1;
      $("nextPageBtn").disabled = data.page >= data.total_pages;
    } catch {}
  }

  // Job control buttons
  $("jdPauseBtn").addEventListener("click", async () => {
    if (!state.activeJobId) return;
    await api(`/api/jobs/${state.activeJobId}/pause`, { method: "POST" });
    toast("已发送暂停指令，等待当前正在处理的文件安全落盘后暂停");
  });
  $("jdResumeBtn").addEventListener("click", async () => {
    if (!state.activeJobId) return;
    await api(`/api/jobs/${state.activeJobId}/start`, { method: "POST" });
    toast("任务已继续执行", "success");
    connectJobStream(state.activeJobId);
    loadJobsList({ skipAutoSelect: true });
  });
  $("jdRetryBtn").addEventListener("click", async () => {
    if (!state.activeJobId) return;
    const res = await api(`/api/jobs/${state.activeJobId}/retry-failed`, { method: "POST" });
    toast(`已将 ${res.retried} 个失败文件重新加入队列`, "success");
    connectJobStream(state.activeJobId);
    loadJobsList({ skipAutoSelect: true });
  });
  $("jdCancelBtn").addEventListener("click", async () => {
    if (!state.activeJobId) return;
    if (!(await showConfirm("确定要取消当前任务吗？（已完成的文件不受影响）", "确认取消任务"))) return;
    await api(`/api/jobs/${state.activeJobId}/cancel`, { method: "POST" });
    toast("任务已取消");
    loadJobsList({ skipAutoSelect: true });
  });
  $("jdOpenDirBtn").addEventListener("click", async () => {
    const j = state.activeJobDetail;
    if (!j) return;
    const target = j.output_dir || j.source_dir;
    try {
      await api("/api/fs/open-folder", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ path: target }),
      });
    } catch (err) {
      toast(err.message, "error");
    }
  });
  $("jdDeleteBtn").addEventListener("click", async () => {
    if (!state.activeJobId) return;
    if (!(await showConfirm("仅删除任务历史记录（不会删除你的原 PDF 文件），确定吗？", "确认删除记录"))) return;
    await api(`/api/jobs/${state.activeJobId}?delete_upload_files=false`, { method: "DELETE" });
    state.activeJobId = null;
    $("jobDetailContent").classList.add("hidden");
    $("jobEmptyState").classList.remove("hidden");
    loadJobsList();
    toast("任务记录已删除");
  });

  // Table filters
  $("fileStatusFilters").querySelectorAll(".filter-pill").forEach((pill) => {
    pill.addEventListener("click", () => {
      state.fileFilter = pill.dataset.status;
      state.filePage = 1;
      $("fileStatusFilters").querySelectorAll(".filter-pill").forEach((p) => p.classList.toggle("active", p === pill));
      loadJobFiles();
    });
  });

  let searchTimer = null;
  $("fileSearchInput").addEventListener("input", (e) => {
    clearTimeout(searchTimer);
    searchTimer = setTimeout(() => {
      state.fileSearch = e.target.value.trim();
      state.filePage = 1;
      loadJobFiles();
    }, 250);
  });

  $("fileSortSelect").addEventListener("change", (e) => {
    state.fileSort = e.target.value;
    state.filePage = 1;
    loadJobFiles();
  });

  $("prevPageBtn").addEventListener("click", () => {
    if (state.filePage > 1) {
      state.filePage--;
      loadJobFiles();
    }
  });
  $("nextPageBtn").addEventListener("click", () => {
    state.filePage++;
    loadJobFiles();
  });
  $("refreshJobsBtn").addEventListener("click", () => loadJobsList({ skipAutoSelect: true }));

  $("clearFpBtn").addEventListener("click", async () => {
    if (!(await showConfirm("清空「已优化文件缓存」后，再次扫描目录时会重新处理之前压缩过的 PDF。确定清空吗？", "确认清空缓存"))) return;
    const res = await api("/api/fingerprints/clear", { method: "POST" });
    toast(`已清空 ${res.removed} 条历史跳过指纹`, "success");
  });

  // ---------- DESKTOP BRIDGE (pywebview) ----------
  function initDesktopBridge() {
    const btn = $("openInBrowserBtn");
    if (!btn) return;
    if (window.pywebview?.api?.open_in_browser) {
      btn.classList.remove("hidden");
    }
    btn.addEventListener("click", async () => {
      try {
        if (window.pywebview?.api?.open_in_browser) {
          await window.pywebview.api.open_in_browser();
        }
      } catch (err) {
        toast(err.message || "打开浏览器失败", "error");
      }
    });
  }

  window.addEventListener("pywebviewready", () => {
    const btn = $("openInBrowserBtn");
    if (btn && window.pywebview?.api?.open_in_browser) {
      btn.classList.remove("hidden");
    }
  });

  // ---------- INIT ----------
  async function init() {
    initDesktopBridge();
    try {
      const sys = await api("/api/system");
      state.system = sys;
      $("cpuBadgeText").textContent = `${sys.cpu_count} 核 CPU · 推荐 ${sys.recommended_workers} 进程`;
      $("cfgWorkers").max = String(Math.max(1, sys.cpu_count));
      $("cfgWorkers").value = String(sys.recommended_workers);
      $("cfgWorkersVal").textContent = String(sys.recommended_workers);
      renderPresets(sys.presets);
      applyConfigToUI(sys.presets.balanced.config, "balanced");
      updateWorkbenchSummary();
      loadJobsList();
    } catch (err) {
      toast(`初始化失败: ${err.message}`, "error");
    }
  }

  init();
})();
