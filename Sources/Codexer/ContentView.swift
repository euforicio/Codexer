import AppKit
import CodexerCore
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var model: CodexerModel
    @EnvironmentObject private var updater: AppUpdater
    @State private var profileSearch = ""
    @State private var showsSettings = false
    @FocusState private var searchFocused: Bool

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 220, ideal: 240, max: 270)
        } detail: {
            detail
        }
        .font(.system(size: 13))
        .preferredColorScheme(preferredColorScheme)
        .sheet(isPresented: $model.showAddProfile) {
            AddProfileSheet()
        }
        .sheet(isPresented: analyticsConsentBinding) {
            AnalyticsConsentView()
        }
        .sheet(isPresented: $model.showEditProfile) {
            if let profile = model.selectedProfile {
                EditProfileSheet(profile: profile)
            }
        }
        .alert("AgentDock Error", isPresented: errorBinding) {
            Button("OK", role: .cancel) {
                model.errorMessage = nil
            }
        } message: {
            Text(model.errorMessage ?? "")
        }
        .alert("Remove Profile?", isPresented: removeBinding) {
            Button("Remove Profile", role: .destructive) {
                if let profile = model.pendingRemoveProfile {
                    model.removeProfileFromList(profile)
                    model.pendingRemoveProfile = nil
                }
            }
            Button("Cancel", role: .cancel) {
                model.pendingRemoveProfile = nil
            }
        } message: {
            Text("AgentDock will remove \(model.pendingRemoveProfile?.name ?? "this profile") from the list. Its local data will remain on disk and can be restored later.")
        }
        .alert("Permanently Delete Profile Data?", isPresented: deleteBinding) {
            Button("Delete Data", role: .destructive) {
                if let profile = model.pendingDeleteProfile {
                    model.deleteProfileData(profile)
                }
            }
            Button("Cancel", role: .cancel) {
                model.pendingDeleteProfile = nil
            }
        } message: {
            Text("This permanently removes the managed local sessions, settings, and shortcut for \(model.pendingDeleteProfile?.name ?? "this profile"). Credentials in shared macOS Keychain or external provider stores are not deleted. This cannot be undone.")
        }
        .task {
            model.refreshChats()
        }
        .onReceive(NotificationCenter.default.publisher(for: .agentDockFocusSearch)) { _ in
            guard showsSettings || model.detailTab != .chats else { return }
            searchFocused = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .agentDockFocusProfileSearch)) { _ in
            searchFocused = true
        }
        .onChange(of: model.detailTab) { _, tab in
            let surface: AnalyticsSurface = switch tab {
            case .overview: .overview
            case .chats: .chats
            case .advanced: .advanced
            }
            ProductAnalytics.shared.capture(AnalyticsEvent(
                .navigation,
                [.action(.viewed), .surface(surface)]
            ))
        }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            Text("AgentDock")
                .font(.system(size: 14, weight: .semibold))
                .frame(maxWidth: .infinity)
                .padding(.top, 10)
                .padding(.bottom, 8)

            searchField
                .padding(.horizontal, 10)
                .padding(.bottom, 8)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    providerSection(.codex)
                    providerSection(.claude)
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 10)
            }

            Divider()
                .overlay(AgentDockPalette.divider)

            HStack {
                Button(action: openSettings) {
                    Image(systemName: "gearshape")
                        .frame(width: 28, height: 28)
                        .background(
                            showsSettings ? AgentDockPalette.selection : .clear,
                            in: .rect(cornerRadius: 7)
                        )
                }
                .buttonStyle(.plain)
                .keyboardShortcut(",", modifiers: .command)
                .help("Settings")
                .accessibilityLabel("Settings")
                .accessibilityHint("Shows AgentDock settings")

                Spacer(minLength: 0)

                if updater.presentation.isVisible {
                    SidebarUpdateButton(presentation: updater.presentation) {
                        updater.installAvailableUpdate()
                    }
                }
            }
            .foregroundStyle(.secondary)
            .font(.system(size: 13))
            .padding(.horizontal, 12)
            .frame(height: 48)
        }
    }

    private var searchField: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search profiles", text: $profileSearch)
                .textFieldStyle(.plain)
                .focused($searchFocused)
                .onSubmit(selectFirstSearchResult)
                .onExitCommand { profileSearch = "" }
                .accessibilityLabel("Search profiles")
            if !profileSearch.isEmpty {
                Button {
                    profileSearch = ""
                    searchFocused = true
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Clear profile search")
                .accessibilityLabel("Clear profile search")
            }
        }
        .font(.system(size: 13))
        .padding(.horizontal, 10)
        .frame(height: 32)
        .agentDockGlassControl()
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private func providerSection(_ product: DesktopProduct) -> some View {
        let profiles = filteredProfiles(for: product)
        VStack(alignment: .leading, spacing: 3) {
            SectionLabel(title: product == .codex ? "Codex" : "Claude Desktop")
                .padding(.horizontal, 10)
                .padding(.top, 6)

            Button {
                showsSettings = false
                model.selectOfficial(product)
            } label: {
                OfficialSidebarRow(
                    product: product,
                    isSelected: !showsSettings && model.sidebarSelection == .official(product)
                )
            }
            .buttonStyle(.plain)

            ForEach(Array(profiles.enumerated()), id: \.element.id) { index, profile in
                ProfileSidebarRow(
                    profile: profile,
                    isSelected: !showsSettings && model.selectedProfileID == profile.id,
                    onSelect: {
                        showsSettings = false
                        model.selectProfile(profile.id)
                    },
                    onOpen: {
                        showsSettings = false
                        model.selectProfile(profile.id)
                        model.launch(profile)
                    },
                    onMove: { draggedID, placeAfter in
                        model.reorderProfile(
                            draggedID,
                            relativeTo: profile.id,
                            placeAfter: placeAfter
                        )
                    },
                    onMoveUp: {
                        guard index > profiles.startIndex else { return }
                        _ = model.reorderProfile(
                            profile.id,
                            relativeTo: profiles[index - 1].id,
                            placeAfter: false
                        )
                    },
                    onMoveDown: {
                        guard index < profiles.index(before: profiles.endIndex) else { return }
                        _ = model.reorderProfile(
                            profile.id,
                            relativeTo: profiles[index + 1].id,
                            placeAfter: true
                        )
                    }
                )
            }

            if profiles.isEmpty, !profileQuery.isEmpty {
                Text("No matching profiles")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
            }
        }
    }

    private var detail: some View {
        Group {
            if showsSettings {
                SettingsView(presentation: .embedded)
            } else {
                VStack(spacing: 0) {
                    detailToolbar
                    Divider()
                        .overlay(AgentDockPalette.divider)
                    Group {
                        switch model.detailTab {
                        case .overview:
                            OverviewView()
                        case .chats:
                            ChatsView()
                                .id(model.sidebarSelection)
                        case .advanced:
                            AdvancedView()
                        }
                    }
                }
            }
        }
        .background(AgentDockBackground())
    }

    private var detailToolbar: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                selectedSourceIdentity
                Spacer(minLength: 12)
                detailActions
            }

            if model.selectedProfile != nil || model.selectedOfficialProduct != nil {
                Picker("Profile Section", selection: $model.detailTab) {
                    ForEach(visibleDetailTabs) { tab in
                        Text(tab.title).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: visibleDetailTabs.count == 3 ? 300 : 170)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
    }

    private var detailActions: some View {
        HStack(spacing: 8) {
            Button {
                model.showAddProfile = true
            } label: {
                Label("Add Profile", systemImage: "plus")
                    .font(.system(size: 13))
            }
            .agentDockToolbarAction()
            .keyboardShortcut("n", modifiers: .command)

            Button(action: refreshContent) {
                Image(systemName: "arrow.clockwise")
                    .frame(width: 14, height: 14)
            }
            .agentDockToolbarAction()
            .help("Refresh profile activity and chats")
            .accessibilityLabel("Refresh")
            .keyboardShortcut("r", modifiers: .command)

            Menu {
                Button("Restore Profile…") {
                    model.restoreProfile()
                }
            } label: {
                Image(systemName: "ellipsis")
                    .frame(width: 24, height: 24)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("More actions")
        }
        .fixedSize()
    }

    @ViewBuilder
    private var selectedSourceIdentity: some View {
        if let profile = model.selectedProfile {
            HStack(spacing: 8) {
                ProfileIconView(profile: profile, size: 26)
                VStack(alignment: .leading, spacing: 1) {
                    Text(profile.name)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    Text("Managed \(profile.product.displayName) profile")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .help("\(profile.name) · Managed \(profile.product.displayName) profile")
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Selected profile: \(profile.name), managed \(profile.product.displayName)")
        } else if let product = model.selectedOfficialProduct {
            HStack(spacing: 8) {
                ProviderIconView(product: product, appURL: model.appURL(for: product), size: 26)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Official \(product.displayName)")
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    Text("Default installation")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            .accessibilityElement(children: .combine)
        } else {
            Text("Profiles")
                .font(.system(size: 13, weight: .semibold))
        }
    }

    private var visibleDetailTabs: [AgentDockDetailTab] {
        AgentDockDetailTab.availableTabs(hasManagedProfile: model.selectedProfile != nil)
    }

    private func filteredProfiles(for product: DesktopProduct) -> [CodexProfile] {
        let productProfiles = model.profiles.filter { $0.product == product }
        guard !profileQuery.isEmpty else { return productProfiles }
        return productProfiles.filter {
            $0.name.localizedCaseInsensitiveContains(profileQuery)
                || $0.slug.localizedCaseInsensitiveContains(profileQuery)
        }
    }

    private var profileQuery: String {
        profileSearch.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func selectFirstSearchResult() {
        ProductAnalytics.shared.capture(AnalyticsEvent(
            .navigation,
            [.action(.searched), .surface(.sidebar)]
        ))
        let first = DesktopProduct.allCases
            .flatMap(filteredProfiles)
            .first
        if let first {
            showsSettings = false
            model.selectProfile(first.id)
        }
    }

    private func openSettings() {
        showsSettings = true
        ProductAnalytics.shared.capture(AnalyticsEvent(
            .navigation,
            [.action(.viewed), .surface(.settingsGeneral)]
        ))
    }

    private func refreshContent() {
        ProductAnalytics.shared.capture(AnalyticsEvent(
            .refresh,
            [
                .action(.manualRefresh),
                .surface(selectedDetailAnalyticsSurface),
                .trigger(.user),
                .countBucket(.init(model.profiles.count))
            ]
        ))
        model.refreshStats(allowCredentialInteraction: true)
        model.refreshChats()
    }

    private var selectedDetailAnalyticsSurface: AnalyticsSurface {
        switch model.detailTab {
        case .overview: .overview
        case .chats: .chats
        case .advanced: .advanced
        }
    }

    private var preferredColorScheme: ColorScheme? {
        switch model.preferences.appearance {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { model.errorMessage != nil && !model.showAddProfile && !model.showEditProfile },
            set: { if !$0 { model.errorMessage = nil } }
        )
    }

    private var removeBinding: Binding<Bool> {
        Binding(
            get: { model.pendingRemoveProfile != nil },
            set: { if !$0 { model.pendingRemoveProfile = nil } }
        )
    }

    private var deleteBinding: Binding<Bool> {
        Binding(
            get: { model.pendingDeleteProfile != nil },
            set: { if !$0 { model.pendingDeleteProfile = nil } }
        )
    }

    private var analyticsConsentBinding: Binding<Bool> {
        Binding(
            get: {
                AnalyticsConsentView.shouldPresent(
                    consent: model.analyticsConsent,
                    isConfigured: ProductAnalytics.shared.isConfigured
                )
            },
            set: { _ in }
        )
    }
}

private struct SidebarUpdateButton: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let presentation: AppUpdatePresentation
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if presentation.showsProgress {
                    ProgressView()
                        .controlSize(.small)
                        .tint(.white)
                } else {
                    Image(systemName: presentation.usesCompactAvailableStyle
                        ? "arrow.down.to.line"
                        : "arrow.clockwise")
                }

                if !presentation.usesCompactAvailableStyle {
                    Text(presentation.buttonTitle)
                        .lineLimit(1)
                }
            }
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, presentation.usesCompactAvailableStyle ? 0 : 11)
            .frame(
                width: presentation.usesCompactAvailableStyle ? 36 : nil,
                height: 36
            )
            .background(AgentDockPalette.blue, in: Capsule())
            .contentShape(Capsule())
            .animation(
                reduceMotion ? nil : .snappy(duration: 0.22),
                value: presentation.usesCompactAvailableStyle
            )
        }
        .buttonStyle(.plain)
        .disabled(!presentation.allowsAction)
        .help(helpText)
        .accessibilityLabel(accessibilityLabel)
    }

    private var helpText: String {
        guard let version = presentation.version else { return "Install update" }
        return "Install AgentDock \(version)"
    }

    private var accessibilityLabel: String {
        guard let version = presentation.version else {
            return presentation.buttonTitle
        }
        return "\(presentation.buttonTitle) AgentDock \(version)"
    }
}

