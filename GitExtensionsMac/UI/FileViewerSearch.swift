import AppKit

final class FileViewerSearchState {
    enum Direction { case next, previous }
    var query = "" { didSet { if !query.utf16.elementsEqual(oldValue.utf16) { currentMatch = nil; currentIndex = nil } } }
    var direction: Direction = .next
    var matchCase = false
    var wholeWord = false
    var highlightAll = false
    private(set) var text = ""
    private(set) var currentMatch: NSRange?
    private(set) var currentIndex: Int?
    private(set) var wrapped = false
    var scanRegion: NSRange?
    private(set) var highlightedRanges: [NSRange] = []

    func setText(_ value: String) {
        text = value
        currentMatch = nil
        currentIndex = nil
        scanRegion = nil
        highlightedRanges = []
        highlightAll = false
        wrapped = false
    }

    private static func upper(_ value: String) -> [UInt16] {
        var result: [UInt16] = []
        for scalar in value.unicodeScalars {
            let original = String(scalar)
            let upper = original.uppercased()
            result.append(contentsOf: (upper.unicodeScalars.count == 1 && upper.utf16.count == original.utf16.count ? upper : original).utf16)
        }
        return result
    }

    private static func alphanumeric(_ unit: UInt16) -> Bool {
        if unit == 95 { return true }
        guard let scalar = UnicodeScalar(unit) else { return false }
        switch scalar.properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter, .decimalNumber: return true
        default: return false
        }
    }

    func matches() -> [NSRange] {
        let source = Array(text.utf16), needle = Array(query.utf16)
        guard !needle.isEmpty, source.count >= needle.count else { return [] }
        let begin = min(scanRegion?.location ?? 0, source.count)
        let end = min(scanRegion.map(NSMaxRange) ?? source.count, source.count)
        guard end - begin >= needle.count else { return [] }
        func boundary(_ offset: Int) -> Bool {
            offset <= 0 || offset >= source.count || !Self.alphanumeric(source[offset - 1]) || !Self.alphanumeric(source[offset])
        }
        let target = matchCase ? needle : Self.upper(query)
        let searchSource = matchCase ? source : Self.upper(text)
        return (begin...(end - needle.count)).compactMap { offset in
            if wholeWord && (!boundary(offset) || !boundary(offset + needle.count)) { return nil }
            for i in needle.indices {
                let unit = searchSource[offset + i]
                if unit != target[i] { return nil }
            }
            return NSRange(location: offset, length: needle.count)
        }
    }

    @discardableResult
    func find(_ direction: Direction, caret: Int? = nil, viaKeyboard: Bool = false) -> NSRange? {
        self.direction = direction
        let position = caret ?? currentMatch.map(NSMaxRange) ?? 0
        if viaKeyboard, let region = scanRegion, position < region.location || position > NSMaxRange(region) { scanRegion = nil }
        let begin = scanRegion?.location ?? 0, end = scanRegion.map(NSMaxRange) ?? text.utf16.count
        var start = position - (direction == .previous ? 1 : 0)
        if start == -1 { start = end }
        start = min(max(start, begin), end)
        let ranges = matches()
        let first = direction == .next ? ranges.first { $0.location >= start }
            : ranges.last { NSMaxRange($0) <= start }
        wrapped = first == nil
        let result = first ?? (direction == .next ? ranges.first { NSMaxRange($0) <= start }
            : ranges.last { $0.location >= start })
        currentMatch = result
        currentIndex = result.flatMap { ranges.firstIndex(of: $0) }
        if highlightAll { markAll() }
        return result
    }

    @MainActor
    @discardableResult
    func findAcrossFiles(_ direction: Direction, caret: Int, viaKeyboard: Bool = false, allowsNavigation: Bool,
                         loadNext: ((Direction) async -> String?)?) async -> NSRange? {
        guard !query.isEmpty, !Task.isCancelled else { return nil }
        var result = find(direction, caret: caret, viaKeyboard: viaKeyboard)
        guard let loadNext, scanRegion == nil, wrapped else { return result }
        guard allowsNavigation else { currentMatch = nil; currentIndex = nil; return nil }
        var visited = Set<String>()
        while wrapped || result == nil {
            guard !Task.isCancelled else { return nil }
            let loadedIdentity = await loadNext(direction)
            guard !Task.isCancelled else { return nil }
            guard let identity = loadedIdentity, visited.insert(identity).inserted else {
                currentMatch = nil
                currentIndex = nil
                return nil
            }
            result = find(direction, caret: 0)
            if result != nil { return result }
        }
        return result
    }

    func markAll() {
        highlightAll = !query.isEmpty
        var end = 0
        highlightedRanges = matches().filter { range in
            guard range.location >= end else { return false }
            end = NSMaxRange(range)
            return true
        }
    }
}

