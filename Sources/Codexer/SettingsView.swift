import AppKit
import CodexerCore
import SwiftUI

enum SettingsPresentation {
    case embedded
    case window
}

struct SettingsView: View {
    @EnvironmentObject private var model: CodexerModel
    @EnvironmentObject private var updater: AppUpdater
    @State private var section: SettingsSection = .general
    let presentation: SettingsPresentation

    init(presentation: SettingsPresentation = .window) {
        self.presentation = presentation
    }

    var body: some View {
        Group {
            switch presentation {
            case .embedded:
                embeddedSettingsContent
                    .preferredColorScheme(preferredColorScheme)
            case .window:
                settingsContent
                    .toolbar {
                        ToolbarItem(placement: .principal) {
                            Text("AgentDock — Settings")
                                .font(.system(size: 13, weight: .medium))
                        }
                    }
                    .frame(
                        minWidth: 780,
                        idealWidth: 840,
                        maxWidth: 880,
                        minHeight: 560,
                        idealHeight: 590,
                        maxHeight: 620
                    )
                    .background(SettingsWindowConfigurator())
                    .preferredColorScheme(preferredColorScheme)
            }
        }
        .onChange(of: section) { _, value in
            ProductAnalytics.shared.capture(AnalyticsEvent(
                .navigation,
                [.action(.viewed), .surface(value.analyticsSurface)]
            ))
        }
    }

