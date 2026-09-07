import XCTest
@testable import CodexerCore

final class LocalChatSessionTests: XCTestCase {
    func testInstalledClaudeHistoryCanBeIndexedWhenEnabled() throws {
        guard ProcessInfo.processInfo.environment["AGENTDOCK_INSTALLED_CLAUDE_HISTORY_TEST"] == "1" else {
            throw XCTSkip(
                "Set AGENTDOCK_INSTALLED_CLAUDE_HISTORY_TEST=1 to validate local Claude history metadata."
            )
        }
        let fileManager = FileManager.default
        let userData = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0].appendingPathComponent("Claude", isDirectory: true)
        let claudeCodeHome = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude", isDirectory: true)
        let scanner = LocalChatScanner(
            maximumSessions: 1_000,
            indexRootURL: fileManager.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
        )

        let result = scanner.scanOfficialClaude(
            claudeHomeURL: userData,
            claudeCodeHomeURL: claudeCodeHome
        )

        XCTAssertEqual(result.availability, .available)
        XCTAssertFalse(result.sessions.isEmpty)
        XCTAssertTrue(result.sessions.allSatisfy { session in
            session.provider == .claude
                && fileManager.isReadableFile(atPath: session.sourceURL.path)
        })
    }

    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalChatSessionTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        root = nil
    }

    func testCoworkHistoryUsesMetadataAndPreservesAuditOrder() throws {
        let fixture = try makeCoworkFixture()
        let scanner = LocalChatScanner(
            transcriptPageBytes: 64 * 1_024,
            transcriptPageEntries: 3,
            indexRootURL: root.appendingPathComponent("Indexes")
        )

        let result = scanner.scanOfficialClaude(claudeHomeURL: root)
        let session = try XCTUnwrap(result.sessions.first)
        let entries = forwardEntries(scanner: scanner, session: session)

        XCTAssertEqual(result.availability, .available)
        XCTAssertEqual(result.sessions.count, 1)
        XCTAssertEqual(session.id, "cowork-session")
        XCTAssertEqual(session.provider, .claude)
        XCTAssertEqual(session.profileName, "Official Claude")
        XCTAssertEqual(session.title, "Review the release")
        XCTAssertEqual(session.preview, "Check the local release evidence")
        XCTAssertEqual(session.model, "claude-opus-4-1")
        XCTAssertEqual(session.repository, "AgentDock")
        XCTAssertNil(session.branch)
        XCTAssertEqual(session.status, "Unknown")
        XCTAssertEqual(session.sourceURL, fixture.audit)
        XCTAssertEqual(
            entries.map(\.kind),
            [.status, .message, .message, .reasoning, .command, .activity, .status, .activity]
        )
        XCTAssertEqual(
            entries.compactMap(\.message).map(\.text),
            ["Inspect the package", "The package is valid."]
        )
        XCTAssertEqual(entries[3].text, "I should verify the artifact.")
        XCTAssertEqual(entries[4].title, "exec_command")
        XCTAssertTrue(entries[4].text.contains("swift test"))
        XCTAssertEqual(entries[5].title, "Tool result")
        XCTAssertEqual(entries[6].title, "Completed")
        XCTAssertEqual(entries[7].title, "Unsupported event")
        XCTAssertEqual(entries.map(\.sourceOrdinal), Array(0..<entries.count).map(Optional.some))

        let tokenBefore = result.changeToken
        let handle = try FileHandle(forWritingTo: fixture.audit)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("\n".utf8))
        try handle.close()
        XCTAssertNotEqual(
            scanner.officialClaudeChangeToken(claudeHomeURL: root),
            tokenBefore
        )
    }

    func testClaudeUsageDeduplicatesMessagesAndKeepsLatestLimitSignal() throws {
        let usage: [String: Any] = [
            "input_tokens": 2,
            "cache_read_input_tokens": 1_000,
            "cache_creation_input_tokens": 66_818,
            "output_tokens": 286
        ]
        let assistant: [String: Any] = [
            "type": "assistant",
            "uuid": "assistant-usage",
            "requestId": "request-1",
            "timestamp": "2026-07-28T10:00:02Z",
            "message": [
                "id": "message-1",
                "model": "claude-opus-4-1",
                "usage": usage,
                "content": [["type": "text", "text": "Done"]]
            ]
        ]
        try makeCoworkFixture(auditRecords: [
            assistant,
            assistant,
            [
                "type": "rate_limit_event",
                "uuid": "limit-1",
                "timestamp": "2026-07-28T10:00:03Z",
                "rate_limit_info": [
                    "status": "allowed_warning",
                    "rateLimitType": "five_hour",
                    "utilization": 0.91,
                    "resetsAt": 1_785_236_400,
                    "isUsingOverage": false
                ]
            ],
            [
                "type": "rate_limit_event",
                "uuid": "limit-2",
                "timestamp": "2026-07-28T10:00:04Z",
                "rate_limit_info": [
                    "status": "allowed",
                    "rateLimitType": "five_hour",
                    "resetsAt": 1_785_240_000,
                    "isUsingOverage": false
                ]
            ]
        ])

        let session = try XCTUnwrap(
            LocalChatScanner(indexRootURL: root.appendingPathComponent("Indexes"))
                .scanOfficialClaude(claudeHomeURL: root)
                .sessions.first
        )

        XCTAssertEqual(session.tokenCount, 68_106)
        XCTAssertEqual(session.latestUsageLimit?.status, .allowed)
        XCTAssertEqual(session.latestUsageLimit?.bucket, "five_hour")
        XCTAssertNil(session.latestUsageLimit?.usedPercent)
        XCTAssertEqual(
            session.latestUsageLimit?.resetsAt,
            Date(timeIntervalSince1970: 1_785_240_000)
        )
        XCTAssertEqual(session.latestUsageLimit?.isUsingOverage, false)
    }

    func testManagedCoworkHistoryUsesProfileIdentity() throws {
        let profileRoot = root.appendingPathComponent("Profiles", isDirectory: true)
        let profile = CodexProfile(
            product: .claude,
            name: "Claude Work",
            slug: "work",
            rootDirectory: profileRoot,
            shortcutDirectory: root.appendingPathComponent("Shortcuts")
        )
        try makeCoworkFixture(userDataURL: profile.claudeUserDataPath)
        let scanner = LocalChatScanner(indexRootURL: root.appendingPathComponent("Indexes"))

        let result = scanner.scan(profile: profile)

        XCTAssertEqual(result.sessions.first?.profileID, profile.id)
        XCTAssertEqual(result.sessions.first?.profileName, "Claude Work")
        XCTAssertEqual(result.sessions.first?.provider, .claude)
        XCTAssertEqual(scanner.changeToken(profile: profile), result.changeToken)
    }

    func testOfficialClaudeCodeFallbackUsesBoundedIndexAndSourceMetadata() throws {
        let history = root.appendingPathComponent("history.jsonl")
        try writeJSONLines([
            [
                "display": "Earlier title",
                "pastedContents": [:],
                "project": "/private/work/project",
                "sessionId": "code-session",
                "timestamp": 1_785_232_800_000
            ],
            [
                "display": "Latest title",
                "pastedContents": [:],
                "project": "/private/work/project",
                "sessionId": "code-session",
                "timestamp": 1_785_232_860_000
            ]
        ], to: history)
        let body = root.appendingPathComponent(
            "projects/-private-work-project/code-session.jsonl"
        )
        try FileManager.default.createDirectory(
            at: body.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try writeJSONLines([
            [
                "type": "user",
                "uuid": "user-event",
                "sessionId": "code-session",
                "timestamp": "2026-07-28T10:00:00Z",
                "cwd": "/private/work/project",
                "gitBranch": "feature/history",
                "message": ["role": "user", "content": "Open the history"]
            ],
            [
                "type": "assistant",
                "uuid": "assistant-event",
                "sessionId": "code-session",
                "timestamp": "2026-07-28T10:00:01Z",
                "message": [
                    "role": "assistant",
                    "model": "claude-sonnet-4",
                    "content": [
                        ["type": "text", "text": "History opened."],
                        ["type": "thinking", "thinking": "Check the ordered records."],
                        [
                            "type": "tool_use",
                            "name": "Read",
                            "input": ["file_path": "/private/work/project/file.swift"]
                        ]
                    ]
                ]
            ]
        ], to: body)
        let scanner = LocalChatScanner(indexRootURL: root.appendingPathComponent("Indexes"))

        let result = scanner.scanOfficialClaude(claudeHomeURL: root)
        let session = try XCTUnwrap(result.sessions.first)
        let entries = forwardEntries(scanner: scanner, session: session)

        XCTAssertEqual(session.id, "code-session")
        XCTAssertEqual(session.title, "Latest title")
        XCTAssertEqual(session.repository, "project")
        XCTAssertEqual(session.branch, "feature/history")
        XCTAssertEqual(session.model, "claude-sonnet-4")
        XCTAssertEqual(session.startedAt, Date(timeIntervalSince1970: 1_785_232_800))
        XCTAssertEqual(session.updatedAt, Date(timeIntervalSince1970: 1_785_232_860))
        XCTAssertEqual(entries.map(\.kind), [.message, .message, .reasoning, .activity])
        XCTAssertEqual(entries.compactMap(\.message).map(\.text), [
            "Open the history", "History opened."
        ])
        XCTAssertEqual(Set(entries.map(\.id)).count, entries.count)
        XCTAssertTrue(entries.allSatisfy { $0.id.hasPrefix("code-session-") })
    }

    func testClaudeMalformedAndOversizedRecordsAreBoundedAndHonest() throws {
        let fixture = try makeCoworkFixture(
            auditRecords: [
                [
                    "type": "user",
                    "uuid": "large-user",
                    "_audit_timestamp": "2026-07-28T10:00:00Z",
                    "message": [
                        "role": "user",
                        "content": String(repeating: "x", count: 2_048)
                    ]
                ]
            ],
            malformedTail: true
        )
        let scanner = LocalChatScanner(
            transcriptPageBytes: 8 * 1_024,
            maximumRenderableEntryBytes: 512,
            indexRootURL: root.appendingPathComponent("Indexes")
        )
        let session = try XCTUnwrap(
            scanner.scanOfficialClaude(claudeHomeURL: root).sessions.first
        )

        let page = scanner.loadTranscriptForwardPage(for: session)

        XCTAssertEqual(page.entries.map(\.kind), [.oversized, .malformed])
        XCTAssertEqual(page.malformedEventCount, 1)
        XCTAssertFalse(page.entries[0].text.contains(String(repeating: "x", count: 32)))
        XCTAssertEqual(session.sourceURL, fixture.audit)
    }

    func testClaudeInventoryRejectsMetadataAndTranscriptSymlinkEscapes() throws {
        let outsideMetadata = root.appendingPathComponent("outside.json")
        try Data(#"{"sessionId":"escaped","title":"Must not load"}"#.utf8)
            .write(to: outsideMetadata)
        let metadataLink = root.appendingPathComponent(
            "claude-code-sessions/org/workspace/local_escape.json"
        )
        try FileManager.default.createDirectory(
            at: metadataLink.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(
            at: metadataLink,
            withDestinationURL: outsideMetadata
        )
        let scanner = LocalChatScanner(indexRootURL: root.appendingPathComponent("Indexes"))
        XCTAssertTrue(scanner.scanOfficialClaude(claudeHomeURL: root).sessions.isEmpty)

        let fixture = try makeCoworkFixture()
        let session = try XCTUnwrap(
            scanner.scanOfficialClaude(claudeHomeURL: root).sessions.first
        )
        let outsideAudit = root.appendingPathComponent("outside-audit.jsonl")
        try writeJSONLines([[
            "type": "user",
            "message": ["role": "user", "content": "Escaped transcript"]
        ]], to: outsideAudit)
        try FileManager.default.removeItem(at: fixture.audit)
        try FileManager.default.createSymbolicLink(
            at: fixture.audit,
            withDestinationURL: outsideAudit
        )

        let page = scanner.loadTranscriptPage(for: session)

        XCTAssertEqual(page.entries.map(\.kind), [.error])
        XCTAssertFalse(page.entries.contains { $0.text.contains("Escaped transcript") })
    }

    func testClaudeSessionIDsAreDeterministicAndCollisionsUseNewestSource() throws {
        try makeCoworkFixture(
            fixtureName: "local_old",
            sessionID: "collision-id",
            title: "Older",
            lastActivityAt: 1_785_232_800_000
        )
        try makeCoworkFixture(
            fixtureName: "local_new",
            sessionID: "collision-id",
            title: "Newer",
            lastActivityAt: 1_785_232_900_000
        )
        try makeCoworkFixture(
            fixtureName: "local_invalid",
            sessionID: "invalid id!",
            title: "Derived ID",
            lastActivityAt: 1_785_232_850_000
        )
        let scanner = LocalChatScanner(indexRootURL: root.appendingPathComponent("Indexes"))

        let first = scanner.scanOfficialClaude(claudeHomeURL: root)
        let second = scanner.scanOfficialClaude(claudeHomeURL: root)

        XCTAssertEqual(first.sessions.filter { $0.id == "collision-id" }.count, 1)
        XCTAssertEqual(first.sessions.first { $0.id == "collision-id" }?.title, "Newer")
        let derived = try XCTUnwrap(first.sessions.first { $0.title == "Derived ID" }?.id)
        XCTAssertTrue(derived.hasPrefix("claude-local-"))
        XCTAssertEqual(
            derived,
            second.sessions.first { $0.title == "Derived ID" }?.id
        )
    }

    func testDuplicateClaudeEventUUIDsStillProduceUniqueStableRowIDs() throws {
        try makeCoworkFixture(auditRecords: [
            [
                "type": "assistant",
                "uuid": "duplicate-event",
                "message": [
                    "role": "assistant",
                    "content": [["type": "text", "text": "First"]]
                ]
            ],
            [
                "type": "assistant",
                "uuid": "duplicate-event",
                "message": [
                    "role": "assistant",
                    "content": [["type": "text", "text": "Second"]]
                ]
            ]
        ])
        let scanner = LocalChatScanner(indexRootURL: root.appendingPathComponent("Indexes"))
        let session = try XCTUnwrap(
            scanner.scanOfficialClaude(claudeHomeURL: root).sessions.first
        )

        let firstRead = forwardEntries(scanner: scanner, session: session)
        let secondRead = forwardEntries(scanner: scanner, session: session)

        XCTAssertEqual(firstRead.map(\.text), ["First", "Second"])
        XCTAssertEqual(Set(firstRead.map(\.id)).count, firstRead.count)
        XCTAssertEqual(firstRead.map(\.id), secondRead.map(\.id))
    }

    func testClaudeUsageSkipsOversizedCompleteLinesAndContinuesReading() throws {
        try makeCoworkFixture(auditRecords: [
            [
                "type": "assistant",
                "message": [
                    "id": "oversized-message",
                    "usage": ["input_tokens": 100],
                    "content": String(repeating: "a", count: 1_024)
                ]
            ],
            [
                "type": "assistant",
                "message": ["id": "bounded-message", "usage": ["input_tokens": 7]]
            ]
        ])
        let scanner = LocalChatScanner(
            maximumSummaryLineBytes: 512,
            indexRootURL: root.appendingPathComponent("Indexes")
        )

        let result = scanner.scanOfficialClaude(claudeHomeURL: root)

        XCTAssertEqual(result.sessions.count, 1)
        XCTAssertEqual(result.sessions.first?.tokenCount, 7)
    }

    func testClaudeInventoryBoundsFilesAndAggregateMetadataBytes() throws {
        for index in 0..<5 {
            try makeCoworkFixture(
                fixtureName: "local_\(index)",
                sessionID: "session-\(index)",
                title: "Session \(index)",
                lastActivityAt: 1_785_232_800_000 + Double(index * 1_000)
            )
        }
        let fileBounded = LocalChatScanner(
            maximumSessions: 10,
            maximumInventoryFiles: 2,
            indexRootURL: root.appendingPathComponent("Indexes")
        ).scanOfficialClaude(claudeHomeURL: root)
        let byteBounded = LocalChatScanner(
            maximumSessions: 10,
            maximumInventoryFiles: 10,
            maximumMetadataBytes: 1,
            indexRootURL: root.appendingPathComponent("OtherIndexes")
        ).scanOfficialClaude(claudeHomeURL: root)

        XCTAssertLessThanOrEqual(fileBounded.sessions.count, 2)
        XCTAssertLessThanOrEqual(fileBounded.diagnostics.sourceFileCount, 2)
        XCTAssertTrue(byteBounded.sessions.isEmpty)
    }

    func testCodexInventoryBoundsAllEnumeratedEntries() throws {
        let sessions = root.appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        for index in 0..<20 {
            let directory = sessions.appendingPathComponent("day-\(index)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data(#"{"type":"session_meta","payload":{"id":"bounded-session"}}"#.utf8)
                .write(to: directory.appendingPathComponent("rollout-\(index).jsonl"))
        }

        let result = LocalChatScanner(
            maximumSessions: 20,
            maximumInventoryFiles: 5,
            indexRootURL: root.appendingPathComponent("Indexes")
        ).scanOfficialCodex(codexHomeURL: root)

        XCTAssertTrue(result.diagnostics.inventoryTruncated)
        XCTAssertLessThanOrEqual(result.diagnostics.sourceFileCount, 5)
    }

    func testClaudePollingTokenUsesMetadataWithoutReadingMetadataBodies() throws {
        let fixture = try makeCoworkFixture()
        let scanner = LocalChatScanner(indexRootURL: root.appendingPathComponent("Indexes"))
        let initial = scanner.scanOfficialClaude(claudeHomeURL: root)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o000],
            ofItemAtPath: fixture.metadata.path
        )
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: fixture.metadata.path
            )
        }

        XCTAssertFalse(initial.changeToken.isEmpty)
        XCTAssertEqual(
            scanner.officialClaudeChangeToken(claudeHomeURL: root),
            initial.changeToken
        )
    }

    @discardableResult
    private func makeCoworkFixture(
        userDataURL: URL? = nil,
        fixtureName: String = "local_fixture",
        sessionID: String = "cowork-session",
        title: String = "Review the release",
        lastActivityAt: Double = 1_785_232_860_000,
        auditRecords: [[String: Any]]? = nil,
        malformedTail: Bool = false
    ) throws -> (metadata: URL, audit: URL) {
        let userDataURL = userDataURL ?? root!
        let metadata = userDataURL.appendingPathComponent(
            "claude-code-sessions/org/workspace/\(fixtureName).json"
        )
        let audit = userDataURL.appendingPathComponent(
            "local-agent-mode-sessions/org/workspace/\(fixtureName)/audit.jsonl"
        )
        try FileManager.default.createDirectory(
            at: metadata.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: audit.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let metadataObject: [String: Any] = [
            "sessionId": sessionID,
            "title": title,
            "promptSuggestion": "Check the local release evidence",
            "cwd": "/private/work/AgentDock",
            "model": "claude-opus-4-1",
            "createdAt": 1_785_232_800_000,
            "lastActivityAt": lastActivityAt,
            "isArchived": false
        ]
        try JSONSerialization.data(
            withJSONObject: metadataObject,
            options: [.sortedKeys]
        ).write(to: metadata)
        let records = auditRecords ?? [
            [
                "type": "system",
                "subtype": "init",
                "uuid": "system-event",
                "_audit_timestamp": "2026-07-28T10:00:00Z",
                "cwd": "/private/work/AgentDock",
                "model": "claude-opus-4-1"
            ],
            [
                "type": "user",
                "uuid": "user-event",
                "_audit_timestamp": "2026-07-28T10:00:01Z",
                "message": ["role": "user", "content": "Inspect the package"]
            ],
            [
                "type": "assistant",
                "uuid": "assistant-event",
                "_audit_timestamp": "2026-07-28T10:00:02Z",
                "message": [
                    "role": "assistant",
                    "content": [
                        ["type": "text", "text": "The package is valid."],
                        ["type": "thinking", "thinking": "I should verify the artifact."],
                        [
                            "type": "tool_use",
                            "name": "exec_command",
                            "input": ["cmd": "swift test"]
                        ]
                    ]
                ]
            ],
            [
                "type": "user",
                "uuid": "tool-result-event",
                "_audit_timestamp": "2026-07-28T10:00:03Z",
                "message": [
                    "role": "user",
                    "content": [[
                        "type": "tool_result",
                        "tool_use_id": "tool-1",
                        "content": "All tests passed."
                    ]]
                ]
            ],
            [
                "type": "result",
                "uuid": "result-event",
                "_audit_timestamp": "2026-07-28T10:00:04Z",
                "is_error": false,
                "result": "Done"
            ],
            [
                "type": "attachment",
                "uuid": "attachment-event",
                "_audit_timestamp": "2026-07-28T10:00:05Z"
            ]
        ]
        try writeJSONLines(records, to: audit)
        if malformedTail {
            let handle = try FileHandle(forWritingTo: audit)
            try handle.seekToEnd()
            try handle.write(contentsOf: Data("\n{\"type\":".utf8))
            try handle.close()
        }
        return (metadata, audit)
    }

    private func forwardEntries(
        scanner: LocalChatScanner,
        session: LocalChatSession
    ) -> [LocalChatTranscriptEntry] {
        var entries: [LocalChatTranscriptEntry] = []
        var cursor: LocalChatTranscriptCursor?
        repeat {
            let page = scanner.loadTranscriptForwardPage(for: session, after: cursor)
            entries.append(contentsOf: page.entries)
            cursor = page.olderCursor
        } while cursor != nil
        return entries
    }

    private func writeJSONLines(_ records: [[String: Any]], to url: URL) throws {
        let lines = try records.map {
            String(decoding: try JSONSerialization.data(
                withJSONObject: $0,
                options: [.sortedKeys]
            ), as: UTF8.self)
        }
        try Data(lines.joined(separator: "\n").utf8).write(to: url)
    }
}
