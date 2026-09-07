import AppKit
import CodexerCore
import SwiftUI

enum CodexerSidebarSelection: Hashable {
    case official(DesktopProduct)
    case profile(CodexProfile.ID)
}

enum AgentDockDetailTab: String, CaseIterable, Identifiable {
    case overview
    case chats
    case advanced

    var id: Self { self }

    var title: String {
        rawValue.capitalized
    }

    static func availableTabs(hasManagedProfile: Bool) -> [Self] {
        hasManagedProfile ? allCases : [.overview, .chats]
    }
}

@MainActor
final class CodexerModel: ObservableObject {
    @Published private(set) var profiles: [CodexProfile] = []
    @Published var sidebarSelection: CodexerSidebarSelection? {
        didSet {
            guard sidebarSelection != oldValue else { return }
            cancelChatWork()
            loadedChatSelection = nil
            selectedChatID = nil
            chatSessions = []
            chatAvailability = .available
            chatTranscriptEntries = []
            chatTranscriptCursor = nil
            chatTranscriptSourceChanged = false
            chatsLoading = false
            chatTranscriptLoading = false
            chatOlderTranscriptLoading = false
        }
    }
    @Published private(set) var appURLs: [DesktopProduct: URL]
    @Published var errorMessage: String?
    @Published var showAddProfile = false
    @Published var showEditProfile = false
    @Published var detailTab: AgentDockDetailTab = .overview
    @Published var pendingRemoveProfile: CodexProfile?
    @Published var pendingDeleteProfile: CodexProfile?
    @Published private(set) var chatSessions: [LocalChatSession] = []
    @Published private(set) var chatAvailability: LocalChatAvailability = .available
    @Published private(set) var chatsLoading = false
    @Published private(set) var chatTranscriptLoading = false
    @Published private(set) var chatOlderTranscriptLoading = false
    @Published private(set) var chatTranscriptEntries: [LocalChatTranscriptEntry] = []
    @Published private(set) var chatTranscriptSourceChanged = false
    @Published var selectedChatID: LocalChatSession.ID?
    @Published private(set) var analyticsConsent = ProductAnalytics.shared.consent
    @Published var preferences: AgentDockPreferences {
        didSet {
            preferencesStore.save(preferences)
            configureProfileActivityRefresh()
        }
    }
    @Published private(set) var officialCodexProfileSettings: OfficialCodexProfileSettings
    @Published private(set) var profileStats: [CodexProfile.ID: ProfileStats] = [:]
    @Published private(set) var statsLoadingProfileIDs: Set<CodexProfile.ID> = []
    @Published private(set) var profileRateLimits: [CodexProfile.ID: ProfileRateLimits] = [:]
    @Published private(set) var officialCodexStats = ProfileStats.empty
    @Published private(set) var officialClaudeStats = ProfileStats.empty
    @Published private(set) var officialStatsLoading = false
    @Published private(set) var officialCodexRateLimits: ProfileRateLimits?
    @Published private(set) var officialClaudeRateLimits: ProfileRateLimits?
    @Published private(set) var profileInstanceStatuses: [CodexProfile.ID: CodexInstanceStatus] = [:]
    @Published private(set) var stockInstanceStatuses: [DesktopProduct: CodexInstanceStatus] = [:]
    @Published private(set) var installedShortcutProfileIDs: Set<CodexProfile.ID> = []
    @Published private(set) var busyProfileIDs: Set<CodexProfile.ID> = []
    @Published private(set) var busyStockProducts: Set<DesktopProduct> = []
    @Published private(set) var storeMutationInProgress = false

    private var store: ProfileStore?
    private let instanceController: any DesktopInstanceManaging
    private let shortcutInstaller: any ShortcutManaging
    private let statsScanner: any ProfileStatsScanning
    private let rateLimitClient: any ProfileRateLimitFetching
    private let claudeUsageClient: any ClaudeUsageFetching
    private let chatScanner: LocalChatScanner
    private let preferencesStore: AgentDockPreferencesStore
    private let appPathKeyPrefix = "AgentDock.desktopAppPath"
    private var statsRefreshTask: Task<Void, Never>?
    private var rateLimitRefreshTask: Task<Void, Never>?
    private var instanceMonitorTask: Task<Void, Never>?
    private var chatRefreshTask: Task<Void, Never>?
    private var chatTranscriptTask: Task<Void, Never>?
    private var chatChangeMonitorTask: Task<Void, Never>?
    private var profileActivityRefreshTask: Task<Void, Never>?
    private var workspaceNotificationTasks: [Task<Void, Never>] = []
    private var workspaceRefreshTask: Task<Void, Never>?
    private var allowsAutomaticRefresh = false
    private var statsGeneration = 0
    private var rateLimitGeneration = 0
    private var chatGeneration = 0
    private var chatTranscriptGeneration = 0
    private var chatTranscriptCursor: LocalChatTranscriptCursor?
    private var loadedChatSelection: CodexerSidebarSelection?
    private var appliedInitialDefaultView = false
    private let officialCodexHomeURL: URL
    private let officialClaudeUserDataURL: URL
    private let officialClaudeCodeHomeURL: URL

    init() {
        officialCodexHomeURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex", isDirectory: true)
        officialClaudeUserDataURL = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0].appendingPathComponent("Claude", isDirectory: true)
        officialClaudeCodeHomeURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude", isDirectory: true)
        let preferencesStore = AgentDockPreferencesStore()
        self.preferencesStore = preferencesStore
        preferences = preferencesStore.load()
        officialCodexProfileSettings = preferencesStore.loadOfficialCodexProfileSettings()
        chatScanner = LocalChatScanner()
        instanceController = DesktopInstanceController()
        shortcutInstaller = ShortcutInstaller()
        statsScanner = ProfileStatsScanner()
        rateLimitClient = CodexRateLimitClient()
        claudeUsageClient = ClaudeUsageClient()
        allowsAutomaticRefresh = true
        let storedPaths: [DesktopProduct: String?] = [
            .codex: UserDefaults.standard.string(
                forKey: "AgentDock.desktopAppPath.codex"
            ) ?? UserDefaults.standard.string(forKey: "Codexer.desktopAppPath.codex")
                ?? UserDefaults.standard.string(forKey: "Codexer.codexAppPath"),
            .claude: UserDefaults.standard.string(
                forKey: "AgentDock.desktopAppPath.claude"
            ) ?? UserDefaults.standard.string(forKey: "Codexer.desktopAppPath.claude")
        ]
        appURLs = [
            .codex: storedPaths[.codex].flatMap { $0 }.map(URL.init(fileURLWithPath:))
                ?? CodexAppLocator.defaultCodexAppURL()
                ?? DesktopAppRegistry.codex.defaultAppURL,
            .claude: storedPaths[.claude].flatMap { $0 }.map(URL.init(fileURLWithPath:))
                ?? DesktopAppRegistry.claude.defaultAppURL
        ]
        startInstanceMonitoring()
        ProductAnalytics.shared.capture(AnalyticsEvent(
            .appLifecycle,
            [.action(.launched), .trigger(.user)]
        ))