    private var embeddedSettingsContent: some View {
        HStack(spacing: 0) {
            settingsSidebar
                .frame(width: 200)
            Divider()
            sectionContent
                .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var settingsContent: some View {
        NavigationSplitView {
            settingsSidebar
            .navigationSplitViewColumnWidth(min: 210, ideal: 220, max: 230)
        } detail: {
            sectionContent
        }
        .navigationSplitViewStyle(.balanced)
    }

    private var settingsSidebar: some View {
        VStack(spacing: 0) {
            List(SettingsSection.allCases, selection: $section) { item in
                Label(item.title, systemImage: item.icon)
                    .font(.system(size: 14))
                    .padding(.horizontal, 8)
                    .frame(maxWidth: .infinity, minHeight: 42, alignment: .leading)
                    .tag(item)
            }
            .listStyle(.sidebar)

            Divider()
            VStack(alignment: .leading, spacing: 2) {
                Label("Settings", systemImage: "gearshape")
                Text(versionAndBuild)
                    .font(.system(size: 11))
            }
            .font(.system(size: 13))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity, minHeight: 50, alignment: .leading)
        }
    }

    @ViewBuilder
    private var sectionContent: some View {
        switch section {
        case .general: general
        case .providerApps: providerApps
        case .privacy: privacy
        case .about: about
        }
    }

    private var general: some View {
        SettingsPage(title: "General") {
            SettingsRow("Appearance") {
                Picker("Appearance", selection: appearanceBinding) {
                    ForEach(AgentDockAppearance.allCases, id: \.self) {
                        Text($0.displayName).tag($0)
                    }
                }
                .labelsHidden()
                .frame(width: 190)
            }
            SettingsRow("Default View") {
                Picker("Default View", selection: defaultViewBinding) {
                    ForEach(AgentDockDefaultView.allCases, id: \.self) {
                        Text($0.displayName).tag($0)
                    }
                }
                .labelsHidden()
                .frame(width: 190)
            }
            SettingsRow("Refresh profile activity") {
                HStack(spacing: 10) {
                    Toggle("", isOn: refreshBinding).labelsHidden()
                    Picker("Refresh Interval", selection: refreshIntervalBinding) {
                        ForEach(AgentDockPreferencesStore.allowedIntervals, id: \.self) { minutes in
                            Text(minutes == 1 ? "Every minute" : "Every \(minutes) minutes")
                                .tag(minutes)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 150)
                    .disabled(!model.preferences.refreshProfileActivity)
                }
            }
            SettingsRow("Show status in profile list") {
                Toggle("", isOn: showStatusBinding).labelsHidden()
            }

            SettingsSectionHeader("Updates")
            SettingsRow("Release channel") {
                Picker("Release Channel", selection: updateChannelBinding) {
                    ForEach(AppUpdateChannel.allCases) { channel in
                        Text(channel.displayName).tag(channel)
                    }
                }
                .labelsHidden()
                .frame(width: 150)
                .disabled(!updater.isConfigured)
            }
            SettingsRow("AgentDock updates") {
                Button("Check for Updates…") {
                    updater.checkForUpdates()
                }
                .disabled(!updater.isConfigured)
            }
            SettingsRow("Check for updates automatically") {
                HStack(spacing: 10) {
                    Toggle("", isOn: automaticChecksBinding)
                        .labelsHidden()
                    Picker("Update Check Frequency", selection: updateCheckFrequencyBinding) {
                        ForEach(AppUpdateCheckFrequency.allCases) { frequency in
                            Text(frequency.displayName).tag(frequency)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 150)
                    .disabled(!updater.automaticallyChecksForUpdates)
                }
                .disabled(!updater.isConfigured)
            }
            SettingsRow("Download and install updates automatically") {
                Toggle("", isOn: automaticDownloadsBinding)
                    .labelsHidden()
                    .disabled(!updater.isConfigured || !updater.automaticallyChecksForUpdates)
            }
            Text(
                updater.isConfigured
                    ? updater.updateChannel == .alpha
                        ? "Alpha receives signed prerelease builds after changes merge. They may be less stable; switch back to Stable at any time."
                        : "Stable is the default and receives signed production releases. Automatic installation completes when AgentDock can safely relaunch."
                    : "Automatic updates are unavailable in this development build."
            )
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)

            SettingsSectionHeader("Provider Apps")
            ForEach(DesktopProduct.allCases) { product in
                ProviderSettingsRow(product: product)
            }

            SettingsSectionHeader("Data & Privacy")
            SettingsRow("Profiles and chat history are stored locally") {
                Button("Manage…") { section = .privacy }
            }

            Button("Restore Defaults") {
                model.restorePreferences()
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)
            .padding(.top, 14)

            Text("AgentDock.app  \(versionAndBuild)   •   Settings save automatically.")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .padding(.top, 8)
        }
    }

    private var providerApps: some View {
        SettingsPage(title: "Provider Apps") {
            SettingsSectionHeader("Provider Apps")
            ForEach(DesktopProduct.allCases) { product in
                ProviderSettingsRow(product: product)
            }
            Text("AgentDock launches only signed, supported provider apps selected here.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .padding(.top, 12)
        }
    }

    private var privacy: some View {
        let delivery = ProductAnalytics.shared.deliveryDiagnostics()
        return SettingsPage(title: "Data & Privacy") {
            SettingsSectionHeader("Local Data")
            SettingsRow("Profiles and chat history are stored locally") {
                Button("Reveal in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([
                        ProfileStore.defaultRootDirectory()
                    ])
                }
            }
            Text(
                "AgentDock reads only managed profile metadata and supported local session records. It does not upload profile data or provide cloud synchronization."
            )
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .padding(.vertical, 12)

            SettingsSectionHeader("Product Analytics")
            SettingsRow("Share pseudonymous product analytics", height: 56) {
                Toggle("", isOn: analyticsBinding).labelsHidden()
            }
            Text(
                "Off until you explicitly allow it. AgentDock then sends only allowlisted feature actions, outcomes, safe error codes, normalized plan tiers, coarse profile, usage, count, and timing buckets, app version, macOS major version, and architecture. It never sends names, account identities, exact usage or balances, model names, paths, commands, prompts, chats, transcripts, session IDs, configuration values, environment variables, logs, crashes, or precise location. No autocapture or session replay is used. Turning this off immediately clears pending events and deletes the local random analytics identifier."
            )
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .padding(.vertical, 12)
            if !ProductAnalytics.shared.isConfigured {
                Label("Analytics delivery is not configured in this build; no events can be sent.", systemImage: "info.circle")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            } else if model.analyticsConsent == .granted,
                      delivery.failedBatches > 0,
                      let failure = delivery.lastFailure {
                Label(
                    "Analytics delivery had \(delivery.failedBatches) issue(s) this launch. Latest: \(failure.displayName).",
                    systemImage: "exclamationmark.triangle"
                )
                .font(.system(size: 11))
                .foregroundStyle(.orange)
            } else if model.analyticsConsent == .granted, delivery.successfulBatches > 0 {
                Label(
                    "Analytics delivery is working (\(delivery.successfulBatches) batch(es) sent this launch).",
                    systemImage: "checkmark.circle"
                )
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            }
            Link(
                "View exact analytics event catalog",
                destination: URL(string: "https://github.com/euforicio/AgentDock/blob/main/docs/analytics.md")!
            )
            .font(.system(size: 12))
            .padding(.top, 10)

            SettingsSectionHeader("Provider Data")
            Text("Provider apps may use their own network services and account storage. AgentDock's isolation boundary is described in the project documentation.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .padding(.vertical, 12)
        }
    }

    private var about: some View {
        SettingsPage(title: "About") {
            HStack(spacing: 14) {
                Image(nsImage: NSApplication.shared.applicationIconImage)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 56, height: 56)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text("AgentDock").font(.system(size: 17, weight: .semibold))
                    Text(versionAndBuild)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    Text("Native local profiles for Codex and Claude Desktop.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Check for Updates…") {
                    updater.checkForUpdates()
                }
                .controlSize(.regular)
                .disabled(!updater.isConfigured)
            }
            .padding(.vertical, 10)
        }
    }

    private var preferredColorScheme: ColorScheme? {
        switch model.preferences.appearance {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? "Development"
    }

    private var appBuild: String? {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
    }

    private var versionAndBuild: String {
        guard let appBuild, !appBuild.isEmpty else {
            return "Version \(appVersion)"
        }
        return "Version \(appVersion) (Build \(appBuild))"
    }

    private var appearanceBinding: Binding<AgentDockAppearance> {
        Binding(get: { model.preferences.appearance }, set: {
            model.preferences.appearance = $0
            ProductAnalytics.shared.capture(AnalyticsEvent(
                .preferenceChanged,
                [.action(.appearanceChanged), .surface(.settingsGeneral)]
            ))
        })
    }

    private var defaultViewBinding: Binding<AgentDockDefaultView> {
        Binding(get: { model.preferences.defaultView }, set: {
            model.preferences.defaultView = $0
            ProductAnalytics.shared.capture(AnalyticsEvent(
                .preferenceChanged,
                [.action(.defaultViewChanged), .surface(.settingsGeneral)]
            ))
        })
    }

    private var refreshBinding: Binding<Bool> {
        Binding(get: { model.preferences.refreshProfileActivity }, set: {
            model.preferences.refreshProfileActivity = $0
            ProductAnalytics.shared.capture(AnalyticsEvent(
                .preferenceChanged,
                [.action(.activityRefreshChanged), .surface(.settingsGeneral), .enabled($0)]
            ))
        })
    }

    private var refreshIntervalBinding: Binding<Int> {
        Binding(get: { model.preferences.refreshIntervalMinutes }, set: { model.preferences.refreshIntervalMinutes = $0 })
    }

    private var showStatusBinding: Binding<Bool> {
        Binding(get: { model.preferences.showStatusInProfileList }, set: {
            model.preferences.showStatusInProfileList = $0
            ProductAnalytics.shared.capture(AnalyticsEvent(
                .preferenceChanged,
                [.action(.statusVisibilityChanged), .surface(.settingsGeneral), .enabled($0)]
            ))
        })
    }

    private var automaticChecksBinding: Binding<Bool> {
        Binding(
            get: { updater.automaticallyChecksForUpdates },
            set: { updater.setAutomaticallyChecksForUpdates($0) }
        )
    }

    private var updateChannelBinding: Binding<AppUpdateChannel> {
        Binding(
            get: { updater.updateChannel },
            set: { updater.setUpdateChannel($0) }
        )
    }

    private var automaticDownloadsBinding: Binding<Bool> {
        Binding(
            get: { updater.automaticallyDownloadsUpdates },
            set: { updater.setAutomaticallyDownloadsUpdates($0) }
        )
    }

    private var updateCheckFrequencyBinding: Binding<AppUpdateCheckFrequency> {
        Binding(
            get: { updater.updateCheckFrequency },
            set: { updater.setUpdateCheckFrequency($0) }
        )
    }

    private var analyticsBinding: Binding<Bool> {
        Binding(
            get: { model.analyticsConsent == .granted },
            set: { model.setAnalyticsConsent(granted: $0, surface: .settingsPrivacy) }
        )
    }
}

private extension AnalyticsDeliveryFailure {
    var displayName: String {
        switch self {
        case .transport: "network transport failure"
        case .invalidResponse: "invalid server response"
        case .rejected: "server rejected the batch"
        case .serialization: "local payload serialization failure"
        }
    }
}

private struct SettingsPage<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    init(title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text(title)
                    .font(.system(size: 24, weight: .semibold))
                    .padding(.bottom, 12)
                Divider()
                content
            }
            .padding(.horizontal, 22)
            .padding(.top, 18)
            .padding(.bottom, 22)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .background(AgentDockPalette.graphite)
    }
}

