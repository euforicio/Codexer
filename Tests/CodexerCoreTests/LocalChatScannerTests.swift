import XCTest
@testable import CodexerCore

final class LocalChatScannerTests: XCTestCase {
    private var root: URL!
    private var indexRoot: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalChatScannerTests-\(UUID().uuidString)", isDirectory: true)
        indexRoot = root.appendingPathComponent("Indexes", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        root = nil
        indexRoot = nil
    }

    func testFallbackIndexAndPagedTranscriptPreserveSupportedSourceEvents() throws {
        let profile = makeProfile("Work")
        let file = try sessionFile(profile: profile, name: "rollout-test.jsonl")
        try writeRecords([
            sessionMeta(id: "session-123456789", cwd: "/private/work/AgentDock"),
            [
                "timestamp": "2026-07-28T10:00:01Z",
                "type": "turn_context",
                "payload": ["model": "gpt-5.6"]
            ],
            message(role: "developer", text: "private instructions", second: 2),
            message(role: "user", text: "Review profile isolation", second: 3),
            [
                "timestamp": "2026-07-28T10:00:04Z",
                "type": "world_state",
                "payload": ["full": "must not render"]
            ],
            [
                "timestamp": "2026-07-28T10:00:05Z",
                "type": "response_item",
                "payload": [
                    "type": "function_call",
                    "name": "exec_command",
                    "arguments": "{\"cmd\":\"swift test\",\"workdir\":\"/private/tmp/project\"}"
                ]
            ],
            [
                "timestamp": "2026-07-28T10:00:05Z",
                "type": "response_item",
                "payload": [
                    "type": "function_call",
                    "name": "send_message",
                    "arguments": "{\"message\":\"gAAAAABsecretopaquevalue123456789012345678901234567890\"}"
                ]
            ],
            [
                "timestamp": "2026-07-28T10:00:05Z",
                "type": "unsupported_future_event",
                "payload": ["value": "valid but unsupported"]
            ],
            message(role: "assistant", text: "Isolation is intact.", second: 6),
            [
                "timestamp": "2026-07-28T10:00:07Z",
                "type": "event_msg",
                "payload": ["type": "task_complete"]
            ]
        ], to: file)

        let scanner = makeScanner()
        let result = scanner.scan(profile: profile)
        let summary = try XCTUnwrap(result.sessions.first)
        let entries = allEntries(scanner: scanner, session: summary)
        var forwardEntries: [LocalChatTranscriptEntry] = []
        var forwardCursor: LocalChatTranscriptCursor?
        repeat {
            let page = scanner.loadTranscriptForwardPage(for: summary, after: forwardCursor)
            forwardEntries += page.entries
            forwardCursor = page.olderCursor
        } while forwardCursor != nil

        XCTAssertEqual(result.diagnostics.parsedFileCount, 1)
        XCTAssertEqual(summary.id, "session-123456789")
        XCTAssertEqual(summary.title, "Review profile isolation")
        XCTAssertEqual(summary.model, "gpt-5.6")
        XCTAssertEqual(summary.repository, "AgentDock")
        XCTAssertTrue(summary.messages.isEmpty)
        XCTAssertEqual(entries.compactMap(\.role), [.user, .assistant])
        XCTAssertEqual(forwardEntries.compactMap(\.role), [.user, .assistant])
        XCTAssertEqual(
            forwardEntries.compactMap(\.message).map(\.text),
            ["Review profile isolation", "Isolation is intact."]
        )
        XCTAssertTrue(entries.contains { $0.kind == .command && $0.text.contains("swift test") })
        XCTAssertTrue(entries.contains { $0.kind == .command && $0.text.contains("…/project") })
        XCTAssertTrue(entries.contains {
            $0.title == "send_message" && $0.text == "Private agent coordination payload omitted."
        })
        XCTAssertTrue(entries.contains { $0.kind == .status && $0.title == "Completed" })
        XCTAssertFalse(entries.contains { $0.kind == .malformed })
        XCTAssertFalse(entries.contains { $0.text.contains("gAAAAA") })
        XCTAssertFalse(entries.contains { $0.text.contains("/private/tmp") })
        XCTAssertFalse(entries.contains { $0.text.contains("private instructions") })
        XCTAssertFalse(entries.contains { $0.text.contains("must not render") })
        XCTAssertTrue(entries.contains {
            $0.kind == .unsupported && $0.text.contains("Unsupported Future Event")
        })
    }

