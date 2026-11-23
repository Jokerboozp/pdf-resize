import SwiftUI
import AppKit

// MARK: - Native AppKit Vibrancy Backdrop (for macOS 14/15 + ambient depth)

public struct VisualEffectBlur: NSViewRepresentable {
    public var material: NSVisualEffectView.Material
    public var blendingMode: NSVisualEffectView.BlendingMode
    public var state: NSVisualEffectView.State

    public init(
        material: NSVisualEffectView.Material = .hudWindow,
        blendingMode: NSVisualEffectView.BlendingMode = .withinWindow,
        state: NSVisualEffectView.State = .active
    ) {
        self.material = material
        self.blendingMode = blendingMode
        self.state = state
    }

    public func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = state
        view.isEmphasized = true
        return view
    }

    public func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
        nsView.state = state
    }
}

// MARK: - Apple HIG Liquid Glass Modifiers & Containers

public enum GlassProminence {
    case regular
    case clear
    case prominentTint(Color)
}

/// Applies genuine macOS 26 Liquid Glass (`glassEffect`) when built with Xcode 26+ on macOS 26+,
/// and seamlessly renders a refractive multi-layer specular glass surface on macOS 14/15.
public struct LiquidGlassModifier<S: InsettableShape>: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    public let shape: S
    public let prominence: GlassProminence
    public let interactive: Bool

    @State private var isHovered = false

    public init(shape: S, prominence: GlassProminence = .regular, interactive: Bool = false) {
        self.shape = shape
        self.prominence = prominence
        self.interactive = interactive
    }

    public func body(content: Content) -> some View {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            nativeLiquidGlass(content)
        } else {
            refractiveFallbackGlass(content)
        }
        #else
        refractiveFallbackGlass(content)
        #endif
    }

    #if compiler(>=6.2)
    @available(macOS 26.0, *)
    @ViewBuilder
    private func nativeLiquidGlass(_ content: Content) -> some View {
        switch prominence {
        case .regular:
            if interactive {
                content.glassEffect(.regular.interactive(), in: shape)
            } else {
                content.glassEffect(.regular, in: shape)
            }
        case .clear:
            if interactive {
                content.glassEffect(.clear.interactive(), in: shape)
            } else {
                content.glassEffect(.clear, in: shape)
            }
        case .prominentTint(let tintColor):
            if interactive {
                content.glassEffect(.regular.tint(tintColor).interactive(), in: shape)
            } else {
                content.glassEffect(.regular.tint(tintColor), in: shape)
            }
        }
    }
    #endif

    @ViewBuilder
    private func refractiveFallbackGlass(_ content: Content) -> some View {
        let topRimOpacity: Double = colorScheme == .dark ? (isHovered ? 0.42 : 0.30) : (isHovered ? 0.85 : 0.68)
        let midRimOpacity: Double = colorScheme == .dark ? 0.06 : 0.20
        let bottomRimOpacity: Double = colorScheme == .dark ? 0.18 : 0.42

        content
            .background {
                ZStack {
                    // Base optical blur layer
                    shape
                        .fill(prominenceFillStyle)

                    // Subtle top caustic meniscus sheen
                    shape
                        .fill(
                            LinearGradient(
                                colors: [
                                    Color.white.opacity(colorScheme == .dark ? (isHovered ? 0.14 : 0.09) : (isHovered ? 0.55 : 0.40)),
                                    Color.white.opacity(0.01),
                                    Color.black.opacity(colorScheme == .dark ? 0.12 : 0.02)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )

                    if case .prominentTint(let tint) = prominence {
                        shape.fill(tint.opacity(colorScheme == .dark ? 0.22 : 0.15))
                    }
                }
            }
            .overlay {
                // Specular refractive rim highlight
                shape
                    .strokeBorder(
                        LinearGradient(
                            stops: [
                                .init(color: .white.opacity(topRimOpacity), location: 0.0),
                                .init(color: .white.opacity(midRimOpacity), location: 0.48),
                                .init(color: .white.opacity(bottomRimOpacity), location: 1.0)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 0.85
                    )
            }
            .shadow(
                color: Color.black.opacity(colorScheme == .dark ? 0.28 : 0.08),
                radius: isHovered && interactive ? 16 : 11,
                x: 0,
                y: isHovered && interactive ? 8 : 5
            )
            .scaleEffect(interactive && isHovered ? 1.008 : 1.0)
            .animation(.spring(response: 0.26, dampingFraction: 0.78), value: isHovered)
            .onHover { hovering in
                if interactive {
                    isHovered = hovering
                }
            }
    }

    private var prominenceFillStyle: AnyShapeStyle {
        switch prominence {
        case .clear:
            return AnyShapeStyle(.ultraThinMaterial)
        case .regular, .prominentTint:
            return AnyShapeStyle(.thinMaterial)
        }
    }
}

public extension View {
    func liquidGlass<S: InsettableShape>(
        in shape: S,
        prominence: GlassProminence = .regular,
        interactive: Bool = false
    ) -> some View {
        modifier(LiquidGlassModifier(shape: shape, prominence: prominence, interactive: interactive))
    }

    func liquidGlassCard(cornerRadius: CGFloat = 16, interactive: Bool = false) -> some View {
        liquidGlass(
            in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous),
            prominence: .regular,
            interactive: interactive
        )
    }

    func liquidGlassCapsule(prominence: GlassProminence = .regular, interactive: Bool = false) -> some View {
        liquidGlass(in: Capsule(style: .continuous), prominence: prominence, interactive: interactive)
    }
}

/// Groups multiple Liquid Glass controls so they optically morph & share refraction on macOS 26+.
public struct AdaptiveGlassGroup<Content: View>: View {
    public var spacing: CGFloat
    @ViewBuilder public var content: () -> Content

    public init(spacing: CGFloat = 14, @ViewBuilder content: @escaping () -> Content) {
        self.spacing = spacing
        self.content = content
    }

    public var body: some View {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) {
                content()
            }
        } else {
            content()
        }
        #else
        content()
        #endif
    }
}

