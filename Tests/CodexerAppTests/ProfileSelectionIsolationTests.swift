import AppKit
@testable import CodexerCore
import SwiftUI
import XCTest
@testable import Codexer

@MainActor
final class ProfileSelectionIsolationTests: XCTestCase {
    func testDirectSelectionChangeImmediatelyClearsPreviousProfileContent() async throws {
        let fixture = try SyntheticProfileFixture()
        defer { fixture.remove() }
        let model = fixture.model
        model.selectProfile(fixture.first.id)
        try await fixture.waitForChats()
        XCTAssertFalse(model.chatTranscriptEntries.isEmpty)
        let previousChat = try XCTUnwrap(model.selectedChatID)

        // Direct bindings and reloads must provide the same boundary as sidebar actions.
        model.sidebarSelection = .profile(fixture.second.id)

        XCTAssertEqual(model.selectedProfile?.id, fixture.second.id)
        XCTAssertTrue(model.chatSessions.isEmpty)
        XCTAssertTrue(model.chatTranscriptEntries.isEmpty)
        XCTAssertNil(model.selectedChatID)
        XCTAssertFalse(model.hasMoreChatTranscript)
        model.selectChat(previousChat)
        XCTAssertNil(model.selectedChatID)

        model.refreshChats()
        try await fixture.waitForChats()
        XCTAssertEqual(model.chatSessions.map(\.profileID), [fixture.second.id])
        XCTAssertEqual(model.chatTranscriptEntries.filter { $0.kind == .message }.map(\.text), ["Second profile conversation"])
    }

    func testInvalidOrEmptySelectionNeverResolvesToAnotherProfile() throws {
        let fixture = try SyntheticProfileFixture()
        defer { fixture.remove() }
        fixture.model.sidebarSelection = .profile(UUID())
        XCTAssertNil(fixture.model.selectedProfile)
        fixture.model.sidebarSelection = nil
        XCTAssertNil(fixture.model.selectedProfile)
    }

    func testOfficialSelectionUsesOnlyTheConfiguredDataRoot() async throws {
        let fixture = try SyntheticProfileFixture()
        defer { fixture.remove() }
        let officialRoot = fixture.root.appendingPathComponent("Official", isDirectory: true)
        try FileManager.default.createDirectory(at: officialRoot, withIntermediateDirectories: true)
        try FileManager.default.copyItem(
            at: fixture.first.codexHomePath,
            to: officialRoot.appendingPathComponent(".codex", isDirectory: true)
        )

        fixture.model.selectOfficial(.codex)
        try await fixture.waitForChats()

        XCTAssertEqual(fixture.model.chatSessions.count, 1)
        XCTAssertEqual(fixture.model.chatTranscriptEntries.filter { $0.kind == .message }.map(\.text),
                       ["First profile conversation"])
        XCTAssertTrue(fixture.model.chatSessions.allSatisfy {
            $0.sourceURL.path.hasPrefix(officialRoot.path + "/")
        })
    }

