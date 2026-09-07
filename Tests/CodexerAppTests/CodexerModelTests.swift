import SwiftUI
import XCTest
@testable import Codexer
import CodexerCore

@MainActor
final class CodexerModelTests: XCTestCase {
    func testWorkspaceNotificationsOnlyRefreshForSupportedProviders() {
        XCTAssertTrue(CodexerModel.isRelevantWorkspaceBundleIdentifier("com.openai.codex"))
        XCTAssertTrue(CodexerModel.isRelevantWorkspaceBundleIdentifier("com.anthropic.claudefordesktop"))
        XCTAssertFalse(CodexerModel.isRelevantWorkspaceBundleIdentifier("com.apple.TextEdit"))
        XCTAssertFalse(CodexerModel.isRelevantWorkspaceBundleIdentifier(nil))
    }

    private let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("CodexerModelTests-\(UUID().uuidString)", isDirectory: true)
        .standardizedFileURL
        .resolvingSymlinksInPath()

    nonisolated override func tearDown() {
        try? FileManager.default.removeItem(at: root)
    }

    func testSuccessfulLaunchClearsBusyStateAndPersistsLaunchDate() async throws {
        let store = try makeStore()
        let profile = try store.createProfile(name: "Launch")
        let manager = RecordingInstanceManager()
        let model = makeModel(store: store, manager: manager)

        model.launch(profile)
        await waitUntil { !model.isBusy(profile) && store.profiles.first?.lastLaunchedAt != nil }

        XCTAssertNil(model.errorMessage)
        let openedProfileIDs = await manager.openedProfileIDs()
        XCTAssertEqual(openedProfileIDs, [profile.id])
        XCTAssertNotNil(store.profiles.first?.lastLaunchedAt)
    }

    func testLaunchFailureClearsBusyStateWithoutMarkingProfile() async throws {
        let store = try makeStore()
        let profile = try store.createProfile(name: "Rejected")
        let manager = RecordingInstanceManager(openShouldFail: true)
        let model = makeModel(store: store, manager: manager)

        model.launch(profile)
        await waitUntil { !model.isBusy(profile) && model.errorMessage != nil }

        XCTAssertNil(store.profiles.first?.lastLaunchedAt)
        XCTAssertEqual(model.errorMessage, "rejected")
    }

    func testDeleteFailureRestoresIdleStateAndKeepsProfile() async throws {
        let store = try ProfileStore(
            rootDirectory: root,
            shortcutDirectory: root.appendingPathComponent("Shortcuts"),
            usageChecker: AlwaysInUseModelChecker()
        )
        let profile = try store.createProfile(name: "Busy")
        let model = makeModel(store: store)

        model.deleteProfileData(profile)
        await waitUntil { !model.storeMutationInProgress && !model.isBusy(profile) }

        XCTAssertEqual(store.profiles.map(\.id), [profile.id])
        XCTAssertTrue(FileManager.default.fileExists(atPath: profile.profileDirectory.path))
        XCTAssertNotNil(model.errorMessage)
    }

    func testNewRefreshCannotBeOverwrittenByCancelledGeneration() async throws {
        let store = try makeStore()
        let profile = try store.createProfile(name: "Refresh")
        let scanner = SequencedStatsScanner()
        let model = makeModel(store: store, scanner: scanner)

        await waitUntil { scanner.invocationCount >= 1 }
        model.refreshStats()
        await waitUntil { model.stats(for: profile).totalSessions == 2 }
        try await Task.sleep(for: .milliseconds(250))

        XCTAssertEqual(model.stats(for: profile).totalSessions, 2)
    }

    func testPartialRefreshClearsCancelledFullRefreshLoadingState() throws {
        let store = try makeStore()
        let first = try store.createProfile(product: .claude, name: "First")
        let second = try store.createProfile(product: .claude, name: "Second")
        let model = CodexerModel(
            store: store,
            officialDataRootURL: root.appendingPathComponent("Official"),
            codexAppURL: URL(fileURLWithPath: "/Applications/Codex.app"),
            statsScanner: ProfileStatsScanner(),
            rateLimitClient: AppServerRateLimitClient(
                codexExecutable: URL(fileURLWithPath: "/usr/bin/false"),
                timeoutSeconds: 0.1
            ),
            startMonitoring: false
        )

        model.refreshStats()
        XCTAssertEqual(model.statsLoadingProfileIDs, [first.id, second.id])
        XCTAssertTrue(model.officialStatsLoading)

        model.refreshStats(for: first)

        XCTAssertEqual(model.statsLoadingProfileIDs, [first.id])
        XCTAssertFalse(model.officialStatsLoading)
    }

