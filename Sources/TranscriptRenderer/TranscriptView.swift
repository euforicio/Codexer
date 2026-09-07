import AppKit
import StreamdownUI
import SwiftUI

public struct TranscriptView: View {
    public let document: TranscriptDocument
    private let onLoadMore: () -> Void

    public init(
        document: TranscriptDocument,
        onLoadMore: @escaping () -> Void = {}
    ) {
        self.document = document
        self.onLoadMore = onLoadMore
    }

    public var body: some View {
        TranscriptViewport(document: document, onLoadMore: onLoadMore)
            .id(document.id)
            .background(TranscriptPalette.background)
    }
}

private struct TranscriptViewport: View {
    let document: TranscriptDocument
    let onLoadMore: () -> Void

    @StateObject private var scrollPreserver = TranscriptScrollPreserver()
    @State private var selectedEventID: TranscriptEvent.ID?
    @State private var maintainsInitialBottomAnchor = false

    var body: some View {
        GeometryReader { viewport in
            ScrollViewReader { scrollProxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        TranscriptProviderIndicator(provider: document.provider)
                            .padding(.bottom, 18)

                        ForEach(document.events) { event in
                            TranscriptEventView(
                                event: event,
                                provider: document.provider,
                                isKeyboardSelected: selectedEventID == event.id
                            )
                            .id(TranscriptScrollElementID.event(event.id))
                        }

                        if document.hasOlderEvents || document.isLoadingOlder {
                            MoreEventsControl(isLoading: document.isLoadingOlder)
                                .padding(.top, 16)
                                .id(TranscriptScrollElementID.loadMore)
                                .onAppear {
                                    guard !document.isLoadingOlder else { return }
                                    onLoadMore()
                                }
                        }

                        Color.clear
                            .frame(height: 1)
                            .id(TranscriptScrollElementID.bottom)
                            .background {
                                GeometryReader { geometry in
                                    Color.clear.preference(
                                        key: TranscriptBottomPreferenceKey.self,
                                        value: geometry.frame(in: .named("transcript-scroll")).maxY
                                    )
                                }
                            }
                    }
                    .frame(maxWidth: 780)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 22)
                    .background {
                        TranscriptScrollResolver(
                            preserver: scrollPreserver,
                            firstEventID: document.events.first?.id,
                            onUserScroll: {
                                maintainsInitialBottomAnchor = false
                            }
                        )
                            .frame(width: 0, height: 0)
                    }
                }
                .coordinateSpace(name: "transcript-scroll")
                .onMoveCommand { direction in
                    maintainsInitialBottomAnchor = false
                    moveSelection(direction, proxy: scrollProxy)
                }
                .focusable()
                .overlay {
                    if document.isInitialLoading {
                        TranscriptSkeleton()
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Conversation transcript")
    }

    private func moveSelection(_ direction: MoveCommandDirection, proxy: ScrollViewProxy) {
        guard !document.events.isEmpty else { return }
        let currentIndex = selectedEventID.flatMap { selectedID in
            document.events.firstIndex(where: { $0.id == selectedID })
        }
        let nextIndex: Int
        switch direction {
        case .up:
            nextIndex = max(0, (currentIndex ?? document.events.count) - 1)
        case .down:
            nextIndex = min(document.events.count - 1, (currentIndex ?? -1) + 1)
        default:
            return
        }
        let eventID = document.events[nextIndex].id
        selectedEventID = eventID
        proxy.scrollTo(TranscriptScrollElementID.event(eventID), anchor: .center)
    }
}

enum TranscriptScrollElementID: Hashable {
    case event(TranscriptEvent.ID)
    case loadMore
    case bottom
}

@MainActor
final class TranscriptScrollPreserver: ObservableObject {
    weak var scrollView: NSScrollView?
    private var prependSnapshot: Snapshot?

    struct Snapshot {
        let documentHeight: CGFloat
        let origin: NSPoint
        let documentIsFlipped: Bool
    }