private struct SettingsRow<Accessory: View>: View {
    let title: String
    let height: CGFloat
    @ViewBuilder let accessory: Accessory

    init(_ title: String, height: CGFloat = 48, @ViewBuilder accessory: () -> Accessory) {
        self.title = title
        self.height = height
        self.accessory = accessory()
    }

    var body: some View {
        HStack(spacing: 16) {
            Text(title)
                .font(.system(size: 14))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 16)
            accessory
                .fixedSize(horizontal: true, vertical: false)
        }
        .padding(.horizontal, 10)
        .frame(minHeight: height)
        .overlay(alignment: .bottom) { Divider() }
    }
}

private struct SettingsSectionHeader: View {
    let title: String

    init(_ title: String) {
        self.title = title
    }

    var body: some View {
        Text(title.uppercased())
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.secondary)
            .tracking(0.35)
            .padding(.top, 14)
            .padding(.bottom, 7)
            .overlay(alignment: .bottom) { Divider() }
    }
}

private struct SettingsWindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { configure(view.window) }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async { configure(view.window) }
    }

    private func configure(_ window: NSWindow?) {
        guard let window else { return }
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.backgroundColor = .windowBackgroundColor
        window.minSize = NSSize(width: 780, height: 560)
        window.maxSize = NSSize(width: 880, height: 620)
    }
}