    func testStoreMutationIsRejectedWhileLaunchIsInFlight() async throws {
        let store = try makeStore()
        let profile = try store.createProfile(name: "Existing")
        let manager = RecordingInstanceManager(openDelay: .milliseconds(200))
        let model = makeModel(store: store, manager: manager)

        model.launch(profile)
        let created = await model.addProfile(name: "Conflicting", color: .blue)

        XCTAssertFalse(created)
        XCTAssertEqual(store.profiles.map(\.id), [profile.id])
        XCTAssertEqual(model.errorMessage, "Another profile change is still in progress.")
        await waitUntil { !model.isBusy(profile) }
    }

    func testProfileReorderUpdatesImmediatelyAndPersists() async throws {
        let store = try makeStore()
        let first = try store.createProfile(name: "First")
        let second = try store.createProfile(name: "Second")
        let third = try store.createProfile(name: "Third")
        let model = makeModel(store: store)

        XCTAssertTrue(model.reorderProfile(
            third.id,
            relativeTo: first.id,
            placeAfter: false
        ))
        XCTAssertEqual(model.profiles.map(\.id), [third.id, first.id, second.id])

        await waitUntil { !model.storeMutationInProgress }
        XCTAssertEqual(store.profiles.map(\.id), [third.id, first.id, second.id])

        let reloaded = try ProfileStore(
            rootDirectory: root,
            shortcutDirectory: root.appendingPathComponent("Shortcuts"),
            usageChecker: NeverInUseModelChecker()
        )
        XCTAssertEqual(reloaded.profiles.map(\.id), [third.id, first.id, second.id])
    }

    func testAddProfileCompletesAndSelectsBothProducts() async throws {
        let store = try makeStore()
        let model = makeRealModel(store: store)

        let claudeCreated = await model.addProfile(
            product: .claude,
            name: "Claude Account",
            color: .purple
        )
        XCTAssertTrue(claudeCreated)
        XCTAssertEqual(model.selectedProfile?.product, .claude)
        XCTAssertEqual(model.selectedProfile?.name, "Claude Account")

        let codexCreated = await model.addProfile(
            product: .codex,
            name: "Codex Account",
            color: .blue
        )
        XCTAssertTrue(codexCreated)
        XCTAssertEqual(model.selectedProfile?.product, .codex)
        XCTAssertEqual(model.selectedProfile?.name, "Codex Account")
        XCTAssertEqual(Set(store.profiles.map(\.product)), Set(DesktopProduct.allCases))
        XCTAssertFalse(model.storeMutationInProgress)
    }

    func testRapidSecondCreateIsRejectedWhileFirstWaitsWithoutBlockingMainActor() async throws {
        let store = try ProfileStore(
            rootDirectory: root,
            shortcutDirectory: root.appendingPathComponent("Shortcuts"),
            usageChecker: NeverInUseModelChecker(),
            operationLockTimeout: .seconds(2)
        )
        let model = makeRealModel(store: store)
        var heldLock: AdvisoryFileLock? = try AdvisoryFileLock.acquireSynchronously(
            at: root.appendingPathComponent(".profiles.lock")
        )

        let firstCreate = Task { @MainActor in
            await model.addProfile(
                product: .claude,
                name: "First",
                color: .purple
            )
        }
        await waitUntil { model.storeMutationInProgress }

        var mainActorAdvanced = false
        Task { @MainActor in
            mainActorAdvanced = true
        }
        await waitUntil { mainActorAdvanced }

        let secondCreated = await model.addProfile(
            product: .claude,
            name: "Second",
            color: .orange
        )
        XCTAssertFalse(secondCreated)
        XCTAssertEqual(model.errorMessage, "Another profile change is still in progress.")

        heldLock = nil
        let firstCreated = await firstCreate.value
        XCTAssertTrue(firstCreated)
        XCTAssertEqual(store.profiles.map(\.name), ["First"])
        XCTAssertFalse(model.storeMutationInProgress)
        withExtendedLifetime(heldLock) {}
    }