    func captureBeforePrepend() {
        guard let scrollView, let documentView = scrollView.documentView else { return }
        prependSnapshot = Snapshot(
            documentHeight: documentView.bounds.height,
            origin: scrollView.contentView.bounds.origin,
            documentIsFlipped: documentView.isFlipped
        )
    }

    func preserveAfterPrepend() -> Bool {
        guard
            let scrollView,
            scrollView.documentView != nil,
            let snapshot = prependSnapshot
        else {
            return false
        }
        prependSnapshot = nil

        DispatchQueue.main.async { [weak scrollView] in
            guard
                let scrollView,
                let documentView = scrollView.documentView
            else {
                return
            }
            scrollView.layoutSubtreeIfNeeded()
            let newHeight = documentView.bounds.height
            let newY = TranscriptScrollOffset.preservedOriginY(
                oldY: snapshot.origin.y,
                oldDocumentHeight: snapshot.documentHeight,
                newDocumentHeight: newHeight,
                viewportHeight: scrollView.contentView.bounds.height,
                isFlipped: snapshot.documentIsFlipped
            )
            scrollView.contentView.scroll(to: NSPoint(x: snapshot.origin.x, y: newY))
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }
        return true
    }
}

enum TranscriptScrollOffset {
    static func preservedOriginY(
        oldY: CGFloat,
        oldDocumentHeight: CGFloat,
        newDocumentHeight: CGFloat,
        viewportHeight: CGFloat,
        isFlipped: Bool
    ) -> CGFloat {
        let heightIncrease = max(0, newDocumentHeight - oldDocumentHeight)
        let proposedY = isFlipped ? oldY + heightIncrease : oldY
        let maximumY = max(0, newDocumentHeight - viewportHeight)
        return min(max(0, proposedY), maximumY)
    }
}

private struct TranscriptScrollResolver: NSViewRepresentable {
    let preserver: TranscriptScrollPreserver
    let firstEventID: TranscriptEvent.ID?
    let onUserScroll: () -> Void

    final class Coordinator {
        var firstEventID: TranscriptEvent.ID?
        var boundsObserver: NSObjectProtocol?
        var liveScrollObserver: NSObjectProtocol?
        var keyMonitor: Any?

        init(firstEventID: TranscriptEvent.ID?) {
            self.firstEventID = firstEventID
        }

        deinit {
            if let boundsObserver {
                NotificationCenter.default.removeObserver(boundsObserver)
            }
            if let liveScrollObserver {
                NotificationCenter.default.removeObserver(liveScrollObserver)
            }
            if let keyMonitor {
                NSEvent.removeMonitor(keyMonitor)
            }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(firstEventID: firstEventID)
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async { [weak view, weak preserver, weak coordinator = context.coordinator] in
            guard let preserver, let scrollView = view?.enclosingScrollView else { return }
            preserver.scrollView = scrollView
            scrollView.contentView.postsBoundsChangedNotifications = true
            preserver.captureBeforePrepend()
            coordinator?.boundsObserver = NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification,
                object: scrollView.contentView,
                queue: .main
            ) { [weak preserver] _ in
                MainActor.assumeIsolated {
                    preserver?.captureBeforePrepend()
                }
            }
            coordinator?.liveScrollObserver = NotificationCenter.default.addObserver(
                forName: NSScrollView.willStartLiveScrollNotification,
                object: scrollView,
                queue: .main
            ) { _ in
                MainActor.assumeIsolated {
                    onUserScroll()
                }
            }
            coordinator?.keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                let scrollKeys: Set<UInt16> = [49, 115, 116, 119, 121, 125, 126]
                if event.window === scrollView.window, scrollKeys.contains(event.keyCode) {
                    onUserScroll()
                }
                return event
            }
        }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        if context.coordinator.firstEventID != firstEventID {
            preserver.captureBeforePrepend()
            context.coordinator.firstEventID = firstEventID
            _ = preserver.preserveAfterPrepend()
        }
        if preserver.scrollView == nil {
            DispatchQueue.main.async { [weak view, weak preserver] in
                preserver?.scrollView = view?.enclosingScrollView
            }
        }
    }
}