private struct ProviderSettingsRow: View {
    @EnvironmentObject private var model: CodexerModel
    let product: DesktopProduct

    var body: some View {
        HStack(spacing: 12) {
            ProviderIconView(product: product, appURL: model.appURL(for: product), size: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(product.displayName).app")
                    .font(.system(size: 14, weight: .semibold))
                Text("Version \(version)")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Text(abbreviatedPath)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .layoutPriority(1)

            HStack(spacing: 6) {
                StatusDot(isRunning: isAvailable, size: 7)
                Text(isAvailable ? "Found" : "Not Found")
                    .font(.system(size: 12))
                    .foregroundStyle(isAvailable ? Color.green : Color.orange)
            }
            .fixedSize()

            Button("Change…") { model.chooseApp(product) }
                .buttonStyle(.bordered)
                .controlSize(.regular)
                .fixedSize()
        }
        .padding(.horizontal, 8)
        .frame(minHeight: 72)
        .overlay(alignment: .bottom) { Divider() }
        .accessibilityElement(children: .contain)
    }

    private var isAvailable: Bool {
        FileManager.default.fileExists(atPath: model.appURL(for: product).path)
    }

    private var version: String {
        let bundle = Bundle(url: model.appURL(for: product))
        return bundle?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Unknown"
    }

    private var abbreviatedPath: String {
        model.appURL(for: product).path.replacingOccurrences(
            of: FileManager.default.homeDirectoryForCurrentUser.path,
            with: "~"
        )
    }
}

private enum SettingsSection: String, CaseIterable, Identifiable {
    case general
    case providerApps
    case privacy
    case about

    var id: Self { self }

    var title: String {
        switch self {
        case .general: "General"
        case .providerApps: "Provider Apps"
        case .privacy: "Data & Privacy"
        case .about: "About"
        }
    }

    var icon: String {
        switch self {
        case .general: "gearshape"
        case .providerApps: "square.grid.2x2"
        case .privacy: "lock"
        case .about: "info.circle"
        }
    }

    var analyticsSurface: AnalyticsSurface {
        switch self {
        case .general: .settingsGeneral
        case .providerApps: .settingsProviders
        case .privacy: .settingsPrivacy
        case .about: .settingsAbout
        }
    }
}
