import GitExtensionsCore
import GitCommands
import AppKit

struct CommitMessageEditorPreferences: Codable, Equatable, Sendable {
    var stageInSuperprojectAfterCommit = true
    var markIllFormedLines = true
    var showsSelectionFilter = false
    var messageEditorWordWrap = false

    init() {}

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = CommitMessageEditorPreferences()
        stageInSuperprojectAfterCommit = try values.decodeIfPresent(Bool.self, forKey: .stageInSuperprojectAfterCommit) ?? defaults.stageInSuperprojectAfterCommit
        markIllFormedLines = try values.decodeIfPresent(Bool.self, forKey: .markIllFormedLines) ?? defaults.markIllFormedLines
        showsSelectionFilter = try values.decodeIfPresent(Bool.self, forKey: .showsSelectionFilter) ?? defaults.showsSelectionFilter
        messageEditorWordWrap = try values.decodeIfPresent(Bool.self, forKey: .messageEditorWordWrap) ?? defaults.messageEditorWordWrap
    }
}

enum CommitWordWrapper {
    static let defaultBodyLineLimit = 72

    static func bodyLineLimit(configured: Int) -> Int {
        configured > 0 ? configured : defaultBodyLineLimit
    }

    static func wrapSingleLine(_ text: String, limit: Int) -> String {
        var lines: [String] = []
        var words: [String] = []
        var wordsLength = 0
        for word in splitOnWhitespace(text) {
            let newLength = wordsLength + words.count + word.utf16.count
            if !(newLength < limit || words.isEmpty) {
                lines.append(words.joined(separator: " "))
                words = []
                wordsLength = 0
            }
            words.append(word)
            wordsLength += word.utf16.count
        }
        if !words.isEmpty { lines.append(words.joined(separator: " ")) }
        return lines.joined(separator: "\n")
    }

    static func wrapBody(_ message: String, limit: Int) -> String {
        var lines = message.components(separatedBy: "\n")
        var index = 1
        while index < lines.count {
            let line = lines[index]
            if line.utf16.count > limit {
                let wrapped = wrapSingleLine(line, limit: limit)
                if wrapped != line {
                    lines.replaceSubrange(index...index, with: wrapped.components(separatedBy: "\n"))
                }
            }
            index += 1
        }
        return lines.joined(separator: "\n")
    }

    private static func splitOnWhitespace(_ text: String) -> [String] {
        var parts: [String] = []
        var current = ""
        for character in text {
            if character.isWhitespace {
                parts.append(current)
                current = ""
            } else {
                current.append(character)
            }
        }
        parts.append(current)
        return parts
    }
}

enum CommitMessageMarkup {
    static let illFormedMarkColor = NSColor(srgbRed: 1, green: 1, blue: 0, alpha: 120.0 / 255.0)
    static let overLimitColor = NSColor.systemRed

    static func illFormedRanges(in text: String) -> [NSRange] {
        var ranges: [NSRange] = []
        var location = 0
        for (index, line) in text.components(separatedBy: "\n").enumerated() {
            let length = line.utf16.count
            let maximum = index == 0 ? 50 : index == 1 ? 0 : 72
            if length > maximum {
                ranges.append(NSRange(location: location + maximum, length: length - maximum))
            }
            location += length + 1
        }
        return ranges
    }

    static func marksBlankFirstLine(_ text: String) -> Bool {
        (text as NSString).length > 1 && text.components(separatedBy: "\n").first?.isEmpty == true
    }

    static func overLimitRanges(in text: String, firstLineLimit: Int, bodyLineLimit: Int, secondLineMustBeEmpty: Bool) -> [NSRange] {
        var ranges: [NSRange] = []
        var location = 0
        let firstBodyLine = secondLineMustBeEmpty ? 2 : 1
        for (index, line) in text.components(separatedBy: "\n").enumerated() {
            let length = line.utf16.count
            let limit: Int
            if index == 0 {
                limit = firstLineLimit
            } else if index >= firstBodyLine {
                limit = bodyLineLimit
            } else {
                limit = 0
            }
            if limit > 0, length > limit {
                ranges.append(NSRange(location: location + limit, length: length - limit))
            }
            location += length + 1
        }
        return ranges
    }
}