    func testPartialDatabaseIndexStillDiscoversUnindexedSessionFiles() throws {
        let profile = makeProfile("Partial Database")
        let indexed = try sessionFile(profile: profile, name: "rollout-indexed.jsonl")
        let fallback = try sessionFile(profile: profile, name: "rollout-fallback.jsonl")
        try writeRecords([
            sessionMeta(id: "indexed-session"),
            message(role: "user", text: "Indexed conversation", second: 1)
        ], to: indexed)
        try writeRecords([
            sessionMeta(id: "fallback-session"),
            message(role: "user", text: "Filesystem conversation", second: 2)
        ], to: fallback)
        let database = profile.codexHomePath.appendingPathComponent("state_5.sqlite")
        try runSQLite(database, sql: """
        create table threads (
          id text,
          rollout_path text,
          title text,
          updated_at integer
        );
        insert into threads values (
          'indexed-session',
          '\(indexed.path)',
          'Database conversation',
          1785232860
        );
        """)

        let result = makeScanner().scan(profile: profile)

        XCTAssertTrue(result.diagnostics.usedDatabase)
        XCTAssertEqual(result.diagnostics.parsedFileCount, 1)
        XCTAssertEqual(Set(result.sessions.map(\.id)), ["indexed-session", "fallback-session"])
        XCTAssertEqual(
            result.sessions.first { $0.id == "indexed-session" }?.title,
            "Database conversation"
        )
        XCTAssertEqual(
            result.sessions.first { $0.id == "fallback-session" }?.title,
            "Filesystem conversation"
        )
    }

    func testArchivedOnlyHistoryIsIndexed() throws {
        let profile = makeProfile("Archive")
        let file = try sessionFile(
            profile: profile,
            rootName: "archived_sessions",
            name: "rollout-archived.jsonl"
        )
        try writeRecords([
            sessionMeta(id: "archived-session"),
            message(role: "user", text: "Read archived chat", second: 1)
        ], to: file)

        let result = makeScanner().scan(profile: profile)

        XCTAssertEqual(result.sessions.count, 1)
        XCTAssertEqual(result.sessions.first?.id, "archived-session")
        XCTAssertEqual(result.sessions.first?.status, "Archived")
    }

