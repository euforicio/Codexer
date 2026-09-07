import Foundation
import Darwin

public enum LocalChatAvailability: Equatable, Sendable {
    case available
    case unavailable(String)
}

private struct ClaudeUsageSummary: Sendable {
    let totalTokens: Int
    let latestUsageLimit: UsageLimitSignal?
}

private final class ClaudeUsageCache: @unchecked Sendable {
    private struct Entry {
        let size: UInt64
        let modifiedAt: Date
        let summary: ClaudeUsageSummary
    }

    private let lock = NSLock()
    private var entries: [String: Entry] = [:]

    func value(for path: String, size: UInt64, modifiedAt: Date) -> ClaudeUsageSummary? {
        lock.lock()
        defer { lock.unlock() }
        guard let entry = entries[path], entry.size == size,
              abs(entry.modifiedAt.timeIntervalSince(modifiedAt)) < 0.002
        else {
            return nil
        }
        return entry.summary
    }

    func store(_ summary: ClaudeUsageSummary, for path: String, size: UInt64, modifiedAt: Date) {
        lock.lock()
        defer { lock.unlock() }
        if entries.count >= 10_000, entries[path] == nil {
            entries.removeAll(keepingCapacity: true)
        }
        entries[path] = Entry(size: size, modifiedAt: modifiedAt, summary: summary)
    }
}

public enum LocalChatRole: String, Codable, Sendable {
    case user
    case assistant
}

public struct LocalChatMessage: Identifiable, Hashable, Sendable {
    public let id: String
    public let role: LocalChatRole
    public let text: String
    public let timestamp: Date?

    public init(
        id: String = UUID().uuidString,
        role: LocalChatRole,
        text: String,
        timestamp: Date?
    ) {
        self.id = id
        self.role = role
        self.text = text
        self.timestamp = timestamp
    }
}

public enum LocalChatTranscriptEntryKind: String, Codable, Sendable {
    case message
    case reasoning
    case activity
    case command
    case file
    case error
    case status
    case malformed
    case oversized
    case unsupported
}

/// Renderer-facing, source-backed transcript data. The UI decides how compact
/// or collapsible non-message entries should be.
public struct LocalChatTranscriptEntry: Identifiable, Hashable, Sendable {
    public let id: String
    public let kind: LocalChatTranscriptEntryKind
    public let role: LocalChatRole?
    public let title: String?
    public let text: String
    public let timestamp: Date?
    public let isCollapsible: Bool
    public let sourceOrdinal: Int?

    public init(
        id: String,
        kind: LocalChatTranscriptEntryKind,
        role: LocalChatRole? = nil,
        title: String? = nil,
        text: String,
        timestamp: Date? = nil,
        isCollapsible: Bool = false,
        sourceOrdinal: Int? = nil
    ) {
        self.id = id
        self.kind = kind
        self.role = role
        self.title = title
        self.text = text
        self.timestamp = timestamp
        self.isCollapsible = isCollapsible
        self.sourceOrdinal = sourceOrdinal
    }

    public var message: LocalChatMessage? {
        guard kind == .message, let role else { return nil }
        return LocalChatMessage(id: id, role: role, text: text, timestamp: timestamp)
    }

    func withSourceOrdinal(_ value: Int) -> Self {
        .init(
            id: id,
            kind: kind,
            role: role,
            title: title,
            text: text,
            timestamp: timestamp,
            isCollapsible: isCollapsible,
            sourceOrdinal: value
        )
    }
}

public struct LocalChatTranscriptCursor: Hashable, Sendable {
    public let byteOffset: UInt64
    public let sourceSize: UInt64
    public let sourceModifiedAt: Date
    public let sourceIdentifier: String?
    public let skippingOversizedLine: Bool
    public let nextSequence: Int

    public init(
        byteOffset: UInt64,
        sourceSize: UInt64,
        sourceModifiedAt: Date,
        sourceIdentifier: String? = nil,
        skippingOversizedLine: Bool = false,
        nextSequence: Int = 0
    ) {
        self.byteOffset = byteOffset
        self.sourceSize = sourceSize
        self.sourceModifiedAt = sourceModifiedAt
        self.sourceIdentifier = sourceIdentifier
        self.skippingOversizedLine = skippingOversizedLine
        self.nextSequence = nextSequence
    }
}

public struct LocalChatTranscriptPage: Sendable {
    public let entries: [LocalChatTranscriptEntry]
    public let olderCursor: LocalChatTranscriptCursor?
    public let sourceChanged: Bool
    public let malformedEventCount: Int

    public init(
        entries: [LocalChatTranscriptEntry],
        olderCursor: LocalChatTranscriptCursor?,
        sourceChanged: Bool,
        malformedEventCount: Int
    ) {
        self.entries = entries
        self.olderCursor = olderCursor
        self.sourceChanged = sourceChanged
        self.malformedEventCount = malformedEventCount
    }
}

public struct LocalChatSession: Identifiable, Hashable, Sendable {
    public let id: String
    public let provider: DesktopProduct
    public let profileID: CodexProfile.ID?
    public let profileName: String
    public let title: String
    public let preview: String?
    public let model: String?
    public let repository: String?
    public let branch: String?
    public let startedAt: Date
    public let updatedAt: Date
    public let tokenCount: Int?
    public let latestUsageLimit: UsageLimitSignal?
    public let status: String
    public let sourceURL: URL
    let sourceRootURL: URL
    public let sourceSize: UInt64
    public let sourceModifiedAt: Date
    public let messages: [LocalChatMessage]

    public var duration: TimeInterval {
        max(0, updatedAt.timeIntervalSince(startedAt))
    }

    init(
        id: String,
        provider: DesktopProduct,
        profileID: CodexProfile.ID?,
        profileName: String,
        title: String,
        preview: String?,
        model: String?,
        repository: String?,
        branch: String?,
        startedAt: Date,
        updatedAt: Date,
        tokenCount: Int?,
        latestUsageLimit: UsageLimitSignal? = nil,
        status: String,
        sourceURL: URL,
        sourceRootURL: URL,
        sourceSize: UInt64,
        sourceModifiedAt: Date,
        messages: [LocalChatMessage] = []
    ) {
        self.id = id
        self.provider = provider
        self.profileID = profileID
        self.profileName = profileName
        self.title = title
        self.preview = preview
        self.model = model
        self.repository = repository
        self.branch = branch
        self.startedAt = startedAt
        self.updatedAt = updatedAt
        self.tokenCount = tokenCount
        self.latestUsageLimit = latestUsageLimit
        self.status = status
        self.sourceURL = sourceURL
        self.sourceRootURL = sourceRootURL
        self.sourceSize = sourceSize
        self.sourceModifiedAt = sourceModifiedAt
        self.messages = messages
    }

    public func replacingMessages(_ messages: [LocalChatMessage]) -> Self {
        Self(
            id: id,
            provider: provider,
            profileID: profileID,
            profileName: profileName,
            title: title,
            preview: preview,
            model: model,
            repository: repository,
            branch: branch,
            startedAt: startedAt,
            updatedAt: updatedAt,
            tokenCount: tokenCount,
            status: status,
            sourceURL: sourceURL,
            sourceRootURL: sourceRootURL,
            sourceSize: sourceSize,
            sourceModifiedAt: sourceModifiedAt,
            messages: messages
        )
    }
}

public struct LocalChatScanDiagnostics: Equatable, Sendable {
    public let cacheHitCount: Int
    public let parsedFileCount: Int
    public let sourceFileCount: Int
    public let usedDatabase: Bool
    public let inventoryTruncated: Bool

    public init(
        cacheHitCount: Int = 0,
        parsedFileCount: Int = 0,
        sourceFileCount: Int = 0,
        usedDatabase: Bool = false,
        inventoryTruncated: Bool = false
    ) {
        self.cacheHitCount = cacheHitCount
        self.parsedFileCount = parsedFileCount
        self.sourceFileCount = sourceFileCount
        self.usedDatabase = usedDatabase
        self.inventoryTruncated = inventoryTruncated
    }
}

public struct LocalChatScanResult: Sendable {
    public let availability: LocalChatAvailability
    public let sessions: [LocalChatSession]
    public let changeToken: String
    public let diagnostics: LocalChatScanDiagnostics

    public init(
        availability: LocalChatAvailability,
        sessions: [LocalChatSession],
        changeToken: String = "",
        diagnostics: LocalChatScanDiagnostics = .init()
    ) {
        self.availability = availability
        self.sessions = sessions
        self.changeToken = changeToken
        self.diagnostics = diagnostics
    }
}

public struct LocalChatScanner: @unchecked Sendable {
    private static let sqliteURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
    private static let indexVersion = 2
    private static let indexMutationLock = NSLock()

    private let fileManager: FileManager
    private let maximumSessions: Int
    private let maximumSummaryLineBytes: Int
    private let transcriptPageBytes: Int
    private let transcriptPageEntries: Int
    private let maximumRenderableEntryBytes: Int
    private let maximumInventoryFiles: Int
    private let maximumMetadataBytes: Int
    private let maximumClaudeUsageBytes: Int
    private let indexRootURL: URL
    private let claudeUsageCache: ClaudeUsageCache

    public init(
        fileManager: FileManager = .default,
        maximumSessions: Int = 1_000,
        maximumSummaryLineBytes: Int = 2 * 1_024 * 1_024,
        transcriptPageBytes: Int = 1 * 1_024 * 1_024,
        transcriptPageEntries: Int = 60,
        maximumRenderableEntryBytes: Int = 2 * 1_024 * 1_024,
        maximumInventoryFiles: Int? = nil,
        maximumMetadataBytes: Int = 16 * 1_024 * 1_024,
        maximumClaudeUsageBytes: Int = 512 * 1_024 * 1_024,
        indexRootURL: URL? = nil
    ) {
        self.fileManager = fileManager
        self.maximumSessions = maximumSessions
        self.maximumSummaryLineBytes = maximumSummaryLineBytes
        self.transcriptPageBytes = transcriptPageBytes
        self.transcriptPageEntries = transcriptPageEntries
        self.maximumRenderableEntryBytes = maximumRenderableEntryBytes
        self.maximumInventoryFiles = max(
            1,
            maximumInventoryFiles
                ?? (maximumSessions > 2_500 ? 10_000 : max(1, maximumSessions * 4))
        )
        self.maximumMetadataBytes = max(1, maximumMetadataBytes)
        self.maximumClaudeUsageBytes = max(1, maximumClaudeUsageBytes)
        self.indexRootURL = indexRootURL
            ?? fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("AgentDock/ChatIndexes", isDirectory: true)
        claudeUsageCache = ClaudeUsageCache()
    }

    public func scan(profile: CodexProfile) -> LocalChatScanResult {
        switch profile.product {
        case .codex:
            return scanCodex(
                codexHomeURL: profile.codexHomePath,
                profileID: profile.id,
                profileName: profile.name
            )
        case .claude:
            return scanClaudeUserData(
                userDataURL: profile.claudeUserDataPath,
                profileID: profile.id,
                profileName: profile.name
            )
        }
    }

    public func scanOfficialCodex(codexHomeURL: URL) -> LocalChatScanResult {
        scanCodex(
            codexHomeURL: codexHomeURL,
            profileID: nil,
            profileName: "Official Codex"
        )
    }

    public func scanOfficialClaude(
        claudeHomeURL: URL,
        claudeCodeHomeURL: URL? = nil
    ) -> LocalChatScanResult {
        let primary = scanClaudeUserData(
            userDataURL: claudeHomeURL,
            profileID: nil,
            profileName: "Official Claude"
        )
        let fallbackRoot = claudeCodeHomeURL
            ?? (fileManager.fileExists(
                atPath: claudeHomeURL.appendingPathComponent("history.jsonl").path
            ) ? claudeHomeURL : nil)
        guard let fallbackRoot, !Task.isCancelled else { return primary }
        let fallback = scanClaudeCode(claudeHomeURL: fallbackRoot)
        let sorted = (primary.sessions + fallback.sessions).sorted {
            if $0.updatedAt == $1.updatedAt { return $0.id > $1.id }
            return $0.updatedAt > $1.updatedAt
        }
        var seenIDs: Set<String> = []
        let sessions = sorted.filter { seenIDs.insert($0.id).inserted }
        return .init(
            availability: .available,
            sessions: Array(sessions.prefix(maximumSessions)),
            changeToken: "\(primary.changeToken):\(fallback.changeToken)",
            diagnostics: .init(
                parsedFileCount: primary.diagnostics.parsedFileCount
                    + fallback.diagnostics.parsedFileCount,
                sourceFileCount: primary.diagnostics.sourceFileCount
                    + fallback.diagnostics.sourceFileCount,
                inventoryTruncated: primary.diagnostics.inventoryTruncated
                    || fallback.diagnostics.inventoryTruncated
            )
        )
    }

