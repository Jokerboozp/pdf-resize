(() => {
  const state = {
    system: null,
    sourceMode: "local", // local | upload
    outputMode: "inplace", // inplace | output_dir
    selectedPreset: "balanced",
    localSourceDirs: [], // string[]
    folderScanStats: {}, // path -> { total_files, total_bytes, pending_count }
    uploadQueue: [], // [{ file, relPath }]
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
    if (st.startsWith("skipped_")) return "status-skipped";
    return `status-${st}`;
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

  // ---------- NAVIGATION ----------
  function switchTab(tabName, opts = {}) {
    document.querySelectorAll(".nav-tab").forEach((b) => {
      b.classList.toggle("active", b.dataset.tab === tabName);
    });
    document.querySelectorAll(".tab-panel").forEach((p) => {
      p.classList.toggle("active", p.id === `tab-${tabName}`);
    });
    if (tabName === "jobs" && !opts.skipLoad) {
      loadJobsList();
    }
  }

  document.querySelectorAll(".nav-tab").forEach((btn) => {
    btn.addEventListener("click", () => switchTab(btn.dataset.tab));
  });

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
    const presetInfo = state.system?.presets?.[state.selectedPreset];
    $("currentPresetChip").textContent = presetInfo ? presetInfo.label : "自定义参数";
  }

  function markCustomPreset() {
    state.selectedPreset = "custom";
    updatePresetHighlight();
  }

  function renderPresets(presets) {
    const grid = $("presetGrid");
    grid.innerHTML = "";
    Object.entries(presets).forEach(([key, info]) => {
      const btn = document.createElement("button");
      btn.type = "button";
      btn.className = `preset-card ${key === state.selectedPreset ? "active" : ""}`;
      btn.dataset.preset = key;
      btn.innerHTML = `<strong>${info.label}</strong><span>${info.description}</span>`;
      btn.addEventListener("click", () => applyConfigToUI(info.config, key));
      grid.appendChild(btn);
    });
  }

  // Slider listeners
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
  });
  ["cfgCompressImages", "cfgDownsample", "cfgGrayscale", "cfgOptimizeTransparent", "cfgSubsetFonts", "cfgStripMetadata", "cfgUseQpdf"].forEach((id) => {
    $(id).addEventListener("change", () => {
      syncImageControlsDisabled();
      markCustomPreset();
    });
  });

  // ---------- SOURCE & OUTPUT SWITCH ----------
  $("sourceModeSwitch").querySelectorAll(".seg-btn").forEach((btn) => {
    btn.addEventListener("click", () => {
      state.sourceMode = btn.dataset.mode;
      $("sourceModeSwitch").querySelectorAll(".seg-btn").forEach((b) => b.classList.toggle("active", b === btn));
      $("sourceLocalPanel").classList.toggle("hidden", state.sourceMode !== "local");
      $("sourceUploadPanel").classList.toggle("hidden", state.sourceMode !== "upload");
      updateLaunchButtonLabel();
    });
  });

  document.querySelectorAll(".radio-card").forEach((card) => {
    card.addEventListener("click", () => {
      state.outputMode = card.dataset.output;
      document.querySelectorAll(".radio-card").forEach((c) => c.classList.toggle("active", c === card));
      card.querySelector("input").checked = true;
      $("backupDirGroup").classList.toggle("hidden", state.outputMode !== "inplace");
      $("outputDirGroup").classList.toggle("hidden", state.outputMode !== "output_dir");
      updateLaunchButtonLabel();
    });
  });

  function updateLaunchButtonLabel() {
    if (state.sourceMode === "upload") {
      $("startJobBtn").textContent = "开始上传并批量压缩";
    } else if (state.outputMode === "inplace") {
      $("startJobBtn").textContent = "开始原地批量优化";
    } else {
      $("startJobBtn").textContent = "开始批量压缩到新目录";
    }
  }

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
    renderLocalSourceDirs();
    return added;
  }

  function removeLocalSourceDir(idx) {
    const [removed] = state.localSourceDirs.splice(idx, 1);
    if (removed) delete state.folderScanStats[removed];
    renderLocalSourceDirs();
  }

  function collectLocalSourceDirs() {
    const inputVal = $("localSourceDir").value.trim();
    if (inputVal) {
      // Allow pasting multiple paths separated by newlines
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
        ? `已添加 ${count} 个源文件夹（支持继续追加，自动递归子目录与去重）`
        : "已添加 0 个文件夹（可点击「浏览添加」「系统多选」，或直接粘贴路径回车添加）";

    const list = $("sourceDirsList");
    list.innerHTML = "";
    state.localSourceDirs.forEach((dirPath, idx) => {
      const st = state.folderScanStats[dirPath];
      const metaText = st ? `${st.total_files.toLocaleString()} 个 PDF · ${fmtSize(st.total_bytes)}` : "";
      const row = document.createElement("div");
      row.className = "source-dir-item";
      row.innerHTML = `
        <span class="source-dir-path" title="${dirPath}">📁 ${dirPath}</span>
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
    if (added > 0) {
      toast(`已添加 ${added} 个文件夹，正在自动扫描...`, "success");
      scanLocalDirectory();
    } else {
      scanLocalDirectory();
    }
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
    renderLocalSourceDirs();
    $("scanResultBox").classList.add("hidden");
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
        div.innerHTML = `<span>${ent.is_drive ? "💾" : "📁"}</span><span>${ent.name}</span>`;
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
    let shouldScan = false;
    if (state.folderCurrentPath) {
      if (state.folderModalAppendSource) {
        const added = addLocalSourceDirs([state.folderCurrentPath]);
        if (added > 0) toast("已添加文件夹，正在自动扫描...", "success");
        shouldScan = true;
      } else if (state.folderModalTargetInput) {
        state.folderModalTargetInput.value = state.folderCurrentPath;
      }
    }
    $("folderModal").classList.add("hidden");
    if (shouldScan) {
      scanLocalDirectory();
    }
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
    $("scanDirBtn").textContent = "扫描中...";
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
      // Update canonical resolved paths and per-folder stats
      if (Array.isArray(data.folders) && data.folders.length) {
        state.localSourceDirs = data.folders.map((f) => f.path);
        state.folderScanStats = {};
        data.folders.forEach((f) => {
          state.folderScanStats[f.path] = f;
        });
        renderLocalSourceDirs();
      }

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
      toast(
        `扫描完成：${data.folders?.length || paths.length} 个目录共发现 ${data.total_files} 个 PDF（${fmtSize(data.total_bytes)}）`,
        "success"
      );
    } catch (err) {
      toast(err.message, "error");
    } finally {
      $("scanDirBtn").disabled = false;
      $("scanDirBtn").textContent = "扫描统计";
    }
  }

  $("scanDirBtn").addEventListener("click", scanLocalDirectory);
  $("quickPreviewSampleBtn").addEventListener("click", () => {
    const sample = $("scanSampleSelect").value;
    if (!sample) return;
    $("previewLocalPath").value = sample;
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
    if (added > 0) {
      toast(`已添加 ${added} 个 PDF 到待上传队列，请点击右侧「开始上传并批量压缩」`, "success");
    } else if (items.length > 0) {
      toast("所选内容中未发现 .pdf 文件", "error");
    }
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
    // IMPORTANT: Extract entries/files synchronously before any await, because
    // browsers clear DataTransferItemList as soon as the event handler yields.
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
      const ok = await showConfirm(
        `即将以【原地覆盖】模式直接优化 ${sourceDirs.length} 个目录中的 PDF 文件（未设置备份目录）。\n\n程序已启用同盘原子写入与页数完整性校验，变大文件会自动放弃覆盖。\n确定开始吗？`,
        "确认原地覆盖优化"
      );
      if (!ok) return;
    }

    $("startJobBtn").disabled = true;
    // Close any prior SSE stream before creating a new job to free browser HTTP connection slots
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
      // Ensure job is running / picks up final uploaded files
      await api(`/api/jobs/${job.id}/start`, { method: "POST" });

      state.uploadQueue = [];
      renderUploadQueue();
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

  // ---------- SINGLE FILE PREVIEW ----------
  function showPreviewResult(data) {
    $("prevOrigSize").textContent = fmtSize(data.orig_size);
    $("prevNewSize").textContent = fmtSize(data.new_size);
    $("prevSaved").textContent = `${fmtSize(data.saved_bytes)} (-${data.saving_percent}%)`;
    $("prevMeta").textContent = `${statusLabel(data.status)} · ${data.duration_ms}ms · 优化 ${data.images_optimized} 图`;
    const pText = `第 ${data.rendered_page + 1} / ${data.pages} 页`;
    $("prevPageLabelOrig").textContent = pText;
    $("prevPageLabelComp").textContent = pText;
    $("prevImgOrig").src = data.orig_image_url;
    $("prevImgComp").src = data.comp_image_url;
    $("prevImgOrig").classList.remove("zoomed");
    $("prevImgComp").classList.remove("zoomed");
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
    } finally {
      $("runLocalPreviewBtn").disabled = false;
      $("previewLoading").classList.add("hidden");
    }
  }

  $("runLocalPreviewBtn").addEventListener("click", runLocalPreview);
  $("previewUploadInput").addEventListener("change", async (e) => {
    const file = e.target.files?.[0];
    if (!file) return;
    const page = Math.max(0, (Number($("previewPageNum").value) || 1) - 1);
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
    } finally {
      $("previewLoading").classList.add("hidden");
      e.target.value = "";
    }
  });

  ["prevImgOrig", "prevImgComp"].forEach((id) => {
    $(id).addEventListener("click", () => {
      const zoomed = !$(id).classList.contains("zoomed");
      $("prevImgOrig").classList.toggle("zoomed", zoomed);
      $("prevImgComp").classList.toggle("zoomed", zoomed);
    });
  });

  // ---------- JOBS MONITOR & SSE ----------
  function updateRunningBadgeFromCache() {
    const runningCount = state.jobsCache.filter((j) => j.status === "running").length;
    $("runningBadge").textContent = String(runningCount);
    $("runningBadge").classList.toggle("hidden", runningCount === 0);
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
        loadJobsList({ skipAutoSelect: true });
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
    }
    updateRunningBadgeFromCache();
  }

  async function loadJobsList(opts = {}) {
    const reqSeq = ++state.jobsListSeq;
    try {
      const data = await api("/api/jobs?limit=50");
      if (reqSeq !== state.jobsListSeq) return; // Discard stale out-of-order response
      state.jobsCache = data.jobs || [];

      const list = $("jobsList");
      list.innerHTML = "";

      if (!state.jobsCache.length) {
        list.innerHTML = `<div class="empty-state">暂无任务</div>`;
        updateRunningBadgeFromCache();
        return;
      }

      state.jobsCache.forEach((j) => {
        const el = document.createElement("div");
        el.className = `job-item ${j.id === state.activeJobId ? "active" : ""}`;
        el.dataset.jobId = j.id;
        const st = j.stats || {};
        el.innerHTML = `
          <div class="job-item-top">
            <span class="job-item-name" title="${j.name}">${j.name}</span>
            <span class="status-pill js-job-status ${statusClass(j.status)}">${statusLabel(j.status)}</span>
          </div>
          <div class="job-item-sub">
            <span class="js-job-count">${st.completed_files || 0}/${st.total_files || 0} 文件</span>
            <span class="text-success js-job-saved">省 ${fmtSize(st.saved_bytes || 0)}</span>
          </div>
        `;
        el.addEventListener("click", () => selectJob(j.id));
        list.appendChild(el);
      });

      updateRunningBadgeFromCache();

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
        // Seamless fallback polling so UI never freezes if SSE drops
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

    // Controls visibility
    $("jdPauseBtn").classList.toggle("hidden", job.status !== "running");
    $("jdResumeBtn").classList.toggle("hidden", !["paused", "created"].includes(job.status));
    $("jdRetryBtn").classList.toggle("hidden", !(st.failed > 0 && job.status !== "running"));
    $("jdCancelBtn").classList.toggle("hidden", !["running", "paused", "created"].includes(job.status));
    $("jdDeleteBtn").classList.toggle("hidden", job.status === "running");

    const showZip = job.source_type === "upload" && st.done + st.skipped > 0;
    $("jdDownloadZipBtn").classList.toggle("hidden", !showZip);
    if (showZip) $("jdDownloadZipBtn").href = `/api/jobs/${job.id}/download-zip`;

    // Progress
    $("jdPctBytes").textContent = `${st.progress_bytes_pct ?? 0}%`;
    $("jdFileProgress").textContent = `${(st.completed_files || 0).toLocaleString()} / ${(st.total_files || 0).toLocaleString()}`;
    $("jdProgressBar").style.width = `${Math.min(100, st.progress_bytes_pct || 0)}%`;

    // KPIs
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

    // Active files chips
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
    loadJobsList();
  });
  $("jdRetryBtn").addEventListener("click", async () => {
    if (!state.activeJobId) return;
    const res = await api(`/api/jobs/${state.activeJobId}/retry-failed`, { method: "POST" });
    toast(`已将 ${res.retried} 个失败文件重新加入队列`, "success");
    connectJobStream(state.activeJobId);
    loadJobsList();
  });
  $("jdCancelBtn").addEventListener("click", async () => {
    if (!state.activeJobId) return;
    if (!(await showConfirm("确定要取消当前任务吗？（已完成的文件不受影响）", "确认取消任务"))) return;
    await api(`/api/jobs/${state.activeJobId}/cancel`, { method: "POST" });
    toast("任务已取消");
    loadJobsList();
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

  // Table filter/search/sort/pagination
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
  $("refreshJobsBtn").addEventListener("click", loadJobsList);

  $("clearFpBtn").addEventListener("click", async () => {
    if (!(await showConfirm("清空「已优化文件缓存」后，再次扫描目录时会重新处理之前压缩过的 PDF。确定清空吗？", "确认清空缓存"))) return;
    const res = await api("/api/fingerprints/clear", { method: "POST" });
    toast(`已清空 ${res.removed} 条历史跳过指纹`, "success");
  });

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
      $("cpuBadge").textContent = `${sys.cpu_count} 核 CPU · 推荐 ${sys.recommended_workers} 进程`;
      $("cfgWorkers").max = String(Math.max(1, sys.cpu_count));
      $("cfgWorkers").value = String(sys.recommended_workers);
      $("cfgWorkersVal").textContent = String(sys.recommended_workers);
      renderPresets(sys.presets);
      applyConfigToUI(sys.presets.balanced.config, "balanced");
      updateLaunchButtonLabel();
      loadJobsList();
    } catch (err) {
      toast(`初始化失败: ${err.message}`, "error");
    }
  }

  init();
})();
