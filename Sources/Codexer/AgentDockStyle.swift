import AppKit
import CodexerCore
import SwiftUI

enum AgentDockPalette {
    static let graphite = Color(nsColor: .windowBackgroundColor)
    static let panel = Color(nsColor: .controlBackgroundColor)
    static let panelBorder = Color(nsColor: .separatorColor).opacity(0.55)
    static let divider = Color(nsColor: .separatorColor).opacity(0.55)
    static let selection = Color.accentColor.opacity(0.18)
    static let blue = Color(red: 0.12, green: 0.43, blue: 0.98)
}

struct AgentDockBackground: View {
    var body: some View {
        AgentDockPalette.graphite
        .ignoresSafeArea()
    }
}

struct SurfaceCard<Content: View>: View {
    private let radius: CGFloat
    private let content: Content

    init(radius: CGFloat = 8, @ViewBuilder content: () -> Content) {
        self.radius = radius
        self.content = content()
    }

    var body: some View {
        content
            .background(AgentDockPalette.panel, in: .rect(cornerRadius: radius))
            .overlay {
                RoundedRectangle(cornerRadius: radius)
                    .stroke(AgentDockPalette.panelBorder)
            }
    }
}

private struct AgentDockPrimaryActionStyle: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.buttonStyle(.glassProminent)
        } else {
            content.buttonStyle(.borderedProminent)
        }
    }
}

private struct AgentDockToolbarActionStyle: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.buttonStyle(.glass)
        } else {
            content.buttonStyle(.bordered)
        }
    }
}

private struct AgentDockGlassControlStyle: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    let radius: CGFloat

    @ViewBuilder
    func body(content: Content) -> some View {
        if reduceTransparency {
            content.background(
                Color(nsColor: .controlBackgroundColor),
                in: .rect(cornerRadius: radius)
            )
        } else if #available(macOS 26.0, *) {
            content.glassEffect(.regular.interactive(), in: .rect(cornerRadius: radius))
        } else {
            content.background(.regularMaterial, in: .rect(cornerRadius: radius))
        }
    }
}

extension View {
    func agentDockPrimaryAction() -> some View {
        modifier(AgentDockPrimaryActionStyle())
    }

    func agentDockToolbarAction() -> some View {
        modifier(AgentDockToolbarActionStyle())
    }

    func agentDockGlassControl(radius: CGFloat = 8) -> some View {
        modifier(AgentDockGlassControlStyle(radius: radius))
    }
}

struct ProfileIconView: View {
    let profile: CodexProfile
    var size: CGFloat = 48

    var body: some View {
        Group {
            if profile.iconKind == .image,
               let image = NSImage(contentsOf: profile.customIconPath),
               image.isValid
            {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: size * 0.2)
                        .fill(
                            LinearGradient(
                                colors: [
                                    Color(hex: profile.iconColor).opacity(1),
                                    Color(hex: profile.iconColor).opacity(0.68)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                    if profile.iconKind == .symbol {
                        Image(systemName: profile.iconValue.isEmpty ? "person.fill" : profile.iconValue)
                            .font(.system(size: size * 0.42, weight: .medium))
                    } else {
                        Text(profile.iconValue.isEmpty
                            ? String(profile.name.prefix(1)).uppercased()
                            : String(profile.iconValue.prefix(1)).uppercased())
                            .font(.system(size: size * 0.46, weight: .medium, design: .rounded))
                    }
                }
                .foregroundStyle(.white)
            }
        }
        .frame(width: size, height: size)
        .clipShape(.rect(cornerRadius: size * 0.2))
        .overlay {
            RoundedRectangle(cornerRadius: size * 0.2)
                .stroke(.white.opacity(0.12))
        }
        .accessibilityHidden(true)
    }
}

struct ProviderIconView: View {
    let product: DesktopProduct
    let appURL: URL
    var size: CGFloat = 40

    var body: some View {
        Image(nsImage: NSWorkspace.shared.icon(forFile: appURL.path))
            .resizable()
            .scaledToFit()
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

struct StatusDot: View {
    let isRunning: Bool
    var size: CGFloat = 9

    var body: some View {
        Circle()
            .fill(isRunning ? Color.green : Color.secondary.opacity(0.7))
            .frame(width: size, height: size)
            .overlay(Circle().stroke(.black.opacity(0.2), lineWidth: 0.5))
            .accessibilityHidden(true)
    }
}

struct SectionLabel: View {
    let title: String

    var body: some View {
        Text(title.uppercased())
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
            .tracking(0.5)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct AgentDockEmptyState: View {
    let title: String
    let systemImage: String
    let description: String
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 32, weight: .light))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.system(size: 20, weight: .semibold))
            Text(description)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .agentDockPrimaryAction()
                    .controlSize(.regular)
                    .padding(.top, 6)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
    }
}

@MainActor
extension ByteCountFormatter {
    static let agentDock: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.countStyle = .file
        return formatter
    }()
}
