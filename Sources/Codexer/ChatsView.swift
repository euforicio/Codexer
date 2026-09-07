import CodexerCore
import SwiftUI
import TranscriptRenderer

struct ChatsView: View {
    @EnvironmentObject private var model: CodexerModel
    @State private var searchText = ""
    @State private var dateFilter: ChatDateFilter = .all
    @State private var showsMetadata = false
    @State private var metadataCopied = false
    @FocusState private var searchFocused: Bool

    var body: some View {
        Group {
            switch model.chatAvailability {
            case let .unavailable(reason):
                AgentDockEmptyState(
                    title: "Chats Unavailable",
                    systemImage: "bubble.left.and.exclamationmark.bubble.right",
                    description: reason
                )
            case .available:
                if model.selectedProfile == nil, model.selectedOfficialProduct == nil {
                    AgentDockEmptyState(
                        title: "Choose a Profile",
                        systemImage: "person.crop.square.stack",
                        description: "Select a provider app or profile in the sidebar to browse its local conversations.",
                        actionTitle: "Add Profile",
                        action: { model.showAddProfile = true }
                    )
                } else if model.chatsLoading, model.chatSessions.isEmpty {
                    ProgressView("Reading local chats…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if model.chatSessions.isEmpty {
                    AgentDockEmptyState(
                        title: "No Local Chats",
                        systemImage: "bubble.left.and.bubble.right",
                        description: emptyChatsDescription,
                        actionTitle: "Open \(currentProviderName)",
                        action: openCurrentProvider
                    )
                } else {
                    browser
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .agentDockFocusSearch)) { _ in
            searchFocused = true
        }
    }

    private var browser: some View {
        GeometryReader { proxy in
            let showsMetadataPane = proxy.size.width >= 820
            let listWidth = min(max(proxy.size.width * 0.27, 220), 260)
            let metadataWidth = min(max(proxy.size.width * 0.24, 210), 240)

            HStack(spacing: 0) {
                chatList
                    .frame(width: listWidth)
                paneDivider
                transcript(showsMetadataButton: !showsMetadataPane)
                    .frame(maxWidth: .infinity)
                if showsMetadataPane {
                    paneDivider
                    metadata
                        .frame(width: metadataWidth)
                }
            }
        }
        .background(chatBackground)
        .onChange(of: filteredSessions.map(\.id)) { _, visibleIDs in
            guard
                let replacementID = ChatSelectionResolver.replacementID(
                    currentID: model.selectedChatID,
                    visibleIDs: visibleIDs
                ),
                replacementID != model.selectedChatID
            else {
                return
            }
            model.selectChat(replacementID)
        }
    }

    private var chatList: some View {
        VStack(spacing: 0) {
            VStack(spacing: 8) {
                HStack(spacing: 9) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.secondary)
                    TextField("Search chats", text: $searchText)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13))
                        .focused($searchFocused)
                        .onSubmit {
                            if let first = filteredSessions.first {
                                model.selectChat(first.id)
                            }
                        }
                        .onExitCommand { searchText = "" }
                        .accessibilityLabel("Search chats")
                    if !searchText.isEmpty {
                        Button {
                            searchText = ""
                            searchFocused = true
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("Clear chat search")
                        .accessibilityLabel("Clear chat search")
                    }
                }
                .padding(.horizontal, 11)
                .frame(height: 34)
                .background(controlBackground, in: RoundedRectangle(cornerRadius: 8))
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(controlBorder, lineWidth: 1)
                }

                HStack(spacing: 6) {
                    Text(currentProviderName)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Menu {
                        ForEach(ChatDateFilter.allCases) { filter in
                            Button {
                                dateFilter = filter
                            } label: {
                                if filter == dateFilter {
                                    Label(filter.title, systemImage: "checkmark")
                                } else {
                                    Text(filter.title)
                                }
                            }
                        }
                    } label: {
                        Label(dateFilter.menuTitle, systemImage: "calendar")
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .accessibilityLabel("Date filter")
                }
                .font(.system(size: 12))
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 8)

            if filteredSessions.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "line.3.horizontal.decrease.circle")
                        .font(.system(size: 24))
                        .foregroundStyle(.secondary)
                    Text("No matching chats")
                        .font(.system(size: 13, weight: .medium))
                    Button("Clear Filters") {
                        searchText = ""
                        dateFilter = .all
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(groupedSessions, id: \.title) { group in
                            Text(group.title)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 12)
                                .padding(.top, 8)
                                .padding(.bottom, 4)
                            ForEach(group.sessions) { session in
                                ChatSessionRow(
                                    session: session,
                                    selected: model.selectedChatID == session.id
                                ) {
                                    model.selectChat(session.id)
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 7)
                }
            }