    public func changeToken(profile: CodexProfile) -> String {
        switch profile.product {
        case .codex:
            return sourceChangeToken(codexHomeURL: profile.codexHomePath)
        case .claude:
            return claudeUserDataChangeToken(userDataURL: profile.claudeUserDataPath)
        }
    }

    public func officialCodexChangeToken(codexHomeURL: URL) -> String {
        sourceChangeToken(codexHomeURL: codexHomeURL)
    }

    public func officialClaudeChangeToken(
        claudeHomeURL: URL,
        claudeCodeHomeURL: URL? = nil
    ) -> String {
        let primary = claudeUserDataChangeToken(userDataURL: claudeHomeURL)
        let fallbackRoot = claudeCodeHomeURL
            ?? (fileManager.fileExists(
                atPath: claudeHomeURL.appendingPathComponent("history.jsonl").path
            ) ? claudeHomeURL : nil)
        guard let fallbackRoot else { return primary }
        return "\(primary):\(claudeCodeChangeToken(claudeHomeURL: fallbackRoot))"
    }

    public func removeIndex(profileID: CodexProfile.ID) {
        Self.indexMutationLock.lock()
        defer { Self.indexMutationLock.unlock() }
        let scopeKey = "managed-\(profileID.uuidString.lowercased())"
        try? fileManager.removeItem(at: indexURL(scopeKey: scopeKey))
        try? fileManager.removeItem(
            at: indexRootURL.appendingPathComponent("\(scopeKey)-v1.json")
        )
    }

    public func loadTranscriptPage(
        for session: LocalChatSession,
        before cursor: LocalChatTranscriptCursor? = nil
    ) -> LocalChatTranscriptPage {
        guard !Task.isCancelled else {
            return LocalChatTranscriptPage(
                entries: [],
                olderCursor: cursor,
                sourceChanged: false,
                malformedEventCount: 0
            )
        }
        guard
            let opened = openTranscriptSource(for: session)
        else {
            return LocalChatTranscriptPage(
                entries: [
                    .init(
                        id: "\(session.id)-missing",
                        kind: .error,
                        title: "Transcript unavailable",
                        text: "The local session file is no longer available."
                    )
                ],
                olderCursor: nil,
                sourceChanged: cursor != nil,
                malformedEventCount: 0
            )
        }
        let values = opened.values
        let handle = opened.handle
        defer { try? handle.close() }

        let currentSize = UInt64(max(0, values.fileSize ?? 0))
        let currentModifiedAt = values.contentModificationDate ?? session.sourceModifiedAt
        let currentIdentifier = values.fileResourceIdentifier.map { String(describing: $0) }
        if let cursor, cursor.sourceSize != currentSize
            || cursor.sourceModifiedAt != currentModifiedAt
            || (cursor.sourceIdentifier != nil && cursor.sourceIdentifier != currentIdentifier)
        {
            return LocalChatTranscriptPage(
                entries: [],
                olderCursor: nil,
                sourceChanged: true,
                malformedEventCount: 0
            )
        }
        let snapshotSize = cursor?.sourceSize ?? currentSize
        let endOffset = min(cursor?.byteOffset ?? snapshotSize, currentSize)
        let sourceChanged = cursor.map {
            $0.sourceSize != currentSize || $0.sourceModifiedAt != currentModifiedAt
        } ?? (session.sourceSize != currentSize
            || !Self.sameModificationDate(session.sourceModifiedAt, currentModifiedAt))

        guard endOffset > 0 else {
            return LocalChatTranscriptPage(
                entries: [],
                olderCursor: nil,
                sourceChanged: sourceChanged,
                malformedEventCount: 0
            )
        }

        let requestedStart = endOffset > UInt64(transcriptPageBytes)
            ? endOffset - UInt64(transcriptPageBytes)
            : 0
        guard let window = readRange(handle: handle, start: requestedStart, end: endOffset) else {
            return LocalChatTranscriptPage(
                entries: [],
                olderCursor: nil,
                sourceChanged: sourceChanged,
                malformedEventCount: 0
            )
        }

        var completeStart = 0
        var olderOffset: UInt64?
        var oversizedPrefixBytes: UInt64?
        if requestedStart > 0 {
            if let newline = window.firstIndex(of: 0x0A) {
                completeStart = window.distance(from: window.startIndex, to: newline) + 1
                olderOffset = requestedStart + UInt64(completeStart - 1)
                if completeStart == window.count {
                    let previous = previousNewlineOffset(handle: handle, before: requestedStart)
                    oversizedPrefixBytes = olderOffset.map { $0 - (previous.map { $0 + 1 } ?? 0) }
                    olderOffset = previous
                }
            } else {
                let previous = previousNewlineOffset(handle: handle, before: requestedStart)
                oversizedPrefixBytes = endOffset - (previous.map { $0 + 1 } ?? 0)
                olderOffset = previous
                completeStart = window.count
            }
        }

        var decoded: [(offset: UInt64, entry: LocalChatTranscriptEntry)] = []
        var malformedCount = 0
        if completeStart < window.count {
            var lineStart = completeStart
            var index = completeStart
            while index <= window.count, !Task.isCancelled {
                let isEnd = index == window.count
                if isEnd || window[index] == 0x0A {
                    if index > lineStart {
                        let absoluteOffset = requestedStart + UInt64(lineStart)
                        let line = window.subdata(in: lineStart..<index)
                        let entries = transcriptEntries(
                            line: line,
                            sessionID: session.id,
                            byteOffset: absoluteOffset,
                            provider: session.provider
                        )
                        if !entries.isEmpty {
                            decoded.append(contentsOf: entries.map { (absoluteOffset, $0) })
                        } else if
                            !line.isEmpty,
                            !isValidHistoryEnvelope(line, provider: session.provider)
                        {
                            malformedCount += 1
                            decoded.append((
                                absoluteOffset,
                                .init(
                                    id: "\(session.id)-\(absoluteOffset)",
                                    kind: .malformed,
                                    title: "Unreadable event",
                                    text: "A malformed or partial local history event could not be decoded.",
                                    isCollapsible: true
                                )
                            ))
                        }
                    }
                    lineStart = index + 1
                }
                index += 1
            }
        }

        if let oversizedPrefixBytes, oversizedPrefixBytes > 0 {
            let markerOffset = olderOffset.map { $0 + 1 } ?? 0
            decoded.insert((
                markerOffset,
                .init(
                    id: "\(session.id)-oversized-\(markerOffset)",
                    kind: .oversized,
                    title: "Large history event",
                    text: "A \(Self.byteCount(oversizedPrefixBytes)) event is present in the local history and was not expanded in memory.",
                    isCollapsible: true
                )
            ), at: 0)
        }

        if decoded.count > transcriptPageEntries {
            let boundary = decoded[decoded.count - transcriptPageEntries].offset
            let firstBoundaryIndex = decoded.firstIndex { $0.offset == boundary }
                ?? (decoded.count - transcriptPageEntries)
            let kept = Array(decoded[firstBoundaryIndex...])
            olderOffset = kept.first?.offset
            decoded = kept
        }
        let entries = decoded.map(\.entry)
        let nextCursor = olderOffset.flatMap { offset -> LocalChatTranscriptCursor? in
            guard offset > 0 else { return nil }
            return LocalChatTranscriptCursor(
                byteOffset: offset,
                sourceSize: snapshotSize,
                sourceModifiedAt: cursor?.sourceModifiedAt ?? currentModifiedAt,
                sourceIdentifier: cursor?.sourceIdentifier ?? currentIdentifier
            )
        }
        return LocalChatTranscriptPage(
            entries: entries,
            olderCursor: nextCursor,
            sourceChanged: sourceChanged,
            malformedEventCount: malformedCount
        )
    }

    /// Reads a bounded chronological page. The cursor points to the next byte
    /// to inspect, so callers can append pages as the reader scrolls down.
    public func loadTranscriptForwardPage(
        for session: LocalChatSession,
        after cursor: LocalChatTranscriptCursor? = nil
    ) -> LocalChatTranscriptPage {
        guard !Task.isCancelled,
              let opened = openTranscriptSource(for: session)
        else {
            return .init(entries: [], olderCursor: nil, sourceChanged: cursor != nil, malformedEventCount: 0)
        }
        let values = opened.values
        let handle = opened.handle
        defer { try? handle.close() }
        let size = UInt64(max(0, values.fileSize ?? 0))
        let modifiedAt = values.contentModificationDate ?? session.sourceModifiedAt
        let identifier = values.fileResourceIdentifier.map { String(describing: $0) }
        if let cursor, cursor.sourceSize != size
            || cursor.sourceModifiedAt != modifiedAt
            || (cursor.sourceIdentifier != nil && cursor.sourceIdentifier != identifier)
        {
            return .init(entries: [], olderCursor: nil, sourceChanged: true, malformedEventCount: 0)
        }
        let start = min(cursor?.byteOffset ?? 0, size)
        guard start < size else {
            return .init(entries: [], olderCursor: nil, sourceChanged: false, malformedEventCount: 0)
        }
        let end = min(size, start + UInt64(transcriptPageBytes))
        guard let window = readRange(handle: handle, start: start, end: end) else {
            return .init(entries: [], olderCursor: nil, sourceChanged: false, malformedEventCount: 0)
        }

        var entries: [LocalChatTranscriptEntry] = []
        var malformed = 0
        var lineStart = 0
        var skipping = cursor?.skippingOversizedLine == true
        var sequence = cursor?.nextSequence ?? 0
        if skipping {
            if let newline = window.firstIndex(of: 0x0A) {
                lineStart = window.distance(from: window.startIndex, to: newline) + 1
                skipping = false
            }
        }

        var nextOffset = end
        if !skipping {
            var index = lineStart
            while index <= window.count, entries.count < transcriptPageEntries, !Task.isCancelled {
                let isWindowEnd = index == window.count
                if isWindowEnd || window[index] == 0x0A {
                    if index > lineStart {
                        let isIncomplete = isWindowEnd && end < size
                        if isIncomplete {
                            if lineStart == 0 {
                                entries.append(.init(
                                    id: "\(session.id)-oversized-\(start)",
                                    kind: .oversized,
                                    title: "Large history event",
                                    text: "A history event larger than the page budget is present and was not expanded in memory.",
                                    isCollapsible: true,
                                    sourceOrdinal: sequence
                                ))
                                sequence += 1
                                skipping = true
                            } else {
                                nextOffset = start + UInt64(lineStart)
                            }
                            break
                        }
                        let offset = start + UInt64(lineStart)
                        let line = window.subdata(in: lineStart..<index)
                        let lineEntries = transcriptEntries(
                            line: line,
                            sessionID: session.id,
                            byteOffset: offset,
                            provider: session.provider
                        )
                        if !lineEntries.isEmpty {
                            for entry in lineEntries {
                                entries.append(entry.withSourceOrdinal(sequence))
                                sequence += 1
                            }
                        } else if !isValidHistoryEnvelope(line, provider: session.provider) {
                            malformed += 1
                            entries.append(.init(
                                id: "\(session.id)-\(offset)",
                                kind: .malformed,
                                title: "Unreadable event",
                                text: "A malformed or partial local history event could not be decoded.",
                                isCollapsible: true,
                                sourceOrdinal: sequence
                            ))
                            sequence += 1
                        }
                    }
                    lineStart = index + 1
                    nextOffset = start + UInt64(lineStart)
                }
                index += 1
            }
        }
        let continuation = nextOffset < size ? LocalChatTranscriptCursor(
            byteOffset: nextOffset,
            sourceSize: size,
            sourceModifiedAt: modifiedAt,
            sourceIdentifier: identifier,
            skippingOversizedLine: skipping,
            nextSequence: sequence
        ) : nil
        return .init(
            entries: entries,
            olderCursor: continuation,
            sourceChanged: session.sourceSize != size
                || !Self.sameModificationDate(session.sourceModifiedAt, modifiedAt),
            malformedEventCount: malformed
        )
    }