enum ConventionalCommitPrefixer {
    static let feat = "feat"
    static let headerCommitTypes = ["build", "chore", "ci", "docs", feat, "fix", "perf", "refactor", "style", "test"]
    static let footerKeywords = ["BREAKING CHANGE", "Co-authored-by", "Reviewed-by"]

    static func prefixOrReplace(keyword: String, message: String, selectionStart currentPosition: Int, insertScope: Bool) -> (title: String, selectionStart: Int) {
        let keywordLength = keyword.utf16.count
        let scope = insertScope ? "()" : ""
        let scopePosition = keywordLength + 1
        let titlePosition = keywordLength + scope.utf16.count / 2 + 2
        let messageLength = message.utf16.count
        let currentTitle = message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? ""
            : String(message.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first ?? "")
        let titleUnits = Array(currentTitle.utf16)

        for key in headerCommitTypes {
            let keyUnits = Array(key.utf16)
            guard titleUnits.starts(with: keyUnits) else { continue }
            if titleUnits.count == keyUnits.count {
                return ("\(keyword)\(scope): ", insertScope ? scopePosition : titlePosition)
            }
            let remainder = String(utf16CodeUnits: Array(titleUnits[keyUnits.count...]), count: titleUnits.count - keyUnits.count)
            let nextCharacter = titleUnits[keyUnits.count]
            func replaceKeyword(_ maximumPosition: (String) -> Int) -> (String, Int) {
                let newTitle = keyword + remainder
                let newMessageLength = messageLength + newTitle.utf16.count - titleUnits.count
                return (newTitle, min(newMessageLength, max(maximumPosition(newTitle), currentPosition + keywordLength - keyUnits.count)))
            }
            if !insertScope {
                if nextCharacter == UInt16(UInt8(ascii: ":")) || nextCharacter == UInt16(UInt8(ascii: "(")) || nextCharacter == UInt16(UInt8(ascii: "!")) {
                    return replaceKeyword { _ in titlePosition }
                }
            } else {
                if nextCharacter == UInt16(UInt8(ascii: ":")) || nextCharacter == UInt16(UInt8(ascii: "!")) {
                    return ("\(keyword)()\(remainder)", scopePosition)
                }
                if nextCharacter == UInt16(UInt8(ascii: "(")) {
                    return replaceKeyword { newTitle in
                        2 + max(utf16Index(of: ":", in: newTitle), utf16Index(of: "(", in: newTitle))
                    }
                }
            }
        }
        return ("\(keyword)\(scope): \(currentTitle)", insertScope ? scopePosition : titlePosition + currentPosition)
    }

    static func apply(keyword: String, message: String, selectionStart: Int, insertScope: Bool) -> (message: String, selectionStart: Int) {
        let (title, position) = prefixOrReplace(keyword: keyword, message: message, selectionStart: selectionStart, insertScope: insertScope)
        guard !message.isEmpty else { return (title, position) }
        var lines = message.components(separatedBy: "\n")
        lines[0] = title
        return (lines.joined(separator: "\n"), position)
    }

    static func appendFooter(_ text: String, to message: String) -> String {
        message.isEmpty ? "\n\(text)" : "\(message)\n\(text)"
    }

    private static func utf16Index(of character: Character, in text: String) -> Int {
        guard let index = text.firstIndex(of: character) else { return -1 }
        return text.utf16.distance(from: text.utf16.startIndex, to: index)
    }
}

enum CommitSelectionFilter {
    static let historyLimit = 10
    static let throttle: Duration = .milliseconds(250)
    static let toolTip = "Enter a regular expression to select unstaged files."
    static let title = "Selection Filter"

    static func errorToolTip(_ error: Error) -> String {
        "Error \(error.localizedDescription)"
    }

    static func matchingPaths(_ paths: [String], pattern: String) throws -> [String] {
        guard !pattern.isEmpty else { return paths }
        let expression = try NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
        return paths.filter { path in
            expression.firstMatch(in: path, range: NSRange(path.startIndex..<path.endIndex, in: path)) != nil
        }
    }