            HStack(spacing: 6) {
                if model.chatsLoading {
                    ProgressView().controlSize(.mini)
                    Text("Refreshing")
                } else {
                    Text("\(filteredSessions.count) conversation\(filteredSessions.count == 1 ? "" : "s")")
                }
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .frame(height: 34)
        }
        .background(listBackground)
    }

    private func transcript(showsMetadataButton: Bool) -> some View {
        Group {
            if let session = selectedSession {
                VStack(spacing: 0) {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(session.title)
                                .font(.system(size: 18, weight: .semibold))
                                .lineLimit(1)
                            Spacer(minLength: 4)
                            if showsMetadataButton {
                                Button {
                                    showsMetadata.toggle()
                                } label: {
                                    Label("Details", systemImage: "info.circle")
                                }
                                .labelStyle(.iconOnly)
                                .buttonStyle(.borderless)
                                .help("Show chat metadata")
                                .accessibilityLabel("Show chat metadata")
                                .popover(isPresented: $showsMetadata, arrowEdge: .trailing) {
                                    metadataContent(session)
                                        .padding(16)
                                        .frame(width: 260)
                                        .background(metadataBackground)
                                }
                            }
                        }
                        Text(transcriptSummary(session))
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 18)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .frame(minHeight: 64)

                    Divider().overlay(separatorColor)

                    if model.chatTranscriptLoading {
                        ProgressView("Reading transcript…")
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else if model.chatTranscriptEntries.isEmpty, !model.hasMoreChatTranscript {
                        AgentDockEmptyState(
                            title: "Transcript Unavailable",
                            systemImage: "doc.text.magnifyingglass",
                            description: "AgentDock could not read this local transcript."
                        )
                    } else {
                        TranscriptView(
                            document: transcriptDocument(session),
                            onLoadMore: model.loadMoreChatTranscript
                        )
                    }
                }
                .background(chatBackground)
            } else {
                let noMatches = filtersAreActive && filteredSessions.isEmpty
                AgentDockEmptyState(
                    title: noMatches ? "No Matching Chats" : "Select a Chat",
                    systemImage: noMatches ? "line.3.horizontal.decrease.circle" : "text.bubble",
                    description: noMatches
                        ? "Clear the search or date filter to see local conversations."
                        : "Choose a local conversation to read it."
                )
            }
        }
    }

    private var metadata: some View {
        Group {
            if let session = selectedSession {
                ScrollView {
                    metadataContent(session)
                        .padding(16)
                }
            } else {
                Color.clear
            }
        }
        .background(metadataBackground)
    }

    private func metadataContent(_ session: LocalChatSession) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Metadata")
                .font(.system(size: 13, weight: .semibold))
            Divider().overlay(separatorColor)

            MetadataRow(label: "Provider", value: session.provider.displayName)
            MetadataRow(label: "Profile", value: session.profileName)
            MetadataRow(label: "Model", value: session.model ?? "Unavailable")
            MetadataRow(label: "Folder", value: session.repository ?? "Unavailable")
            MetadataRow(label: "Branch", value: session.branch ?? "Unavailable")

            Divider().overlay(separatorColor)

            MetadataRow(
                label: "Started",
                value: session.startedAt.formatted(date: .abbreviated, time: .shortened)
            )
            MetadataRow(
                label: "Updated",
                value: session.updatedAt.formatted(date: .abbreviated, time: .shortened)
            )
            MetadataRow(label: "Activity Span", value: durationText(session.duration))
            MetadataRow(
                label: "Tokens",
                value: session.tokenCount?.formatted() ?? "Unavailable"
            )
            MetadataRow(label: "Status", value: session.status)
            MetadataRow(label: "Session ID", value: maskedSessionID(session.id))

            Button {
                model.copyChatMetadata(session)
                metadataCopied = true
                Task {
                    try? await Task.sleep(for: .seconds(2))
                    metadataCopied = false
                }
            } label: {
                Label(
                    metadataCopied ? "Copied" : "Copy Metadata",
                    systemImage: metadataCopied ? "checkmark" : "doc.on.doc"
                )
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .padding(.top, 4)

            Button {
                model.revealChat(session)
            } label: {
                Label("Reveal Session", systemImage: "folder")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
        }
    }

    private var paneDivider: some View {
        Rectangle()
            .fill(separatorColor)
            .frame(width: 1)
    }

    private var listBackground: Color { AgentDockPalette.graphite }
    private var chatBackground: Color { AgentDockPalette.panel }
    private var metadataBackground: Color { AgentDockPalette.graphite }
    private var controlBackground: Color { AgentDockPalette.panel }
    private var controlBorder: Color { AgentDockPalette.panelBorder }
    private var separatorColor: Color { AgentDockPalette.divider }

    private var filteredSessions: [LocalChatSession] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return model.chatSessions.filter { session in
            let dateMatches = dateFilter.contains(session.updatedAt)
            let queryMatches = query.isEmpty
                || session.title.localizedCaseInsensitiveContains(query)
                || session.preview?.localizedCaseInsensitiveContains(query) == true
                || session.repository?.localizedCaseInsensitiveContains(query) == true
                || session.branch?.localizedCaseInsensitiveContains(query) == true
                || session.model?.localizedCaseInsensitiveContains(query) == true
            return dateMatches && queryMatches
        }
    }

    private var filtersAreActive: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || dateFilter != .all
    }

    private var emptyChatsDescription: String {
        let name = model.selectedProfile?.name ?? "Official \(currentProviderName)"
        if model.selectedProfile?.product == .claude || model.selectedOfficialProduct == .claude {
            return "Local Cowork conversations for \(name) will appear here. Synced claude.ai web chats are not available locally."
        }
        return "Local conversations for \(name) will appear here after you use \(currentProviderName)."
    }

    private func openCurrentProvider() {
        if let profile = model.selectedProfile {
            model.launch(profile)
        } else if let product = model.selectedOfficialProduct {
            model.openStock(product)
        }
    }

    private var currentProviderName: String {
        if let profile = model.selectedProfile {
            return profile.product.displayName
        }
        return model.selectedOfficialProduct?.displayName ?? "Provider"
    }

    private var groupedSessions: [(title: String, sessions: [LocalChatSession])] {
        let calendar = Calendar.current
        var today: [LocalChatSession] = []
        var yesterday: [LocalChatSession] = []
        var earlier: [LocalChatSession] = []
        for session in filteredSessions {
            if calendar.isDateInToday(session.updatedAt) {
                today.append(session)
            } else if calendar.isDateInYesterday(session.updatedAt) {
                yesterday.append(session)
            } else {
                earlier.append(session)
            }
        }
        return [
            ("Today", today),
            ("Yesterday", yesterday),
            ("Earlier", earlier)
        ].filter { !$0.1.isEmpty }
    }

    private var selectedSession: LocalChatSession? {
        guard let selectedID = ChatSelectionResolver.displayedID(
            currentID: model.selectedChatID,
            visibleIDs: filteredSessions.map(\.id)
        ) else {
            return nil
        }
        return filteredSessions.first { $0.id == selectedID }
    }

    private func durationText(_ duration: TimeInterval) -> String {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = duration >= 3600 ? [.hour, .minute] : [.minute, .second]
        formatter.unitsStyle = .abbreviated
        return formatter.string(from: duration) ?? "Unavailable"
    }

    private func maskedSessionID(_ value: String) -> String {
        guard value.count > 12 else { return value }
        return "\(value.prefix(8))…\(value.suffix(6))"
    }

    private func transcriptSummary(_ session: LocalChatSession) -> String {
        [
            session.provider.displayName,
            session.profileName,
            session.repository,
            session.updatedAt.formatted(date: .abbreviated, time: .shortened),
            "Stored locally"
        ]
        .compactMap { $0 }
        .joined(separator: " · ")
    }

    private func transcriptDocument(_ session: LocalChatSession) -> TranscriptDocument {
        var events = model.chatTranscriptEntries.enumerated().map { index, entry in
            TranscriptEvent(
                id: entry.id,
                sequence: entry.sourceOrdinal ?? index,
                kind: transcriptKind(entry.kind),
                role: transcriptRole(entry.role),
                title: entry.title,
                text: entry.text.isEmpty ? nil : TranscriptText(entry.text),
                sourceType: entry.kind.rawValue,
                timestamp: entry.timestamp
            )
        }
        if model.chatTranscriptSourceChanged {
            events.insert(
                TranscriptEvent(
                    id: "\(session.id)-source-changed",
                    sequence: -1,
                    kind: .status,
                    title: "Conversation changed",
                    text: TranscriptText(
                        "Reloaded from the beginning to preserve a consistent snapshot."
                    ),
                    sourceType: "source_changed"
                ),
                at: 0
            )
        }
        return TranscriptDocument(
            id: session.id,
            sessionID: session.id,
            provider: session.provider == .claude ? .claude : .codex,
            events: events,
            hasOlderEvents: model.hasMoreChatTranscript,
            isInitialLoading: model.chatTranscriptLoading,
            isLoadingOlder: model.chatOlderTranscriptLoading
        )
    }

    private func transcriptKind(_ kind: LocalChatTranscriptEntryKind) -> TranscriptEventKind {
        switch kind {
        case .message: .message
        case .reasoning: .reasoning
        case .activity: .toolOutput
        case .command: .command
        case .file: .fileReference
        case .error: .error
        case .status: .status
        case .malformed: .malformed
        case .oversized: .unsupported
        case .unsupported: .unsupported
        }
    }

    private func transcriptRole(_ role: LocalChatRole?) -> TranscriptMessageRole {
        switch role {
        case .user: .user
        case .assistant: .assistant
        case nil: .unknown
        }
    }
}