    func testStoppedCodexProfileCanSelectNamedProfileUseDefaultAndReturnToBuiltIn() async throws {
        let store = try ProfileStore(
            rootDirectory: root,
            shortcutDirectory: root.appendingPathComponent("Shortcuts"),
            usageChecker: NeverInUseModelChecker()
        )
        let profile = try store.createProfile(name: "Local")
        try Data("model_provider = \"ollama\"\n".utf8).write(
            to: profile.codexHomePath.appendingPathComponent("ollama.config.toml")
        )
        let model = makeRealModel(store: store)
        let ollama = try CodexConfigProfile(validating: "ollama")

        model.setCodexLaunchProfileSelection(.named(ollama), for: profile)
        await waitUntil { !model.storeMutationInProgress }
        XCTAssertEqual(store.profiles.first?.codexLaunchProfileSelection, .named(ollama))

        model.setDefaultCodexConfigProfile(ollama, for: try XCTUnwrap(store.profiles.first))
        await waitUntil { !model.storeMutationInProgress }
        XCTAssertEqual(store.profiles.first?.codexDefaultConfigProfile, ollama)
        let selected = try XCTUnwrap(store.profiles.first)
        model.setCodexLaunchProfileSelection(.useDefault, for: selected)
        await waitUntil { !model.storeMutationInProgress }
        XCTAssertEqual(store.profiles.first?.codexLaunchProfileSelection, .useDefault)
        XCTAssertEqual(model.effectiveCodexConfigProfile(for: try XCTUnwrap(store.profiles.first)), ollama)

        let inherited = try XCTUnwrap(store.profiles.first)
        model.setCodexLaunchProfileSelection(.builtIn, for: inherited)
        await waitUntil { !model.storeMutationInProgress }
        XCTAssertEqual(store.profiles.first?.codexLaunchProfileSelection, .builtIn)
        XCTAssertNil(model.effectiveCodexConfigProfile(for: try XCTUnwrap(store.profiles.first)))
    }