    func testSyntheticVisualAudit() async throws {
        guard let output = ProcessInfo.processInfo.environment["AGENTDOCK_VISUAL_AUDIT_DIR"] else {
            throw XCTSkip("Set AGENTDOCK_VISUAL_AUDIT_DIR to render synthetic UI acceptance images.")
        }
        let directory = URL(fileURLWithPath: output, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for size in [(name: "regular", width: 1080.0, height: 720.0),
                     (name: "compact", width: 900.0, height: 600.0)] {
            let fixture = try SyntheticProfileFixture(firstName: size.name == "compact"
                ? "Design Studio — Product and Platform Engineering" : "Design Studio")
            defer { fixture.remove() }
            let model = fixture.model
            model.selectProfile(fixture.first.id)
            try await fixture.waitForChats()
            let updater = AppUpdater()
            for appearance in [AgentDockAppearance.light, .dark] {
              for tab in [AgentDockDetailTab.overview, .chats] {
                model.preferences.appearance = appearance
                model.detailTab = tab
                let view = NSHostingView(rootView: ContentView()
                    .environmentObject(model)
                    .environmentObject(updater))
                let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: size.width, height: size.height),
                                      styleMask: [.titled, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.titleVisibility = .hidden
                window.titlebarAppearsTransparent = true
                window.contentView = view
                NSApplication.shared.setActivationPolicy(.regular)
                NSApplication.shared.activate(ignoringOtherApps: true)
                window.makeKeyAndOrderFront(nil)
                try await Task.sleep(for: .milliseconds(800))
                view.layoutSubtreeIfNeeded()
                // Capture WindowServer composition, including native glass controls.
                let arguments = ["-x", "-o", "-l", String(window.windowNumber),
                                 directory.appendingPathComponent("\(size.name)-\(appearance.rawValue)-\(tab.rawValue).png").path]
                var capture = try BoundedSubprocess.run(
                    executableURL: URL(fileURLWithPath: "/usr/sbin/screencapture"),
                    arguments: arguments,
                    timeout: 5,
                    maximumOutputBytes: 1_024
                )
                if capture.terminationStatus != 0 {
                    // Initial activation may not have reached WindowServer yet.
                    window.orderFrontRegardless()
                    try await Task.sleep(for: .milliseconds(800))
                    capture = try BoundedSubprocess.run(
                        executableURL: URL(fileURLWithPath: "/usr/sbin/screencapture"),
                        arguments: arguments, timeout: 5, maximumOutputBytes: 1_024
                    )
                }
                XCTAssertEqual(capture.terminationStatus, 0, "Could not capture the synthetic window; verify Screen Recording access.")
                window.close()
              }
            }
        }
    }
}

/// Real on-disk provider records and production services, with no live account reads.
@MainActor
private final class SyntheticProfileFixture {
    let root: URL
    let defaultsName: String
    let model: CodexerModel
    let first: CodexProfile
    let second: CodexProfile

    init(firstName: String = "Design Studio") throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentDock-Selection-\(UUID().uuidString)", isDirectory: true)
            .standardizedFileURL.resolvingSymlinksInPath()
        defaultsName = "AgentDock.SelectionTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsName))
        let store = try ProfileStore(rootDirectory: root,
                                     shortcutDirectory: root.appendingPathComponent("Shortcuts"))
        first = try store.createProfile(name: firstName)
        second = try store.createProfile(name: "Engineering")
        for (profile, prompt) in [(first, "First profile conversation"), (second, "Second profile conversation")] {
            let sessions = profile.codexHomePath.appendingPathComponent("sessions/2026/09/07", isDirectory: true)
            try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
            let records: [[String: Any]] = [
                ["timestamp": "2026-09-07T10:00:00Z", "type": "session_meta",
                 "payload": ["id": "shared-session-id", "timestamp": "2026-09-07T10:00:00Z"]],
                ["timestamp": "2026-09-07T10:00:01Z", "type": "response_item",
                 "payload": ["type": "message", "role": "user",
                             "content": [["type": "input_text", "text": prompt]]]]
            ]
            let data = try records.map { try JSONSerialization.data(withJSONObject: $0) }
                .reduce(into: Data()) { $0.append($1); $0.append(0x0a) }
            try data.write(to: sessions.appendingPathComponent("rollout-synthetic.jsonl"))
        }
        model = CodexerModel(
            store: store,
            officialDataRootURL: root.appendingPathComponent("Official"),
            codexAppURL: root.appendingPathComponent("Unavailable.app"),
            claudeAppURL: root.appendingPathComponent("Unavailable.app"),
            preferencesStore: AgentDockPreferencesStore(defaults: defaults),
            chatScanner: LocalChatScanner(indexRootURL: root.appendingPathComponent("Indexes")),
            loadActivityOnInit: false
        )
    }

    func waitForChats() async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while model.chatsLoading || model.chatTranscriptLoading {
            guard ContinuousClock.now < deadline else {
                XCTFail("Synthetic transcript did not finish loading")
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    func remove() {
        model.sidebarSelection = nil
        UserDefaults.standard.removePersistentDomain(forName: defaultsName)
        try? FileManager.default.removeItem(at: root)
    }
}