enum ChatSelectionResolver {
    static func displayedID(currentID: String?, visibleIDs: [String]) -> String? {
        guard let currentID, visibleIDs.contains(currentID) else { return nil }
        return currentID
    }

    static func replacementID(currentID: String?, visibleIDs: [String]) -> String? {
        displayedID(currentID: currentID, visibleIDs: visibleIDs) ?? visibleIDs.first
    }
}

private struct ChatSessionRow: View {
    let session: LocalChatSession
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 8) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 8, height: 8)
                    .padding(.top, 4)
                VStack(alignment: .leading, spacing: 3) {
                    Text(session.title)
                        .font(.system(size: 14, weight: .medium))
                        .lineLimit(2)
                    Text([session.provider.displayName, session.profileName, session.repository]
                        .compactMap { $0 }
                        .joined(separator: " · "))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    HStack {
                        Text(session.updatedAt.formatted(date: .omitted, time: .shortened))
                        Spacer()
                        if let tokens = session.tokenCount {
                            Text("\(tokens.formatted()) tokens")
                        }
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 8)
            .frame(minHeight: 72)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(.rect)
            .background {
                if selected {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(AgentDockPalette.selection)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }

    private var statusColor: Color {
        switch session.status.lowercased() {
        case let status where status.contains("complete"):
            .green
        case let status where status.contains("progress") || status.contains("start"):
            .orange
        case let status where status.contains("fail") || status.contains("error"):
            .red
        default:
            .secondary
        }
    }
}

private struct MetadataRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Text(value)
                .multilineTextAlignment(.trailing)
                .lineLimit(2)
                .textSelection(.enabled)
        }
        .font(.system(size: 12))
        .accessibilityElement(children: .combine)
    }
}

private enum ChatDateFilter: String, CaseIterable, Identifiable {
    case all
    case today
    case week
    case month

    var id: Self { self }
    var title: String { rawValue.capitalized }

    var menuTitle: String {
        switch self {
        case .all: "All dates"
        case .today: "Today"
        case .week: "7 days"
        case .month: "30 days"
        }
    }

    func contains(_ date: Date) -> Bool {
        switch self {
        case .all:
            true
        case .today:
            Calendar.current.isDateInToday(date)
        case .week:
            date >= Calendar.current.date(byAdding: .day, value: -7, to: .now) ?? .distantPast
        case .month:
            date >= Calendar.current.date(byAdding: .month, value: -1, to: .now) ?? .distantPast
        }
    }
}