    static func history(_ history: [String], adding filter: String) -> [String] {
        guard !filter.isEmpty, !history.contains(filter) else { return history }
        var result = history
        while result.count >= historyLimit { result.remove(at: historyLimit - 1) }
        result.insert(filter, at: 0)
        return result
    }
}

@MainActor
final class CommitSelectionFilterThrottle {
    private let delay: Duration
    private var pending: Task<Void, Never>?

    init(delay: Duration = CommitSelectionFilter.throttle) {
        self.delay = delay
    }

    func submit(_ value: String, perform: @escaping @MainActor (String) -> Void) {
        pending?.cancel()
        let delay = delay
        pending = Task { @MainActor in
            do { try await Task.sleep(for: delay) } catch { return }
            guard !Task.isCancelled else { return }
            perform(value)
        }
    }

    func cancel() {
        pending?.cancel()
        pending = nil
    }
}

enum CommitAuthorStatus {
    static let settingsPage = "git_config"
    static let toolTip = "Click to change committer information."

    static func text(committer: String?, author: String) -> String {
        guard let committer else { return "Loading author…" }
        let committerText = "Committer \(committer)"
        return author.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? committerText : "\(committerText) Author \(author)"
    }
}

enum CommitSuperprojectStaging {
    static let title = "Stage in Superproject"
    static let toolTip = "Stage current submodule in superproject after commit"

    static func target(location: RepositorySuperprojectSubmodule?, preference: Bool) -> RepositorySuperprojectSubmodule? {
        guard preference, let location, !location.path.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return location
    }

    static func shouldStage(target: RepositorySuperprojectSubmodule?, pushRequested: Bool, pushCompleted: Bool) -> Bool {
        target != nil && (!pushRequested || pushCompleted)
    }
}

struct CommitWordAtCursorExtractor {
    func extract(_ text: String, index: Int) -> String {
        let units = Array(text.utf16)
        let start = findStartOfWord(units, index: index)
        guard start >= 0, index >= start, index < units.count else { return "" }
        return String(utf16CodeUnits: Array(units[start...index]), count: index - start + 1)
    }

    func wordBounds(_ text: String, index: Int) -> (start: Int, length: Int) {
        let units = Array(text.utf16)
        let start = min(findStartOfWord(units, index: index), index)
        guard start >= 0 else { return (0, 0) }
        let end = findEndOfWord(units, index: index)
        return (start, max(1, end - start))
    }

    func findStartOfWord(_ text: String, index: Int) -> Int { findStartOfWord(Array(text.utf16), index: index) }
    func findEndOfWord(_ text: String, index: Int) -> Int { findEndOfWord(Array(text.utf16), index: index) }

    func completionRange(in text: String, caret: Int) -> NSRange {
        let units = Array(text.utf16)
        let start = findStartOfWord(units, index: caret - 1)
        guard start >= 0, start <= caret else { return NSRange(location: caret, length: 0) }
        return NSRange(location: start, length: caret - start)
    }

    private func findStartOfWord(_ text: [UInt16], index: Int) -> Int {
        var index = min(index, text.count - 1)
        guard index >= 0 else { return -1 }
        while index >= 0 && belongsToStartOfWord(text, index) { index -= 1 }
        return index + 1
    }

    private func findEndOfWord(_ text: [UInt16], index: Int) -> Int {
        var index = min(index, text.count)
        guard index >= 0 else { return -1 }
        while index < text.count && Self.belongsToWord(text[index]) { index += 1 }
        return index
    }

    private func belongsToStartOfWord(_ text: [UInt16], _ index: Int) -> Bool {
        text[index] == UInt16(UInt8(ascii: ".")) ? isLeadingCharacter(text, index) : Self.belongsToWord(text[index])
    }

    private func isLeadingCharacter(_ text: [UInt16], _ index: Int) -> Bool {
        index == 0 || isSeparatorExceptClosingBrackets(text[index - 1])
    }

    private func isSeparatorExceptClosingBrackets(_ unit: UInt16) -> Bool {
        unit != UInt16(UInt8(ascii: ")")) && unit != UInt16(UInt8(ascii: "]")) && Self.isSeparator(unit)
    }