private struct TranscriptProviderIndicator: View {
    let provider: TranscriptProvider

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(provider == .codex ? TranscriptPalette.accent : TranscriptPalette.claude)
                .frame(width: 6, height: 6)
                .accessibilityHidden(true)
            Text(provider == .codex ? "Codex" : "Claude")
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(provider == .codex ? "Codex" : "Claude") conversation")
    }
}

private struct MoreEventsControl: View {
    let isLoading: Bool

    var body: some View {
        HStack(spacing: 7) {
            if isLoading {
                ProgressView()
                    .controlSize(.mini)
            }
            Text(isLoading ? "Loading more activity…" : "More activity loads as you scroll")
                .font(.caption)
        }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 7)
        .foregroundStyle(.secondary)
        .background(TranscriptPalette.activity, in: RoundedRectangle(cornerRadius: 7))
        .overlay {
            RoundedRectangle(cornerRadius: 7)
                .stroke(TranscriptPalette.border)
        }
    }
}

private struct TranscriptEventView: View {
    let event: TranscriptEvent
    let provider: TranscriptProvider
    let isKeyboardSelected: Bool

    var body: some View {
        Group {
            if event.kind == .message {
                TranscriptMessageView(event: event)
            } else {
                TranscriptActivityView(event: event, provider: provider)
            }
        }
        .padding(.vertical, event.kind == .message ? 14 : 5)
        .overlay {
            RoundedRectangle(cornerRadius: 9)
                .stroke(
                    isKeyboardSelected ? TranscriptPalette.accent.opacity(0.65) : .clear,
                    lineWidth: 1
                )
                .padding(.horizontal, -6)
        }
    }
}

private struct TranscriptMessageView: View {
    let event: TranscriptEvent

    var body: some View {
        if event.role == .user {
            userPrompt
        } else {
            assistantResponse
        }
    }

    private var userPrompt: some View {
        VStack(alignment: .leading, spacing: 10) {
            TranscriptMarkdown(text: event.text?.value ?? "")
            if let text = event.text {
                TranscriptTruncationNotice(text: text)
            }
            HStack {
                TranscriptTimestamp(date: event.timestamp)
                Spacer()
                TranscriptCopyButton(
                    text: event.text?.value ?? "",
                    label: event.text?.isTruncated == true ? "Copy visible prompt" : "Copy prompt"
                )
            }
        }
        .padding(.horizontal, 15)
        .padding(.vertical, 13)
        .background(TranscriptPalette.userPrompt, in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(TranscriptPalette.border)
        }
        .frame(maxWidth: 690, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .trailing)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("You")
    }

    private var assistantResponse: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 7) {
                Image(systemName: "sparkle")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(TranscriptPalette.assistant)
                    .accessibilityHidden(true)
                Text("Assistant")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                TranscriptTimestamp(date: event.timestamp)
            }
            TranscriptMarkdown(text: event.text?.value ?? "")
            if let text = event.text {
                TranscriptTruncationNotice(text: text)
                TranscriptCopyButton(text: text.value, label: "Copy response")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
    }
}

private struct TranscriptMarkdown: View {
    let text: String

    var body: some View {
        StreamdownView(
            content: text,
            mode: .static,
            controls: .agentDockTranscript,
            linkSafety: .enabled,
            animation: .none
        )
        .environment(\.streamdownTheme, .agentDockTranscript)
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
    }
}

private struct TranscriptActivityView: View {
    let event: TranscriptEvent
    let provider: TranscriptProvider

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isExpanded = false