@MainActor
final class FileViewerFindPanel: NSWindowController {
    private let state: FileViewerSearchState
    private let changed: () -> Void
    private let caret: () -> Int
    var loadNext: ((FileViewerSearchState.Direction) async -> String?)?
    private var searchTask: Task<Void, Never>?
    private let query = NSSearchField()
    private let matchCase = NSButton(checkboxWithTitle: "Match case", target: nil, action: nil)
    private let wholeWord = NSButton(checkboxWithTitle: "Match whole word", target: nil, action: nil)

    init(state: FileViewerSearchState, caret: @escaping () -> Int, changed: @escaping () -> Void) {
        self.state = state
        self.caret = caret
        self.changed = changed
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 470, height: 140), styleMask: [.titled, .closable, .utilityWindow], backing: .buffered, defer: false)
        panel.title = "Find"
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = true
        super.init(window: panel)
        let next = NSButton(title: "Find next", target: self, action: #selector(findNext))
        next.keyEquivalent = "\r"
        let previous = NSButton(title: "Find previous", target: self, action: #selector(findPrevious))
        let all = NSButton(title: "Find & highlight all", target: self, action: #selector(findAll))
        let stack = NSStackView(views: [NSStackView(views: [NSTextField(labelWithString: "Find what:"), query]), NSStackView(views: [matchCase, wholeWord]), NSStackView(views: [all, previous, next])])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        let root = NSView()
        root.addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12), stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12), stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 12), stack.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -12), query.widthAnchor.constraint(greaterThanOrEqualToConstant: 330)])
        panel.contentView = root
    }

    required init?(coder: NSCoder) { nil }

    func present(owner: NSWindow?, selection: NSRange? = nil) {
        if let selection, selection.length > 0, NSMaxRange(selection) <= state.text.utf16.count {
            let selected = (state.text as NSString).substring(with: selection)
            if selected.contains("\n") { state.scanRegion = selection }
            else { state.query = selected; state.scanRegion = nil }
        }
        query.stringValue = state.query
        matchCase.state = state.matchCase ? .on : .off
        wholeWord.state = state.wholeWord ? .on : .off
        if let owner, let window {
            window.setFrameTopLeftPoint(Self.origin(ownerFrame: owner.frame))
            owner.addChildWindow(window, ordered: .above)
        }
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(query)
    }

    static func origin(ownerFrame: NSRect) -> NSPoint {
        NSPoint(x: ownerFrame.minX + 100, y: ownerFrame.maxY - 100)
    }

    private func update() {
        state.query = query.stringValue
        state.matchCase = matchCase.state == .on
        state.wholeWord = wholeWord.state == .on
    }

    @objc private func findNext() { find(.next) }
    @objc private func findPrevious() { find(.previous) }
    private func find(_ direction: FileViewerSearchState.Direction) {
        update()
        perform(direction, viaKeyboard: false)
    }
    func perform(_ direction: FileViewerSearchState.Direction, viaKeyboard: Bool) {
        searchTask?.cancel()
        let start = caret()
        let navigates = window?.isVisible == true
        searchTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let result = await state.findAcrossFiles(direction, caret: start, viaKeyboard: viaKeyboard, allowsNavigation: navigates, loadNext: loadNext)
            guard !Task.isCancelled else { return }
            if result == nil { inform(state.query.isEmpty ? "No string specified to look for!" : "Text not found") }
            changed()
        }
    }

    override func close() { searchTask?.cancel(); super.close() }
    override func cancelOperation(_ sender: Any?) { close() }

    @objc private func findAll() {
        update()
        state.markAll()
        changed()
        if !state.highlightedRanges.isEmpty { window?.orderOut(nil) } else if !state.query.isEmpty { inform("No occurrences found.") }
    }

    private func inform(_ message: String) {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = message
        alert.addButton(withTitle: "OK")
        if let window, window.isVisible { alert.beginSheetModal(for: window) } else { alert.runModal() }
    }
}