    private static func belongsToWord(_ unit: UInt16) -> Bool { !isSeparator(unit) }

    static func isSeparator(_ unit: UInt16) -> Bool {
        if unit == UInt16(UInt8(ascii: "_")) || unit == UInt16(UInt8(ascii: "+")) || unit == UInt16(UInt8(ascii: "-")) { return false }
        guard let scalar = Unicode.Scalar(unit) else { return true }
        switch scalar.properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter, .decimalNumber:
            return false
        default:
            return true
        }
    }
}

struct CommitAutoCompleteWord: Hashable, Sendable {
    let word: String
    private let camelHumps: String

    init(_ word: String) {
        self.word = word
        camelHumps = String(word.filter { $0.isUppercase })
    }

    func matches(_ typed: String) -> Bool {
        word.lowercased().hasPrefix(typed.lowercased()) || camelHumps.lowercased().hasPrefix(typed.lowercased())
    }
}

enum CommitAutoCompleteRegexes {
    static let metadataKeywords = [
        "Co-authored-by: ",
        "Signed-off-by: ",
        "BREAKING CHANGE: ",
        "Reviewed-by: ",
        "Tested-by: "
    ]

    static let defaultDefinitions = #"""
.asm = ^([\w]+):
.au3, .auh = Func\s+([\w]+)|\$([\w]+)
.bas, .frm, .cls = ^\s*(?:(?:Public (?:Default )?|Private )?(?:Sub|Function|Property Get|Property Set|Property Let) ?)(\w+)\(|^Attribute VB_Name = "(\w+)"
.bat = ^\:(\w+)|^set\s+(\w+)
.build = \sname\s*=\s*\"(\w+)\"
.cbl, .cpy = ^.{6} ([A-Z][A-Z0-9-]*)(?: SECTION)?\.
.c, .cc, .cpp, .cxx = \s(?:[\w]+)::([\w]+)|[ \t:.>]([\w]+)\s?\([\w\s,.)]*\);|^#\s*define\s+(\w+)
.asp, .aspx, .cs = (?:(?:(?:public|protected|private|internal)\s+(?:[\w.]+(?:\s*<[<>\w\s.,]+>)?\s+)*([\w.]+)(?:\s*<[<>\w\s.,]+>)?)|(?:namespace\s+([\w.]+))|(?:new\s+([\w]+))|(?:using\s+([\w.]+)))
.h, .hpp, .hxx = ^\s*(?:class|struct)\s+([\w]+)|^\s+(?:\w+\s+)*([\w]+)\s*\(|^#define\s+(\w+)
.html = \"#(\w+)\"
.java, .groovy = (?:public|protected|private|internal)\s+(?:[\w.]+\s+)*([\w.]+)|class\s+([\w]+)(?:(?:\s+)?(?:extends|implements)(?:\s+)?([\w]+)?)
.js = (?:(?:prototype\.|this\.)(\w+)\s*=\s*)?function\s*(?:(\w*)\s*)\(
.pas = (\w+)\s+=\s+(?:class|record|interface)|(?:procedure|function|property|constructor)\s+(\w+)
.php = ^\s*class\s+(\w+)|^\s*(?:(?:public|private)?\s+function)\s+(\w+)|::(\w+)|->(\w+)
.cgi, .pl, .pm = ^\s*sub\s+(\w+)|\s*(?:package|use)\s+([\w\:]+)
.ps1 = ^\s*(?:function)\s+(\w+[\w\-]*)
.py, .pyw, .rb = ^\s*(?:class|def)\s+(\w+)
.sd = ^\s*(?:procedure|function)\s+(\w+)
.vb, .vb6 = (?:class|function|sub)\s+(\w+)(?:\s*(?:[\(\']|$))
.xaml = \sname\s*=\s*\"(\w+)\"
"""#

    static var overrideFileURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("GitExtensionsMac", isDirectory: true)
            .appendingPathComponent("AutoCompleteRegexes.txt")
    }

    @MainActor private static var cached: [String: NSRegularExpression]?

    @MainActor static var regexes: [String: NSRegularExpression] {
        if let cached { return cached }
        let loaded = load(overrideURL: overrideFileURL)
        cached = loaded
        return loaded
    }

    static func load(overrideURL: URL) -> [String: NSRegularExpression] {
        if let text = try? String(contentsOf: overrideURL, encoding: .utf8) {
            return parse(text.components(separatedBy: .newlines))
        }
        return parse(defaultDefinitions.components(separatedBy: .newlines).filter { !$0.isEmpty })
    }

    static func parse(_ lines: [String]) -> [String: NSRegularExpression] {
        var result: [String: NSRegularExpression] = [:]
        for line in lines {
            guard let separator = line.firstIndex(of: "=") else { continue }
            let pattern = line[line.index(after: separator)...].trimmingCharacters(in: .whitespaces)
            guard let expression = try? NSRegularExpression(pattern: pattern) else { continue }
            var seen = Set<String>()
            for extensionName in line[..<separator].split(separator: ",", omittingEmptySubsequences: false)
                .map({ $0.trimmingCharacters(in: .whitespaces) }) where seen.insert(extensionName).inserted {
                if result[extensionName] == nil { result[extensionName] = expression }
            }
        }
        return result
    }

    static func fileExtension(_ path: String) -> String {
        let name = (path as NSString).lastPathComponent
        guard let dot = name.lastIndex(of: "."), name.index(after: dot) != name.endIndex else { return "" }
        return String(name[dot...])
    }

    static func fileNameWithoutExtension(_ path: String) -> String {
        let name = (path as NSString).lastPathComponent
        guard let dot = name.lastIndex(of: ".") else { return name }
        return String(name[..<dot])
    }

    static func captures(in text: String, expression: NSRegularExpression) -> [String] {
        let source = text as NSString
        var words: [String] = []
        for match in expression.matches(in: text, range: NSRange(location: 0, length: source.length)) {
            guard match.numberOfRanges > 1 else { continue }
            for group in 1..<match.numberOfRanges {
                let range = match.range(at: group)
                if range.location != NSNotFound { words.append(source.substring(with: range)) }
            }
        }
        return words
    }

    static func patchText(path: String, diff: FileDiff?) -> String {
        guard let diff else { return "" }
        var lines: [String] = []
        if diff.lines.first?.kind != .header { lines.append("diff --git a/\(path) b/\(path)") }
        for line in diff.lines {
            switch line.kind {
            case .header, .hunk: lines.append(line.text)
            case .context: lines.append(" " + line.text)
            case .addition: lines.append("+" + line.text)
            case .deletion: lines.append("-" + line.text)
            }
        }
        return lines.joined(separator: "\n")
    }

    static func contentText(diff: FileDiff?) -> String {
        guard let diff else { return "" }
        return diff.lines.filter { $0.kind == .addition || $0.kind == .context }.map(\.text).joined(separator: "\n")
    }

    static func collectWords(files: [(file: ChangedFile, kind: Commit.Kind)], regexes: [String: NSRegularExpression],
                             loadDiff: (ChangedFile, Commit.Kind) async -> FileDiff?) async -> [String] {
        var words = Set<String>()
        for (file, kind) in files {
            if Task.isCancelled { return [] }
            var text: String?
            if !file.isSubmodule, regexes[fileExtension(file.path)] != nil {
                let diff = await loadDiff(file, kind)
                let untracked = !file.isTracked || (kind == .workingDirectory && file.changeType == .added)
                text = untracked ? contentText(diff: diff) : patchText(path: file.path, diff: diff)
            }
            words.formUnion(self.words(for: file, text: text, regexes: regexes))
        }
        return words.filter { !$0.isEmpty }.sorted()
    }

    static func words(for file: ChangedFile, text: String?, regexes: [String: NSRegularExpression]) -> [String] {
        var words = [(file.path as NSString).lastPathComponent]
        if file.isSubmodule { return words }
        if let expression = regexes[fileExtension(file.path)], let text {
            words += captures(in: text, expression: expression)
        }
        words.append(fileNameWithoutExtension(file.path))
        if let oldPath = file.oldPath, !oldPath.trimmingCharacters(in: .whitespaces).isEmpty {
            words.append(fileNameWithoutExtension(oldPath))
            words.append((oldPath as NSString).lastPathComponent)
        }
        return words
    }
}

final class CommitMessageTextView: NSTextView {
    var illFormedRanges: [NSRange] = [] { didSet { if illFormedRanges != oldValue { needsDisplay = true } } }
    var marksBlankFirstLine = false { didSet { if marksBlankFirstLine != oldValue { needsDisplay = true } } }
    var overLimitRanges: [NSRange] = []
    var onStringAssigned: (() -> Void)?
    private let wordExtractor = CommitWordAtCursorExtractor()

    @objc func deleteSelectedMessageText(_ sender: Any?) {
        guard isEditable, selectedRange().length > 0 else { return }
        insertText("", replacementRange: selectedRange())
    }

    override var string: String {
        get { super.string }
        set {
            super.string = newValue
            onStringAssigned?()
        }
    }

    func setSoftWrap(_ enabled: Bool) {
        guard let textContainer else { return }
        isHorizontallyResizable = !enabled
        textContainer.widthTracksTextView = enabled
        let width = enabled ? max(1, (enclosingScrollView?.contentSize.width ?? bounds.width) - textContainerInset.width * 2) : CGFloat.greatestFiniteMagnitude
        textContainer.containerSize = NSSize(width: width, height: CGFloat.greatestFiniteMagnitude)
        if enabled { setFrameSize(NSSize(width: enclosingScrollView?.contentSize.width ?? bounds.width, height: frame.height)) }
    }

    override var rangeForUserCompletion: NSRange {
        let caret = selectedRange().location
        guard caret != NSNotFound else { return super.rangeForUserCompletion }
        return wordExtractor.completionRange(in: string, caret: caret)
    }

    func applyOverLimitRanges(_ ranges: [NSRange]) {
        guard let layoutManager else { return }
        let length = (string as NSString).length
        layoutManager.removeTemporaryAttribute(.foregroundColor, forCharacterRange: NSRange(location: 0, length: length))
        overLimitRanges = ranges.filter { NSMaxRange($0) <= length }
        for range in overLimitRanges {
            layoutManager.addTemporaryAttribute(.foregroundColor, value: CommitMessageMarkup.overLimitColor, forCharacterRange: range)
        }
    }

    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        guard let layoutManager, let textContainer else { return }
        let length = (string as NSString).length
        let origin = textContainerOrigin
        CommitMessageMarkup.illFormedMarkColor.setFill()
        for range in illFormedRanges where NSMaxRange(range) <= length {
            let glyphs = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            layoutManager.enumerateEnclosingRects(forGlyphRange: glyphs, withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0),
                                                  in: textContainer) { enclosing, _ in
                enclosing.offsetBy(dx: origin.x, dy: origin.y).fill(using: .sourceOver)
            }
        }
        if marksBlankFirstLine, layoutManager.numberOfGlyphs > 0 {
            let line = layoutManager.lineFragmentRect(forGlyphAt: 0, effectiveRange: nil)
            NSRect(x: 0, y: line.minY + origin.y, width: bounds.width, height: line.height).fill(using: .sourceOver)
        }
    }
}

final class CommitAuthorStatusButton: NSButton {
    private var hovering = false { didSet { updateTitle() } }
    private var trackingAreaReference: NSTrackingArea?
    private var text = ""

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isBordered = false
        setButtonType(.momentaryChange)
        alignment = .left
        lineBreakMode = .byTruncatingTail
        toolTip = CommitAuthorStatus.toolTip
        setAccessibilityRole(.link)
    }

    required init?(coder: NSCoder) { nil }

    var statusText: String {
        get { text }
        set { text = newValue; updateTitle() }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingAreaReference { removeTrackingArea(trackingAreaReference) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingAreaReference = area
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }

    private func updateTitle() {
        var attributes: [NSAttributedString.Key: Any] = [
            .foregroundColor: NSColor.linkColor,
            .font: font ?? AppSettingsStore.shared.applicationFont(size: 11)
        ]
        if hovering { attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue }
        attributedTitle = NSAttributedString(string: text, attributes: attributes)
    }
}