        let legacyDefaultConfigProfile = preferencesStore.legacyDefaultCodexConfigProfile()
        Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                Result {
                    let selection = Self.validatedAppSelections(storedPaths: storedPaths)
                    let store = try ProfileStore(codexAppURL: selection.urls[.codex])
                    if let legacyDefaultConfigProfile {
                        for profile in store.profiles where
                            profile.product == .codex
                                && profile.codexDefaultConfigProfile == nil
                                && profile.codexLaunchProfileSelection
                                    == .named(legacyDefaultConfigProfile)
                        {
                            try store.setCodexDefaultConfigProfile(
                                id: profile.id,
                                configProfile: legacyDefaultConfigProfile
                            )
                        }
                    }
                    return (
                        store,
                        selection
                    )
                }
            }.value
            guard let self else { return }
            switch result {
            case let .success((store, selection)):
                if legacyDefaultConfigProfile != nil {
                    preferencesStore.clearLegacyDefaultCodexConfigProfile()
                }
                self.store = store
                self.appURLs = selection.urls
                self.errorMessage = selection.errorMessages.first
                self.reload()
                self.refreshOutdatedShortcuts()
                self.configureProfileActivityRefresh()
                await self.refreshInstanceStatuses()
                for product in DesktopProduct.allCases {
                    ProductAnalytics.shared.capture(AnalyticsEvent(
                        .providerStatus,
                        [.action(.validated), .outcome(.succeeded), .provider(product.analyticsProvider)]
                    ))
                }
            case let .failure(error):
                self.store = nil
                self.errorMessage = "AgentDock could not load profile metadata safely: \(error.localizedDescription)"
            }
        }
    }

    init(
        store: ProfileStore,
        officialDataRootURL: URL,
        codexAppURL: URL,
        claudeAppURL: URL = DesktopAppRegistry.claude.defaultAppURL,
        instanceController: any DesktopInstanceManaging = DesktopInstanceController(),
        shortcutInstaller: any ShortcutManaging = ShortcutInstaller(),
        statsScanner: any ProfileStatsScanning = ProfileStatsScanner(),
        rateLimitClient: any ProfileRateLimitFetching = CodexRateLimitClient(),
        claudeUsageClient: any ClaudeUsageFetching = ClaudeUsageClient(),
        preferencesStore: AgentDockPreferencesStore = AgentDockPreferencesStore(),
        chatScanner: LocalChatScanner? = nil,
        startMonitoring: Bool = false,
        loadActivityOnInit: Bool = true
    ) {
        officialCodexHomeURL = officialDataRootURL.appendingPathComponent(".codex", isDirectory: true)
        officialClaudeUserDataURL = officialDataRootURL.appendingPathComponent("Claude", isDirectory: true)
        officialClaudeCodeHomeURL = officialDataRootURL.appendingPathComponent(".claude", isDirectory: true)
        self.preferencesStore = preferencesStore
        preferences = preferencesStore.load()
        officialCodexProfileSettings = preferencesStore.loadOfficialCodexProfileSettings()
        self.chatScanner = chatScanner ?? LocalChatScanner(
            indexRootURL: officialDataRootURL.appendingPathComponent("ChatIndexes", isDirectory: true)
        )
        self.store = store
        appURLs = [.codex: codexAppURL, .claude: claudeAppURL]
        self.instanceController = instanceController
        self.shortcutInstaller = shortcutInstaller
        self.statsScanner = statsScanner
        self.rateLimitClient = rateLimitClient
        self.claudeUsageClient = claudeUsageClient
        allowsAutomaticRefresh = startMonitoring
        reload(refreshData: loadActivityOnInit)
        if startMonitoring {
            startInstanceMonitoring()
        }
        configureProfileActivityRefresh()
    }

    deinit {
        statsRefreshTask?.cancel()
        rateLimitRefreshTask?.cancel()
        instanceMonitorTask?.cancel()
        chatRefreshTask?.cancel()
        chatTranscriptTask?.cancel()
        chatChangeMonitorTask?.cancel()
        profileActivityRefreshTask?.cancel()
        workspaceNotificationTasks.forEach { $0.cancel() }
        workspaceRefreshTask?.cancel()
    }

    var codexAppURL: URL {
        appURL(for: .codex)
    }

    var claudeAppURL: URL {
        appURL(for: .claude)
    }

    var stockInstanceStatus: CodexInstanceStatus {
        stockInstanceStatuses[.codex] ?? CodexInstanceStatus()
    }

    var stockOperationInProgress: Bool {
        busyStockProducts.contains(.codex)
    }

    func appURL(for product: DesktopProduct) -> URL {
        appURLs[product] ?? DesktopAppRegistry.descriptor(for: product).defaultAppURL
    }

    var selectedProfile: CodexProfile? {
        guard let selectedProfileID else { return nil }
        return profiles.first { $0.id == selectedProfileID }
    }

    var selectedProfileID: CodexProfile.ID? {
        get {
            guard case let .profile(id) = sidebarSelection else { return nil }
            return id
        }
        set {
            sidebarSelection = newValue.map(CodexerSidebarSelection.profile)
        }
    }

    var showsOfficialCodex: Bool {
        selectedOfficialProduct == .codex
    }

    var selectedOfficialProduct: DesktopProduct? {
        guard case let .official(product) = sidebarSelection else { return nil }
        return product
    }

    func selectOfficialCodex() {
        selectOfficial(.codex)
    }

    func selectOfficial(_ product: DesktopProduct) {
        if detailTab == .advanced {
            detailTab = .overview
        }
        sidebarSelection = .official(product)
        refreshChats()
        ProductAnalytics.shared.capture(AnalyticsEvent(
            .navigation,
            [.action(.selected), .surface(.overview), .provider(product.analyticsProvider)]
        ))
    }

    func selectProfile(_ id: CodexProfile.ID?) {
        sidebarSelection = id.map(CodexerSidebarSelection.profile)
        refreshChats()
        ProductAnalytics.shared.capture(AnalyticsEvent(
            .navigation,
            [.action(.selected), .surface(.overview)]
        ))
    }

    @discardableResult
    func reorderProfile(
        _ profileID: CodexProfile.ID,
        relativeTo targetID: CodexProfile.ID,
        placeAfter: Bool
    ) -> Bool {
        guard profileID != targetID,
              let profile = profiles.first(where: { $0.id == profileID }),
              let target = profiles.first(where: { $0.id == targetID }),
              profile.product == target.product,
              let store,
              beginStoreMutationIfAvailable()
        else {
            return false
        }

        let product = profile.product
        let currentIDs = profiles.filter { $0.product == product }.map(\.id)
        var orderedIDs = currentIDs
        guard let sourceIndex = orderedIDs.firstIndex(of: profileID),
              let originalTargetIndex = orderedIDs.firstIndex(of: targetID)
        else {
            storeMutationInProgress = false
            return false
        }
        orderedIDs.remove(at: sourceIndex)
        let adjustedTargetIndex = originalTargetIndex - (sourceIndex < originalTargetIndex ? 1 : 0)
        let destinationIndex = adjustedTargetIndex + (placeAfter ? 1 : 0)
        orderedIDs.insert(profileID, at: destinationIndex)
        guard orderedIDs != currentIDs else {
            storeMutationInProgress = false
            return true
        }

        let previousProfiles = profiles
        let persistedOrder = orderedIDs
        profiles = Self.applyingProfileOrder(
            persistedOrder,
            for: product,
            to: profiles
        )
        Task { [weak self] in
            guard let self else { return }
            defer { storeMutationInProgress = false }
            do {
                try await Task.detached(priority: .userInitiated) { [store, product, persistedOrder] in
                    try store.reorderProfiles(product: product, orderedIDs: persistedOrder)
                }.value
                reload(refreshData: false)
                errorMessage = nil
            } catch {
                profiles = previousProfiles
                present(error, code: .persistenceFailed, provider: product.analyticsProvider, action: .edited)
            }
        }
        return true
    }

    private static func applyingProfileOrder(
        _ orderedIDs: [CodexProfile.ID],
        for product: DesktopProduct,
        to profiles: [CodexProfile]
    ) -> [CodexProfile] {
        let profilesByID = Dictionary(
            uniqueKeysWithValues: profiles.lazy
                .filter { $0.product == product }
                .map { ($0.id, $0) }
        )
        var orderedIterator = orderedIDs.makeIterator()
        return profiles.map { profile in
            guard profile.product == product,
                  let id = orderedIterator.next(),
                  let orderedProfile = profilesByID[id]
            else {
                return profile
            }
            return orderedProfile
        }
    }

    func reload(refreshData: Bool = true) {
        guard let store else { return }
        profiles = store.profiles
        installedShortcutProfileIDs = Set(
            profiles.lazy.filter { self.shortcutInstaller.shortcutExists(for: $0) }.map(\.id)
        )
        if selectedOfficialProduct == nil,
           selectedProfileID == nil || !profiles.contains(where: { $0.id == selectedProfileID })
        {
            selectedProfileID = profiles.first?.id
        }
        if !appliedInitialDefaultView {
            switch preferences.defaultView {
            case .lastOpened:
                if let lastOpened = profiles
                    .filter({ $0.lastLaunchedAt != nil })
                    .max(by: {
                        ($0.lastLaunchedAt ?? .distantPast)
                            < ($1.lastLaunchedAt ?? .distantPast)
                    })
                {
                    selectedProfileID = lastOpened.id
                }
                detailTab = .overview
            case .overview:
                detailTab = .overview
            case .chats:
                detailTab = .chats
            }
            appliedInitialDefaultView = true
        }
        if refreshData {
            refreshStats()
        }
    }

    func stats(for profile: CodexProfile) -> ProfileStats {
        profileStats[profile.id] ?? .empty
    }

    func statsAreLoading(for profile: CodexProfile) -> Bool {
        statsLoadingProfileIDs.contains(profile.id)
    }

    func rateLimits(for profile: CodexProfile) -> ProfileRateLimits? {
        profileRateLimits[profile.id]
    }

    func instanceStatus(for profile: CodexProfile) -> CodexInstanceStatus {
        profileInstanceStatuses[profile.id] ?? CodexInstanceStatus()
    }

    func isBusy(_ profile: CodexProfile) -> Bool {
        busyProfileIDs.contains(profile.id)
    }

    func refreshStats(allowCredentialInteraction: Bool = false) {
        refreshStats(for: profiles, replaceAll: true)
        refreshRateLimits(
            for: profiles,
            replaceAll: true,
            allowCredentialInteraction: allowCredentialInteraction
        )
    }

    func refreshStats(for profile: CodexProfile) {
        refreshStats(for: [profile], replaceAll: false)
    }

    func refreshRateLimits() {
        refreshRateLimits(
            for: profiles,
            replaceAll: true
        )
    }

    private func refreshStats(for profiles: [CodexProfile], replaceAll: Bool) {
        statsRefreshTask?.cancel()
        statsGeneration += 1
        let generation = statsGeneration
        let scanner = statsScanner
        let officialCodexHomeURL = officialCodexHomeURL
        let officialClaudeUserDataURL = officialClaudeUserDataURL
        let officialClaudeCodeHomeURL = officialClaudeCodeHomeURL
        statsLoadingProfileIDs.removeAll()
        officialStatsLoading = false
        if replaceAll {
            statsLoadingProfileIDs = Set(profiles.map(\.id))
            officialStatsLoading = true
        } else {
            statsLoadingProfileIDs.formUnion(profiles.map(\.id))
        }

        statsRefreshTask = Task { [weak self] in
            let worker = Task.detached(priority: .utility) {
                var collected: [CodexProfile.ID: ProfileStats] = [:]
                let official = replaceAll
                    ? scanner.stats(
                        codexHomeURL: officialCodexHomeURL,
                        dataRootURL: officialCodexHomeURL,
                        now: Date()
                    )
                    : nil
                let officialClaude = replaceAll
                    ? scanner.stats(
                        claudeUserDataURL: officialClaudeUserDataURL,
                        claudeCodeHomeURL: officialClaudeCodeHomeURL,
                        dataRootURL: officialClaudeUserDataURL,
                        now: Date()
                    )
                    : nil
                for profile in profiles {
                    guard !Task.isCancelled else {
                        return (collected, official, officialClaude)
                    }
                    collected[profile.id] = scanner.stats(for: profile, now: Date())
                }
                return (collected, official, officialClaude)
            }
            let results = await withTaskCancellationHandler {
                await worker.value
            } onCancel: {
                worker.cancel()
            }
            guard !Task.isCancelled, let self, self.statsGeneration == generation else { return }
            self.statsLoadingProfileIDs.subtract(profiles.map(\.id))
            if replaceAll {
                self.officialStatsLoading = false
            }
            if replaceAll {
                self.profileStats = results.0
                if let official = results.1 {
                    self.officialCodexStats = official
                }
                if let officialClaude = results.2 {
                    self.officialClaudeStats = officialClaude
                }
            } else {
                self.profileStats.merge(results.0) { _, new in new }
            }
        }
    }

    private func refreshRateLimits(
        for profiles: [CodexProfile],
        replaceAll: Bool,
        allowCredentialInteraction: Bool = false
    ) {
        let profiles = profiles.map(resolvedProfileForLaunch)
        rateLimitRefreshTask?.cancel()
        rateLimitGeneration += 1
        let generation = rateLimitGeneration
        let client = rateLimitClient
        let claudeClient = claudeUsageClient
        let appURL = codexAppURL
        let officialHomeURL = officialCodexHomeURL
        let officialClaudeCodeHomeURL = officialClaudeCodeHomeURL
        let officialClaudeUserDataURL = officialClaudeUserDataURL
        let officialConfigProfile = effectiveOfficialCodexConfigProfile

        rateLimitRefreshTask = Task { [weak self] in
            // A provider may fulfill the async protocol with blocking I/O.
            // Keep it off the main actor while still propagating cancellation.
            let officialWorker = Task.detached(priority: .utility) {
                replaceAll
                    ? await client.fetchRateLimits(
                        codexHomeURL: officialHomeURL,
                        codexAppURL: appURL,
                        configProfile: officialConfigProfile
                    )
                    : nil
            }
            let officialClaudeWorker = Task.detached(priority: .utility) {
                replaceAll
                    ? await claudeClient.fetchOfficialUsage(
                        claudeCodeHomeURL: officialClaudeCodeHomeURL,
                        claudeUserDataURL: officialClaudeUserDataURL,
                        allowKeychainInteraction: allowCredentialInteraction,
                        forceRefresh: allowCredentialInteraction
                    )
                    : nil
            }
            async let officialResult = withTaskCancellationHandler {
                await officialWorker.value
            } onCancel: {
                officialWorker.cancel()
            }
            async let officialClaudeResult = withTaskCancellationHandler {
                await officialClaudeWorker.value
            } onCancel: {
                officialClaudeWorker.cancel()
            }
            let results = await withTaskGroup(
                of: (CodexProfile.ID, ProfileRateLimits).self,
                returning: [CodexProfile.ID: ProfileRateLimits].self
            ) { group in
                var iterator = profiles.makeIterator()
                for _ in 0..<min(4, profiles.count) {
                    if let profile = iterator.next() {
                        group.addTask {
                            let limits = switch profile.product {
                            case .codex:
                                await client.fetchRateLimits(for: profile, codexAppURL: appURL)
                            case .claude:
                                await claudeClient.fetchManagedUsage(
                                    claudeUserDataURL: profile.claudeUserDataPath,
                                    allowKeychainInteraction: allowCredentialInteraction,
                                    forceRefresh: allowCredentialInteraction
                                )
                            }
                            return (profile.id, limits)
                        }
                    }
                }

                var collected: [CodexProfile.ID: ProfileRateLimits] = [:]
                while let (id, limits) = await group.next() {
                    guard !Task.isCancelled else {
                        group.cancelAll()
                        return [:]
                    }
                    collected[id] = limits
                    if let profile = iterator.next() {
                        group.addTask {
                            let limits = switch profile.product {
                            case .codex:
                                await client.fetchRateLimits(for: profile, codexAppURL: appURL)
                            case .claude:
                                await claudeClient.fetchManagedUsage(
                                    claudeUserDataURL: profile.claudeUserDataPath,
                                    allowKeychainInteraction: allowCredentialInteraction,
                                    forceRefresh: allowCredentialInteraction
                                )
                            }
                            return (profile.id, limits)
                        }
                    }
                }
                return collected
            }
            let (official, officialClaude) = await (officialResult, officialClaudeResult)

            guard !Task.isCancelled, let self, self.rateLimitGeneration == generation else { return }
            if replaceAll {
                self.profileRateLimits = results
                self.officialCodexRateLimits = official
                self.officialClaudeRateLimits = officialClaude
            } else {
                self.profileRateLimits.merge(results) { _, new in new }
            }
            self.captureRateLimitAnalytics(
                profiles: profiles,
                limitsByProfileID: results,
                officialCodex: replaceAll ? official : nil,
                officialClaude: replaceAll ? officialClaude : nil,
                includeInventory: replaceAll
            )
        }
    }

    private func captureRateLimitAnalytics(
        profiles: [CodexProfile],
        limitsByProfileID: [CodexProfile.ID: ProfileRateLimits],
        officialCodex: ProfileRateLimits?,
        officialClaude: ProfileRateLimits?,
        includeInventory: Bool
    ) {
        var sources: [AnalyticsRateLimitSource] = profiles.map { profile in
            AnalyticsRateLimitSource(
                provider: profile.product.analyticsProvider,
                scope: .managed,
                limits: limitsByProfileID[profile.id] ?? ProfileRateLimits(
                    errorMessage: "Unavailable"
                )
            )
        }
        if let officialCodex {
            sources.append(AnalyticsRateLimitSource(
                provider: .codex,
                scope: .official,
                limits: officialCodex
            ))
        }
        if let officialClaude {
            sources.append(AnalyticsRateLimitSource(
                provider: .claude,
                scope: .official,
                limits: officialClaude
            ))
        }

        if includeInventory {
            let inventory = Dictionary(grouping: sources) { source in
                AnalyticsInventoryKey(
                    provider: source.provider,
                    scope: source.scope,
                    planTier: AnalyticsPlanTier(providerValue: source.limits.planType),
                    succeeded: source.limits.errorMessage == nil
                )
            }
            for (key, groupedSources) in inventory {
                ProductAnalytics.shared.capture(AnalyticsEvent(
                    .profileInventory,
                    [
                        .action(.observed),
                        .outcome(key.succeeded ? .succeeded : .failed),
                        .provider(key.provider),
                        .profileScope(key.scope),
                        .planTier(key.planTier),
                        .countBucket(.init(groupedSources.count))
                    ]
                ))
            }
        }

        let failuresByProvider = Dictionary(grouping: sources.filter {
            $0.limits.errorMessage != nil
        }, by: \.provider)
        for provider in failuresByProvider.keys {
            ProductAnalytics.shared.capture(AnalyticsEvent(
                .error,
                [.errorCode(.rateLimitUnavailable), .provider(provider), .action(.observed)]
            ))
        }

        var usageCounts: [AnalyticsUsageKey: Int] = [:]
        for source in sources where source.limits.errorMessage == nil {
            let planTier = AnalyticsPlanTier(providerValue: source.limits.planType)
            let primary = source.limits.buckets.compactMap(\.primary?.usedPercent).max()
            let secondary = source.limits.buckets.compactMap(\.secondary?.usedPercent).max()
            for (window, usedPercent) in [
                (AnalyticsLimitWindow.primary, primary),
                (AnalyticsLimitWindow.secondary, secondary)
            ] {
                guard let usedPercent else { continue }
                let key = AnalyticsUsageKey(
                    provider: source.provider,
                    scope: source.scope,
                    planTier: planTier,
                    window: window,
                    usageBucket: AnalyticsUsageBucket(usedPercent: usedPercent)
                )
                usageCounts[key, default: 0] += 1
            }
        }
        for (key, count) in usageCounts {
            ProductAnalytics.shared.capture(AnalyticsEvent(
                .usageSnapshot,
                [
                    .action(.observed),
                    .outcome(.succeeded),
                    .provider(key.provider),
                    .profileScope(key.scope),
                    .planTier(key.planTier),
                    .usageBucket(key.usageBucket),
                    .limitWindow(key.window),
                    .countBucket(.init(count))
                ]
            ))
        }
    }

    @discardableResult
    func addProfile(
        product: DesktopProduct = .codex,
        name: String,
        color: Color,
        iconKind: ProfileIconKind = .monogram,
        iconValue: String = "",
        customIconData: Data? = nil
    ) async -> Bool {
        let analyticsStart = ContinuousClock.now
        guard beginStoreMutationIfAvailable() else { return false }
        guard let store else {
            storeMutationInProgress = false
            present(CodexerModelError.storeUnavailable)
            return false
        }
        errorMessage = nil
        let iconColor = color.hexString
        let worker = Task.detached(priority: .userInitiated) {
            try store.createProfile(
                product: product,
                name: name,
                iconColor: iconColor,
                iconKind: iconKind,
                iconValue: iconValue,
                customIconData: customIconData
            )
        }
        defer { storeMutationInProgress = false }
        do {
            let profile = try await withTaskCancellationHandler {
                try await worker.value
            } onCancel: {
                worker.cancel()
            }
            try Task.checkCancellation()
            reload()
            selectProfile(profile.id)
            errorMessage = nil
            ProductAnalytics.shared.capture(AnalyticsEvent(
                .profileLifecycle,
                [.action(.created), .outcome(.succeeded), .provider(product.analyticsProvider), .countBucket(.init(profiles.count)), .durationBucket(analyticsDurationBucket(since: analyticsStart))]
            ))
            ProductAnalytics.shared.capture(AnalyticsEvent(
                .featureAdoption,
                [.action(.created), .feature(.managedProfiles), .provider(product.analyticsProvider)]
            ))
            return true
        } catch is CancellationError {
            ProductAnalytics.shared.capture(AnalyticsEvent(
                .profileLifecycle,
                [.action(.created), .outcome(.cancelled), .provider(product.analyticsProvider)]
            ))
            return false
        } catch {
            ProductAnalytics.shared.capture(AnalyticsEvent(
                .profileLifecycle,
                [.action(.created), .outcome(.failed), .provider(product.analyticsProvider)]
            ))
            present(error, code: .persistenceFailed, provider: product.analyticsProvider, action: .created)
            return false
        }
    }

    func restoreProfile(product: DesktopProduct? = nil) {
        guard beginStoreMutationIfAvailable() else { return }
        guard let store else {
            storeMutationInProgress = false
            present(CodexerModelError.storeUnavailable)
            return
        }
        let selectedProduct = product
            ?? selectedProfile?.product
            ?? selectedOfficialProduct
            ?? .codex
        let panel = NSOpenPanel()
        panel.title = "Restore \(selectedProduct.displayName) Profile"
        panel.prompt = "Restore"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = store.profilesRootDirectory(for: selectedProduct)

        guard panel.runModal() == .OK, let directory = panel.url else {
            storeMutationInProgress = false
            return
        }

        let name = directory.lastPathComponent.replacingOccurrences(of: "-", with: " ").capitalized
        Task { [weak self] in
            guard let self else { return }
            defer { storeMutationInProgress = false }
            do {
                let profile = try await Task.detached(priority: .userInitiated) {
                    try store.restoreProfile(
                        product: selectedProduct,
                        name: name,
                        profileDirectory: directory
                    )
                }.value
                reload()
                selectProfile(profile.id)
                errorMessage = nil
                ProductAnalytics.shared.capture(AnalyticsEvent(
                    .profileLifecycle,
                    [.action(.restored), .outcome(.succeeded), .provider(selectedProduct.analyticsProvider)]
                ))
            } catch {
                present(error, code: .persistenceFailed, provider: selectedProduct.analyticsProvider, action: .restored)
            }
        }
    }

    func chooseCodexApp() {
        chooseApp(.codex)
    }

    func chooseApp(_ product: DesktopProduct) {
        guard !profiles.contains(where: {
            $0.product == product && instanceStatus(for: $0).isRunning
        }) else {
            errorMessage = "Close running \(product.displayName) profiles before changing the provider app."
            return
        }
        let panel = NSOpenPanel()
        panel.title = "Select \(product.displayName).app"
        panel.prompt = "Select"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications")

        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }

        Task { [weak self] in
            guard let self else { return }
            do {
                try await instanceController.validateApp(product: product, at: url)
                let shortcutProfiles = profiles.filter {
                    $0.product == product && self.shortcutExists(for: $0)
                }.map(resolvedProfileForLaunch)
                let installer = shortcutInstaller
                try await Task.detached(priority: .userInitiated) {
                    for profile in shortcutProfiles {
                        try installer.installShortcut(for: profile, codexAppURL: url)
                    }
                }.value
                appURLs[product] = url
                UserDefaults.standard.set(
                    url.path,
                    forKey: "\(appPathKeyPrefix).\(product.rawValue)"
                )
                errorMessage = nil
                installedShortcutProfileIDs.formUnion(shortcutProfiles.map(\.id))
                if product == .codex {
                    refreshRateLimits()
                }
                await refreshInstanceStatuses()
                ProductAnalytics.shared.capture(AnalyticsEvent(
                    .providerStatus,
                    [.action(.configured), .outcome(.succeeded), .provider(product.analyticsProvider)]
                ))
            } catch {
                ProductAnalytics.shared.capture(AnalyticsEvent(
                    .providerStatus,
                    [.action(.configured), .outcome(.failed), .provider(product.analyticsProvider)]
                ))
                present(error, code: .invalidConfiguration, provider: product.analyticsProvider, action: .configured)
            }
        }
    }

    func launch(_ profile: CodexProfile) {
        let analyticsStart = ContinuousClock.now
        guard !isBusy(profile), !storeMutationInProgress else { return }
        busyProfileIDs.insert(profile.id)
        let appURL = appURL(for: profile.product)
        let launchProfile = resolvedProfileForLaunch(profile)

        Task { [weak self] in
            guard let self else { return }
            defer { busyProfileIDs.remove(profile.id) }
            do {
                guard let store else { throw CodexerModelError.storeUnavailable }
                _ = try await instanceController.open(profile: launchProfile, appURL: appURL)
                try await Task.detached(priority: .utility) {
                    try store.markLaunched(id: profile.id)
                }.value
                reload(refreshData: false)
                if let updated = store.profiles.first(where: { $0.id == profile.id }) {
                    refreshStats(for: updated)
                    refreshRateLimits(for: [updated], replaceAll: false)
                }
                errorMessage = nil
                ProductAnalytics.shared.capture(AnalyticsEvent(
                    .launcherLifecycle,
                    [.action(.opened), .outcome(.succeeded), .provider(profile.product.analyticsProvider), .trigger(.user), .durationBucket(analyticsDurationBucket(since: analyticsStart))]
                ))
            } catch {
                ProductAnalytics.shared.capture(AnalyticsEvent(
                    .launcherLifecycle,
                    [.action(.opened), .outcome(.failed), .provider(profile.product.analyticsProvider), .trigger(.user)]
                ))
                present(error, code: .launchFailed, provider: profile.product.analyticsProvider, action: .opened)
            }
            await refreshInstanceStatuses()
        }
    }

    func openStockCodex() {
        openStock(.codex)
    }

    func openStock(_ product: DesktopProduct) {
        guard !busyStockProducts.contains(product) else { return }
        busyStockProducts.insert(product)
        let appURL = appURL(for: product)
        let configProfile = product == .codex ? effectiveOfficialCodexConfigProfile : nil
        let codexHomeURL = product == .codex ? officialCodexHomeURL : nil

        Task { [weak self] in
            guard let self else { return }
            defer { busyStockProducts.remove(product) }
            do {
                _ = try await instanceController.openStock(
                    product: product,
                    appURL: appURL,
                    codexHomeURL: codexHomeURL,
                    codexConfigProfile: configProfile
                )
                errorMessage = nil
                ProductAnalytics.shared.capture(AnalyticsEvent(
                    .launcherLifecycle,
                    [.action(.opened), .outcome(.succeeded), .provider(product.analyticsProvider), .trigger(.user)]
                ))
            } catch {
                present(error, code: .launchFailed, provider: product.analyticsProvider, action: .opened)
            }
            await refreshInstanceStatuses()
        }
    }

    func close(_ profile: CodexProfile) {
        guard !isBusy(profile) else { return }
        busyProfileIDs.insert(profile.id)
        let appURL = appURL(for: profile.product)

        Task { [weak self] in
            guard let self else { return }
            defer { busyProfileIDs.remove(profile.id) }
            do {
                _ = try await instanceController.close(profile: profile, appURL: appURL)
                errorMessage = nil
                ProductAnalytics.shared.capture(AnalyticsEvent(
                    .launcherLifecycle,
                    [.action(.closed), .outcome(.succeeded), .provider(profile.product.analyticsProvider), .trigger(.user)]
                ))
            } catch {
                ProductAnalytics.shared.capture(AnalyticsEvent(
                    .launcherLifecycle,
                    [.action(.closed), .outcome(.failed), .provider(profile.product.analyticsProvider), .trigger(.user)]
                ))
                present(error, code: .closeFailed, provider: profile.product.analyticsProvider, action: .closed)
            }
            await refreshInstanceStatuses()
        }
    }

    func installShortcut(_ profile: CodexProfile) {
        guard !isBusy(profile), !storeMutationInProgress else { return }
        busyProfileIDs.insert(profile.id)
        let installer = shortcutInstaller
        let appURL = appURL(for: profile.product)
        let launchProfile = resolvedProfileForLaunch(profile)
        Task { [weak self] in
            guard let self else { return }
            defer { busyProfileIDs.remove(profile.id) }
            do {
                try await Task.detached(priority: .utility) {
                    try installer.installShortcut(for: launchProfile, codexAppURL: appURL)
                }.value
                reload(refreshData: false)
                errorMessage = nil
                ProductAnalytics.shared.capture(AnalyticsEvent(
                    .launcherLifecycle,
                    [.action(.installed), .outcome(.succeeded), .provider(profile.product.analyticsProvider), .trigger(.user)]
                ))
                ProductAnalytics.shared.capture(AnalyticsEvent(
                    .featureAdoption,
                    [.action(.installed), .feature(.shortcuts), .provider(profile.product.analyticsProvider)]
                ))
            } catch {
                ProductAnalytics.shared.capture(AnalyticsEvent(
                    .launcherLifecycle,
                    [.action(.installed), .outcome(.failed), .provider(profile.product.analyticsProvider), .trigger(.user)]
                ))
                present(error, code: .shortcutFailed, provider: profile.product.analyticsProvider, action: .installed)
            }
        }
    }

    func removeShortcut(_ profile: CodexProfile) {
        guard !isBusy(profile), !storeMutationInProgress else { return }
        busyProfileIDs.insert(profile.id)
        let installer = shortcutInstaller
        Task { [weak self] in
            guard let self else { return }
            defer { busyProfileIDs.remove(profile.id) }
            do {
                try await Task.detached(priority: .utility) {
                    try installer.removeShortcut(for: profile)
                }.value
                reload(refreshData: false)
                errorMessage = nil
                ProductAnalytics.shared.capture(AnalyticsEvent(
                    .launcherLifecycle,
                    [.action(.uninstalled), .outcome(.succeeded), .provider(profile.product.analyticsProvider), .trigger(.user)]
                ))
            } catch {
                present(error, code: .shortcutFailed, provider: profile.product.analyticsProvider, action: .uninstalled)
            }
        }
    }

    func removeProfileFromList(_ profile: CodexProfile) {
        guard beginStoreMutationIfAvailable() else { return }
        guard let store else {
            storeMutationInProgress = false
            present(CodexerModelError.storeUnavailable)
            return
        }
        cancelChatWork()
        let chatScanner = chatScanner
        Task { [weak self] in
            guard let self else { return }
            defer { storeMutationInProgress = false }
            do {
                try await Task.detached(priority: .userInitiated) {
                    try store.removeProfile(id: profile.id, policy: .removeFromList)
                    chatScanner.removeIndex(profileID: profile.id)
                }.value
                reload()
                errorMessage = nil
                ProductAnalytics.shared.capture(AnalyticsEvent(
                    .profileLifecycle,
                    [.action(.removed), .outcome(.succeeded), .provider(profile.product.analyticsProvider), .countBucket(.init(profiles.count))]
                ))
            } catch {
                present(error, code: .persistenceFailed, provider: profile.product.analyticsProvider, action: .removed)
            }
        }
    }

    func confirmRemoveProfile(_ profile: CodexProfile) {
        pendingRemoveProfile = profile
    }

    func updateProfile(
        _ profile: CodexProfile,
        name: String,
        color: Color,
        iconKind: ProfileIconKind,
        iconValue: String,
        customIconData: Data?
    ) {
        guard beginStoreMutationIfAvailable() else { return }
        guard let store else {
            storeMutationInProgress = false
            present(CodexerModelError.storeUnavailable)
            return
        }
        let hadShortcut = shortcutExists(for: profile)
        let installer = shortcutInstaller
        let appURL = appURL(for: profile.product)
        Task { [weak self] in
            guard let self else { return }
            defer { storeMutationInProgress = false }
            do {
                let updated = try await Task.detached(priority: .userInitiated) {
                    let result = try store.updateProfile(
                        id: profile.id,
                        name: name,
                        iconColor: color.hexString,
                        iconKind: iconKind,
                        iconValue: iconValue,
                        customIconData: customIconData
                    )
                    if hadShortcut {
                        var shortcutProfile = result
                        if shortcutProfile.product == .codex {
                            shortcutProfile.codexLaunchProfileSelection = Self
                                .resolvedCodexLaunchSelection(for: result)
                        }
                        try installer.installShortcut(for: shortcutProfile, codexAppURL: appURL)
                    }
                    return result
                }.value
                reload(refreshData: false)
                selectProfile(updated.id)
                showEditProfile = false
                errorMessage = nil
                ProductAnalytics.shared.capture(AnalyticsEvent(
                    .profileLifecycle,
                    [.action(.edited), .outcome(.succeeded), .provider(profile.product.analyticsProvider)]
                ))
            } catch {
                present(error, code: .persistenceFailed, provider: profile.product.analyticsProvider, action: .edited)
            }
        }
    }

    func deleteProfileData(_ profile: CodexProfile) {
        guard beginStoreMutationIfAvailable() else { return }
        guard let store else {
            storeMutationInProgress = false
            present(CodexerModelError.storeUnavailable)
            return
        }
        cancelRefreshes()
        cancelChatWork()
        busyProfileIDs.insert(profile.id)
        let chatScanner = chatScanner

        Task { [weak self] in
            guard let self else { return }
            defer {
                storeMutationInProgress = false
                busyProfileIDs.remove(profile.id)
            }
            do {
                try await Task.detached(priority: .utility) {
                    try store.removeProfile(id: profile.id, policy: .deleteAllData)
                    chatScanner.removeIndex(profileID: profile.id)
                }.value
                pendingDeleteProfile = nil
                reload()
                errorMessage = nil
                ProductAnalytics.shared.capture(AnalyticsEvent(
                    .profileLifecycle,
                    [.action(.deleted), .outcome(.succeeded), .provider(profile.product.analyticsProvider), .countBucket(.init(profiles.count))]
                ))
            } catch {
                present(error, code: .persistenceFailed, provider: profile.product.analyticsProvider, action: .deleted)
            }
        }
    }

    func revealData(_ profile: CodexProfile) {
        NSWorkspace.shared.activateFileViewerSelecting([profile.profileDirectory])
    }

    func revealOfficialCodexData() {
        NSWorkspace.shared.activateFileViewerSelecting([officialCodexHomeURL])
    }

    func revealOfficialData(_ product: DesktopProduct) {
        switch product {
        case .codex:
            revealOfficialCodexData()
        case .claude:
            NSWorkspace.shared.activateFileViewerSelecting([
                FileManager.default.urls(
                    for: .applicationSupportDirectory,
                    in: .userDomainMask
                )[0].appendingPathComponent("Claude", isDirectory: true)
            ])
        }
    }

    func revealShortcut(_ profile: CodexProfile) {
        NSWorkspace.shared.activateFileViewerSelecting([profile.shortcutPath])
    }

    func revealChat(_ session: LocalChatSession) {
        NSWorkspace.shared.activateFileViewerSelecting([session.sourceURL])
    }

    func copyChatMetadata(_ session: LocalChatSession) {
        var lines = [
            "Provider: \(session.provider.displayName)",
            "Profile: \(session.profileName)",
            "Started: \(session.startedAt.formatted(date: .abbreviated, time: .shortened))",
            "Updated: \(session.updatedAt.formatted(date: .abbreviated, time: .shortened))",
            "Activity span: \(Self.durationText(session.duration))",
            "Status: \(session.status)"
        ]
        if let model = session.model { lines.append("Model: \(model)") }
        if let repository = session.repository { lines.append("Folder: \(repository)") }
        if let branch = session.branch { lines.append("Branch: \(branch)") }
        if let tokenCount = session.tokenCount { lines.append("Tokens: \(tokenCount)") }
        let sanitizedID = session.id.count > 12
            ? "\(session.id.prefix(8))…\(session.id.suffix(6))"
            : session.id
        lines.append("Session ID: \(sanitizedID)")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
    }

    private static func durationText(_ duration: TimeInterval) -> String {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = duration >= 3600 ? [.hour, .minute] : [.minute, .second]
        formatter.unitsStyle = .abbreviated
        return formatter.string(from: duration) ?? "Unavailable"
    }

    func copyPath(_ url: URL) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.path, forType: .string)
    }

    func refreshChats() {
        let analyticsStart = ContinuousClock.now
        chatGeneration += 1
        let generation = chatGeneration
        chatRefreshTask?.cancel()
        chatTranscriptTask?.cancel()
        chatChangeMonitorTask?.cancel()
        let scanner = chatScanner
        let selection = sidebarSelection
        let profiles = profiles
        let officialHome = officialCodexHomeURL
        let officialClaudeUserData = officialClaudeUserDataURL
        let officialClaudeCodeHome = officialClaudeCodeHomeURL
        let preferredChatID = loadedChatSelection == selection ? selectedChatID : nil
        chatTranscriptGeneration += 1
        if loadedChatSelection != selection {
            selectedChatID = nil
            chatSessions = []
            chatTranscriptEntries = []
            chatTranscriptCursor = nil
            chatTranscriptSourceChanged = false
        }
        chatsLoading = true
        chatTranscriptLoading = false
        chatOlderTranscriptLoading = false
        chatRefreshTask = Task { [weak self] in
            let worker = Task.detached(priority: .utility) {
                switch selection {
                case let .profile(id):
                    guard let profile = profiles.first(where: { $0.id == id }) else {
                        return LocalChatScanResult(availability: .available, sessions: [])
                    }
                    return scanner.scan(profile: profile)
                case .official(.codex):
                    return scanner.scanOfficialCodex(codexHomeURL: officialHome)
                case .official(.claude):
                    return scanner.scanOfficialClaude(
                        claudeHomeURL: officialClaudeUserData,
                        claudeCodeHomeURL: officialClaudeCodeHome
                    )
                case nil:
                    return LocalChatScanResult(availability: .available, sessions: [])
                }
            }
            let result = await withTaskCancellationHandler {
                await worker.value
            } onCancel: {
                worker.cancel()
            }
            guard
                !Task.isCancelled,
                let self,
                self.chatGeneration == generation,
                self.sidebarSelection == selection
            else {
                return
            }
            chatSessions = result.sessions
            chatAvailability = result.availability
            loadedChatSelection = selection
            selectedChatID = preferredChatID.flatMap { preferred in
                result.sessions.contains(where: { $0.id == preferred }) ? preferred : nil
            } ?? result.sessions.first?.id
            chatsLoading = false
            ProductAnalytics.shared.capture(AnalyticsEvent(
                .chatUsage,
                [.action(.listed), .outcome(.succeeded), .countBucket(.init(result.sessions.count)), .durationBucket(analyticsDurationBucket(since: analyticsStart))]
            ))
            ProductAnalytics.shared.capture(AnalyticsEvent(
                .featureAdoption,
                [.action(.viewed), .feature(.chats), .surface(.chats)]
            ))
            loadSelectedChatTranscript()
            startChatChangeMonitoring(
                selection: selection,
                initialToken: result.changeToken,
                generation: generation
            )
        }
    }

    func selectChat(_ id: LocalChatSession.ID) {
        guard loadedChatSelection == sidebarSelection,
              chatSessions.contains(where: { $0.id == id }),
              id != selectedChatID
        else { return }
        selectedChatID = id
        ProductAnalytics.shared.capture(AnalyticsEvent(
            .chatUsage,
            [.action(.transcriptOpened)]
        ))
        loadSelectedChatTranscript()
    }

    private func loadSelectedChatTranscript() {
        chatTranscriptGeneration += 1
        let generation = chatTranscriptGeneration
        chatTranscriptTask?.cancel()
        chatTranscriptEntries = []
        chatTranscriptCursor = nil
        chatTranscriptSourceChanged = false
        chatOlderTranscriptLoading = false
        guard
            let selectedChatID,
            let summary = chatSessions.first(where: { $0.id == selectedChatID })
        else {
            chatTranscriptLoading = false
            return
        }
        let scanner = chatScanner
        chatTranscriptLoading = true
        chatTranscriptTask = Task { [weak self] in
            let worker = Task.detached(priority: .utility) {
                scanner.loadTranscriptForwardPage(for: summary)
            }
            let page = await withTaskCancellationHandler {
                await worker.value
            } onCancel: {
                worker.cancel()
            }
            guard
                !Task.isCancelled,
                let self,
                self.selectedChatID == selectedChatID,
                self.chatTranscriptGeneration == generation
            else {
                return
            }
            chatTranscriptEntries = page.entries
            chatTranscriptCursor = page.olderCursor
            chatTranscriptSourceChanged = page.sourceChanged
            chatTranscriptLoading = false
            if
                let continuation = page.olderCursor,
                page.entries.isEmpty || continuation.skippingOversizedLine
            {
                loadMoreChatTranscript()
            }
        }
    }

    var hasMoreChatTranscript: Bool {
        chatTranscriptCursor != nil
    }

    func loadMoreChatTranscript() {
        guard
            !chatTranscriptLoading,
            !chatOlderTranscriptLoading,
            let cursor = chatTranscriptCursor,
            let selectedChatID,
            let summary = chatSessions.first(where: { $0.id == selectedChatID })
        else {
            return
        }
        ProductAnalytics.shared.capture(AnalyticsEvent(
            .chatUsage,
            [.action(.transcriptPageLoaded)]
        ))
        let scanner = chatScanner
        let generation = chatTranscriptGeneration
        chatOlderTranscriptLoading = true
        chatTranscriptTask = Task { [weak self] in
            let worker = Task.detached(priority: .utility) {
                scanner.loadTranscriptForwardPage(for: summary, after: cursor)
            }
            let page = await withTaskCancellationHandler {
                await worker.value
            } onCancel: {
                worker.cancel()
            }
            guard
                !Task.isCancelled,
                let self,
                self.selectedChatID == selectedChatID,
                self.chatTranscriptGeneration == generation
            else {
                return
            }
            if page.sourceChanged {
                chatTranscriptEntries = []
                chatTranscriptCursor = nil
                chatTranscriptSourceChanged = true
                chatOlderTranscriptLoading = false
                loadSelectedChatTranscript()
                return
            }
            chatTranscriptEntries += page.entries
            chatTranscriptCursor = page.olderCursor
            chatTranscriptSourceChanged = chatTranscriptSourceChanged || page.sourceChanged
            chatOlderTranscriptLoading = false
            if
                let continuation = page.olderCursor,
                page.entries.isEmpty || continuation.skippingOversizedLine
            {
                loadMoreChatTranscript()
            }
        }
    }

    private func startChatChangeMonitoring(
        selection: CodexerSidebarSelection?,
        initialToken: String,
        generation: Int
    ) {
        guard selection != nil, detailTab == .chats else { return }
        let scanner = chatScanner
        let profiles = profiles
        let officialHome = officialCodexHomeURL
        let officialClaudeUserData = officialClaudeUserDataURL
        let officialClaudeCodeHome = officialClaudeCodeHomeURL
        chatChangeMonitorTask?.cancel()
        chatChangeMonitorTask = Task { [weak self] in
            var pendingToken: String?
            var matchingPolls = 0
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(5))
                } catch {
                    return
                }
                let worker = Task.detached(priority: .background) {
                    switch selection {
                    case let .profile(id):
                        guard let profile = profiles.first(where: { $0.id == id }) else {
                            return ""
                        }
                        return scanner.changeToken(profile: profile)
                    case .official(.codex):
                        return scanner.officialCodexChangeToken(codexHomeURL: officialHome)
                    case .official(.claude):
                        return scanner.officialClaudeChangeToken(
                            claudeHomeURL: officialClaudeUserData,
                            claudeCodeHomeURL: officialClaudeCodeHome
                        )
                    case nil:
                        return ""
                    }
                }
                let token = await withTaskCancellationHandler {
                    await worker.value
                } onCancel: {
                    worker.cancel()
                }
                guard
                    !Task.isCancelled,
                    let self,
                    self.chatGeneration == generation,
                    self.sidebarSelection == selection
                else {
                    return
                }
                if token == initialToken {
                    pendingToken = nil
                    matchingPolls = 0
                } else if token == pendingToken {
                    matchingPolls += 1
                } else {
                    pendingToken = token
                    matchingPolls = 1
                }
                if matchingPolls >= 2 {
                    ProductAnalytics.shared.capture(AnalyticsEvent(
                        .refresh,
                        [.action(.automaticRefresh), .surface(.chats), .trigger(.automatic)]
                    ))
                    refreshChats()
                    return
                }
            }
        }
    }

    func restorePreferences() {
        preferencesStore.restoreDefaults()
        preferences = .defaults
        officialCodexProfileSettings = .defaults
        refreshRateLimits()
    }

    var officialCodexConfigProfiles: [CodexConfigProfile] {
        CodexConfigProfile.discover(in: officialCodexHomeURL)
    }

    var effectiveOfficialCodexConfigProfile: CodexConfigProfile? {
        switch officialCodexProfileSettings.launchSelection {
        case .useDefault:
            officialCodexProfileSettings.defaultConfigProfile
        case .builtIn:
            nil
        case let .named(configProfile):
            configProfile
        }
    }

    func setOfficialCodexDefaultConfigProfile(_ configProfile: CodexConfigProfile?) {
        guard configProfile != officialCodexProfileSettings.defaultConfigProfile else { return }
        if let configProfile {
            do {
                try configProfile.validate(in: officialCodexHomeURL)
            } catch {
                present(error, code: .invalidConfiguration, provider: .codex, action: .configured)
                return
            }
        }
        var updated = officialCodexProfileSettings
        updated.defaultConfigProfile = configProfile
        applyOfficialCodexProfileSettings(
            updated,
            restart: updated.launchSelection == .useDefault
                && stockInstanceStatuses[.codex]?.isRunning == true
        )
    }

    func setOfficialCodexLaunchProfileSelection(_ selection: CodexLaunchProfileSelection) {
        guard selection != officialCodexProfileSettings.launchSelection else { return }
        let resolvedSelection = Self.resolvedCodexLaunchSelection(
            selection,
            defaultProfile: officialCodexProfileSettings.defaultConfigProfile
        )
        if case let .named(configProfile) = resolvedSelection {
            do {
                try configProfile.validate(in: officialCodexHomeURL)
            } catch {
                present(error, code: .invalidConfiguration, provider: .codex, action: .configured)
                return
            }
        }
        var updated = officialCodexProfileSettings
        updated.launchSelection = selection
        applyOfficialCodexProfileSettings(
            updated,
            restart: stockInstanceStatuses[.codex]?.isRunning == true
        )
    }

    private func applyOfficialCodexProfileSettings(
        _ settings: OfficialCodexProfileSettings,
        restart: Bool
    ) {
        guard !busyStockProducts.contains(.codex) else { return }
        officialCodexProfileSettings = settings
        preferencesStore.saveOfficialCodexProfileSettings(settings)
        refreshRateLimits()
        guard restart else {
            errorMessage = nil
            return
        }

        busyStockProducts.insert(.codex)
        let appURL = appURL(for: .codex)
        let configProfile = effectiveOfficialCodexConfigProfile
        let homeURL = officialCodexHomeURL
        Task { [weak self] in
            guard let self else { return }
            defer { busyStockProducts.remove(.codex) }
            do {
                _ = try await instanceController.closeOfficialCodex(appURL: appURL)
                _ = try await instanceController.openStock(
                    product: .codex,
                    appURL: appURL,
                    codexHomeURL: homeURL,
                    codexConfigProfile: configProfile
                )
                errorMessage = nil
            } catch {
                present(error, code: .launchFailed, provider: .codex, action: .configured)
            }
            await refreshInstanceStatuses()
        }
    }

    func codexConfigProfiles(for profile: CodexProfile) -> [CodexConfigProfile] {
        guard profile.product == .codex else { return [] }
        return CodexConfigProfile.discover(in: profile.codexHomePath)
    }

    func effectiveCodexConfigProfile(for profile: CodexProfile) -> CodexConfigProfile? {
        switch profile.codexLaunchProfileSelection {
        case .useDefault:
            profile.codexDefaultConfigProfile
        case .builtIn:
            nil
        case let .named(configProfile):
            configProfile
        }
    }

    func setDefaultCodexConfigProfile(
        _ configProfile: CodexConfigProfile?,
        for profile: CodexProfile
    ) {
        guard profile.product == .codex,
              configProfile != profile.codexDefaultConfigProfile,
              beginStoreMutationIfAvailable()
        else { return }
        guard let store else {
            storeMutationInProgress = false
            present(CodexerModelError.storeUnavailable)
            return
        }
        if let configProfile {
            do {
                try configProfile.validate(in: profile.codexHomePath)
            } catch {
                storeMutationInProgress = false
                present(error, code: .invalidConfiguration, provider: .codex, action: .configured)
                return
            }
        }

        let hadShortcut = shortcutExists(for: profile)
        let installer = shortcutInstaller
        let appURL = appURL(for: .codex)
        busyProfileIDs.insert(profile.id)
        Task { [weak self] in
            guard let self else { return }
            defer {
                storeMutationInProgress = false
                busyProfileIDs.remove(profile.id)
            }
            do {
                let updated = try await Task.detached(priority: .userInitiated) {
                    try store.setCodexDefaultConfigProfile(
                        id: profile.id,
                        configProfile: configProfile
                    )
                }.value
                if hadShortcut, updated.codexLaunchProfileSelection == .useDefault {
                    var shortcutProfile = updated
                    shortcutProfile.codexLaunchProfileSelection = Self
                        .resolvedCodexLaunchSelection(for: updated)
                    try await Task.detached(priority: .utility) {
                        try installer.installShortcut(for: shortcutProfile, codexAppURL: appURL)
                    }.value
                }
                reload(refreshData: false)
                selectProfile(profile.id)
                refreshRateLimits(for: [updated], replaceAll: false)
                errorMessage = nil
            } catch {
                reload(refreshData: false)
                selectProfile(profile.id)
                present(error, code: .persistenceFailed, provider: .codex, action: .configured)
            }
        }
    }

    func setCodexLaunchProfileSelection(
        _ selection: CodexLaunchProfileSelection,
        for profile: CodexProfile
    ) {
        guard profile.product == .codex,
              selection != profile.codexLaunchProfileSelection,
              beginStoreMutationIfAvailable()
        else { return }
        guard let store else {
            storeMutationInProgress = false
            present(CodexerModelError.storeUnavailable)
            return
        }

        let resolvedSelection = Self.resolvedCodexLaunchSelection(
            selection,
            defaultProfile: profile.codexDefaultConfigProfile
        )
        if case let .named(configProfile) = resolvedSelection {
            do {
                try configProfile.validate(in: profile.codexHomePath)
            } catch {
                storeMutationInProgress = false
                present(error, code: .invalidConfiguration, provider: .codex, action: .configured)
                return
            }
        }

        let wasRunning = instanceStatus(for: profile).isRunning
        let hadShortcut = shortcutExists(for: profile)
        let appURL = appURL(for: .codex)
        let installer = shortcutInstaller
        busyProfileIDs.insert(profile.id)
        Task { [weak self] in
            guard let self else { return }
            defer {
                storeMutationInProgress = false
                busyProfileIDs.remove(profile.id)
            }
            do {
                if wasRunning {
                    _ = try await instanceController.close(profile: profile, appURL: appURL)
                }
                let updated = try await Task.detached(priority: .userInitiated) {
                    try store.setCodexLaunchProfileSelection(
                        id: profile.id,
                        selection: selection
                    )
                }.value
                var resolvedProfile = updated
                resolvedProfile.codexLaunchProfileSelection = resolvedSelection
                let launchProfile = resolvedProfile
                if wasRunning {
                    _ = try await instanceController.open(profile: launchProfile, appURL: appURL)
                    try await Task.detached(priority: .utility) {
                        try store.markLaunched(id: profile.id)
                    }.value
                }
                if hadShortcut {
                    try await Task.detached(priority: .utility) {
                        try installer.installShortcut(for: launchProfile, codexAppURL: appURL)
                    }.value
                }
                reload(refreshData: false)
                selectProfile(profile.id)
                errorMessage = nil
            } catch {
                reload(refreshData: false)
                selectProfile(profile.id)
                present(error, code: .persistenceFailed, provider: .codex, action: .configured)
            }
            await refreshInstanceStatuses()
        }
    }

    private func resolvedProfileForLaunch(_ profile: CodexProfile) -> CodexProfile {
        guard profile.product == .codex else { return profile }
        var resolved = profile
        resolved.codexLaunchProfileSelection = resolvedCodexLaunchSelection(for: profile)
        return resolved
    }

    private func resolvedCodexLaunchSelection(
        for profile: CodexProfile
    ) -> CodexLaunchProfileSelection {
        Self.resolvedCodexLaunchSelection(for: profile)
    }

    nonisolated private static func resolvedCodexLaunchSelection(
        for profile: CodexProfile
    ) -> CodexLaunchProfileSelection {
        resolvedCodexLaunchSelection(
            profile.codexLaunchProfileSelection,
            defaultProfile: profile.codexDefaultConfigProfile
        )
    }

    nonisolated private static func resolvedCodexLaunchSelection(
        _ selection: CodexLaunchProfileSelection,
        defaultProfile: CodexConfigProfile?
    ) -> CodexLaunchProfileSelection {
        guard selection == .useDefault else { return selection }
        return defaultProfile.map(CodexLaunchProfileSelection.named) ?? .builtIn
    }

    func setAnalyticsConsent(granted: Bool, surface: AnalyticsSurface) {
        if granted {
            ProductAnalytics.shared.grantConsent(surface: surface)
            analyticsConsent = .granted
        } else {
            ProductAnalytics.shared.denyConsent()
            analyticsConsent = .denied
        }
    }

    func shortcutExists(for profile: CodexProfile) -> Bool {
        installedShortcutProfileIDs.contains(profile.id)
    }

    private func refreshOutdatedShortcuts() {
        let candidates = profiles.filter {
            shortcutInstaller.shortcutExists(for: $0)
                && shortcutInstaller.shortcutNeedsRefresh(for: $0)
        }.map(resolvedProfileForLaunch)
        guard !candidates.isEmpty else { return }
        let installer = shortcutInstaller
        let selectedAppURLs = appURLs
        Task { [weak self] in
            let failures = await Task.detached(priority: .utility) {
                var messages: [String] = []
                for profile in candidates {
                    do {
                        let appURL = selectedAppURLs[profile.product]
                            ?? DesktopAppRegistry.descriptor(for: profile.product).defaultAppURL
                        try installer.installShortcut(for: profile, codexAppURL: appURL)
                    } catch {
                        messages.append("\(profile.name): \(error.localizedDescription)")
                    }
                }
                return messages
            }.value
            guard let self else { return }
            installedShortcutProfileIDs.formUnion(candidates.map(\.id))
            ProductAnalytics.shared.capture(AnalyticsEvent(
                .launcherLifecycle,
                [.action(.repaired), .outcome(failures.isEmpty ? .succeeded : .failed), .provider(.mixed), .trigger(.automatic), .countBucket(.init(candidates.count))]
            ))
            if let firstFailure = failures.first {
                errorMessage = "AgentDock updated, but a profile shortcut could not be refreshed: \(firstFailure)"
                ProductAnalytics.shared.capture(AnalyticsEvent(
                    .error,
                    [.errorCode(.shortcutFailed), .provider(.mixed), .action(.repaired)]
                ))
            }
        }
    }

    private func present(
        _ error: Error,
        code requestedCode: AnalyticsErrorCode = .unknownSafe,
        surface: AnalyticsSurface? = nil,
        provider: AnalyticsProvider? = nil,
        action: AnalyticsAction? = nil
    ) {
        errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        let code: AnalyticsErrorCode = error is CodexerModelError ? .storeUnavailable : requestedCode
        var properties: [AnalyticsProperty] = [.errorCode(code)]
        if let surface { properties.append(.surface(surface)) }
        if let provider { properties.append(.provider(provider)) }
        if let action { properties.append(.action(action)) }
        ProductAnalytics.shared.capture(AnalyticsEvent(.error, properties))
    }

    private func beginStoreMutationIfAvailable() -> Bool {
        guard !storeMutationInProgress, busyProfileIDs.isEmpty else {
            errorMessage = "Another profile change is still in progress."
            ProductAnalytics.shared.capture(AnalyticsEvent(
                .error,
                [.errorCode(.operationBusy)]
            ))
            return false
        }
        storeMutationInProgress = true
        return true
    }

    private func startInstanceMonitoring() {
        instanceMonitorTask?.cancel()
        let center = NSWorkspace.shared.notificationCenter
        workspaceNotificationTasks.forEach { $0.cancel() }
        workspaceNotificationTasks.removeAll()
        for name in [
            NSWorkspace.didLaunchApplicationNotification,
            NSWorkspace.didTerminateApplicationNotification
        ] {
            workspaceNotificationTasks.append(
                Task { [weak self] in
                    for await notification in center.notifications(named: name) {
                        guard !Task.isCancelled else { return }
                        let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
                            as? NSRunningApplication
                        guard Self.isRelevantWorkspaceBundleIdentifier(
                            application?.bundleIdentifier
                        ) else { continue }
                        self?.scheduleWorkspaceStatusRefresh()
                    }
                }
            )
        }
        instanceMonitorTask = Task { [weak self] in
            while !Task.isCancelled {
                guard self != nil else { return }
                await self?.refreshInstanceStatuses()
                do {
                    try await Task.sleep(for: .seconds(60))
                } catch {
                    return
                }
            }
        }
    }

    nonisolated static func isRelevantWorkspaceBundleIdentifier(_ identifier: String?) -> Bool {
        identifier == DesktopAppRegistry.codex.bundleIdentifier
            || identifier == DesktopAppRegistry.claude.bundleIdentifier
    }

    private func scheduleWorkspaceStatusRefresh() {
        workspaceRefreshTask?.cancel()
        workspaceRefreshTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(150))
            } catch {
                return
            }
            await self?.refreshInstanceStatuses()
        }
    }

    private func configureProfileActivityRefresh() {
        profileActivityRefreshTask?.cancel()
        guard allowsAutomaticRefresh, preferences.refreshProfileActivity else { return }
        let interval = max(1, preferences.refreshIntervalMinutes)
        profileActivityRefreshTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(interval * 60))
                } catch {
                    return
                }
                guard !Task.isCancelled, let self else { return }
                ProductAnalytics.shared.capture(AnalyticsEvent(
                    .refresh,
                    [.action(.automaticRefresh), .surface(.overview), .trigger(.automatic), .countBucket(.init(self.profiles.count))]
                ))
                self.refreshStats()
                if self.detailTab == .chats {
                    self.refreshChats()
                }
            }
        }
    }

    private func refreshInstanceStatuses() async {
        let profileSnapshot = profiles
        let selectedApps = appURLs
        let controller = instanceController
        async let profileStatuses = try? controller.statuses(
            for: profileSnapshot,
            appURLs: selectedApps
        )
        let stockStatuses = await withTaskGroup(
            of: (DesktopProduct, CodexInstanceStatus?).self,
            returning: [DesktopProduct: CodexInstanceStatus].self
        ) { group in
            for product in DesktopProduct.allCases {
                let appURL = selectedApps[product]
                    ?? DesktopAppRegistry.descriptor(for: product).defaultAppURL
                group.addTask {
                    let status = try? await controller.stockStatus(
                        product: product,
                        appURL: appURL
                    )
                    return (product, status)
                }
            }
            var collected = stockInstanceStatuses
            for await (product, status) in group {
                if let status {
                    collected[product] = status
                }
            }
            return collected
        }
        let statuses = await profileStatuses
        guard !Task.isCancelled else { return }
        if let statuses, profileInstanceStatuses != statuses {
            profileInstanceStatuses = statuses
        }
        if stockInstanceStatuses != stockStatuses {
            stockInstanceStatuses = stockStatuses
        }
    }

    private func cancelRefreshes() {
        statsGeneration += 1
        rateLimitGeneration += 1
        statsRefreshTask?.cancel()
        rateLimitRefreshTask?.cancel()
        statsRefreshTask = nil
        rateLimitRefreshTask = nil
    }

    private func cancelChatWork() {
        chatGeneration += 1
        chatTranscriptGeneration += 1
        chatRefreshTask?.cancel()
        chatTranscriptTask?.cancel()
        chatChangeMonitorTask?.cancel()
        chatRefreshTask = nil
        chatTranscriptTask = nil
        chatChangeMonitorTask = nil
    }

    nonisolated private static func validatedAppSelections(
        storedPaths: [DesktopProduct: String?]
    ) -> (urls: [DesktopProduct: URL], errorMessages: [String]) {
        let codexSelection = validatedCodexAppSelection(
            storedPath: storedPaths[.codex] ?? nil
        )
        let claudeFallback = DesktopAppRegistry.claude.defaultAppURL
        let storedClaudePath = storedPaths[.claude] ?? nil
        let claudeCandidate = storedClaudePath.map(URL.init(fileURLWithPath:))
            ?? claudeFallback
        var messages = codexSelection.errorMessage.map { [$0] } ?? []
        let claudeURL: URL
        do {
            try OfficialDesktopAppValidator().validateApp(
                at: claudeCandidate,
                product: .claude
            )
            try ClaudeDesktopContractProbe().validate(appURL: claudeCandidate)
            claudeURL = claudeCandidate
        } catch {
            claudeURL = claudeFallback
            if storedClaudePath != nil {
                messages.append(
                    "The saved Claude.app was rejected. Select a signed, supported Claude Desktop build before launching a Claude profile."
                )
            }
        }
        return (
            [.codex: codexSelection.url, .claude: claudeURL],
            messages
        )
    }

    nonisolated private static func validatedCodexAppSelection(
        storedPath: String?
    ) -> (url: URL, errorMessage: String?) {
        let fallback = CodexAppLocator.defaultCodexAppURL()
            ?? URL(fileURLWithPath: "/Applications/Codex.app")
        let candidate = storedPath.map { URL(fileURLWithPath: $0) } ?? fallback

        do {
            try OfficialCodexAppValidator().validateCodexApp(at: candidate)
            return (candidate, nil)
        } catch {
            guard candidate != fallback else {
                return (
                    fallback,
                    "AgentDock will not run bundled Codex tools until a valid official Codex.app is selected: \(error.localizedDescription)"
                )
            }
            do {
                try OfficialCodexAppValidator().validateCodexApp(at: fallback)
                return (
                    fallback,
                    "The saved Codex.app was rejected, so AgentDock returned to /Applications/Codex.app."
                )
            } catch {
                return (
                    fallback,
                    "No valid official Codex.app is selected. Choose the signed app before launching a profile."
                )
            }
        }
    }
}