    private func scanClaudeUserData(
        userDataURL: URL,
        profileID: CodexProfile.ID?,
        profileName: String
    ) -> LocalChatScanResult {
        let inventory = claudeUserDataInventory(userDataURL: userDataURL)
        guard !Task.isCancelled else {
            return .init(
                availability: .available,
                sessions: [],
                changeToken: inventory.changeToken
            )
        }
        return .init(
            availability: .available,
            sessions: inventory.records.map { record in
                LocalChatSession(
                    id: record.id,
                    provider: .claude,
                    profileID: profileID,
                    profileName: profileName,
                    title: record.title,
                    preview: record.preview,
                    model: record.model,
                    repository: record.repository,
                    branch: nil,
                    startedAt: record.startedAt,
                    updatedAt: record.updatedAt,
                    tokenCount: record.tokenCount,
                    latestUsageLimit: record.latestUsageLimit,
                    status: record.status,
                    sourceURL: record.source.url,
                    sourceRootURL: userDataURL,
                    sourceSize: record.source.fileSize,
                    sourceModifiedAt: record.source.modifiedAt
                )
            },
            changeToken: inventory.changeToken,
            diagnostics: .init(
                parsedFileCount: inventory.records.count,
                sourceFileCount: inventory.records.count
            )
        )
    }

    private func claudeUserDataInventory(userDataURL: URL) -> ClaudeUserDataInventory {
        let candidates = claudeMetadataCandidates(userDataURL: userDataURL).sorted {
            if $0.modifiedAt == $1.modifiedAt { return $0.relativePath < $1.relativePath }
            return $0.modifiedAt > $1.modifiedAt
        }
        var records: [ClaudeUserDataRecord] = []
        var tokenParts: [String] = []
        var metadataBytes = 0
        var remainingUsageBytes = maximumClaudeUsageBytes
        for candidate in candidates {
            guard !Task.isCancelled else { break }
            tokenParts.append(
                "\(candidate.relativePath)|\(candidate.fileSize)|\(candidate.modifiedAt.timeIntervalSince1970)"
            )
            let source = claudeAuditSourceFile(
                userDataURL: userDataURL,
                relativeMetadataPath: candidate.relativePath
            )
            if let source {
                tokenParts.append(
                    "\(source.relativePath)|\(source.fileSize)|\(source.modifiedAt.timeIntervalSince1970)"
                )
            }
            guard
                candidate.fileSize <= maximumSummaryLineBytes,
                metadataBytes <= maximumMetadataBytes - candidate.fileSize,
                let source
            else {
                continue
            }
            metadataBytes += candidate.fileSize
            guard
                let data = readBoundedFile(
                    at: candidate.url,
                    under: userDataURL,
                    expectedSize: candidate.fileSize,
                    maximumBytes: min(
                        maximumSummaryLineBytes,
                        maximumMetadataBytes - (metadataBytes - candidate.fileSize)
                    )
                ),
                let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else {
                continue
            }
            let rawID = (object["sessionId"] as? String)
                ?? candidate.url.deletingPathExtension().lastPathComponent
            let id = Self.stableSourceID(
                provider: .claude,
                rawID: rawID,
                relativePath: candidate.relativePath
            )
            let titleText = Self.cleanTranscriptText(object["title"] as? String ?? "")
            let prompt = Self.cleanTranscriptText(object["promptSuggestion"] as? String ?? "")
            let createdAt = Self.claudeDate(object["createdAt"]) ?? source.modifiedAt
            let updatedAt = Self.claudeDate(object["lastActivityAt"])
                ?? Self.claudeDate(object["lastFocusedAt"])
                ?? source.modifiedAt
            let cwd = (object["cwd"] as? String) ?? (object["originCwd"] as? String)
            let usage: ClaudeUsageSummary?
            if source.fileSize <= UInt64(remainingUsageBytes) {
                remainingUsageBytes -= Int(source.fileSize)
                usage = claudeUsageSummary(at: source, under: userDataURL)
            } else {
                usage = nil
            }
            records.append(.init(
                id: id,
                title: Self.title(from: titleText.isEmpty ? prompt : titleText),
                preview: Self.preview(from: prompt.isEmpty ? titleText : prompt),
                model: Self.cleanMetadata(object["model"] as? String),
                repository: Self.safeLastPathComponent(cwd),
                startedAt: createdAt,
                updatedAt: max(createdAt, updatedAt),
                tokenCount: usage?.totalTokens,
                latestUsageLimit: usage?.latestUsageLimit,
                status: Self.boolValue(object["isArchived"]) ? "Archived" : "Unknown",
                source: source
            ))
        }
        let bounded = boundedClaudeUserDataRecords(records)
        return .init(
            records: bounded,
            changeToken: tokenParts.isEmpty
                ? ""
                : String(
                    Self.fnv1a64(tokenParts.sorted().joined(separator: "\n")),
                    radix: 16
                )
        )
    }

    private func claudeUserDataChangeToken(userDataURL: URL) -> String {
        let candidates = claudeMetadataCandidates(userDataURL: userDataURL)
        var tokenParts: [String] = []
        tokenParts.reserveCapacity(min(maximumInventoryFiles * 2, 20_000))
        for candidate in candidates {
            guard !Task.isCancelled else { break }
            tokenParts.append(
                "\(candidate.relativePath)|\(candidate.fileSize)|\(candidate.modifiedAt.timeIntervalSince1970)"
            )
            if let source = claudeAuditSourceFile(
                userDataURL: userDataURL,
                relativeMetadataPath: candidate.relativePath
            ) {
                tokenParts.append(
                    "\(source.relativePath)|\(source.fileSize)|\(source.modifiedAt.timeIntervalSince1970)"
                )
            }
        }
        guard !tokenParts.isEmpty else { return "" }
        return String(Self.fnv1a64(tokenParts.sorted().joined(separator: "\n")), radix: 16)
    }

    private func claudeMetadataCandidates(userDataURL: URL) -> [ClaudeMetadataCandidate] {
        let metadataRoot = userDataURL
            .appendingPathComponent("claude-code-sessions", isDirectory: true)
            .resolvingSymlinksInPath()
            .standardizedFileURL
        guard let enumerator = fileManager.enumerator(
            at: metadataRoot,
            includingPropertiesForKeys: [
                .isRegularFileKey, .isSymbolicLinkKey,
                .fileSizeKey, .contentModificationDateKey
            ],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return []
        }
        var candidates: [ClaudeMetadataCandidate] = []
        var inspectedEntries = 0
        for case let url as URL in enumerator {
            guard !Task.isCancelled, inspectedEntries < maximumInventoryFiles else { break }
            inspectedEntries += 1
            guard
                url.pathExtension == "json",
                url.deletingPathExtension().lastPathComponent.hasPrefix("local_")
            else {
                continue
            }
            guard
                let safe = canonicalRegularFile(url: url, under: metadataRoot),
                safe.fileSize >= 0
            else {
                continue
            }
            candidates.append(.init(
                url: safe.url,
                relativePath: safe.relativePath,
                fileSize: safe.fileSize,
                modifiedAt: safe.modifiedAt
            ))
        }
        return candidates
    }

    private func claudeAuditSourceFile(
        userDataURL: URL,
        relativeMetadataPath: String
    ) -> SourceFile? {
        let sessionDirectory = (relativeMetadataPath as NSString).deletingPathExtension
        guard
            !sessionDirectory.hasPrefix("/"),
            !sessionDirectory.split(separator: "/").contains("..")
        else {
            return nil
        }
        let auditRoot = userDataURL
            .appendingPathComponent("local-agent-mode-sessions", isDirectory: true)
            .resolvingSymlinksInPath()
            .standardizedFileURL
        let candidate = auditRoot
            .appendingPathComponent(sessionDirectory, isDirectory: true)
            .appendingPathComponent("audit.jsonl")
            .standardizedFileURL
        guard
            let safe = canonicalRegularFile(url: candidate, under: auditRoot),
            let relativePath = relativePath(for: safe.url, under: userDataURL)
        else {
            return nil
        }
        return .init(
            url: safe.url,
            relativePath: relativePath,
            fileSize: UInt64(safe.fileSize),
            modifiedAt: safe.modifiedAt,
            status: "Unknown"
        )
    }