    func testCancellingCreateWaitingForStoreLockLeavesNoProfileState() async throws {
        let store = try ProfileStore(
            rootDirectory: root,
            shortcutDirectory: root.appendingPathComponent("Shortcuts"),
            usageChecker: NeverInUseModelChecker(),
            operationLockTimeout: .seconds(2)
        )
        let model = makeRealModel(store: store)
        let heldLock = try AdvisoryFileLock.acquireSynchronously(
            at: root.appendingPathComponent(".profiles.lock")
        )

        let create = Task { @MainActor in
            await model.addProfile(
                product: .claude,
                name: "Cancelled",
                color: .red
            )
        }
        await waitUntil { model.storeMutationInProgress }
        create.cancel()

        let created = await create.value
        XCTAssertFalse(created)
        XCTAssertFalse(model.storeMutationInProgress)
        XCTAssertTrue(store.profiles.isEmpty)
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(
                at: store.profilesRootDirectory(for: .claude),
                includingPropertiesForKeys: nil
            ).filter { !$0.lastPathComponent.hasPrefix(".") },
            []
        )
        withExtendedLifetime(heldLock) {}
    }

    func testCreateCompletesWhileRealStatsRefreshIsRunning() async throws {
        let store = try makeStore()
        let existing = try store.createProfile(product: .claude, name: "Existing")
        try Data(repeating: 0x41, count: 2 * 1_024 * 1_024).write(
            to: existing.claudeUserDataPath.appendingPathComponent("activity.bin")
        )
        let model = makeRealModel(store: store)

        model.refreshStats()
        let created = await model.addProfile(
            product: .claude,
            name: "During Refresh",
            color: .green
        )

        XCTAssertTrue(created)
        XCTAssertEqual(model.selectedProfile?.name, "During Refresh")
        XCTAssertEqual(Set(store.profiles.map(\.name)), Set(["Existing", "During Refresh"]))
        XCTAssertFalse(model.storeMutationInProgress)
    }

    func testOfficialCodexActionUsesStockInstancePath() async throws {
        let store = try makeStore()
        let manager = RecordingInstanceManager()
        let model = makeModel(store: store, manager: manager)

        model.openStockCodex()
        await waitUntil { !model.stockOperationInProgress }

        XCTAssertNil(model.errorMessage)
        let stockOpenCount = await manager.stockOpenCount()
        XCTAssertEqual(stockOpenCount, 1)
    }

    func testOfficialCodexUsesNativeProfileAndKeepsManagedDefaultsIsolated() async throws {
        let store = try makeStore()
        let managed = try store.createProfile(name: "Managed")
        let officialDataRoot = root.appendingPathComponent("Official", isDirectory: true)
        let officialHome = officialDataRoot.appendingPathComponent(".codex", isDirectory: true)
        try FileManager.default.createDirectory(at: officialHome, withIntermediateDirectories: true)
        try Data(#"""
        [model_providers.ollama]
        name = "Ollama"
        base_url = "http://127.0.0.1:11434/v1"

        """#.utf8).write(to: officialHome.appendingPathComponent("config.toml"))
        try Data(#"""
        model_provider = "ollama"
        model = "local-model"
        """#.utf8).write(to: officialHome.appendingPathComponent("ollama.config.toml"))
        let suiteName = "OfficialCodexProfileSettings.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let preferencesStore = AgentDockPreferencesStore(defaults: defaults)
        let manager = RecordingInstanceManager(stockRunning: true)
        let model = CodexerModel(
            store: store,
            officialDataRootURL: officialDataRoot,
            codexAppURL: URL(fileURLWithPath: "/Applications/Codex.app"),
            instanceController: manager,
            shortcutInstaller: NoopShortcutManager(),
            statsScanner: FixedStatsScanner(),
            rateLimitClient: FixedRateLimitClient(),
            preferencesStore: preferencesStore
        )
        let ollama = try XCTUnwrap(model.officialCodexConfigProfiles.first)

        model.openStockCodex()
        await waitUntil { !model.busyStockProducts.contains(.codex) }
        model.setOfficialCodexDefaultConfigProfile(ollama)
        await waitUntil { !model.busyStockProducts.contains(.codex) }

        XCTAssertEqual(model.effectiveOfficialCodexConfigProfile, ollama)
        XCTAssertEqual(
            preferencesStore.loadOfficialCodexProfileSettings().defaultConfigProfile,
            ollama
        )
        XCTAssertNil(store.profiles.first(where: { $0.id == managed.id })?.codexDefaultConfigProfile)
        let firstCloseCount = await manager.stockCloseCount()
        let firstOpenedProfiles = await manager.openedStockConfigProfiles()
        XCTAssertEqual(firstCloseCount, 1)
        XCTAssertEqual(firstOpenedProfiles, [nil, ollama])

        model.setOfficialCodexLaunchProfileSelection(.builtIn)
        await waitUntil { !model.busyStockProducts.contains(.codex) }

        XCTAssertNil(model.effectiveOfficialCodexConfigProfile)
        let finalCloseCount = await manager.stockCloseCount()
        let finalOpenedProfiles = await manager.openedStockConfigProfiles()
        XCTAssertEqual(finalCloseCount, 2)
        XCTAssertEqual(finalOpenedProfiles, [nil, ollama, nil])
    }

    func testClaudeSelectionAndAppPathRemainProductScoped() throws {
        let store = try makeStore()
        let profile = try store.createProfile(product: .claude, name: "Personal")
        let claudeAppURL = URL(fileURLWithPath: "/Applications/Claude Preview.app")
        let model = makeModel(store: store, claudeAppURL: claudeAppURL)

        model.selectOfficial(.claude)
        XCTAssertEqual(model.selectedOfficialProduct, .claude)
        XCTAssertNil(model.selectedProfile)
        XCTAssertEqual(model.appURL(for: .claude), claudeAppURL)
        XCTAssertEqual(
            model.appURL(for: .codex),
            URL(fileURLWithPath: "/Applications/Codex.app")
        )

        model.selectProfile(profile.id)
        XCTAssertEqual(model.selectedProfile?.id, profile.id)
        XCTAssertEqual(model.selectedProfile?.product, .claude)
        XCTAssertNil(model.rateLimits(for: profile))
    }

    func testSidebarSelectionPreservesCurrentDetailSection() throws {
        let store = try makeStore()
        let profile = try store.createProfile(name: "Personal")
        let model = makeModel(store: store)

        model.detailTab = .chats
        model.selectOfficial(.codex)
        XCTAssertEqual(model.detailTab, .chats)

        model.selectProfile(profile.id)
        XCTAssertEqual(model.detailTab, .chats)
    }

    func testOverviewAndChatsAreAlwaysAvailableWhileAdvancedIsProfileScoped() {
        XCTAssertEqual(
            AgentDockDetailTab.availableTabs(hasManagedProfile: false),
            [.overview, .chats]
        )
        XCTAssertEqual(
            AgentDockDetailTab.availableTabs(hasManagedProfile: true),
            [.overview, .chats, .advanced]
        )
    }

    func testOfficialSelectionLeavesChatsSelectedAndFallsBackFromAdvanced() throws {
        let store = try makeStore()
        let profile = try store.createProfile(name: "Personal")
        let model = makeModel(store: store)

        model.selectProfile(profile.id)
        model.detailTab = .chats
        model.selectOfficial(.codex)
        XCTAssertEqual(model.detailTab, .chats)

        model.selectProfile(profile.id)
        model.detailTab = .advanced
        model.selectOfficial(.codex)
        XCTAssertEqual(model.detailTab, .overview)
    }

    func testRapidProfileSwitchSuppressesStaleChatListAndTranscript() async throws {
        let store = try makeStore()
        let slow = try store.createProfile(name: "Slow History")
        let current = try store.createProfile(name: "Current History")
        let slowSessions = slow.codexHomePath.appendingPathComponent(
            "sessions/2026/07/28",
            isDirectory: true
        )
        let currentSessions = current.codexHomePath.appendingPathComponent(
            "sessions/2026/07/28",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: slowSessions, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: currentSessions, withIntermediateDirectories: true)
        for index in 0..<500 {
            try chatFixture(
                id: "slow-\(index)",
                prompt: "Slow conversation \(index)",
                response: "Old profile response"
            ).write(to: slowSessions.appendingPathComponent("rollout-\(index).jsonl"))
        }
        try chatFixture(
            id: "current",
            prompt: "Current conversation",
            response: "Current profile response"
        ).write(to: currentSessions.appendingPathComponent("rollout-current.jsonl"))
        let model = CodexerModel(
            store: store,
            officialDataRootURL: root.appendingPathComponent("Official"),
            codexAppURL: URL(fileURLWithPath: "/Applications/Codex.app"),
            instanceController: RecordingInstanceManager(),
            shortcutInstaller: NoopShortcutManager(),
            statsScanner: FixedStatsScanner(),
            rateLimitClient: FixedRateLimitClient(),
            chatScanner: LocalChatScanner(
                indexRootURL: root.appendingPathComponent("ChatIndexes")
            ),
            startMonitoring: false
        )

        model.selectProfile(slow.id)
        model.selectProfile(current.id)
        await waitUntil(timeout: .seconds(5)) {
            !model.chatsLoading && !model.chatTranscriptLoading
        }

        XCTAssertEqual(model.chatSessions.map(\.profileID), [current.id])
        XCTAssertEqual(model.chatSessions.first?.title, "Current conversation")
        XCTAssertEqual(
            model.chatTranscriptEntries.filter { $0.kind == .message }.map(\.text),
            ["Current conversation", "Current profile response"]
        )
    }

    func testRapidConversationSwitchSuppressesCancelledTranscriptPage() async throws {
        let store = try makeStore()
        let profile = try store.createProfile(name: "Conversation Switch")
        let sessions = profile.codexHomePath.appendingPathComponent(
            "sessions/2026/07/28",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        let large = sessions.appendingPathComponent("rollout-large.jsonl")
        try chatFixture(id: "large", prompt: "Large", response: nil).write(to: large)
        let handle = try FileHandle(forWritingTo: large)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("\n{\"type\":\"tool_output\",\"payload\":{\"blob\":\"".utf8))
        try handle.write(contentsOf: Data(repeating: 0x61, count: 24 * 1_024 * 1_024))
        try handle.write(contentsOf: Data("\"}}\n".utf8))
        try handle.close()
        let small = sessions.appendingPathComponent("rollout-small.jsonl")
        try chatFixture(
            id: "small",
            prompt: "Small",
            response: "Selected response"
        ).write(to: small)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(2)],
            ofItemAtPath: small.path
        )
        let model = CodexerModel(
            store: store,
            officialDataRootURL: root.appendingPathComponent("Official"),
            codexAppURL: URL(fileURLWithPath: "/Applications/Codex.app"),
            instanceController: RecordingInstanceManager(),
            shortcutInstaller: NoopShortcutManager(),
            statsScanner: FixedStatsScanner(),
            rateLimitClient: FixedRateLimitClient(),
            chatScanner: LocalChatScanner(
                indexRootURL: root.appendingPathComponent("ChatIndexes")
            ),
            startMonitoring: false
        )
        model.selectProfile(profile.id)
        await waitUntil(timeout: .seconds(5)) { !model.chatsLoading }
        let largeID = try XCTUnwrap(model.chatSessions.first { $0.title == "Large" }?.id)
        let smallID = try XCTUnwrap(model.chatSessions.first { $0.title == "Small" }?.id)

        model.selectChat(largeID)
        model.selectChat(smallID)
        await waitUntil(timeout: .seconds(5)) { !model.chatTranscriptLoading }

        XCTAssertEqual(model.selectedChatID, smallID)
        XCTAssertEqual(
            model.chatTranscriptEntries.filter { $0.kind == .message }.map(\.text),
            ["Small", "Selected response"]
        )
        XCTAssertFalse(model.chatTranscriptEntries.contains { $0.text == "Large" })
    }

    func testFilteredSelectionDoesNotDisplayAnotherChatsTranscript() {
        XCTAssertNil(
            ChatSelectionResolver.displayedID(
                currentID: "chat-a",
                visibleIDs: ["chat-b"]
            )
        )
        XCTAssertEqual(
            ChatSelectionResolver.replacementID(
                currentID: "chat-a",
                visibleIDs: ["chat-b"]
            ),
            "chat-b"
        )
        XCTAssertEqual(
            ChatSelectionResolver.displayedID(
                currentID: "chat-b",
                visibleIDs: ["chat-b", "chat-c"]
            ),
            "chat-b"
        )
    }

    func testOneLoadMoreRequestContinuesAcrossEmptyOversizedPages() async throws {
        let store = try makeStore()
        let profile = try store.createProfile(name: "Oversized Paging")
        let sessions = profile.codexHomePath.appendingPathComponent(
            "sessions/2026/07/28",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        let file = sessions.appendingPathComponent("rollout-oversized.jsonl")
        try chatFixture(id: "oversized", prompt: "Before oversized", response: nil).write(to: file)
        let writer = try FileHandle(forWritingTo: file)
        try writer.seekToEnd()
        try writer.write(contentsOf: Data("\n{\"type\":\"tool_output\",\"payload\":{\"blob\":\"".utf8))
        try writer.write(contentsOf: Data(repeating: 0x61, count: 3 * 1_024 * 1_024))
        try writer.write(contentsOf: Data("\"}}\n".utf8))
        try writer.write(contentsOf: try transcriptMessageLine(
            role: "assistant",
            text: "After oversized",
            second: 3
        ))
        try writer.close()
        let model = makeChatModel(store: store)

        model.selectProfile(profile.id)
        await waitUntil(timeout: .seconds(5)) {
            !model.chatsLoading && !model.chatTranscriptLoading
        }
        model.loadMoreChatTranscript()
        await waitUntil(timeout: .seconds(5)) {
            model.chatTranscriptEntries.contains { $0.text == "After oversized" }
                && !model.chatOlderTranscriptLoading
        }

        XCTAssertEqual(
            model.chatTranscriptEntries.filter { $0.kind == .message }.map(\.text),
            ["Before oversized", "After oversized"]
        )
        XCTAssertTrue(model.chatTranscriptEntries.contains { $0.kind == .oversized })
    }

    func testForwardPagingRetainsEveryLoadedEntryInSourceOrder() async throws {
        let store = try makeStore()
        let profile = try store.createProfile(name: "Long Paging")
        let sessions = profile.codexHomePath.appendingPathComponent(
            "sessions/2026/07/28",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        let file = sessions.appendingPathComponent("rollout-long.jsonl")
        var data = try chatFixture(id: "long", prompt: "Message 0", response: nil)
        for index in 1..<700 {
            data.append(try transcriptMessageLine(
                role: "assistant",
                text: "Message \(index)",
                second: index % 60
            ))
        }
        try data.write(to: file)
        let model = makeChatModel(store: store)

        model.selectProfile(profile.id)
        await waitUntil(timeout: .seconds(5)) {
            !model.chatsLoading && !model.chatTranscriptLoading
        }
        while model.hasMoreChatTranscript {
            model.loadMoreChatTranscript()
            await waitUntil(timeout: .seconds(5)) { !model.chatOlderTranscriptLoading }
        }

        let messages = model.chatTranscriptEntries
            .filter { $0.kind == .message }
            .map(\.text)
        XCTAssertEqual(messages.count, 700)
        XCTAssertEqual(messages.first, "Message 0")
        XCTAssertEqual(messages.last, "Message 699")
        let ordinals = model.chatTranscriptEntries.compactMap(\.sourceOrdinal)
        XCTAssertEqual(ordinals.count, 700)
        let firstOrdinal = try XCTUnwrap(ordinals.first)
        XCTAssertEqual(ordinals, Array(firstOrdinal..<(firstOrdinal + 700)))
    }

    func testProfileEditRebuildsInstalledShortcutIconAndDisplayName() async throws {
        let store = try makeStore()
        let profile = try store.createProfile(name: "Work", iconColor: "#2563EB")
        let installer = ShortcutInstaller(
            fileManager: .default,
            helperExecutableURL: URL(fileURLWithPath: "/usr/bin/true")
        )
        let appURL = URL(fileURLWithPath: "/Applications/Codex.app")
        try installer.installShortcut(for: profile, codexAppURL: appURL)
        let iconURL = profile.shortcutPath
            .appendingPathComponent("Contents/Resources/ProfileIcon.icns")
        let originalIcon = try Data(contentsOf: iconURL)

        let model = CodexerModel(
            store: store,
            officialDataRootURL: root.appendingPathComponent("Official"),
            codexAppURL: appURL,
            shortcutInstaller: installer,
            startMonitoring: false
        )
        model.updateProfile(
            profile,
            name: "Day Job",
            color: Color(hex: "#F97316"),
            iconKind: .symbol,
            iconValue: "briefcase",
            customIconData: nil
        )
        await waitUntil {
            !model.storeMutationInProgress && store.profiles.first?.name == "Day Job"
        }

        let updated = try XCTUnwrap(store.profiles.first)
        XCTAssertEqual(updated.iconKind, .symbol)
        XCTAssertEqual(updated.iconValue, "briefcase")
        XCTAssertEqual(updated.iconColor, "#F97316")
        XCTAssertNotEqual(try Data(contentsOf: iconURL), originalIcon)

        let plistData = try Data(contentsOf: updated.shortcutPath.appendingPathComponent("Contents/Info.plist"))
        let plist = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: plistData, format: nil) as? [String: Any]
        )
        XCTAssertEqual(plist["CFBundleDisplayName"] as? String, "Day Job")
    }

    private func makeStore() throws -> ProfileStore {
        try ProfileStore(
            rootDirectory: root,
            shortcutDirectory: root.appendingPathComponent("Shortcuts"),
            usageChecker: NeverInUseModelChecker()
        )
    }

    private func chatFixture(
        id: String,
        prompt: String,
        response: String?
    ) throws -> Data {
        var records: [[String: Any]] = [
            [
                "timestamp": "2026-07-28T10:00:00Z",
                "type": "session_meta",
                "payload": ["id": id, "timestamp": "2026-07-28T10:00:00Z"]
            ],
            [
                "timestamp": "2026-07-28T10:00:01Z",
                "type": "response_item",
                "payload": [
                    "type": "message",
                    "role": "user",
                    "content": [["type": "input_text", "text": prompt]]
                ]
            ]
        ]
        if let response {
            records.append([
                "timestamp": "2026-07-28T10:00:02Z",
                "type": "response_item",
                "payload": [
                    "type": "message",
                    "role": "assistant",
                    "content": [["type": "output_text", "text": response]]
                ]
            ])
        }
        return try records.map {
            String(decoding: try JSONSerialization.data(withJSONObject: $0), as: UTF8.self)
        }
        .joined(separator: "\n")
        .data(using: .utf8)!
    }

    private func transcriptMessageLine(
        role: String,
        text: String,
        second: Int
    ) throws -> Data {
        let record: [String: Any] = [
            "timestamp": String(format: "2026-07-28T10:00:%02dZ", second),
            "type": "response_item",
            "payload": [
                "type": "message",
                "role": role,
                "content": [[
                    "type": role == "user" ? "input_text" : "output_text",
                    "text": text
                ]]
            ]
        ]
        var data = Data("\n".utf8)
        data.append(try JSONSerialization.data(withJSONObject: record))
        return data
    }

    private func makeChatModel(store: ProfileStore) -> CodexerModel {
        CodexerModel(
            store: store,
            officialDataRootURL: root.appendingPathComponent("Official"),
            codexAppURL: URL(fileURLWithPath: "/Applications/Codex.app"),
            instanceController: RecordingInstanceManager(),
            shortcutInstaller: NoopShortcutManager(),
            statsScanner: FixedStatsScanner(),
            rateLimitClient: FixedRateLimitClient(),
            chatScanner: LocalChatScanner(
                indexRootURL: root.appendingPathComponent("ChatIndexes")
            ),
            startMonitoring: false
        )
    }

    private func makeModel(
        store: ProfileStore,
        claudeAppURL: URL = DesktopAppRegistry.claude.defaultAppURL,
        manager: any DesktopInstanceManaging = RecordingInstanceManager(),
        scanner: any ProfileStatsScanning = FixedStatsScanner()
    ) -> CodexerModel {
        CodexerModel(
            store: store,
            officialDataRootURL: root.appendingPathComponent("Official"),
            codexAppURL: URL(fileURLWithPath: "/Applications/Codex.app"),
            claudeAppURL: claudeAppURL,
            instanceController: manager,
            shortcutInstaller: NoopShortcutManager(),
            statsScanner: scanner,
            rateLimitClient: FixedRateLimitClient()
        )
    }

    private func makeRealModel(store: ProfileStore) -> CodexerModel {
        CodexerModel(
            store: store,
            officialDataRootURL: root.appendingPathComponent("Official"),
            codexAppURL: URL(fileURLWithPath: "/Applications/Codex.app"),
            claudeAppURL: URL(fileURLWithPath: "/Applications/Claude.app"),
            instanceController: DesktopInstanceController(),
            shortcutInstaller: ShortcutInstaller(),
            statsScanner: ProfileStatsScanner(),
            rateLimitClient: AppServerRateLimitClient()
        )
    }

    private func waitUntil(
        timeout: Duration = .seconds(2),
        condition: @escaping @MainActor () -> Bool
    ) async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !condition(), clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(condition())
    }
}

private actor RecordingInstanceManager: DesktopInstanceManaging {
    private let openShouldFail: Bool
    private let openDelay: Duration?
    private var opened: [CodexProfile.ID] = []
    private var stockOpens = 0
    private var stockCloses = 0
    private var stockConfigProfiles: [CodexConfigProfile?] = []
    private let stockRunning: Bool

    init(
        openShouldFail: Bool = false,
        openDelay: Duration? = nil,
        stockRunning: Bool = false
    ) {
        self.openShouldFail = openShouldFail
        self.openDelay = openDelay
        self.stockRunning = stockRunning
    }

    func statuses(
        for profiles: [CodexProfile],
        appURLs _: [DesktopProduct: URL]
    ) async throws -> [CodexProfile.ID: CodexInstanceStatus] {
        Dictionary(uniqueKeysWithValues: profiles.map { ($0.id, CodexInstanceStatus()) })
    }

    func open(profile: CodexProfile, appURL _: URL) async throws -> CodexOpenOutcome {
        opened.append(profile.id)
        if let openDelay {
            try await Task.sleep(for: openDelay)
        }
        if openShouldFail {
            throw TestFailure.rejected
        }
        return .launched(processID: 123)
    }

    func close(profile _: CodexProfile, appURL _: URL) async throws -> CodexCloseOutcome {
        .alreadyStopped
    }

    func stockStatus(
        product _: DesktopProduct,
        appURL _: URL
    ) async throws -> CodexInstanceStatus {
        CodexInstanceStatus(processIDs: stockRunning ? [456] : [])
    }

    func openStock(
        product _: DesktopProduct,
        appURL _: URL,
        codexHomeURL _: URL?,
        codexConfigProfile: CodexConfigProfile?
    ) async throws -> CodexOpenOutcome {
        stockOpens += 1
        stockConfigProfiles.append(codexConfigProfile)
        return .launched(processID: 456)
    }

    func closeOfficialCodex(appURL _: URL) async throws -> CodexCloseOutcome {
        stockCloses += 1
        return .closed(processIDs: [456])
    }

    func validateApp(product _: DesktopProduct, at _: URL) async throws {}

    func openedProfileIDs() -> [CodexProfile.ID] {
        opened
    }

    func stockOpenCount() -> Int {
        stockOpens
    }

    func stockCloseCount() -> Int {
        stockCloses
    }

    func openedStockConfigProfiles() -> [CodexConfigProfile?] {
        stockConfigProfiles
    }
}

private final class SequencedStatsScanner: ProfileStatsScanning, @unchecked Sendable {
    private let lock = NSLock()
    private var invocation = 0

    var invocationCount: Int {
        lock.withLock { invocation }
    }

    func stats(for _: CodexProfile, now _: Date) -> ProfileStats {
        let current = lock.withLock {
            invocation += 1
            return invocation
        }
        if current == 1 {
            Thread.sleep(forTimeInterval: 0.15)
        }
        var stats = ProfileStats.empty
        stats.totalSessions = current
        return stats
    }

    func stats(codexHomeURL _: URL, dataRootURL _: URL, now _: Date) -> ProfileStats {
        .empty
    }

    func stats(
        claudeUserDataURL _: URL,
        claudeCodeHomeURL _: URL,
        dataRootURL _: URL,
        now _: Date
    ) -> ProfileStats { .empty }
}

private struct FixedStatsScanner: ProfileStatsScanning {
    func stats(for _: CodexProfile, now _: Date) -> ProfileStats { .empty }
    func stats(codexHomeURL _: URL, dataRootURL _: URL, now _: Date) -> ProfileStats { .empty }
    func stats(
        claudeUserDataURL _: URL,
        claudeCodeHomeURL _: URL,
        dataRootURL _: URL,
        now _: Date
    ) -> ProfileStats { .empty }
}

private struct FixedRateLimitClient: ProfileRateLimitFetching {
    func fetchRateLimits(for _: CodexProfile, codexAppURL _: URL) -> ProfileRateLimits {
        ProfileRateLimits()
    }

    func fetchRateLimits(codexHomeURL _: URL, codexAppURL _: URL) -> ProfileRateLimits {
        ProfileRateLimits()
    }
}

private struct NoopShortcutManager: ShortcutManaging {
    func installShortcut(for _: CodexProfile, codexAppURL _: URL) throws {}
    func removeShortcut(for _: CodexProfile) throws {}
    func shortcutExists(for _: CodexProfile) -> Bool { false }
}

private struct NeverInUseModelChecker: ProfileUsageChecking {
    func isProfileInUse(_: CodexProfile) -> Bool { false }
}

private struct AlwaysInUseModelChecker: ProfileUsageChecking {
    func isProfileInUse(_: CodexProfile) -> Bool { true }
}

private enum TestFailure: LocalizedError {
    case rejected

    var errorDescription: String? { "rejected" }
}

private extension NSLock {
    func withLock<T>(_ operation: () -> T) -> T {
        lock()
        defer { unlock() }
        return operation()
    }
}