private struct OfficialSidebarRow: View {
    @EnvironmentObject private var model: CodexerModel
    let product: DesktopProduct
    let isSelected: Bool

    var body: some View {
        let running = model.stockInstanceStatuses[product]?.isRunning == true
        HStack(spacing: 9) {
            ProviderIconView(product: product, appURL: model.appURL(for: product), size: 32)
            VStack(alignment: .leading, spacing: 1) {
                Text("Official \(product.displayName)")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    if model.preferences.showStatusInProfileList {
                        StatusDot(isRunning: running, size: 6)
                    }
                    Text(product.rawValue)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .frame(height: 46)
        .background(isSelected ? AgentDockPalette.selection : .clear, in: .rect(cornerRadius: 8))
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
        .accessibilityValue(running ? "Running" : "Stopped")
    }
}

private struct ProfileSidebarRow: View {
    @EnvironmentObject private var model: CodexerModel
    let profile: CodexProfile
    let isSelected: Bool
    let onSelect: () -> Void
    let onOpen: () -> Void
    let onMove: (CodexProfile.ID, Bool) -> Bool
    let onMoveUp: () -> Void
    let onMoveDown: () -> Void

    private static let rowHeight: CGFloat = 46

    var body: some View {
        let running = model.instanceStatus(for: profile).isRunning
        HStack(spacing: 9) {
            Button(action: onOpen) {
                ProfileIconView(profile: profile, size: 32)
            }
            .buttonStyle(.plain)
            .disabled(model.isBusy(profile))
            .help(running ? "Focus \(profile.name)" : "Open \(profile.name)")
            .accessibilityLabel(running ? "Focus \(profile.name)" : "Open \(profile.name)")

            Button(action: onSelect) {
                HStack(spacing: 9) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(profile.name)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        HStack(spacing: 6) {
                            if model.preferences.showStatusInProfileList {
                                StatusDot(isRunning: running, size: 6)
                            }
                            Text(sidebarSubtitle)
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(isSelected ? [.isSelected] : [])
            .accessibilityValue(running ? "Running" : "Stopped")
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment:
                    onMoveDown()
                case .decrement:
                    onMoveUp()
                @unknown default:
                    break
                }
            }
        }
        .padding(.horizontal, 10)
        .frame(height: Self.rowHeight)
        .background(isSelected ? AgentDockPalette.selection : .clear, in: .rect(cornerRadius: 8))
        .draggable(profile.id.uuidString)
        .dropDestination(for: String.self) { items, location in
            guard let rawID = items.first,
                  let draggedID = CodexProfile.ID(uuidString: rawID)
            else {
                return false
            }
            return onMove(draggedID, location.y >= Self.rowHeight / 2)
        }
    }

    private var sidebarSubtitle: String {
        guard profile.product == .codex else { return profile.slug }
        let provider = model.effectiveCodexConfigProfile(for: profile)?.displayName
            ?? "Built-in Codex"
        return "\(profile.slug) · \(provider)"
    }
}

extension Notification.Name {
    static let agentDockFocusSearch = Notification.Name("AgentDock.focusSearch")
    static let agentDockFocusProfileSearch = Notification.Name("AgentDock.focusProfileSearch")
}