private struct AnalyticsRateLimitSource {
    let provider: AnalyticsProvider
    let scope: AnalyticsProfileScope
    let limits: ProfileRateLimits
}

private struct AnalyticsInventoryKey: Hashable {
    let provider: AnalyticsProvider
    let scope: AnalyticsProfileScope
    let planTier: AnalyticsPlanTier
    let succeeded: Bool
}

private struct AnalyticsUsageKey: Hashable {
    let provider: AnalyticsProvider
    let scope: AnalyticsProfileScope
    let planTier: AnalyticsPlanTier
    let window: AnalyticsLimitWindow
    let usageBucket: AnalyticsUsageBucket
}

private extension DesktopProduct {
    var analyticsProvider: AnalyticsProvider {
        switch self {
        case .codex: .codex
        case .claude: .claude
        }
    }
}

private enum CodexerModelError: LocalizedError {
    case storeUnavailable

    var errorDescription: String? {
        "Profile storage is unavailable. Resolve the profile metadata error and relaunch AgentDock."
    }
}

private func analyticsDurationBucket(
    since start: ContinuousClock.Instant
) -> AnalyticsDurationBucket {
    let components = start.duration(to: .now).components
    let milliseconds = components.seconds * 1_000
        + components.attoseconds / 1_000_000_000_000_000
    return AnalyticsDurationBucket(milliseconds: Int(clamping: milliseconds))
}

extension Color {
    init(hex: String) {
        let clean = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        let value = Int(clean, radix: 16) ?? 0x2563EB
        self.init(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }

    var hexString: String {
        let nsColor = NSColor(self).usingColorSpace(.sRGB) ?? .systemBlue
        let red = Int(round(nsColor.redComponent * 255))
        let green = Int(round(nsColor.greenComponent * 255))
        let blue = Int(round(nsColor.blueComponent * 255))
        return String(format: "#%02X%02X%02X", red, green, blue)
    }
}
