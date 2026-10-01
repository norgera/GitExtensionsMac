import AppKit
import GitCommands



@MainActor
enum OutputHistoryRecording {
    static func perform<T>(_ operation: () async throws -> T) async rethrows -> T {
        try await ProcessOutputHistory.recording.withValue(true, operation: operation)
    }
}

@MainActor
final class OutputHistoryViewController: NSViewController {
    let textView = OutputHistoryTextView()
    private let journal: CommandLog
    private var observer: UUID?
    private var preferencesObserver: NSObjectProtocol?

    init(journal: CommandLog = .shared) {
        self.journal = journal
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { nil }
    deinit {
        if let observer { journal.removeOutputHistoryObserver(observer) }
        if let preferencesObserver { NotificationCenter.default.removeObserver(preferencesObserver) }
    }
    override func loadView() {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = true
        scroll.borderType = .bezelBorder
        textView.isEditable = false; textView.isSelectable = true; textView.isRichText = false
        textView.setAccessibilityIdentifier("OutputHistory.text")
        textView.isVerticallyResizable = true; textView.isHorizontallyResizable = true
        textView.autoresizingMask = [.width]
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = false
        textView.textContainerInset = NSSize(width: 6, height: 6)
        textView.onClear = { [weak self] in self?.journal.clearOutputHistory() }
        scroll.documentView = textView
        view = scroll
        observer = journal.observeOutputHistory { [weak self] in Task { @MainActor in self?.reload() } }
        preferencesObserver = NotificationCenter.default.addObserver(forName: .appPreferencesDidChange, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.applyFont() }
        }
        applyFont(); reload()
    }
    private func applyFont() {
        textView.font = AppSettingsStore.shared.fontPreferences.font(.monospace, fallback: .monospacedSystemFont(ofSize: 11, weight: .regular))
    }
    func reload() {
        textView.string = Self.format(journal.outputHistorySnapshot())
        if let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) {
            let range = NSRange(location: 0, length: textView.string.utf16.count)
            for match in detector.matches(in: textView.string, range: range) {
                if let url = match.url { textView.textStorage?.addAttribute(.link, value: url, range: match.range) }
            }
        }
        textView.sizeToFit()
        textView.setSelectedRange(NSRange(location: textView.string.utf16.count, length: 0))
        textView.scrollToEndOfDocument(nil)
    }
    static func format(_ records: [ProcessOutputRecord]) -> String {
        records.map { record in
            let time = DateFormatter.localizedString(from: record.finishedAt, dateStyle: .none, timeStyle: .short)

            let output = record.output.replacingOccurrences(of: #"\x1B\[[0-?]*[ -/]*[@-~]"#, with: "", options: .regularExpression)
                .replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
                .replacingOccurrences(of: "\u{000B}", with: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            return "\(time) \(record.command.commandLine)\n\(output)\n\n"
        }.joined() + "###\n"
    }
    func focus() { view.window?.makeFirstResponder(textView) }
}

@MainActor
final class OutputHistoryTextView: NSTextView {
    var onClear: (() -> Void)?
    var copyContent: String {
        let range = selectedRange()
        return range.length == 0 ? string : (string as NSString).substring(with: range)
    }
    override func copy(_ sender: Any?) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(copyContent, forType: .string)
    }
    override func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(copy(_:)) { return !string.isEmpty }
        return super.validateMenuItem(menuItem)
    }
    @objc private func clearHistory(_ sender: Any?) { onClear?() }
    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        let copy = menu.addItem(withTitle: "Copy", action: #selector(copy(_:)), keyEquivalent: "c")
        copy.keyEquivalentModifierMask = .command; copy.target = self
        menu.addItem(withTitle: "Clear", action: #selector(clearHistory(_:)), keyEquivalent: "").target = self
        return menu
    }
}
