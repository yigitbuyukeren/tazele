import SwiftUI
import TazeleCore

enum Theme {
    static let brandTop = Color(red: 0.13, green: 0.78, blue: 0.66)
    static let brandBottom = Color(red: 0.04, green: 0.46, blue: 0.52)
    static var brand: LinearGradient {
        LinearGradient(colors: [brandTop, brandBottom], startPoint: .topLeading, endPoint: .bottomTrailing)
    }
    static let corner: CGFloat = 14
    /// Varsayılan yay: kritik sönümlü (taşma yok), kesilebilir. Geri dönüşlerde hızı korur.
    static let spring = Animation.spring(response: 0.35, dampingFraction: 1.0)
    /// Momentum taşıyan etkileşimler için hafif sıçrama.
    static let springBouncy = Animation.spring(response: 0.35, dampingFraction: 0.8)
}

/// Yüzey "malzeme gibi" belirir: blur + ölçek birlikte canlanır, sadece solmaz.
struct MaterializeModifier: ViewModifier {
    let progress: Double
    func body(content: Content) -> some View {
        content
            .blur(radius: (1 - progress) * 8)
            .scaleEffect(0.97 + 0.03 * progress, anchor: .top)
            .opacity(progress)
    }
}

extension AnyTransition {
    static var materialize: AnyTransition {
        .modifier(active: MaterializeModifier(progress: 0), identity: MaterializeModifier(progress: 1))
    }
}

extension SourceKind {
    var symbol: String {
        switch self {
        case .homebrewFormula: "shippingbox.fill"
        case .homebrewCask: "macwindow"
        case .selfUpdatingCask: "macwindow.badge.plus"
        case .appStore: "bag.fill"
        case .sparkle: "app.badge.fill"
        case .npm: "cube.fill"
        case .rustup: "gearshape.fill"
        case .gem: "diamond.fill"
        case .pythonTools: "terminal.fill"
        case .ohMyZsh: "chevron.left.forwardslash.chevron.right"
        case .system: "gearshape.2.fill"
        }
    }

    var tint: Color {
        switch self {
        case .homebrewFormula: .orange
        case .homebrewCask: .purple
        case .selfUpdatingCask: .indigo
        case .appStore: .blue
        case .sparkle: .teal
        case .npm: .red
        case .rustup: .brown
        case .gem: .pink
        case .pythonTools: .yellow
        case .ohMyZsh: .mint
        case .system: .gray
        }
    }

    var shortTitle: String {
        switch self {
        case .homebrewFormula: String(localized: "Formül")
        case .homebrewCask: String(localized: "Cask")
        case .selfUpdatingCask: String(localized: "Kendi güncelleyen")
        case .appStore: String(localized: "App Store")
        case .sparkle: String(localized: "Uygulama")
        case .npm: String(localized: "npm")
        case .rustup: String(localized: "Rust")
        case .gem: String(localized: "Gem")
        case .pythonTools: String(localized: "Python")
        case .ohMyZsh: String(localized: "Oh My Zsh")
        case .system: String(localized: "macOS")
        }
    }
}

/// Hafif malzeme yüzeyi; üst kenarda ışığı yakalayan parlak çizgi (açık/koyu temada uyum sağlar).
struct Card<Content: View>: View {
    var elevated = false
    @ViewBuilder var content: Content
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Theme.corner, style: .continuous)
        content
            .background(.thinMaterial, in: shape)
            .overlay(shape.strokeBorder(LinearGradient(
                colors: [.white.opacity(0.22), .white.opacity(0.04)], startPoint: .top, endPoint: .bottom), lineWidth: 0.75))
            .shadow(color: .black.opacity(elevated ? 0.18 : 0.06), radius: elevated ? 10 : 2, y: elevated ? 4 : 1)
    }
}

struct PrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13.5, weight: .semibold))
            .foregroundStyle(isEnabled ? .white : .secondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 11)
            .background {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(isEnabled ? AnyShapeStyle(Theme.brand) : AnyShapeStyle(.quaternary))
                    .shadow(color: Theme.brandBottom.opacity(isEnabled ? 0.35 : 0), radius: 8, y: 3)
            }
            .brightness(configuration.isPressed ? -0.06 : 0)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}

struct IconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(width: 28, height: 28)
            .background(.primary.opacity(configuration.isPressed ? 0.16 : 0.07), in: Circle())
            .scaleEffect(configuration.isPressed ? 0.92 : 1)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}

/// Satır geri bildirimi fare basıldığı anda başlar, bırakılınca değil.
struct RowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(Color.primary.opacity(configuration.isPressed ? 0.08 : 0))
            .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
    }
}

struct VersionPill: View {
    let installed: String
    let latest: String

    var body: some View {
        HStack(spacing: 4) {
            if !installed.isEmpty {
                Text(installed).foregroundStyle(.secondary)
                Image(systemName: "arrow.right").font(.system(size: 7, weight: .bold)).foregroundStyle(.tertiary)
            }
            Text(latest).foregroundStyle(Theme.brandBottom).fontWeight(.semibold)
        }
        .font(.system(size: 10.5, design: .monospaced))
        .tracking(0.1)
        .lineLimit(1)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(.primary.opacity(0.06), in: Capsule())
    }
}

/// Öğeleri yan yana dizer, sığmayanı alt satıra geçirir.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8
    var lineSpacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(maxWidth: proposal.width ?? .infinity, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let frames = arrange(maxWidth: bounds.width, subviews: subviews).frames
        for (subview, frame) in zip(subviews, frames) {
            subview.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                          proposal: ProposedViewSize(frame.size))
        }
    }

    private func arrange(maxWidth: CGFloat, subviews: Subviews) -> (frames: [CGRect], size: CGSize) {
        var frames: [CGRect] = []
        var x: CGFloat = 0, y: CGFloat = 0, lineHeight: CGFloat = 0, width: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > maxWidth {
                x = 0
                y += lineHeight + lineSpacing
                lineHeight = 0
            }
            frames.append(CGRect(origin: CGPoint(x: x, y: y), size: size))
            width = max(width, x + size.width)
            lineHeight = max(lineHeight, size.height)
            x += size.width + spacing
        }
        return (frames, CGSize(width: width, height: y + lineHeight))
    }
}

struct CheckCircle: View {
    let isOn: Bool
    var body: some View {
        ZStack {
            Circle().strokeBorder(isOn ? Color.clear : Color.secondary.opacity(0.45), lineWidth: 1.3)
            if isOn {
                Circle().fill(Theme.brand)
                Image(systemName: "checkmark").font(.system(size: 8, weight: .heavy)).foregroundStyle(.white)
            }
        }
        .frame(width: 17, height: 17)
        .animation(Theme.spring, value: isOn)
    }
}