/// Adaptive button style using native `.glass` / `.glassProminent` on macOS 26+,
/// and tactile translucent capsule buttons on macOS 14/15.
public struct AdaptiveGlassButtonModifier: ViewModifier {
    public let prominent: Bool

    public init(prominent: Bool = false) {
        self.prominent = prominent
    }

    public func body(content: Content) -> some View {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            if prominent {
                content.buttonStyle(.glassProminent)
            } else {
                content.buttonStyle(.glass)
            }
        } else {
            fallbackButton(content)
        }
        #else
        fallbackButton(content)
        #endif
    }

    @ViewBuilder
    private func fallbackButton(_ content: Content) -> some View {
        if prominent {
            content.buttonStyle(.borderedProminent)
        } else {
            content.buttonStyle(.bordered)
        }
    }
}

public extension View {
    func adaptiveGlassButton(prominent: Bool = false) -> some View {
        modifier(AdaptiveGlassButtonModifier(prominent: prominent))
    }
}

/// Subtle Apple-HIG ambient luminous canvas background so Liquid Glass layers refract soft depth
/// while respecting both Light and Dark system appearances.
public struct AmbientGlassCanvasBackground: View {
    @Environment(\.colorScheme) private var colorScheme

    public init() {}

    public var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)

            GeometryReader { geo in
                ZStack {
                    Circle()
                        .fill(Color.accentColor.opacity(colorScheme == .dark ? 0.13 : 0.08))
                        .frame(width: geo.size.width * 0.55, height: geo.size.width * 0.55)
                        .blur(radius: 95)
                        .offset(x: -geo.size.width * 0.18, y: -geo.size.height * 0.22)

                    Circle()
                        .fill(Color.cyan.opacity(colorScheme == .dark ? 0.10 : 0.07))
                        .frame(width: geo.size.width * 0.45, height: geo.size.width * 0.45)
                        .blur(radius: 90)
                        .offset(x: geo.size.width * 0.26, y: geo.size.height * 0.24)

                    Circle()
                        .fill(Color.mint.opacity(colorScheme == .dark ? 0.07 : 0.05))
                        .frame(width: geo.size.width * 0.35, height: geo.size.width * 0.35)
                        .blur(radius: 80)
                        .offset(x: geo.size.width * 0.10, y: -geo.size.height * 0.28)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .ignoresSafeArea()
    }
}