    private func claudeUsageSummary(
        at source: SourceFile,
        under root: URL
    ) -> ClaudeUsageSummary? {
        if let cached = claudeUsageCache.value(
            for: source.url.path,
            size: source.fileSize,
            modifiedAt: source.modifiedAt
        ) {
            return cached
        }

        var totalTokens = 0
        var seenMessageRequests: Set<String> = []
        var latestUsageLimit: UsageLimitSignal?
        let usageMarker = Data(#""usage""#.utf8)
        let rateLimitMarker = Data(#""rate_limit_event""#.utf8)
        let readResult = forEachForwardLine(
            at: source.url,
            under: root,
            maximumBytes: Int(clamping: source.fileSize)
        ) { line in
            guard line.range(of: usageMarker) != nil
                || line.range(of: rateLimitMarker) != nil
            else {
                return true
            }
            guard
                let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                let type = object["type"] as? String
            else {
                return true
            }

            if type == "assistant",
               let message = object["message"] as? [String: Any],
               let usage = message["usage"] as? [String: Any]
            {
                let messageID = message["id"] as? String
                let requestID = object["requestId"] as? String
                let dedupeKey = (messageID == nil && requestID == nil)
                    ? nil
                    : "\(messageID ?? ""):\(requestID ?? "")"
                if dedupeKey.map({ seenMessageRequests.insert($0).inserted }) ?? true {
                    for key in [
                        "input_tokens", "cache_read_input_tokens",
                        "cache_creation_input_tokens", "output_tokens"
                    ] {
                        totalTokens = Self.saturatingAdd(
                            totalTokens,
                            Self.nonnegativeInt(usage[key])
                        )
                    }
                }
            }

            if type == "rate_limit_event",
               let info = object["rate_limit_info"] as? [String: Any],
               let rawStatus = info["status"] as? String,
               let status = UsageLimitSignal.Status(rawValue: rawStatus)
            {
                let observedAt = Self.date(object["_audit_timestamp"])
                    ?? Self.date(object["timestamp"])
                    ?? source.modifiedAt
                let rawUtilization = (info["utilization"] as? NSNumber)?.doubleValue
                let usedPercent = rawUtilization.flatMap { value -> Double? in
                    guard value.isFinite, value >= 0 else { return nil }
                    let percent = value <= 1 ? value * 100 : value
                    return percent <= 100 ? percent : nil
                }
                let signal = UsageLimitSignal(
                    status: status,
                    bucket: Self.cleanMetadata(info["rateLimitType"] as? String),
                    usedPercent: usedPercent,
                    resetsAt: Self.claudeDate(info["resetsAt"]),
                    observedAt: observedAt,
                    isUsingOverage: info["isUsingOverage"].map(Self.boolValue)
                )
                if latestUsageLimit == nil
                    || observedAt >= (latestUsageLimit?.observedAt ?? .distantPast)
                {
                    latestUsageLimit = signal
                }
            }
            return true
        }
        guard readResult.completed, !Task.isCancelled else { return nil }
        let summary = ClaudeUsageSummary(
            totalTokens: totalTokens,
            latestUsageLimit: latestUsageLimit
        )
        claudeUsageCache.store(
            summary,
            for: source.url.path,
            size: source.fileSize,
            modifiedAt: source.modifiedAt
        )
        return summary
    }

    private func boundedClaudeUserDataRecords(
        _ records: [ClaudeUserDataRecord]
    ) -> [ClaudeUserDataRecord] {
        let sorted = records.sorted {
            if $0.updatedAt == $1.updatedAt { return $0.id > $1.id }
            return $0.updatedAt > $1.updatedAt
        }
        var seen: Set<String> = []
        return sorted.filter { seen.insert($0.id).inserted }
            .prefix(maximumSessions)
            .map { $0 }
    }

    private func scanClaudeCode(claudeHomeURL: URL) -> LocalChatScanResult {
        let inventory = claudeInventory(claudeHomeURL: claudeHomeURL)
        guard !Task.isCancelled else {
            return .init(
                availability: .available,
                sessions: [],
                changeToken: inventory.changeToken
            )
        }
        var remainingMetadataBytes = max(
            0,
            maximumMetadataBytes - inventory.metadataBytes
        )
        let sessions = inventory.records.compactMap { record -> LocalChatSession? in
            guard
                let source = claudeSourceFile(
                    claudeHomeURL: claudeHomeURL,
                    project: record.project,
                    sessionID: record.sourceSessionID
                )
            else {
                return nil
            }
            let metadata = claudeBodyMetadata(
                at: source.url,
                under: claudeHomeURL,
                maximumBytes: min(256 * 1_024, remainingMetadataBytes)
            )
            remainingMetadataBytes -= metadata.inspectedBytes
            return LocalChatSession(
                id: record.id,
                provider: .claude,
                profileID: nil,
                profileName: "Official Claude",
                title: Self.title(from: record.display),
                preview: Self.preview(from: record.display),
                model: metadata.model,
                repository: Self.safeLastPathComponent(metadata.cwd ?? record.project),
                branch: metadata.branch,
                startedAt: record.startedAt ?? source.modifiedAt,
                updatedAt: record.updatedAt ?? source.modifiedAt,
                tokenCount: nil,
                status: "Unknown",
                sourceURL: source.url,
                sourceRootURL: claudeHomeURL,
                sourceSize: source.fileSize,
                sourceModifiedAt: source.modifiedAt
            )
        }
        return .init(
            availability: .available,
            sessions: sessions,
            changeToken: inventory.changeToken,
            diagnostics: .init(
                parsedFileCount: sessions.count,
                sourceFileCount: sessions.count
            )
        )
    }

    private func claudeInventory(claudeHomeURL: URL) -> ClaudeInventory {
        let home = claudeHomeURL.resolvingSymlinksInPath().standardizedFileURL
        let historyURL = home.appendingPathComponent("history.jsonl")
        guard
            let history = canonicalRegularFile(url: historyURL, under: home),
            history.fileSize <= maximumMetadataBytes
        else {
            return .init(records: [], changeToken: "")
        }

        var recordsByID: [String: ClaudeHistoryRecord] = [:]
        var inspectedRecords = 0
        _ = forEachForwardLine(
            at: history.url,
            under: home,
            maximumBytes: maximumMetadataBytes
        ) { line in
            guard !Task.isCancelled else { return false }
            guard inspectedRecords < maximumInventoryFiles else { return false }
            inspectedRecords += 1
            guard
                line.count <= maximumSummaryLineBytes,
                let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                let rawSessionID = object["sessionId"] as? String,
                Self.safeFilename(rawSessionID),
                let project = object["project"] as? String,
                !project.isEmpty
            else {
                return true
            }
            let relativeSource = "projects/\(project.replacingOccurrences(of: "/", with: "-"))/\(rawSessionID).jsonl"
            let sessionID = Self.stableSourceID(
                provider: .claude,
                rawID: rawSessionID,
                relativePath: relativeSource
            )
            let timestamp = Self.claudeDate(object["timestamp"])
            let display = Self.cleanTranscriptText(object["display"] as? String ?? "")
            if var existing = recordsByID[sessionID] {
                if let timestamp {
                    existing.startedAt = existing.startedAt.map { min($0, timestamp) } ?? timestamp
                    existing.updatedAt = existing.updatedAt.map { max($0, timestamp) } ?? timestamp
                }
                if !display.isEmpty {
                    existing.display = display
                }
                existing.project = project
                recordsByID[sessionID] = existing
            } else {
                recordsByID[sessionID] = .init(
                    id: sessionID,
                    sourceSessionID: rawSessionID,
                    project: project,
                    display: display,
                    startedAt: timestamp,
                    updatedAt: timestamp
                )
            }
            return true
        }

        let records = recordsByID.values.sorted {
            if $0.updatedAt == $1.updatedAt { return $0.id > $1.id }
            return ($0.updatedAt ?? .distantPast) > ($1.updatedAt ?? .distantPast)
        }.prefix(maximumSessions)
        return .init(
            records: Array(records),
            changeToken: claudeCodeChangeToken(claudeHomeURL: claudeHomeURL),
            metadataBytes: min(history.fileSize, maximumMetadataBytes)
        )
    }

    private func claudeCodeChangeToken(claudeHomeURL: URL) -> String {
        let home = claudeHomeURL.resolvingSymlinksInPath().standardizedFileURL
        guard
            let history = canonicalRegularFile(
                url: home.appendingPathComponent("history.jsonl"),
                under: home
            )
        else {
            return ""
        }
        return String(
            Self.fnv1a64(
                "history.jsonl|\(history.fileSize)|\(history.modifiedAt.timeIntervalSince1970)"
            ),
            radix: 16
        )
    }

    private func claudeSourceFile(
        claudeHomeURL: URL,
        project: String,
        sessionID: String
    ) -> SourceFile? {
        guard
            Self.safeFilename(sessionID),
            !project.isEmpty
        else {
            return nil
        }
        let projectsRoot = claudeHomeURL
            .appendingPathComponent("projects", isDirectory: true)
            .resolvingSymlinksInPath()
            .standardizedFileURL
        let projectDirectoryName = project.replacingOccurrences(of: "/", with: "-")
        let candidate = projectsRoot
            .appendingPathComponent(projectDirectoryName, isDirectory: true)
            .appendingPathComponent("\(sessionID).jsonl")
            .standardizedFileURL
        guard
            let safe = canonicalRegularFile(url: candidate, under: projectsRoot),
            let relativePath = relativePath(for: safe.url, under: claudeHomeURL)
        else {
            return nil
        }
        return .init(
            url: safe.url,
            relativePath: relativePath,
            fileSize: UInt64(safe.fileSize),
            modifiedAt: safe.modifiedAt,
            status: "Unknown"
        )
    }

    private func claudeBodyMetadata(
        at url: URL,
        under root: URL,
        maximumBytes: Int
    ) -> ClaudeBodyMetadata {
        guard maximumBytes > 0 else { return .init() }
        var metadata = ClaudeBodyMetadata()
        var inspectedBytes = 0
        _ = forEachForwardLine(
            at: url,
            under: root,
            maximumBytes: maximumBytes
        ) { line in
            inspectedBytes += line.count
            guard
                let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any]
            else {
                return inspectedBytes < 256 * 1_024
            }
            metadata.cwd = Self.cleanMetadata(object["cwd"] as? String) ?? metadata.cwd
            metadata.branch = Self.cleanMetadata(object["gitBranch"] as? String) ?? metadata.branch
            if
                let message = object["message"] as? [String: Any],
                let model = message["model"] as? String
            {
                metadata.model = Self.cleanMetadata(model)
            }
            return inspectedBytes < 256 * 1_024
                && (metadata.branch == nil || metadata.model == nil)
        }
        metadata.inspectedBytes = min(inspectedBytes, maximumBytes)
        return metadata
    }

    private func scanCodex(
        codexHomeURL: URL,
        profileID: CodexProfile.ID?,
        profileName: String
    ) -> LocalChatScanResult {
        let canonicalHomeURL = codexHomeURL.resolvingSymlinksInPath().standardizedFileURL
        let scopeKey = profileID.map { "managed-\($0.uuidString.lowercased())" }
            ?? "official-\(String(Self.fnv1a64(codexHomeURL.standardizedFileURL.path), radix: 16))"
        let sourceRootKey = String(
            Self.fnv1a64(canonicalHomeURL.path),
            radix: 16
        )
        let cached = loadIndex(scopeKey: scopeKey, sourceRootKey: sourceRootKey)
        let cachedByPath = Dictionary(uniqueKeysWithValues: cached.records.map {
            ($0.relativePath, $0)
        })
        let databaseRows = indexedRows(codexHomeURL: codexHomeURL)
        let inventory = sourceInventory(canonicalHomeURL: canonicalHomeURL)
        guard inventory.rootsExist else {
            return LocalChatScanResult(
                availability: .available,
                sessions: [],
                changeToken: inventory.changeToken
            )
        }
        guard !Task.isCancelled else {
            return LocalChatScanResult(
                availability: .available,
                sessions: [],
                changeToken: inventory.changeToken
            )
        }
        let databaseByPath = Dictionary(
            databaseRows.map { ($0.relativePath, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        var cacheHits = 0
        var parsedFiles = 0
        var remainingSummaryBytes = maximumMetadataBytes
        var records: [ChatIndexRecord] = []
        let sources = boundedSources(inventory.files)
        let sourcesByPath = Dictionary(uniqueKeysWithValues: sources.map {
            ($0.relativePath, $0)
        })

        for source in sources {
            guard !Task.isCancelled else {
                return LocalChatScanResult(
                    availability: .available,
                    sessions: [],
                    changeToken: inventory.changeToken
                )
            }
            if let row = databaseByPath[source.relativePath] {
                records.append(row.merging(source: source))
                cacheHits += cachedByPath[source.relativePath] == nil ? 0 : 1
            } else if
                let existing = cachedByPath[source.relativePath],
                existing.summaryComplete != false,
                existing.fileSize == source.fileSize,
                Self.sameModificationDate(existing.modifiedAt, source.modifiedAt),
                existing.status == source.status
            {
                records.append(existing)
                cacheHits += 1
            } else {
                let summary = summaryRecord(source: source, maximumBytes: remainingSummaryBytes)
                records.append(summary.record)
                remainingSummaryBytes -= summary.bytesRead
                if summary.bytesRead > 0 { parsedFiles += 1 }
            }
        }

        var seenIDs: Set<String> = []
        records = records.filter { seenIDs.insert($0.id).inserted }
        records = boundedRecords(records)
        let document = ChatIndexDocument(
            version: Self.indexVersion,
            scopeKey: scopeKey,
            sourceRootKey: sourceRootKey,
            records: records
        )
        if document != cached {
            saveIndex(document, scopeKey: scopeKey)
        }

        let sessions = records.compactMap { record -> LocalChatSession? in
            guard let source = sourcesByPath[record.relativePath] else { return nil }
            return session(
                record: record,
                source: source,
                codexHomeURL: canonicalHomeURL,
                profileID: profileID,
                profileName: profileName
            )
        }
        return LocalChatScanResult(
            availability: .available,
            sessions: sessions,
            changeToken: inventory.changeToken,
            diagnostics: .init(
                cacheHitCount: cacheHits,
                parsedFileCount: parsedFiles,
                sourceFileCount: inventory.files.count,
                usedDatabase: !databaseRows.isEmpty,
                inventoryTruncated: inventory.truncated
            )
        )
    }

    private func sourceInventory(canonicalHomeURL: URL) -> SourceInventory {
        let roots = [
            (canonicalHomeURL.appendingPathComponent("sessions", isDirectory: true), "Unknown"),
            (canonicalHomeURL.appendingPathComponent("archived_sessions", isDirectory: true), "Archived")
        ]
        let homePrefix = canonicalHomeURL.path + "/"
        let keys: Set<URLResourceKey> = [
            .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey
        ]
        var files: [SourceFile] = []
        var tokenParts: [String] = []
        var rootsExist = false
        var inspectedEntries = 0
        var truncated = false

        inventory: for (root, status) in roots where fileManager.fileExists(atPath: root.path) {
            rootsExist = true
            let canonicalRoot = root.resolvingSymlinksInPath().standardizedFileURL
            guard canonicalRoot.path == root.path else { continue }
            let rootPrefix = canonicalRoot.path + "/"
            guard let enumerator = fileManager.enumerator(
                at: canonicalRoot,
                includingPropertiesForKeys: Array(keys),
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else {
                continue
            }
            for case let url as URL in enumerator {
                guard !Task.isCancelled else { break inventory }
                guard inspectedEntries < maximumInventoryFiles else {
                    truncated = true
                    break inventory
                }
                inspectedEntries += 1
                guard url.pathExtension == "jsonl" else { continue }
                guard
                    let values = try? url.resourceValues(forKeys: keys),
                    values.isRegularFile == true,
                    values.isSymbolicLink != true,
                    let fileSize = values.fileSize,
                    fileSize >= 0
                else {
                    continue
                }
                let standardized = url.standardizedFileURL
                let canonicalURL = standardized.resolvingSymlinksInPath().standardizedFileURL
                guard
                    canonicalURL.path == standardized.path,
                    canonicalURL.path.hasPrefix(rootPrefix),
                    canonicalURL.path.hasPrefix(homePrefix)
                else {
                    continue
                }
                let relativePath = String(canonicalURL.path.dropFirst(homePrefix.count))
                let size = UInt64(fileSize)
                let modifiedAt = values.contentModificationDate ?? .distantPast
                files.append(.init(
                    url: canonicalURL,
                    relativePath: relativePath,
                    fileSize: size,
                    modifiedAt: modifiedAt,
                    status: status
                ))
                tokenParts.append("\(relativePath)|\(size)|\(modifiedAt.timeIntervalSince1970)")
            }
        }
        for name in ["state_5.sqlite", "state_5.sqlite-wal", "state_5.sqlite-shm"] {
            let url = canonicalHomeURL.appendingPathComponent(name)
            if let values = try? url.resourceValues(
                forKeys: [.fileSizeKey, .contentModificationDateKey]
            ) {
                tokenParts.append(
                    "\(name)|\(values.fileSize ?? 0)|\(values.contentModificationDate?.timeIntervalSince1970 ?? 0)"
                )
            }
        }
        files.sort { $0.relativePath < $1.relativePath }
        tokenParts.sort()
        return SourceInventory(
            rootsExist: rootsExist,
            files: files,
            changeToken: String(Self.fnv1a64(tokenParts.joined(separator: "\n")), radix: 16),
            truncated: truncated
        )
    }

    private func sourceChangeToken(codexHomeURL: URL) -> String {
        let database = codexHomeURL.appendingPathComponent("state_5.sqlite")
        guard fileManager.fileExists(atPath: database.path) else {
            return sourceInventory(
                canonicalHomeURL: codexHomeURL.resolvingSymlinksInPath().standardizedFileURL
            ).changeToken
        }
        var parts: [String] = []
        for name in [
            "state_5.sqlite", "state_5.sqlite-wal",
            "sessions", "archived_sessions"
        ] {
            let url = codexHomeURL.appendingPathComponent(name)
            if let values = try? url.resourceValues(
                forKeys: [.fileSizeKey, .contentModificationDateKey]
            ) {
                parts.append(
                    "\(name)|\(values.fileSize ?? 0)|\(values.contentModificationDate?.timeIntervalSince1970 ?? 0)"
                )
            }
        }
        return String(Self.fnv1a64(parts.sorted().joined(separator: "\n")), radix: 16)
    }

    private func summaryRecord(
        source: SourceFile,
        maximumBytes: Int
    ) -> (record: ChatIndexRecord, bytesRead: Int) {
        var sessionID: String?
        var firstUserMessage: String?
        var startedAt: Date?
        var updatedAt = source.modifiedAt
        var repository: String?
        var branch: String?
        var model: String?
        var tokenCount: Int?
        var status = source.status
        let sourceBudget = min(maximumSummaryLineBytes, maximumMetadataBytes)

        let readResult = forEachForwardLine(
            at: source.url,
            maximumBytes: min(sourceBudget, maximumBytes)
        ) { line in
            guard
                let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                let type = object["type"] as? String,
                let payload = object["payload"] as? [String: Any]
            else {
                return true
            }
            let eventDate = Self.eventDate(object: object, payload: payload)
            if let eventDate {
                startedAt = startedAt.map { min($0, eventDate) } ?? eventDate
                updatedAt = max(updatedAt, eventDate)
            }
            switch type {
            case "session_meta":
                sessionID = (payload["id"] as? String)
                    ?? (payload["session_id"] as? String)
                    ?? sessionID
                if let cwd = payload["cwd"] as? String {
                    repository = Self.safeLastPathComponent(cwd)
                }
                if let git = payload["git"] as? [String: Any] {
                    branch = Self.cleanMetadata(git["branch"] as? String)
                }
            case "turn_context":
                model = Self.cleanMetadata(payload["model"] as? String) ?? model
                if repository == nil, let cwd = payload["cwd"] as? String {
                    repository = Self.safeLastPathComponent(cwd)
                }
            case "response_item":
                if
                    payload["type"] as? String == "message",
                    payload["role"] as? String == LocalChatRole.user.rawValue,
                    let text = Self.messageText(payload)
                {
                    let visible = Self.visibleMessageText(text, role: .user)
                    if !visible.isEmpty { firstUserMessage = visible }
                }
            case "event_msg":
                switch payload["type"] as? String {
                case "token_count":
                    if
                        let info = payload["info"] as? [String: Any],
                        let usage = info["total_token_usage"] as? [String: Any]
                    {
                        tokenCount = usage["total_tokens"] as? Int ?? tokenCount
                    }
                case "task_complete": status = "Completed"
                case "task_started": status = "In progress"
                case "task_failed": status = "Failed"
                default: break
                }
            default:
                break
            }
            return firstUserMessage == nil
        }

        let safeID = Self.cleanIdentifier(sessionID)
            ?? "local-\(String(Self.fnv1a64(source.relativePath), radix: 16))"
        let title = Self.title(from: firstUserMessage)
        let record = ChatIndexRecord(
            relativePath: source.relativePath,
            fileSize: source.fileSize,
            modifiedAt: source.modifiedAt,
            id: safeID,
            title: title,
            preview: Self.preview(from: firstUserMessage),
            model: model,
            repository: repository,
            branch: branch,
            startedAt: startedAt ?? source.modifiedAt,
            updatedAt: updatedAt,
            tokenCount: tokenCount,
            status: status,
            summaryComplete: firstUserMessage != nil
                || maximumBytes >= min(sourceBudget, Int(clamping: source.fileSize))
        )
        return (record, readResult.bytesRead)
    }

    private func indexedRows(codexHomeURL: URL) -> [ChatIndexRecord] {
        let database = codexHomeURL.appendingPathComponent("state_5.sqlite")
        guard fileManager.isReadableFile(atPath: database.path) else { return [] }
        guard let columns = threadColumns(database: database), columns.contains("rollout_path") else {
            return []
        }
        func expression(_ column: String, fallback: String) -> String {
            columns.contains(column) ? column : fallback
        }
        let orderColumn = [
            "recency_at_ms", "updated_at_ms", "updated_at", "created_at_ms", "created_at"
        ].first(where: columns.contains) ?? "rowid"
        let createdExpression = expression(
            columns.contains("created_at_ms") ? "created_at_ms" : "created_at",
            fallback: "0"
        )
        let updatedExpression = expression(
            columns.contains("updated_at_ms") ? "updated_at_ms" : "updated_at",
            fallback: createdExpression
        )
        let titleCandidates = ["title", "name", "first_user_message", "preview"]
            .filter(columns.contains)
            .map { "NULLIF(\($0), '')" }
        let titleExpression = titleCandidates.isEmpty
            ? "''"
            : "COALESCE(\(titleCandidates.joined(separator: ", ")), '')"
        let statusPartition = columns.contains("archived")
            ? "CASE WHEN archived IS NOT NULL AND archived != 0 THEN 1 ELSE 0 END"
            : "0"
        let query = """
        PRAGMA query_only=ON;
        WITH ranked AS (
        SELECT
          \(expression("id", fallback: "''")) AS id,
          \(expression("rollout_path", fallback: "''")) AS rollout_path,
          \(createdExpression) AS created_at,
          \(updatedExpression) AS updated_at,
          \(expression("cwd", fallback: "''")) AS cwd,
          \(titleExpression) AS title,
          \(expression("tokens_used", fallback: "NULL")) AS tokens_used,
          \(expression("archived", fallback: "0")) AS archived,
          \(expression("git_branch", fallback: "NULL")) AS git_branch,
          \(expression("model", fallback: "NULL")) AS model,
          ROW_NUMBER() OVER (
            PARTITION BY \(statusPartition)
            ORDER BY \(orderColumn) DESC
          ) AS status_rank
        FROM threads
        )
        SELECT id, rollout_path, created_at, updated_at, cwd, title,
               tokens_used, archived, git_branch, model
        FROM ranked
        WHERE status_rank <= \(maximumSessions)
        ORDER BY updated_at DESC
        LIMIT \(maximumSessions + max(1, maximumSessions / 4));
        """
        guard
            let databaseArgument = try? SQLiteReadOnly.databaseArgument(for: database),
            let result = try? BoundedSubprocess.run(
                executableURL: Self.sqliteURL,
                arguments: [
                    "-nofollow", "-readonly", "-json",
                    databaseArgument,
                    query
                ],
                timeout: 3,
                maximumOutputBytes: 8 * 1_024 * 1_024,
                captureStandardError: true
            ),
            result.terminationStatus == 0,
            !result.exceededOutputLimit,
            !Task.isCancelled,
            let values = try? JSONSerialization.jsonObject(with: result.output) as? [[String: Any]]
        else {
            return []
        }
        return values.compactMap { row in
            guard
                let rawPath = row["rollout_path"] as? String,
                let sourceURL = safeSessionURL(path: rawPath, codexHomeURL: codexHomeURL),
                let relativePath = relativePath(for: sourceURL, under: codexHomeURL),
                let source = sourceFile(
                    url: sourceURL,
                    relativePath: relativePath,
                    status: relativePath.hasPrefix("archived_sessions/")
                        || Self.boolValue(row["archived"]) ? "Archived" : "Unknown"
                )
            else {
                return nil
            }
            let rawTitle = row["title"] as? String
            let visibleTitle = Self.visibleMessageText(rawTitle ?? "", role: .user)
            let createdAt = Self.date(fromSQLite: row["created_at"]) ?? source.modifiedAt
            let updatedAt = Self.date(fromSQLite: row["updated_at"]) ?? source.modifiedAt
            return ChatIndexRecord(
                relativePath: relativePath,
                fileSize: source.fileSize,
                modifiedAt: source.modifiedAt,
                id: Self.cleanIdentifier(row["id"] as? String)
                    ?? "local-\(String(Self.fnv1a64(relativePath), radix: 16))",
                title: Self.title(from: visibleTitle),
                preview: Self.preview(from: visibleTitle),
                model: Self.cleanMetadata(row["model"] as? String),
                repository: Self.safeLastPathComponent(row["cwd"] as? String),
                branch: Self.cleanMetadata(row["git_branch"] as? String),
                startedAt: createdAt,
                updatedAt: updatedAt,
                tokenCount: Self.intValue(row["tokens_used"]),
                status: source.status,
                summaryComplete: true
            )
        }
    }

    private func threadColumns(database: URL) -> Set<String>? {
        guard
            let databaseArgument = try? SQLiteReadOnly.databaseArgument(for: database),
            let result = try? BoundedSubprocess.run(
                executableURL: Self.sqliteURL,
                arguments: [
                    "-nofollow", "-readonly", "-json",
                    databaseArgument,
                    "PRAGMA table_info(threads);"
                ],
                timeout: 2,
                maximumOutputBytes: 256 * 1_024,
                captureStandardError: true
            ),
            result.terminationStatus == 0,
            let rows = try? JSONSerialization.jsonObject(with: result.output) as? [[String: Any]]
        else {
            return nil
        }
        return Set(rows.compactMap { $0["name"] as? String })
    }

    private func transcriptEntries(
        line: Data,
        sessionID: String,
        byteOffset: UInt64,
        provider: DesktopProduct
    ) -> [LocalChatTranscriptEntry] {
        if line.count > maximumRenderableEntryBytes {
            return [.init(
                id: "\(sessionID)-oversized-\(byteOffset)",
                kind: .oversized,
                title: "Large history event",
                text: "A \(Self.byteCount(UInt64(line.count))) event is present and was not expanded in memory.",
                isCollapsible: true
            )]
        }
        switch provider {
        case .codex:
            return codexTranscriptEntry(
                line: line,
                sessionID: sessionID,
                byteOffset: byteOffset
            ).map { [$0] } ?? []
        case .claude:
            return claudeTranscriptEntries(
                line: line,
                sessionID: sessionID,
                byteOffset: byteOffset
            )
        }
    }

    private func codexTranscriptEntry(
        line: Data,
        sessionID: String,
        byteOffset: UInt64
    ) -> LocalChatTranscriptEntry? {
        guard
            let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
            let type = object["type"] as? String,
            let payload = object["payload"] as? [String: Any]
        else {
            return nil
        }
        let id = "\(sessionID)-\(byteOffset)"
        let timestamp = Self.eventDate(object: object, payload: payload)
        switch type {
        case "response_item":
            let itemType = payload["type"] as? String
            if
                itemType == "message",
                let rawRole = payload["role"] as? String,
                let role = LocalChatRole(rawValue: rawRole),
                let rawText = Self.messageText(payload)
            {
                let text = Self.visibleMessageText(rawText, role: role)
                guard !text.isEmpty else { return nil }
                return .init(
                    id: id,
                    kind: .message,
                    role: role,
                    text: text,
                    timestamp: timestamp
                )
            }
            if itemType == "reasoning" {
                let text = Self.payloadText(payload)
                guard !text.isEmpty else { return nil }
                return .init(
                    id: id,
                    kind: .reasoning,
                    title: "Reasoning",
                    text: text,
                    timestamp: timestamp,
                    isCollapsible: true
                )
            }
            if itemType == "function_call" || itemType == "custom_tool_call" {
                let name = Self.cleanMetadata(payload["name"] as? String) ?? "Tool"
                let arguments = Self.privateToolNames.contains(name.lowercased())
                    ? "Private agent coordination payload omitted."
                    : Self.cleanToolText(
                        (payload["arguments"] as? String)
                            ?? (payload["input"] as? String)
                            ?? ""
                    )
                return .init(
                    id: id,
                    kind: Self.commandLike(name) ? .command : .activity,
                    title: name,
                    text: arguments.isEmpty ? "Started" : arguments,
                    timestamp: timestamp,
                    isCollapsible: true
                )
            }
            if itemType == "function_call_output" || itemType == "custom_tool_call_output" {
                let output = Self.cleanToolText(
                    (payload["output"] as? String) ?? Self.payloadText(payload)
                )
                let isError = (payload["success"] as? Bool) == false
                    || output.localizedCaseInsensitiveContains("error")
                return .init(
                    id: id,
                    kind: isError ? .error : .activity,
                    title: isError ? "Tool error" : "Tool result",
                    text: output.isEmpty ? "Completed" : output,
                    timestamp: timestamp,
                    isCollapsible: true
                )
            }
            guard itemType != "message" else { return nil }
            return Self.unsupportedCodexEntry(
                id: id,
                type: itemType ?? "response item",
                timestamp: timestamp
            )
        case "event_msg":
            let eventType = payload["type"] as? String ?? "Activity"
            switch eventType {
            case "agent_reasoning", "reasoning":
                return .init(
                    id: id,
                    kind: .reasoning,
                    title: "Reasoning",
                    text: Self.payloadText(payload),
                    timestamp: timestamp,
                    isCollapsible: true
                )
            case "task_started":
                return .init(id: id, kind: .status, title: "Started", text: "", timestamp: timestamp)
            case "task_complete":
                return .init(id: id, kind: .status, title: "Completed", text: "", timestamp: timestamp)
            case "task_failed", "error":
                return .init(
                    id: id,
                    kind: .error,
                    title: "Error",
                    text: Self.payloadText(payload),
                    timestamp: timestamp,
                    isCollapsible: true
                )
            case "token_count":
                return nil
            default:
                let text = Self.payloadText(payload)
                guard !text.isEmpty else { return nil }
                return .init(
                    id: id,
                    kind: .activity,
                    title: Self.humanized(eventType),
                    text: text,
                    timestamp: timestamp,
                    isCollapsible: true
                )
            }
        case "session_meta", "turn_context", "world_state":
            return nil
        default:
            return Self.unsupportedCodexEntry(id: id, type: type, timestamp: timestamp)
        }
    }

    private static func unsupportedCodexEntry(
        id: String,
        type: String,
        timestamp: Date?
    ) -> LocalChatTranscriptEntry {
        .init(
            id: id,
            kind: .unsupported,
            title: "Unsupported event",
            text: "A \(humanized(type)) history event is not supported by this AgentDock version.",
            timestamp: timestamp,
            isCollapsible: true
        )
    }

    private func claudeTranscriptEntries(
        line: Data,
        sessionID: String,
        byteOffset: UInt64
    ) -> [LocalChatTranscriptEntry] {
        guard
            let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
            let type = object["type"] as? String
        else {
            return []
        }
        let rawEventID = object["uuid"] as? String
        let eventComponent = Self.unchangedValidIdentifier(rawEventID)
            ?? "derived-\(String(Self.fnv1a64(rawEventID ?? ""), radix: 16))"
        let eventID = "\(sessionID)-\(byteOffset)-\(eventComponent)"
        let timestamp = Self.date(object["_audit_timestamp"])
            ?? Self.date(object["timestamp"])
        let message = object["message"] as? [String: Any]

        switch type {
        case "user", "assistant":
            let role: LocalChatRole = type == "user" ? .user : .assistant
            var entries: [LocalChatTranscriptEntry] = []
            if
                type == "assistant",
                Self.boolValue(object["isApiErrorMessage"])
                    || (object["error"] != nil && !(object["error"] is NSNull))
            {
                entries.append(.init(
                    id: "\(eventID)-error",
                    kind: .error,
                    title: "Error",
                    text: Self.claudeErrorText(object["error"]),
                    timestamp: timestamp,
                    isCollapsible: true
                ))
            }
            guard let content = message?["content"] else {
                return entries.isEmpty
                    ? [Self.unsupportedClaudeEntry(
                        id: eventID,
                        type: type,
                        timestamp: timestamp
                    )]
                    : entries
            }
            if let text = content as? String {
                let cleaned = Self.visibleMessageText(text, role: role)
                if !cleaned.isEmpty {
                    entries.append(.init(
                        id: eventID,
                        kind: .message,
                        role: role,
                        text: cleaned,
                        timestamp: timestamp
                    ))
                }
                return entries
            }
            guard let blocks = content as? [[String: Any]] else {
                entries.append(Self.unsupportedClaudeEntry(
                    id: eventID,
                    type: "\(type) content",
                    timestamp: timestamp
                ))
                return entries
            }
            for (index, block) in blocks.prefix(transcriptPageEntries).enumerated() {
                let id = "\(eventID)-\(index)"
                let blockType = block["type"] as? String ?? "unknown"
                switch blockType {
                case "text":
                    let text = Self.visibleMessageText(block["text"] as? String ?? "", role: role)
                    if !text.isEmpty {
                        entries.append(.init(
                            id: id,
                            kind: .message,
                            role: role,
                            text: text,
                            timestamp: timestamp
                        ))
                    }
                case "thinking":
                    let text = Self.cleanTranscriptText(
                        (block["thinking"] as? String) ?? (block["text"] as? String) ?? ""
                    )
                    entries.append(.init(
                        id: id,
                        kind: .reasoning,
                        title: "Reasoning",
                        text: text.isEmpty ? "Reasoning content unavailable." : text,
                        timestamp: timestamp,
                        isCollapsible: true
                    ))
                case "tool_use":
                    let name = Self.cleanMetadata(block["name"] as? String) ?? "Tool"
                    let input = Self.privateToolNames.contains(name.lowercased())
                        ? "Private agent coordination payload omitted."
                        : Self.cleanToolText(Self.jsonText(block["input"]))
                    entries.append(.init(
                        id: id,
                        kind: Self.commandLike(name) ? .command : .activity,
                        title: name,
                        text: input.isEmpty ? "Started" : input,
                        timestamp: timestamp,
                        isCollapsible: true
                    ))
                case "tool_result":
                    let text = Self.cleanToolText(Self.claudeContentText(block["content"]))
                    let isError = Self.boolValue(block["is_error"])
                    entries.append(.init(
                        id: id,
                        kind: isError ? .error : .activity,
                        title: isError ? "Tool error" : "Tool result",
                        text: text.isEmpty ? (isError ? "Failed" : "Completed") : text,
                        timestamp: timestamp,
                        isCollapsible: true
                    ))
                default:
                    entries.append(Self.unsupportedClaudeEntry(
                        id: id,
                        type: "\(type) \(blockType)",
                        timestamp: timestamp
                    ))
                }
            }
            if blocks.count > transcriptPageEntries {
                entries.append(Self.unsupportedClaudeEntry(
                    id: "\(eventID)-truncated",
                    type: "additional content blocks",
                    timestamp: timestamp
                ))
            }
            return entries
        case "system":
            let subtype = Self.cleanMetadata(object["subtype"] as? String) ?? "system"
            let isError = subtype.localizedCaseInsensitiveContains("error")
                || Self.boolValue(object["isApiErrorMessage"])
                || (object["error"] != nil && !(object["error"] is NSNull))
            if let name = Self.cleanMetadata(object["tool_name"] as? String) {
                let input = Self.cleanToolText(Self.jsonText(object["tool_input"]))
                return [.init(
                    id: eventID,
                    kind: Self.commandLike(name) ? .command : .activity,
                    title: name,
                    text: input.isEmpty ? Self.humanized(subtype) : input,
                    timestamp: timestamp,
                    isCollapsible: true
                )]
            }
            return [.init(
                id: eventID,
                kind: isError ? .error : .status,
                title: Self.humanized(subtype),
                text: isError
                    ? Self.claudeErrorText(object["error"])
                    : Self.cleanTranscriptText(object["message"] as? String ?? ""),
                timestamp: timestamp,
                isCollapsible: isError
            )]
        case "mode", "permission-mode":
            let value = (object["mode"] as? String)
                ?? (object["permissionMode"] as? String)
                ?? "Updated"
            return [.init(
                id: eventID,
                kind: .status,
                title: Self.humanized(type),
                text: Self.cleanTranscriptText(value),
                timestamp: timestamp
            )]
        case "tool_use_summary":
            return [.init(
                id: eventID,
                kind: .activity,
                title: "Tool summary",
                text: Self.cleanTranscriptText(object["summary"] as? String ?? ""),
                timestamp: timestamp,
                isCollapsible: true
            )]
        case "result":
            let isError = Self.boolValue(object["is_error"])
                || (object["subtype"] as? String)?.localizedCaseInsensitiveContains("error") == true
            let text = Self.cleanToolText(
                (object["result"] as? String)
                    ?? (object["terminal_reason"] as? String)
                    ?? ""
            )
            return [.init(
                id: eventID,
                kind: isError ? .error : .status,
                title: isError ? "Error" : "Completed",
                text: text,
                timestamp: timestamp,
                isCollapsible: isError
            )]
        case "rate_limit_event":
            return [.init(
                id: eventID,
                kind: .status,
                title: "Rate limit",
                text: "Rate limit status updated.",
                timestamp: timestamp
            )]
        default:
            return [Self.unsupportedClaudeEntry(id: eventID, type: type, timestamp: timestamp)]
        }
    }

    private func isValidHistoryEnvelope(_ line: Data, provider: DesktopProduct) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else {
            return false
        }
        switch provider {
        case .codex:
            return object["type"] is String && object["payload"] is [String: Any]
        case .claude:
            return object["type"] is String
        }
    }

    private func forEachForwardLine(
        at url: URL,
        under root: URL? = nil,
        maximumBytes: Int? = nil,
        body: (Data) -> Bool
    ) -> (completed: Bool, bytesRead: Int) {
        guard maximumBytes.map({ $0 > 0 }) ?? true,
              let handle = openNoFollowRegularFile(at: url, under: root)
        else { return (false, 0) }
        defer { try? handle.close() }
        var buffer = Data()
        var discardingOversized = false
        var bytesRead = 0
        while !Task.isCancelled {
            let remaining = maximumBytes.map { $0 - bytesRead }
            guard remaining.map({ $0 > 0 }) ?? true else {
                if !discardingOversized, !buffer.isEmpty { _ = body(buffer) }
                return (true, bytesRead)
            }
            let count = min(64 * 1_024, remaining ?? (64 * 1_024))
            guard let chunk = try? handle.read(upToCount: count), !chunk.isEmpty else {
                if !discardingOversized, !buffer.isEmpty { _ = body(buffer) }
                return (true, bytesRead)
            }
            bytesRead += chunk.count
            var cursor = chunk.startIndex
            if discardingOversized {
                guard let newline = chunk.firstIndex(of: 0x0A) else { continue }
                cursor = chunk.index(after: newline)
                discardingOversized = false
            }
            while cursor < chunk.endIndex {
                if let newline = chunk[cursor...].firstIndex(of: 0x0A) {
                    let lineBytes = chunk.distance(from: cursor, to: newline)
                    if lineBytes <= maximumSummaryLineBytes - buffer.count {
                        buffer.append(chunk[cursor..<newline])
                        if !buffer.isEmpty, !body(buffer) { return (true, bytesRead) }
                    }
                    buffer.removeAll(keepingCapacity: true)
                    cursor = chunk.index(after: newline)
                } else {
                    buffer.append(chunk[cursor...])
                    if buffer.count > maximumSummaryLineBytes {
                        buffer.removeAll(keepingCapacity: true)
                        discardingOversized = true
                    }
                    break
                }
            }
        }
        return (false, bytesRead)
    }

    private func readRange(handle: FileHandle, start: UInt64, end: UInt64) -> Data? {
        guard end >= start, !Task.isCancelled else { return nil }
        do {
            try handle.seek(toOffset: start)
            return try handle.read(upToCount: Int(end - start)) ?? Data()
        } catch {
            return nil
        }
    }

    private func readBoundedFile(
        at url: URL,
        under root: URL,
        expectedSize: Int,
        maximumBytes: Int
    ) -> Data? {
        guard
            expectedSize >= 0,
            expectedSize <= maximumBytes,
            !Task.isCancelled,
            let handle = openNoFollowRegularFile(at: url, under: root)
        else {
            return nil
        }
        defer { try? handle.close() }
        guard
            let data = try? handle.read(upToCount: expectedSize + 1),
            data.count == expectedSize
        else {
            return nil
        }
        return data
    }

    private func previousNewlineOffset(handle: FileHandle, before offset: UInt64) -> UInt64? {
        var cursor = offset
        let lowerBound = offset > UInt64(maximumRenderableEntryBytes)
            ? offset - UInt64(maximumRenderableEntryBytes)
            : 0
        while cursor > lowerBound, !Task.isCancelled {
            let start = cursor > 64 * 1_024 ? cursor - 64 * 1_024 : 0
            let boundedStart = max(start, lowerBound)
            guard let data = readRange(handle: handle, start: boundedStart, end: cursor) else {
                return nil
            }
            if let index = data.lastIndex(of: 0x0A) {
                return boundedStart + UInt64(data.distance(from: data.startIndex, to: index))
            }
            cursor = boundedStart
        }
        return lowerBound > 0 ? lowerBound : nil
    }

    private func transcriptSourceValues(for session: LocalChatSession) -> URLResourceValues? {
        guard
            let safe = canonicalRegularFile(
                url: session.sourceURL,
                under: session.sourceRootURL
            )
        else {
            return nil
        }
        let allowed: Bool
        switch session.provider {
        case .codex:
            allowed = safe.relativePath.hasPrefix("sessions/")
                || safe.relativePath.hasPrefix("archived_sessions/")
        case .claude:
            allowed = safe.relativePath.hasPrefix("local-agent-mode-sessions/")
                || safe.relativePath.hasPrefix("projects/")
        }
        guard
            allowed,
            safe.url.path == session.sourceURL.standardizedFileURL.path
        else {
            return nil
        }
        return try? safe.url.resourceValues(forKeys: [
            .fileSizeKey, .contentModificationDateKey,
            .isRegularFileKey, .isSymbolicLinkKey,
            .fileResourceIdentifierKey
        ])
    }

    private func openTranscriptSource(for session: LocalChatSession) -> OpenedTranscriptSource? {
        guard
            let before = transcriptSourceValues(for: session),
            let handle = openNoFollowRegularFile(
                at: session.sourceURL,
                under: session.sourceRootURL
            ),
            let after = transcriptSourceValues(for: session),
            before.fileSize == after.fileSize,
            before.fileResourceIdentifier.map({ String(describing: $0) })
                == after.fileResourceIdentifier.map({ String(describing: $0) })
        else {
            return nil
        }
        return .init(handle: handle, values: after)
    }

    private func openNoFollowRegularFile(at url: URL, under root: URL? = nil) -> FileHandle? {
        if let root, canonicalRegularFile(url: url, under: root) == nil {
            return nil
        }
        let descriptor = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { return nil }
        var descriptorStatus = Darwin.stat()
        var pathStatus = Darwin.stat()
        guard
            Darwin.fstat(descriptor, &descriptorStatus) == 0,
            Darwin.lstat(url.path, &pathStatus) == 0,
            descriptorStatus.st_mode & S_IFMT == S_IFREG,
            pathStatus.st_mode & S_IFMT == S_IFREG,
            descriptorStatus.st_dev == pathStatus.st_dev,
            descriptorStatus.st_ino == pathStatus.st_ino,
            root.map({ canonicalRegularFile(url: url, under: $0) != nil }) ?? true
        else {
            Darwin.close(descriptor)
            return nil
        }
        return FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    }

    private func sourceFile(url: URL, relativePath: String, status: String) -> SourceFile? {
        guard
            let values = try? url.resourceValues(
                forKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
            ),
            values.isRegularFile == true
        else {
            return nil
        }
        return SourceFile(
            url: url,
            relativePath: relativePath,
            fileSize: UInt64(max(0, values.fileSize ?? 0)),
            modifiedAt: values.contentModificationDate ?? .distantPast,
            status: status
        )
    }

    private func canonicalRegularFile(
        url: URL,
        under root: URL
    ) -> CanonicalRegularFile? {
        let canonicalRoot = root.resolvingSymlinksInPath().standardizedFileURL
        let standardized = url.standardizedFileURL
        let resolved = standardized.resolvingSymlinksInPath().standardizedFileURL
        guard
            standardized.path == resolved.path,
            let relativePath = relativePath(for: resolved, under: canonicalRoot),
            !relativePath.isEmpty,
            let values = try? standardized.resourceValues(forKeys: [
                .isRegularFileKey, .isSymbolicLinkKey,
                .fileSizeKey, .contentModificationDateKey
            ]),
            values.isRegularFile == true,
            values.isSymbolicLink != true,
            let fileSize = values.fileSize,
            fileSize >= 0
        else {
            return nil
        }
        return .init(
            url: resolved,
            relativePath: relativePath,
            fileSize: fileSize,
            modifiedAt: values.contentModificationDate ?? .distantPast
        )
    }

    private func session(
        record: ChatIndexRecord,
        source: SourceFile,
        codexHomeURL: URL,
        profileID: CodexProfile.ID?,
        profileName: String
    ) -> LocalChatSession {
        return LocalChatSession(
            id: record.id,
            provider: .codex,
            profileID: profileID,
            profileName: profileName,
            title: record.title,
            preview: record.preview,
            model: record.model,
            repository: record.repository,
            branch: record.branch,
            startedAt: record.startedAt,
            updatedAt: record.updatedAt,
            tokenCount: record.tokenCount,
            status: record.status,
            sourceURL: source.url,
            sourceRootURL: codexHomeURL,
            sourceSize: source.fileSize,
            sourceModifiedAt: source.modifiedAt
        )
    }

    private func boundedRecords(_ records: [ChatIndexRecord]) -> [ChatIndexRecord] {
        let sorted = records.sorted {
            if $0.updatedAt == $1.updatedAt { return $0.id > $1.id }
            return $0.updatedAt > $1.updatedAt
        }
        guard sorted.count > maximumSessions else { return sorted }
        let archived = sorted.filter { $0.status == "Archived" }
        let active = sorted.filter { $0.status != "Archived" }
        let archiveCapacity = min(archived.count, max(1, maximumSessions / 4))
        let activeCapacity = maximumSessions - archiveCapacity
        var kept = Array(active.prefix(activeCapacity)) + archived.prefix(archiveCapacity)
        if kept.count < maximumSessions {
            let keptIDs = Set(kept.map(\.id))
            kept += sorted.filter { !keptIDs.contains($0.id) }.prefix(maximumSessions - kept.count)
        }
        return kept.sorted {
            if $0.updatedAt == $1.updatedAt { return $0.id > $1.id }
            return $0.updatedAt > $1.updatedAt
        }
    }

    private func boundedSources(_ sources: [SourceFile]) -> [SourceFile] {
        guard sources.count > maximumSessions else { return sources }
        let sorted = sources.sorted {
            if $0.modifiedAt == $1.modifiedAt { return $0.relativePath > $1.relativePath }
            return $0.modifiedAt > $1.modifiedAt
        }
        let archived = sorted.filter { $0.status == "Archived" }
        let active = sorted.filter { $0.status != "Archived" }
        let archiveCapacity = min(archived.count, max(1, maximumSessions / 4))
        let activeCapacity = maximumSessions - archiveCapacity
        var kept = Array(active.prefix(activeCapacity)) + archived.prefix(archiveCapacity)
        if kept.count < maximumSessions {
            let paths = Set(kept.map(\.relativePath))
            kept += sorted.filter { !paths.contains($0.relativePath) }
                .prefix(maximumSessions - kept.count)
        }
        return kept
    }

    private func safeSessionURL(path: String, codexHomeURL: URL) -> URL? {
        let candidate = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL
        let home = codexHomeURL.resolvingSymlinksInPath().standardizedFileURL
        let allowedRoots = ["sessions", "archived_sessions"].map {
            home.appendingPathComponent($0, isDirectory: true).path + "/"
        }
        guard
            allowedRoots.contains(where: { candidate.path.hasPrefix($0) }),
            (try? candidate.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
        else {
            return nil
        }
        return candidate
    }

    private func relativePath(for url: URL, under root: URL) -> String? {
        let base = root.resolvingSymlinksInPath().standardizedFileURL.path + "/"
        let path = url.resolvingSymlinksInPath().standardizedFileURL.path
        guard path.hasPrefix(base) else { return nil }
        return String(path.dropFirst(base.count))
    }

    private func loadIndex(scopeKey: String, sourceRootKey: String) -> ChatIndexDocument {
        let url = indexURL(scopeKey: scopeKey)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        guard
            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
            values.isRegularFile == true,
            let size = values.fileSize,
            size >= 0, size <= 8 * 1_024 * 1_024,
            let data = try? BoundedFileReader.data(
                at: url,
                maximumBytes: LocalControlFileLimit.chatIndex
            ),
            let document = try? decoder.decode(ChatIndexDocument.self, from: data),
            document.version == Self.indexVersion,
            document.scopeKey == scopeKey,
            document.sourceRootKey == sourceRootKey,
            document.records.count <= maximumSessions,
            Set(document.records.map(\.relativePath)).count == document.records.count,
            document.records.allSatisfy(Self.isValidCachedRecord)
        else {
            return ChatIndexDocument(
                version: Self.indexVersion,
                scopeKey: scopeKey,
                sourceRootKey: sourceRootKey,
                records: []
            )
        }
        return document
    }

    private func saveIndex(_ document: ChatIndexDocument, scopeKey: String) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        guard !Task.isCancelled, let data = try? encoder.encode(document) else { return }
        Self.indexMutationLock.lock()
        defer { Self.indexMutationLock.unlock() }
        guard !Task.isCancelled else { return }
        let url = indexURL(scopeKey: scopeKey)
        do {
            try fileManager.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try fileManager.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: url.deletingLastPathComponent().path
            )
            try data.write(to: url, options: [.atomic])
            try fileManager.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: url.path
            )
        } catch {
            // A read-only profile remains usable; it simply loses the incremental cache.
        }
    }

    private func indexURL(scopeKey: String) -> URL {
        indexRootURL.appendingPathComponent("\(scopeKey)-v2.json")
    }

    private struct SourceInventory {
        let rootsExist: Bool
        let files: [SourceFile]
        let changeToken: String
        let truncated: Bool
    }

    private struct ClaudeInventory {
        let records: [ClaudeHistoryRecord]
        let changeToken: String
        var metadataBytes: Int = 0
    }

    private struct ClaudeUserDataInventory {
        let records: [ClaudeUserDataRecord]
        let changeToken: String
    }

    private struct ClaudeUserDataRecord {
        let id: String
        let title: String
        let preview: String?
        let model: String?
        let repository: String?
        let startedAt: Date
        let updatedAt: Date
        let tokenCount: Int?
        let latestUsageLimit: UsageLimitSignal?
        let status: String
        let source: SourceFile
    }

    private struct ClaudeHistoryRecord {
        let id: String
        let sourceSessionID: String
        var project: String
        var display: String
        var startedAt: Date?
        var updatedAt: Date?
    }

    private struct ClaudeMetadataCandidate {
        let url: URL
        let relativePath: String
        let fileSize: Int
        let modifiedAt: Date
    }

    private struct CanonicalRegularFile {
        let url: URL
        let relativePath: String
        let fileSize: Int
        let modifiedAt: Date
    }

    private struct OpenedTranscriptSource {
        let handle: FileHandle
        let values: URLResourceValues
    }

    private struct ClaudeBodyMetadata {
        var cwd: String?
        var branch: String?
        var model: String?
        var inspectedBytes = 0
    }

    private struct SourceFile {
        let url: URL
        let relativePath: String
        let fileSize: UInt64
        let modifiedAt: Date
        let status: String
    }

    private struct ChatIndexDocument: Codable, Equatable {
        let version: Int
        let scopeKey: String
        let sourceRootKey: String?
        let records: [ChatIndexRecord]
    }

    private static func isValidCachedRecord(_ record: ChatIndexRecord) -> Bool {
        record.relativePath.count <= 4_096
            && record.id.count <= 1_024
            && record.title.count <= 8_192
            && (record.preview?.count ?? 0) <= 32_768
            && (record.model?.count ?? 0) <= 1_024
            && (record.repository?.count ?? 0) <= 4_096
            && (record.branch?.count ?? 0) <= 4_096
            && (record.relativePath.hasPrefix("sessions/")
                || record.relativePath.hasPrefix("archived_sessions/"))
    }

    private struct ChatIndexRecord: Codable, Equatable {
        let relativePath: String
        let fileSize: UInt64
        let modifiedAt: Date
        let id: String
        let title: String
        let preview: String?
        let model: String?
        let repository: String?
        let branch: String?
        let startedAt: Date
        let updatedAt: Date
        let tokenCount: Int?
        let status: String
        let summaryComplete: Bool?

        func merging(source: SourceFile) -> Self {
            Self(
                relativePath: source.relativePath,
                fileSize: source.fileSize,
                modifiedAt: source.modifiedAt,
                id: id,
                title: title,
                preview: preview,
                model: model,
                repository: repository,
                branch: branch,
                startedAt: startedAt,
                updatedAt: updatedAt,
                tokenCount: tokenCount,
                status: source.status == "Archived" ? "Archived" : status,
                summaryComplete: summaryComplete
            )
        }
    }

    private static func eventDate(
        object: [String: Any],
        payload: [String: Any]
    ) -> Date? {
        date(object["timestamp"]) ?? date(payload["timestamp"])
            ?? date(payload["started_at"]) ?? date(payload["completed_at"])
    }

    private static func messageText(_ payload: [String: Any]) -> String? {
        guard let content = payload["content"] as? [[String: Any]] else { return nil }
        return content.compactMap { item -> String? in
            let type = item["type"] as? String
            guard type == "input_text" || type == "output_text" else { return nil }
            return item["text"] as? String
        }
        .joined(separator: "\n")
    }

    private static func payloadText(_ payload: [String: Any]) -> String {
        if let text = payload["text"] as? String { return cleanTranscriptText(text) }
        if let message = payload["message"] as? String { return cleanTranscriptText(message) }
        if let output = payload["output"] as? String { return cleanTranscriptText(output) }
        return ""
    }

    private static func date(_ raw: Any?) -> Date? {
        guard let value = raw as? String else { return nil }
        if let date = try? Date(
            value,
            strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)
        ) {
            return date
        }
        return try? Date(value, strategy: Date.ISO8601FormatStyle())
    }

    private static func claudeDate(_ raw: Any?) -> Date? {
        if let date = date(raw) { return date }
        guard let number = raw as? NSNumber else { return nil }
        let value = number.doubleValue
        guard value > 0 else { return nil }
        return Date(timeIntervalSince1970: value > 100_000_000_000 ? value / 1_000 : value)
    }

    private static func date(fromSQLite raw: Any?) -> Date? {
        let value: Double?
        if let number = raw as? NSNumber {
            value = number.doubleValue
        } else if let string = raw as? String {
            value = Double(string)
        } else {
            value = nil
        }
        guard let value, value > 0 else { return nil }
        return Date(timeIntervalSince1970: value > 100_000_000_000 ? value / 1_000 : value)
    }

    private static func intValue(_ raw: Any?) -> Int? {
        if raw is NSNull { return nil }
        if let number = raw as? NSNumber { return number.intValue }
        if let string = raw as? String { return Int(string) }
        return nil
    }

    private static func nonnegativeInt(_ raw: Any?) -> Int {
        guard !(raw is Bool), let value = intValue(raw), value > 0 else { return 0 }
        return value
    }

    private static func saturatingAdd(_ lhs: Int, _ rhs: Int) -> Int {
        let (sum, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? Int.max : sum
    }

    private static func boolValue(_ raw: Any?) -> Bool {
        if let value = raw as? Bool { return value }
        if let number = raw as? NSNumber { return number.intValue != 0 }
        if let string = raw as? String { return string == "1" || string.lowercased() == "true" }
        return false
    }

    private static func visibleMessageText(_ raw: String, role: LocalChatRole) -> String {
        var text = raw
        if role == .user {
            if let delegatedInput = firstCapture(
                in: text,
                pattern: #"<codex_delegation>[\s\S]*?<input>([\s\S]*?)</input>[\s\S]*?</codex_delegation>"#
            ) {
                text = delegatedInput
            } else {
                for pattern in [
                    #"<recommended_plugins>[\s\S]*?</recommended_plugins>"#,
                    #"# AGENTS\.md instructions\s*[\s\S]*?<INSTRUCTIONS>[\s\S]*?</INSTRUCTIONS>"#,
                    #"<environment_context>[\s\S]*?</environment_context>"#
                ] {
                    text = text.replacingOccurrences(
                        of: pattern,
                        with: "",
                        options: .regularExpression
                    )
                }
            }
        }
        return cleanTranscriptText(text)
    }

    private static func cleanTranscriptText(_ raw: String) -> String {
        var text = raw
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if !home.isEmpty { text = text.replacingOccurrences(of: home, with: "~") }
        text = text.replacingOccurrences(
            of: #"(?<![:A-Za-z0-9])/(?:[A-Za-z0-9._-]+/)+([A-Za-z0-9._-]+)"#,
            with: "…/$1",
            options: .regularExpression
        )
        for pattern in [
            #"\bsk-[A-Za-z0-9_-]{12,}\b"#,
            #"\b(?:ghp_|github_pat_|xox[baprs]-)[A-Za-z0-9_-]{12,}\b"#,
            #"\bgAAAAA[A-Za-z0-9_-]{40,}\b"#,
            #"(?i)\b(api[_-]?key|access[_-]?token|password|secret)\s*[:=]\s*[^\s,;]+"#
        ] {
            text = text.replacingOccurrences(
                of: pattern,
                with: "[redacted]",
                options: .regularExpression
            )
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func cleanToolText(_ raw: String) -> String {
        cleanTranscriptText(raw).replacingOccurrences(
            of: #"\b[A-Za-z0-9_=+-]{64,}\b"#,
            with: "[redacted opaque value]",
            options: .regularExpression
        )
    }

    private static func jsonText(_ value: Any?) -> String {
        guard
            let value,
            JSONSerialization.isValidJSONObject(value),
            let data = try? JSONSerialization.data(
                withJSONObject: value,
                options: [.sortedKeys, .withoutEscapingSlashes]
            )
        else {
            return value as? String ?? ""
        }
        return String(decoding: data, as: UTF8.self)
    }

    private static func claudeContentText(_ value: Any?) -> String {
        if let text = value as? String { return text }
        if let blocks = value as? [[String: Any]] {
            return blocks.compactMap { block -> String? in
                if let text = block["text"] as? String { return text }
                if let content = block["content"] as? String { return content }
                return nil
            }.joined(separator: "\n")
        }
        return jsonText(value)
    }

    private static func claudeErrorText(_ value: Any?) -> String {
        let text = cleanToolText(
            (value as? String) ?? jsonText(value)
        )
        return text.isEmpty ? "Claude reported an error for this event." : text
    }

    private static func unsupportedClaudeEntry(
        id: String,
        type: String,
        timestamp: Date?
    ) -> LocalChatTranscriptEntry {
        .init(
            id: id,
            kind: .activity,
            title: "Unsupported event",
            text: "Claude history event “\(cleanMetadata(type) ?? "unknown")” is not rendered.",
            timestamp: timestamp,
            isCollapsible: true
        )
    }

    private static func cleanMetadata(_ value: String?) -> String? {
        guard let value else { return nil }
        let cleaned = cleanTranscriptText(value)
        guard !cleaned.isEmpty else { return nil }
        return String(cleaned.prefix(256))
    }

    private static func cleanIdentifier(_ value: String?) -> String? {
        guard let value else { return nil }
        let allowed = value.unicodeScalars.filter {
            CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_")).contains($0)
        }
        let cleaned = String(String.UnicodeScalarView(allowed)).prefix(128)
        return cleaned.isEmpty ? nil : String(cleaned)
    }

    private static func unchangedValidIdentifier(_ value: String?) -> String? {
        guard
            let value,
            value.count <= 128,
            cleanIdentifier(value) == value
        else {
            return nil
        }
        return value
    }

    private static func stableSourceID(
        provider: DesktopProduct,
        rawID: String?,
        relativePath: String
    ) -> String {
        if let valid = unchangedValidIdentifier(rawID) { return valid }
        let namespace = "\(provider.rawValue)|\(relativePath)|\(rawID ?? "")"
        return "\(provider.rawValue)-local-\(String(fnv1a64(namespace), radix: 16))"
    }

    private static func safeFilename(_ value: String) -> Bool {
        !value.isEmpty
            && value.utf8.count <= 255
            && value != "."
            && value != ".."
            && !value.contains("/")
            && !value.contains("\0")
    }

    private static func safeLastPathComponent(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return cleanMetadata(URL(fileURLWithPath: value).lastPathComponent)
    }

    private static func firstCapture(in text: String, pattern: String) -> String? {
        guard
            let expression = try? NSRegularExpression(pattern: pattern),
            let match = expression.firstMatch(
                in: text,
                range: NSRange(text.startIndex..., in: text)
            ),
            match.numberOfRanges > 1,
            let range = Range(match.range(at: 1), in: text)
        else {
            return nil
        }
        return String(text[range])
    }

    private static func title(from text: String?) -> String {
        guard let text else { return "Untitled chat" }
        let firstLine = text.split(whereSeparator: \.isNewline).first.map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !firstLine.isEmpty else { return "Untitled chat" }
        return firstLine.count <= 80 ? firstLine : String(firstLine.prefix(77)) + "…"
    }

    private static func preview(from text: String?) -> String? {
        guard let text else { return nil }
        let compact = text.replacingOccurrences(
            of: #"\s+"#,
            with: " ",
            options: .regularExpression
        )
        guard !compact.isEmpty else { return nil }
        return compact.count <= 180 ? compact : String(compact.prefix(177)) + "…"
    }

    private static func commandLike(_ name: String) -> Bool {
        let value = name.lowercased()
        return value.contains("shell") || value.contains("exec") || value.contains("command")
    }

    private static let privateToolNames: Set<String> = [
        "send_message", "followup_task", "spawn_agent"
    ]

    private static func humanized(_ value: String) -> String {
        value.replacingOccurrences(of: "_", with: " ").capitalized
    }

    private static func byteCount(_ count: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: count), countStyle: .file)
    }

    private static func sameModificationDate(_ lhs: Date, _ rhs: Date) -> Bool {
        abs(lhs.timeIntervalSince(rhs)) < 0.002
    }

    private static func fnv1a64(_ value: String) -> UInt64 {
        value.utf8.reduce(14_695_981_039_346_656_037) {
            ($0 ^ UInt64($1)) &* 1_099_511_628_211
        }
    }
}