    func testHundredsOfSessionsUseDurableCacheAndOnlyReparseChangedFile() throws {
        let profile = makeProfile("Many")
        var files: [URL] = []
        for index in 0..<350 {
            let file = try sessionFile(
                profile: profile,
                name: "rollout-\(String(format: "%04d", index)).jsonl"
            )
            try writeRecords([
                sessionMeta(id: "session-\(index)"),
                message(role: "user", text: "Conversation \(index)", second: index % 60)
            ], to: file)
            files.append(file)
        }
        let scanner = makeScanner(maximumSessions: 500)

        let first = scanner.scan(profile: profile)
        let second = scanner.scan(profile: profile)
        try FileHandle(forWritingTo: files[173]).use { handle in
            try handle.seekToEnd()
            try handle.write(contentsOf: Data("\n".utf8))
        }
        let third = scanner.scan(profile: profile)

        XCTAssertEqual(first.sessions.count, 350)
        XCTAssertEqual(first.diagnostics.parsedFileCount, 350)
        XCTAssertEqual(second.diagnostics.cacheHitCount, 350)
        XCTAssertEqual(second.diagnostics.parsedFileCount, 0)
        XCTAssertEqual(third.diagnostics.parsedFileCount, 1)
        XCTAssertEqual(third.diagnostics.cacheHitCount, 349)

        let index = try XCTUnwrap(
            FileManager.default.contentsOfDirectory(
                at: indexRoot,
                includingPropertiesForKeys: nil
            ).first
        )
        let data = try Data(contentsOf: index)
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(text.contains(profile.codexHomePath.path))
        XCTAssertEqual(
            try FileManager.default.attributesOfItem(atPath: index.path)[.posixPermissions] as? Int,
            0o600
        )
        scanner.removeIndex(profileID: profile.id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: index.path))
    }

    func testCodexSummaryBoundsEachSourceAndKeepsFullTranscriptAvailable() throws {
        let profile = makeProfile("Bounded")
        let file = try sessionFile(profile: profile, name: "rollout-bounded.jsonl")
        try writeRecords([
            sessionMeta(id: "bounded-session"),
            ["type": "ignored", "payload": ["padding": String(repeating: "a", count: 2_048)]],
            message(role: "user", text: "Message beyond summary budget", second: 1)
        ], to: file)
        let scanner = LocalChatScanner(maximumSummaryLineBytes: 1_024, indexRootURL: indexRoot)

        let result = scanner.scan(profile: profile)
        let session = try XCTUnwrap(result.sessions.first)

        XCTAssertEqual(result.sessions.count, 1)
        XCTAssertEqual(session.id, "bounded-session")
        XCTAssertEqual(session.title, "Untitled chat")
        XCTAssertTrue(allEntries(scanner: scanner, session: session).contains {
            $0.message?.text == "Message beyond summary budget"
        })
    }

    func testCodexSummaryBoundsAggregateReadBytesWithoutDroppingSessions() throws {
        let profile = makeProfile("Aggregate")
        for index in 0..<3 {
            let file = try sessionFile(profile: profile, name: "rollout-\(index).jsonl")
            try writeRecords([
                ["type": "ignored", "payload": ["padding": String(repeating: "a", count: 2_048)]],
                message(role: "user", text: "Message beyond budget", second: 1)
            ], to: file)
        }
        let scanner = LocalChatScanner(
            maximumMetadataBytes: 1_024,
            indexRootURL: indexRoot
        )
        let result = scanner.scan(profile: profile)

        XCTAssertEqual(result.sessions.count, 3)
        XCTAssertTrue(result.sessions.allSatisfy { $0.title == "Untitled chat" })
        XCTAssertEqual(result.diagnostics.parsedFileCount, 1)
        XCTAssertEqual(scanner.scan(profile: profile).diagnostics.parsedFileCount, 1)
        XCTAssertEqual(scanner.scan(profile: profile).diagnostics.parsedFileCount, 1)
        XCTAssertEqual(scanner.scan(profile: profile).diagnostics.cacheHitCount, 3)
    }

    func testManagedCacheDoesNotReuseMetadataAfterSourceRootChanges() throws {
        let original = makeProfile("Original")
        var replacement = makeProfile("Replacement")
        replacement.id = original.id
        let originalFile = try sessionFile(profile: original, name: "rollout-shared.jsonl")
        let replacementFile = try sessionFile(profile: replacement, name: "rollout-shared.jsonl")
        try writeRecords([
            sessionMeta(id: "shared-session"),
            message(role: "user", text: "Account A", second: 1)
        ], to: originalFile)
        try writeRecords([
            sessionMeta(id: "shared-session"),
            message(role: "user", text: "Account B", second: 1)
        ], to: replacementFile)
        let modifiedAt = Date(timeIntervalSince1970: 1_800_000_000)
        for file in [originalFile, replacementFile] {
            try FileManager.default.setAttributes(
                [.modificationDate: modifiedAt],
                ofItemAtPath: file.path
            )
        }
        let scanner = makeScanner()
        XCTAssertEqual(scanner.scan(profile: original).sessions.first?.title, "Account A")

        let result = scanner.scan(profile: replacement)

        XCTAssertEqual(result.sessions.first?.title, "Account B")
        XCTAssertEqual(result.diagnostics.parsedFileCount, 1)
        XCTAssertEqual(result.diagnostics.cacheHitCount, 0)
    }

    func testDuplicateCachedPathsAreDiscardedAndRebuilt() throws {
        let profile = makeProfile("Duplicate")
        let file = try sessionFile(profile: profile, name: "rollout-duplicate.jsonl")
        try writeRecords([
            sessionMeta(id: "duplicate-session"),
            message(role: "user", text: "Original content", second: 1)
        ], to: file)
        let scanner = makeScanner()
        XCTAssertEqual(scanner.scan(profile: profile).sessions.count, 1)
        let index = try XCTUnwrap(FileManager.default.contentsOfDirectory(
            at: indexRoot,
            includingPropertiesForKeys: nil
        ).first)
        var document = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: index)) as? [String: Any]
        )
        let records = try XCTUnwrap(document["records"] as? [[String: Any]])
        document["records"] = records + records
        try JSONSerialization.data(withJSONObject: document).write(to: index)

        let result = scanner.scan(profile: profile)

        XCTAssertEqual(result.sessions.map(\.title), ["Original content"])
        XCTAssertEqual(result.diagnostics.parsedFileCount, 1)
    }

    func testUnchangedScanDoesNotRewriteDurableIndex() throws {
        let profile = makeProfile("Unchanged")
        let file = try sessionFile(profile: profile, name: "rollout-unchanged.jsonl")
        try writeRecords([
            sessionMeta(id: "unchanged-session"),
            message(role: "user", text: "Stable content", second: 1)
        ], to: file)
        let scanner = makeScanner()
        XCTAssertEqual(scanner.scan(profile: profile).sessions.count, 1)
        let index = try XCTUnwrap(FileManager.default.contentsOfDirectory(
            at: indexRoot,
            includingPropertiesForKeys: nil
        ).first)
        let modifiedAt = Date(timeIntervalSince1970: 1_800_000_000)
        try FileManager.default.setAttributes(
            [.modificationDate: modifiedAt],
            ofItemAtPath: index.path
        )

        XCTAssertEqual(scanner.scan(profile: profile).diagnostics.cacheHitCount, 1)
        XCTAssertEqual(
            try FileManager.default.attributesOfItem(atPath: index.path)[.modificationDate] as? Date,
            modifiedAt
        )
    }

    func testCachedTimestampRoundTripDoesNotReportUnchangedTranscriptAsChanged() throws {
        let profile = makeProfile("Cached Transcript")
        let file = try sessionFile(profile: profile, name: "rollout-cached.jsonl")
        try writeRecords([
            sessionMeta(id: "cached-session"),
            message(role: "user", text: "Stable conversation", second: 1)
        ], to: file)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 1_800_000_000.1234567)],
            ofItemAtPath: file.path
        )
        let scanner = makeScanner()
        _ = scanner.scan(profile: profile)
        let cached = scanner.scan(profile: profile)
        XCTAssertEqual(cached.diagnostics.cacheHitCount, 1)
        let session = try XCTUnwrap(cached.sessions.first)

        let page = scanner.loadTranscriptForwardPage(for: session)
        XCTAssertFalse(page.sourceChanged)
        XCTAssertTrue(page.entries.contains { $0.text == "Stable conversation" })
    }

    func testWarmScanRejectsCachedSourceReplacedWithSymlink() throws {
        let profile = makeProfile("Replaced Source")
        let file = try sessionFile(profile: profile, name: "rollout-replaced.jsonl")
        try writeRecords([
            sessionMeta(id: "replaced-session"),
            message(role: "user", text: "Original conversation", second: 1)
        ], to: file)
        let scanner = makeScanner()
        _ = scanner.scan(profile: profile)
        let warm = scanner.scan(profile: profile)
        XCTAssertEqual(warm.diagnostics.cacheHitCount, 1)
        let session = try XCTUnwrap(warm.sessions.first)

        let movedFile = root.appendingPathComponent("outside-session.jsonl")
        try FileManager.default.moveItem(at: file, to: movedFile)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: movedFile)

        let replaced = scanner.scan(profile: profile)
        XCTAssertTrue(replaced.sessions.isEmpty)
        XCTAssertEqual(replaced.diagnostics.cacheHitCount, 0)
        XCTAssertEqual(replaced.diagnostics.sourceFileCount, 0)
        let page = scanner.loadTranscriptPage(for: session)
        XCTAssertEqual(page.entries.map(\.kind), [.error])

        try FileManager.default.removeItem(at: file)
        try FileManager.default.moveItem(at: movedFile, to: file)
        let restored = scanner.scan(profile: profile)
        XCTAssertEqual(restored.sessions.map(\.id), ["replaced-session"])
        XCTAssertEqual(restored.diagnostics.parsedFileCount, 1)
    }

    func testWarmScanRevalidatesSessionRootAfterSymlinkReplacement() throws {
        let profile = makeProfile("Replaced Root")
        let file = try sessionFile(profile: profile, name: "rollout-root.jsonl")
        try writeRecords([
            sessionMeta(id: "root-session"),
            message(role: "user", text: "Original conversation", second: 1)
        ], to: file)
        let scanner = makeScanner()
        _ = scanner.scan(profile: profile)
        XCTAssertEqual(scanner.scan(profile: profile).diagnostics.cacheHitCount, 1)
        let sessionsRoot = profile.codexHomePath.appendingPathComponent("sessions", isDirectory: true)
        let movedRoot = root.appendingPathComponent("outside-sessions", isDirectory: true)
        try FileManager.default.moveItem(at: sessionsRoot, to: movedRoot)
        try FileManager.default.createSymbolicLink(at: sessionsRoot, withDestinationURL: movedRoot)

        let replaced = scanner.scan(profile: profile)
        XCTAssertTrue(replaced.sessions.isEmpty)
        XCTAssertEqual(replaced.diagnostics.cacheHitCount, 0)
        XCTAssertEqual(replaced.diagnostics.sourceFileCount, 0)

        try FileManager.default.removeItem(at: sessionsRoot)
        try FileManager.default.moveItem(at: movedRoot, to: sessionsRoot)
        let restored = scanner.scan(profile: profile)
        XCTAssertEqual(restored.sessions.map(\.id), ["root-session"])
        XCTAssertEqual(restored.diagnostics.parsedFileCount, 1)
    }

    func testTranscriptOverTwentyMegabytesAndOversizedLineRemainVisible() throws {
        let profile = makeProfile("Large")
        let file = try sessionFile(profile: profile, name: "rollout-large.jsonl")
        try writeRecords([
            sessionMeta(id: "large-session"),
            message(role: "user", text: "Open the large chat", second: 1)
        ], to: file)
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("\n{\"type\":\"tool_output\",\"payload\":{\"blob\":\"".utf8))
        try handle.write(contentsOf: Data(repeating: 0x61, count: 21 * 1_024 * 1_024))
        try handle.write(contentsOf: Data("\"}}\n".utf8))
        try handle.write(contentsOf: try lineData(
            message(role: "assistant", text: "Large chat loaded.", second: 2)
        ))
        try handle.close()

        let scanner = makeScanner()
        let summary = try XCTUnwrap(scanner.scan(profile: profile).sessions.first)
        let entries = allEntries(scanner: scanner, session: summary)
        var forwardEntries: [LocalChatTranscriptEntry] = []
        var cursor: LocalChatTranscriptCursor?
        repeat {
            let page = scanner.loadTranscriptForwardPage(for: summary, after: cursor)
            forwardEntries += page.entries
            cursor = page.olderCursor
        } while cursor != nil

        XCTAssertGreaterThan(summary.sourceSize, 20 * 1_024 * 1_024)
        XCTAssertEqual(
            entries.filter { $0.kind == .message }.map(\.text),
            ["Open the large chat", "Large chat loaded."]
        )
        XCTAssertTrue(entries.contains { $0.kind == .oversized })
        XCTAssertEqual(
            forwardEntries.filter { $0.kind == .message }.map(\.text),
            ["Open the large chat", "Large chat loaded."]
        )
        XCTAssertTrue(forwardEntries.contains { $0.kind == .oversized })
    }

    func testOversizedOnlyContentStillProducesAListRecord() throws {
        let profile = makeProfile("Oversized")
        let file = try sessionFile(profile: profile, name: "rollout-oversized.jsonl")
        let handle = FileManager.default.createFile(atPath: file.path, contents: nil)
        XCTAssertTrue(handle)
        let writer = try FileHandle(forWritingTo: file)
        try writer.write(contentsOf: Data("{\"type\":\"response_item\",\"payload\":{\"type\":\"message\",\"role\":\"user\",\"content\":[{\"type\":\"input_text\",\"text\":\"".utf8))
        try writer.write(contentsOf: Data(repeating: 0x62, count: 3 * 1_024 * 1_024))
        try writer.write(contentsOf: Data("\"}]}}\n".utf8))
        try writer.close()

        let result = makeScanner().scan(profile: profile)

        XCTAssertEqual(result.sessions.count, 1)
        XCTAssertEqual(result.sessions.first?.title, "Untitled chat")
        XCTAssertTrue(
            allEntries(scanner: makeScanner(), session: try XCTUnwrap(result.sessions.first))
                .contains { $0.kind == .oversized }
        )
    }

    func testMalformedAndTruncatedTailAreRepresentedHonestly() throws {
        let profile = makeProfile("Partial")
        let file = try sessionFile(profile: profile, name: "rollout-partial.jsonl")
        try writeRecords([
            sessionMeta(id: "partial-session"),
            message(role: "user", text: "Before the partial event", second: 1)
        ], to: file)
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("\n{\"type\":\"response_item\",\"payload\":".utf8))
        try handle.close()

        let scanner = makeScanner()
        let summary = try XCTUnwrap(scanner.scan(profile: profile).sessions.first)
        let page = scanner.loadTranscriptPage(for: summary)

        XCTAssertTrue(page.entries.contains { $0.kind == .message })
        XCTAssertTrue(page.entries.contains { $0.kind == .malformed })
        XCTAssertEqual(page.malformedEventCount, 1)
    }

    func testSchemaDriftUsesAvailableColumnsWithoutParsingTranscript() throws {
        let profile = makeProfile("Drift")
        let file = try sessionFile(profile: profile, name: "rollout-drift.jsonl")
        try writeRecords([sessionMeta(id: "file-id")], to: file)
        let database = profile.codexHomePath.appendingPathComponent("state_5.sqlite")
        try runSQLite(database, sql: """
        create table threads (
          rollout_path text not null,
          title text,
          updated_at_ms integer,
          archived text
        );
        insert into threads values (
          '\(file.path)',
          'Schema drift title',
          1785232860000,
          '0'
        );
        """)

        let result = makeScanner().scan(profile: profile)
        let session = try XCTUnwrap(result.sessions.first)

        XCTAssertTrue(result.diagnostics.usedDatabase)
        XCTAssertEqual(result.diagnostics.parsedFileCount, 0)
        XCTAssertEqual(session.title, "Schema drift title")
        XCTAssertTrue(session.id.hasPrefix("local-"))
    }

    func testIncompatibleDatabaseFallsBackToFiles() throws {
        let profile = makeProfile("Fallback")
        let file = try sessionFile(profile: profile, name: "rollout-fallback.jsonl")
        try writeRecords([
            sessionMeta(id: "fallback-session"),
            message(role: "user", text: "Filesystem fallback", second: 1)
        ], to: file)
        let database = profile.codexHomePath.appendingPathComponent("state_5.sqlite")
        try runSQLite(database, sql: "create table threads (unexpected text);")

        let result = makeScanner().scan(profile: profile)

        XCTAssertFalse(result.diagnostics.usedDatabase)
        XCTAssertEqual(result.sessions.first?.title, "Filesystem fallback")
    }

    func testClosedWALDatabaseWithoutSidecarsRemainsReadable() throws {
        let profile = makeProfile("WAL")
        let file = try sessionFile(profile: profile, name: "rollout-wal.jsonl")
        try writeRecords([sessionMeta(id: "wal-session")], to: file)
        let database = profile.codexHomePath.appendingPathComponent("state_5.sqlite")
        try runSQLite(database, sql: """
        pragma journal_mode=wal;
        create table threads (
          id text,
          rollout_path text,
          title text,
          updated_at integer
        );
        insert into threads values (
          'wal-session',
          '\(file.path)',
          'Checkpointed WAL chat',
          1785232860
        );
        pragma wal_checkpoint(truncate);
        """)
        try? FileManager.default.removeItem(at: URL(fileURLWithPath: database.path + "-wal"))
        try? FileManager.default.removeItem(at: URL(fileURLWithPath: database.path + "-shm"))

        let result = makeScanner().scan(profile: profile)

        XCTAssertTrue(result.diagnostics.usedDatabase)
        XCTAssertEqual(result.sessions.first?.title, "Checkpointed WAL chat")
    }

    func testActiveWALDatabaseWithSidecarsRemainsReadable() throws {
        let profile = makeProfile("Active WAL")
        let file = try sessionFile(profile: profile, name: "rollout-active-wal.jsonl")
        try writeRecords([sessionMeta(id: "active-wal-session")], to: file)
        let database = profile.codexHomePath.appendingPathComponent("state_5.sqlite")
        let process = Process()
        let input = Pipe()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = [database.path]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = Pipe()
        try process.run()
        defer {
            try? input.fileHandleForWriting.write(contentsOf: Data(".quit\n".utf8))
            process.waitUntilExit()
        }
        let sql = """
        pragma journal_mode=wal;
        create table threads (
          id text,
          rollout_path text,
          title text,
          updated_at integer
        );
        insert into threads values (
          'active-wal-session',
          '\(file.path)',
          'Active WAL chat',
          1785232860
        );
        select 'agentdock-ready';

        """
        try input.fileHandleForWriting.write(contentsOf: Data(sql.utf8))
        var sqliteOutput = Data()
        while !sqliteOutput.contains(Data("agentdock-ready\n".utf8)) {
            let chunk = output.fileHandleForReading.availableData
            guard !chunk.isEmpty else { break }
            sqliteOutput.append(chunk)
        }
        XCTAssertTrue(sqliteOutput.contains(Data("agentdock-ready\n".utf8)))
        let wal = URL(fileURLWithPath: database.path + "-wal")
        XCTAssertTrue(FileManager.default.fileExists(atPath: wal.path))

        let result = makeScanner().scan(profile: profile)

        XCTAssertTrue(result.diagnostics.usedDatabase)
        XCTAssertEqual(result.sessions.first?.title, "Active WAL chat")
    }

    func testSQLiteSharedMemoryChurnDoesNotTriggerChatRefresh() throws {
        let profile = makeProfile("Stable")
        try FileManager.default.createDirectory(
            at: profile.codexHomePath,
            withIntermediateDirectories: true
        )
        let database = profile.codexHomePath.appendingPathComponent("state_5.sqlite")
        try runSQLite(database, sql: "create table threads (rollout_path text);")
        let scanner = makeScanner()
        let before = scanner.changeToken(profile: profile)
        let sharedMemory = URL(fileURLWithPath: database.path + "-shm")
        try Data(repeating: 0x41, count: 32 * 1_024).write(to: sharedMemory)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(10)],
            ofItemAtPath: sharedMemory.path
        )

        XCTAssertEqual(scanner.changeToken(profile: profile), before)
    }

    func testCancelledPageLoadDoesNotPublishContent() async throws {
        let profile = makeProfile("Cancelled")
        let file = try sessionFile(profile: profile, name: "rollout-cancelled.jsonl")
        try writeRecords([
            sessionMeta(id: "cancelled-session"),
            message(role: "user", text: "Cancel me", second: 1)
        ], to: file)
        let scanner = makeScanner()
        let session = try XCTUnwrap(scanner.scan(profile: profile).sessions.first)

        let task = Task.detached {
            withUnsafeCurrentTask { $0?.cancel() }
            return scanner.loadTranscriptPage(for: session)
        }
        let page = await task.value

        XCTAssertTrue(page.entries.isEmpty)
    }

    func testManagedClaudeWithoutLocalAgentHistoryIsAvailableAndEmpty() {
        let profile = CodexProfile(
            product: .claude,
            name: "Claude Work",
            slug: "work",
            rootDirectory: root,
            shortcutDirectory: root.appendingPathComponent("Shortcuts")
        )

        let result = makeScanner().scan(profile: profile)

        XCTAssertTrue(result.sessions.isEmpty)
        XCTAssertEqual(result.availability, .available)
        XCTAssertEqual(result.changeToken, "")
    }

    private func makeProfile(_ name: String) -> CodexProfile {
        CodexProfile(
            name: name,
            slug: name.lowercased(),
            rootDirectory: root,
            shortcutDirectory: root.appendingPathComponent("Shortcuts")
        )
    }

    private func makeScanner(maximumSessions: Int = 1_000) -> LocalChatScanner {
        LocalChatScanner(
            maximumSessions: maximumSessions,
            indexRootURL: indexRoot
        )
    }

    private func sessionFile(
        profile: CodexProfile,
        rootName: String = "sessions",
        name: String
    ) throws -> URL {
        let directory = profile.codexHomePath.appendingPathComponent(
            rootName == "sessions" ? "\(rootName)/2026/07/28" : rootName,
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent(name)
    }

    private func allEntries(
        scanner: LocalChatScanner,
        session: LocalChatSession
    ) -> [LocalChatTranscriptEntry] {
        var page = scanner.loadTranscriptPage(for: session)
        var entries = page.entries
        var iterations = 0
        while let cursor = page.olderCursor, iterations < 100 {
            page = scanner.loadTranscriptPage(for: session, before: cursor)
            entries = page.entries + entries
            iterations += 1
        }
        return entries
    }

    private func sessionMeta(id: String, cwd: String? = nil) -> [String: Any] {
        var payload: [String: Any] = [
            "id": id,
            "timestamp": "2026-07-28T10:00:00Z"
        ]
        if let cwd {
            payload["cwd"] = cwd
            payload["git"] = ["branch": "codex/history-index"]
        }
        return [
            "timestamp": "2026-07-28T10:00:00Z",
            "type": "session_meta",
            "payload": payload
        ]
    }

    private func message(role: String, text: String, second: Int) -> [String: Any] {
        [
            "timestamp": String(format: "2026-07-28T10:00:%02dZ", second),
            "type": "response_item",
            "payload": [
                "type": "message",
                "role": role,
                "content": [[
                    "type": role == "assistant" ? "output_text" : "input_text",
                    "text": text
                ]]
            ]
        ]
    }

    private func writeRecords(_ records: [[String: Any]], to file: URL) throws {
        try records.map { String(decoding: try lineData($0), as: UTF8.self) }
            .joined(separator: "\n")
            .data(using: .utf8)!
            .write(to: file)
    }

    private func lineData(_ record: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: record)
    }

    private func runSQLite(_ database: URL, sql: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = [database.path, sql]
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
    }

}

private extension FileHandle {
    func use(_ body: (FileHandle) throws -> Void) throws {
        defer { try? close() }
        try body(self)
    }
}