    private var availabilityMessage: String? {
        switch event.availability(for: provider) {
        case .available:
            return nil
        case let .unavailable(message):
            return message
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: toggleExpanded) {
                HStack(spacing: 9) {
                    Image(systemName: iconName)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(iconColor)
                        .frame(width: 16)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        if let preview = previewText {
                            Text(preview)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    Spacer(minLength: 8)
                    Text(event.sourceType)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .accessibilityHidden(true)
                }
                .contentShape(Rectangle())
                .padding(.horizontal, 11)
                .padding(.vertical, 9)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(title), \(isExpanded ? "expanded" : "collapsed")")
            .accessibilityHint("Show or hide event details")

            if isExpanded {
                Divider().overlay(TranscriptPalette.border)
                TranscriptActivityDetail(
                    event: event,
                    provider: provider,
                    unavailableMessage: availabilityMessage
                )
                .padding(11)
            }
        }
        .background(backgroundColor, in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(borderColor)
        }
    }

    private func toggleExpanded() {
        if reduceMotion {
            isExpanded.toggle()
        } else {
            withAnimation(.easeInOut(duration: 0.16)) {
                isExpanded.toggle()
            }
        }
    }

    private var title: String {
        if let explicitTitle = event.title ?? event.name {
            return explicitTitle
        }
        return switch event.kind {
        case .reasoning: "Reasoning"
        case .toolCall: "Tool call"
        case .toolOutput: "Tool result"
        case .command: "Command"
        case .fileReference: "File reference"
        case .patch: "Changes"
        case .error: "Error"
        case .approval: "Approval"
        case .status: "Status"
        case .unsupported: "Unsupported record"
        case .malformed: "Malformed record"
        case .message: "Message"
        }
    }

    private var previewText: String? {
        availabilityMessage ?? event.text?.value
            .split(whereSeparator: \.isNewline)
            .first
            .map(String.init)
    }

    private var iconName: String {
        switch event.kind {
        case .reasoning: "brain"
        case .toolCall: "wrench.and.screwdriver"
        case .toolOutput: "checkmark.circle"
        case .command: "terminal"
        case .fileReference: "doc.text"
        case .patch: "plusminus"
        case .error: "exclamationmark.triangle"
        case .approval: "hand.raised"
        case .status: "clock"
        case .unsupported: "questionmark.diamond"
        case .malformed: "exclamationmark.bubble"
        case .message: "text.bubble"
        }
    }

    private var iconColor: Color {
        switch event.kind {
        case .error, .malformed: TranscriptPalette.error
        case .approval: TranscriptPalette.warning
        case .patch: TranscriptPalette.success
        default: .secondary
        }
    }

    private var backgroundColor: Color {
        event.kind == .error || event.kind == .malformed
            ? TranscriptPalette.error.opacity(0.07)
            : TranscriptPalette.activity
    }

    private var borderColor: Color {
        event.kind == .error || event.kind == .malformed
            ? TranscriptPalette.error.opacity(0.28)
            : TranscriptPalette.border
    }
}

private struct TranscriptActivityDetail: View {
    let event: TranscriptEvent
    let provider: TranscriptProvider
    let unavailableMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            if let unavailableMessage {
                Label(unavailableMessage, systemImage: "nosign")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let text = event.renderableText(for: provider) {
                ScrollView([.horizontal, .vertical]) {
                    Text(renderedValue(text))
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(event.kind == .error ? TranscriptPalette.error : .primary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: true, vertical: false)
                        .padding(.bottom, 2)
                }
                .frame(maxHeight: 320)
                TranscriptTruncationNotice(
                    text: text,
                    displayedByteCount: min(text.value.utf8.count, Self.renderLimit)
                )
                TranscriptCopyButton(text: text.value, label: "Copy event details")
            } else if unavailableMessage == nil {
                Text("No additional detail was recorded.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private static let renderLimit = 8 * 1024

    private func renderedValue(_ text: TranscriptText) -> String {
        guard !text.value.isEmpty else { return "No detail was recorded." }
        return TranscriptText(text.value, limit: Self.renderLimit).value
    }
}

private struct TranscriptTimestamp: View {
    let date: Date?

    var body: some View {
        if let date {
            Text(date.formatted(date: .omitted, time: .shortened))
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .accessibilityLabel("Sent at \(date.formatted(date: .omitted, time: .shortened))")
        }
    }
}

private struct TranscriptTruncationNotice: View {
    let text: TranscriptText
    var displayedByteCount: Int? = nil

    private var displayedCount: Int {
        displayedByteCount ?? text.value.utf8.count
    }

    var body: some View {
        if text.isTruncated || displayedCount < text.value.utf8.count {
            Text(
                "Showing \(displayedCount.formatted()) of "
                    + "\(text.originalByteCount.formatted()) bytes."
            )
            .font(.caption2)
            .foregroundStyle(.secondary)
            .accessibilityLabel(
                "Content truncated. Showing \(displayedCount) of "
                    + "\(text.originalByteCount) bytes."
            )
        }
    }
}

private struct TranscriptCopyButton: View {
    let text: String
    let label: String

    @State private var copied = false

    var body: some View {
        Button(action: copy) {
            Label(copied ? "Copied" : label, systemImage: copied ? "checkmark" : "doc.on.doc")
                .font(.caption2)
        }
        .buttonStyle(.plain)
        .foregroundStyle(copied ? TranscriptPalette.success : .secondary)
        .disabled(text.isEmpty)
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        copied = true
        Task {
            try? await Task.sleep(for: .seconds(2))
            copied = false
        }
    }
}

private struct TranscriptSkeleton: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            RoundedRectangle(cornerRadius: 10)
                .frame(maxWidth: 420)
                .frame(height: 82)
            RoundedRectangle(cornerRadius: 6)
                .frame(height: 18)
            RoundedRectangle(cornerRadius: 6)
                .frame(maxWidth: 520)
                .frame(height: 18)
            RoundedRectangle(cornerRadius: 8)
                .frame(height: 54)
        }
        .foregroundStyle(reduceTransparency ? TranscriptPalette.activity : .primary.opacity(0.07))
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(TranscriptPalette.background)
        .redacted(reason: .placeholder)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Loading conversation")
    }
}

private struct TranscriptTailRevision: Equatable {
    let id: TranscriptEvent.ID
    let originalByteCount: Int?
}

private struct TranscriptBottomPreferenceKey: PreferenceKey {
    static let defaultValue: CGFloat = .greatestFiniteMagnitude

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

private enum TranscriptPalette {
    static let background = Color(nsColor: .textBackgroundColor)
    static let userPrompt = Color.primary.opacity(0.055)
    static let activity = Color.primary.opacity(0.028)
    static let border = Color.primary.opacity(0.085)
    static let accent = Color(red: 0.32, green: 0.60, blue: 1)
    static let claude = Color(red: 0.82, green: 0.45, blue: 0.28)
    static let assistant = Color(red: 0.62, green: 0.53, blue: 0.96)
    static let success = Color(red: 0.33, green: 0.78, blue: 0.49)
    static let warning = Color(red: 0.96, green: 0.66, blue: 0.25)
    static let error = Color(red: 0.96, green: 0.35, blue: 0.35)
}

private extension StreamdownControls {
    static let agentDockTranscript = StreamdownControls(
        table: .init(enabled: true, copy: true, download: false, fullscreen: false),
        code: .init(enabled: true, copy: true, download: false, lineNumbers: false),
        mermaid: .init(
            enabled: false,
            copy: false,
            download: false,
            fullscreen: false,
            panZoom: false
        )
    )
}

private extension StreamdownTheme {
    static let agentDockTranscript = StreamdownTheme(
        spacing: .init(
            xxs: 2,
            xs: 4,
            sm: 7,
            md: 10,
            base: 14,
            lg: 20,
            minTouchTarget: 36
        ),
        colors: .init(
            background: .clear,
            foreground: .primary,
            secondaryBackground: TranscriptPalette.activity,
            tertiaryBackground: Color.primary.opacity(0.045),
            secondaryLabel: .secondary,
            tertiaryLabel: .secondary.opacity(0.78),
            mutedForeground: .secondary,
            border: TranscriptPalette.border,
            separator: TranscriptPalette.border,
            card: TranscriptPalette.activity
        ),
        fonts: .init(
            body: .body,
            caption: .caption,
            caption2: .caption2,
            callout: .callout,
            subheadline: .subheadline,
            mono: .system(.callout, design: .monospaced),
            monoSmall: .system(.caption, design: .monospaced)
        )
    )
}
