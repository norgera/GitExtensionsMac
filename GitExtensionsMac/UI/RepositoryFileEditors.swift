import GitExtensionsCore
import GitCommands
import AppKit

enum FileViewerTextLines {
    static func starts(in text: String) -> [Int] {
        let value = text as NSString
        var starts = [0]
        var offset = 0
        while offset < value.length {
            var end = 0
            var contentsEnd = 0
            value.getLineStart(nil, end: &end, contentsEnd: &contentsEnd, for: NSRange(location: offset, length: 0))
            if end > contentsEnd { starts.append(end) }
            offset = end
        }
        return starts
    }
}

final class FileViewerLineNumberRuler: NSRulerView {
    private weak var textView: NSTextView?
    private var observers: [NSObjectProtocol] = []
    private(set) var lineStarts = [0]
    private var thicknessUpdatePending = false

    init(scrollView: NSScrollView, textView: NSTextView) {
        self.textView = textView
        super.init(scrollView: scrollView, orientation: .verticalRuler)
        clientView = textView
        observers.append(NotificationCenter.default.addObserver(forName: NSTextStorage.didProcessEditingNotification, object: textView.textStorage, queue: .main) { [weak self] notification in
            MainActor.assumeIsolated {
                if (notification.object as? NSTextStorage)?.editedMask.contains(.editedCharacters) == true { self?.refresh() }
                else { self?.needsDisplay = true }
            }
        })
        observers.append(NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: scrollView.contentView, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.needsDisplay = true }
        })
        scrollView.contentView.postsBoundsChangedNotifications = true
        refresh()
    }

    required init(coder: NSCoder) { fatalError() }

    deinit { for observer in observers { NotificationCenter.default.removeObserver(observer) } }

    override var isFlipped: Bool { true }

    func refresh() {
        guard let textView else { return }
        lineStarts = FileViewerTextLines.starts(in: textView.string)
        needsDisplay = true
        guard !thicknessUpdatePending else { return }
        thicknessUpdatePending = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            thicknessUpdatePending = false
            guard let textView = self.textView else { return }
            let font = textView.font ?? AppSettingsStore.shared.codeFont
            let thickness = max(32, ceil((String(lineStarts.count) as NSString).size(withAttributes: [.font: font]).width) + 14)
            if ruleThickness != thickness { ruleThickness = thickness }
        }
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let textView, let layout = textView.layoutManager, let container = textView.textContainer else { return }
        ApplicationColors.color("EditorBackground", fallback: .textBackgroundColor).setFill()
        bounds.fill()
        let visible = textView.visibleRect.offsetBy(dx: -textView.textContainerOrigin.x, dy: -textView.textContainerOrigin.y)
        let glyphs = layout.glyphRange(forBoundingRect: visible, in: container)
        let characters = layout.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        var low = 0
        var high = lineStarts.count
        while low < high {
            let middle = (low + high) / 2
            if lineStarts[middle] <= characters.location { low = middle + 1 } else { high = middle }
        }
        let font = textView.font ?? AppSettingsStore.shared.codeFont
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.secondaryLabelColor]
        for index in max(0, low - 1)..<lineStarts.count {
            let start = lineStarts[index]
            if start > NSMaxRange(characters) { break }
            let fragment: NSRect
            if start < (textView.textStorage?.length ?? 0) {
                let glyph = layout.glyphIndexForCharacter(at: start)
                fragment = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            } else {
                fragment = layout.extraLineFragmentRect
            }
            let point = convert(NSPoint(x: textView.textContainerOrigin.x, y: fragment.minY + textView.textContainerOrigin.y), from: textView)
            let label = String(index + 1) as NSString
            let size = label.size(withAttributes: attributes)
            label.draw(at: NSPoint(x: ruleThickness - size.width - 7, y: point.y), withAttributes: attributes)
        }
    }

    static func install(on scrollView: NSScrollView, textView: NSTextView) {
        scrollView.verticalRulerView = FileViewerLineNumberRuler(scrollView: scrollView, textView: textView)
        scrollView.hasVerticalRuler = true
        scrollView.rulersVisible = true
    }
}


final class EditableFileTextView: NSView, NSTextViewDelegate {
    let textView = EditorTextView(frame: .zero)
    private let scrollView = NSScrollView()
    private(set) var viewerToolbar: DiffViewerToolbar?
    private(set) var viewerPreferences = AppSettingsStore.shared.preferencesForNewFileViewer()
    private var resolvedViewerEncoding: RepositoryTextEncoding?
    var onTextChanged: (() -> Void)?
    var syntaxPath: String? { didSet { updateHighlighting() } }
    var commentSetting = "#" { didSet { updateHighlighting() } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.smartInsertDeleteEnabled = false
        textView.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        textView.textColor = .textColor
        textView.backgroundColor = .textBackgroundColor
        textView.delegate = self
        NotificationCenter.default.addObserver(self, selector: #selector(updateHighlighting), name: .fileViewerSettingsApplied, object: AppSettingsStore.shared)
        NotificationCenter.default.addObserver(self, selector: #selector(updateHighlighting), name: .appPreferencesDidChange, object: AppSettingsStore.shared)

        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = true
        textView.autoresizingMask = [.width, .height]
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        scrollView.documentView = textView
        FileViewerLineNumberRuler.install(on: scrollView, textView: textView)
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.borderType = .bezelBorder
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    required init?(coder: NSCoder) { nil }

    func enableViewerToolbar(resolvedEncoding: RepositoryTextEncoding? = nil) {
        if let resolvedEncoding { resolvedViewerEncoding = resolvedEncoding }
        if viewerToolbar == nil {
            let toolbar = DiffViewerToolbar(preferences: viewerPreferences)
            toolbar.configure(for: .text)
            toolbar.isHidden = false
            toolbar.onAction = { [weak self] action, state in self?.performViewerAction(action, state: state) }
            toolbar.install(in: self)
            viewerToolbar = toolbar
            textView.onGoToLine = { [weak self] in
                guard let self, let line = FileViewerNavigationDialogs.requestLine(maximum: FileViewerTextLines.starts(in: text).count) else { return }
                goToLine(line)
            }
        }
        viewerToolbar?.apply(preferences: viewerPreferences, resolvedEncoding: resolvedViewerEncoding?.foundationEncoding)
        textView.layoutManager?.showsInvisibleCharacters = viewerPreferences.showsNonPrintingCharacters
    }

    private func performViewerAction(_ action: String, state: NSControl.StateValue) {
        if action == "Show nonprinting characters" {
            viewerPreferences.showsNonPrintingCharacters = state == .on
            textView.layoutManager?.showsInvisibleCharacters = state == .on
            var preferences = AppSettingsStore.shared.fileViewerPreferences
            preferences.showsNonPrintingCharacters = state == .on
            AppSettingsStore.shared.updateFileViewerPreferences(preferences)
        } else if action.hasPrefix("Encoding:"), let encoding = RepositoryTextEncoding(rawValue: String(action.dropFirst("Encoding:".count))) {
            viewerPreferences.textEncoding = encoding
        } else if action == "Settings" {
            BrowserCommandCenter.perform(.settings)
        }
    }


    var text: String {
        get { textView.string }
        set {
            textView.string = newValue
            updateHighlighting()
            textView.undoManager?.removeAllActions(withTarget: textView.textStorage as Any)
        }
    }


    func replaceAll(with value: String) {
        let range = NSRange(location: 0, length: (textView.string as NSString).length)
        guard textView.shouldChangeText(in: range, replacementString: value) else { return }
        textView.replaceCharacters(in: range, with: value)
        textView.didChangeText()
    }


    func goToLine(_ line: Int) {
        let string = textView.string as NSString
        var location = 0
        var current = 1
        while current < line, location < string.length {
            location = NSMaxRange(string.lineRange(for: NSRange(location: location, length: 0)))
            current += 1
        }
        let range = NSRange(location: min(location, string.length), length: 0)
        textView.setSelectedRange(range)
        textView.scrollRangeToVisible(range)
    }

    func textDidChange(_ notification: Notification) { updateHighlighting(); onTextChanged?() }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateHighlighting()
    }

    @objc func updateHighlighting() {
        if viewerToolbar != nil {
            viewerPreferences.showsNonPrintingCharacters = AppSettingsStore.shared.fileViewerPreferences.showsNonPrintingCharacters
            textView.layoutManager?.showsInvisibleCharacters = viewerPreferences.showsNonPrintingCharacters
            viewerToolbar?.apply(preferences: viewerPreferences, resolvedEncoding: resolvedViewerEncoding?.foundationEncoding)
        }
        guard let layout = textView.layoutManager else { return }
        let entire = NSRange(location: 0, length: textView.string.utf16.count)
        for key in [NSAttributedString.Key.foregroundColor, .font] { layout.removeTemporaryAttribute(key, forCharacterRange: entire) }
        let model = syntaxPath.map { FileEditorHighlighting.build(text: textView.string, path: $0, commentSetting: commentSetting) } ?? FileEditorHighlighting()
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let font = AppSettingsStore.shared.codeFont
        let bold = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
        for token in model.tokens {
            let color: NSColor
            var tokenFont = font
            switch token.kind {
            case .syntax(let kind): color = DiffSyntaxHighlighter.color(for: kind)
            case .comment: color = dark ? .systemGreen : NSColor(calibratedRed: 0, green: 0.392, blue: 0, alpha: 1)
            case .summary: color = .textColor; tokenFont = bold
            case .command(let command), .commitID(let command): color = FileEditorHighlighting.color(for: command, dark: dark); tokenFont = bold
            }
            layout.addTemporaryAttributes([.foregroundColor: color, .font: tokenFont], forCharacterRange: token.range)
        }
        textView.syntaxMarkers = model.markers
        textView.needsDisplay = true
    }
}


class FileViewerTextView: NSTextView {
    var onReadOnlyFind: ((FileViewerShortcut) -> Void)?
    var onGoToLine: (() -> Void)?
    var normalizesCopyLineEndings = false

    override func copy(_ sender: Any?) {
        guard let text = FileViewerCopy.payload(.selection, text: string, selection: selectedRange(), isDiff: false,
                                               normalizeLineEndings: normalizesCopyLineEndings) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private var occurrenceTerm = ""

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if let id = ApplicationHotkeys.shared.matching(event, category: "File viewer"),
           let shortcut = FileViewerShortcut(rawValue: String(id.dropFirst("viewer.".count))) {
            if !isEditable, [.find, .findNext, .findPrevious].contains(shortcut), let onReadOnlyFind {
                onReadOnlyFind(shortcut)
                return true
            }
            switch shortcut {
            case .goToLine:
                guard let onGoToLine else { return super.performKeyEquivalent(with: event) }
                onGoToLine()
            case .find: findAction(.showFindInterface)
            case .replace:
                guard isEditable else { return false }
                findAction(.showReplaceInterface)
            case .findNext: findAction(.nextMatch)
            case .findPrevious: findAction(.previousMatch)
            case .nextOccurrence: moveOccurrence(forward: true)
            case .previousOccurrence: moveOccurrence(forward: false)
            default: return super.performKeyEquivalent(with: event)
            }
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        super.mouseUp(with: event)
        rememberOccurrence()
    }

    private func rememberOccurrence() {
        let range = selectedRange()
        if range.length > 0, NSMaxRange(range) <= (string as NSString).length {
            occurrenceTerm = (string as NSString).substring(with: range)
        }
        let entire = NSRange(location: 0, length: (string as NSString).length)
        layoutManager?.removeTemporaryAttribute(.backgroundColor, forCharacterRange: entire)
        for match in FileViewerOccurrences.ranges(of: occurrenceTerm, in: string) {
            layoutManager?.addTemporaryAttribute(.backgroundColor, value: ApplicationColors.color("HighlightAllOccurences", fallback: NSColor.systemYellow.withAlphaComponent(0.35)), forCharacterRange: match)
        }
    }

    func moveOccurrence(forward: Bool) {
        rememberOccurrence()
        let caret = selectedRange().location
        let matches = FileViewerOccurrences.ranges(of: occurrenceTerm, in: string)
        let target = forward ? matches.first { $0.location > caret } : matches.last { $0.location < caret }
        guard let target else { return }
        setSelectedRange(NSRange(location: target.location, length: 0))
        scrollRangeToVisible(target)
    }

    private func findAction(_ action: NSTextFinder.Action) {
        usesFindBar = true
        isIncrementalSearchingEnabled = true
        let item = NSMenuItem(); item.tag = action.rawValue
        performTextFinderAction(item)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        if !isEditable, onReadOnlyFind != nil, let menu { return menu }
        let menu = super.menu(for: event) ?? NSMenu()
        if !isEditable, onReadOnlyFind != nil { return menu }
        menu.addItem(.separator())
        for (title, action) in [("Find…", NSTextFinder.Action.showFindInterface), ("Replace…", .showReplaceInterface)] {
            if action == .showReplaceInterface && !isEditable { continue }
            let item = NSMenuItem(title: title, action: #selector(performTextFinderAction(_:)), keyEquivalent: "")
            item.target = self; item.tag = action.rawValue
            menu.addItem(item)
        }
        return menu
    }
}

final class EditorTextView: FileViewerTextView {
    var onEscape: (() -> Bool)?
    var syntaxMarkers: [FileEditorHighlighting.Marker] = []
    private var markerTrackingArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let markerTrackingArea { removeTrackingArea(markerTrackingArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self)
        addTrackingArea(area)
        markerTrackingArea = area
    }

    override func mouseExited(with event: NSEvent) { toolTip = nil; super.mouseExited(with: event) }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let layoutManager, let textContainer else { return }
        NSColor.systemRed.setStroke()
        for marker in syntaxMarkers {
            let glyphs = layoutManager.glyphRange(forCharacterRange: marker.range, actualCharacterRange: nil)
            layoutManager.enumerateLineFragments(forGlyphRange: glyphs) { _, _, _, lineGlyphs, _ in
                let range = NSIntersectionRange(glyphs, lineGlyphs)
                guard range.length > 0 else { return }
                let rect = layoutManager.boundingRect(forGlyphRange: range, in: textContainer).offsetBy(dx: self.textContainerOrigin.x, dy: self.textContainerOrigin.y)
                guard rect.intersects(dirtyRect) else { return }
                let wave = NSBezierPath()
                wave.lineWidth = 1
                wave.move(to: NSPoint(x: rect.minX, y: rect.maxY - 1))
                var x = rect.minX
                while x < rect.maxX {
                    x = min(x + 2, rect.maxX)
                    wave.line(to: NSPoint(x: x, y: rect.maxY - 3))
                    x = min(x + 2, rect.maxX)
                    wave.line(to: NSPoint(x: x, y: rect.maxY - 1))
                }
                wave.stroke()
            }
        }
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        guard let layoutManager, let textContainer else { return }
        let point = convert(event.locationInWindow, from: nil)
        let index = layoutManager.characterIndex(for: NSPoint(x: point.x - textContainerOrigin.x, y: point.y - textContainerOrigin.y), in: textContainer, fractionOfDistanceBetweenInsertionPoints: nil)
        toolTip = syntaxMarkers.first { NSLocationInRange(index, $0.range) }?.message
    }
    override func cancelOperation(_ sender: Any?) {
        if onEscape?() == true { return }
        super.cancelOperation(sender)
    }
}


final class RepositoryFileEditorWindow: NSWindow {
    var onSave: (() -> Void)?
    var onCommandReturn: (() -> Void)?
    var onCancel: (() -> Void)?
    override func cancelOperation(_ sender: Any?) {
        if let onCancel { onCancel() } else { super.cancelOperation(sender) }
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let command = event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command
        if let onSave, command, event.charactersIgnoringModifiers?.lowercased() == "s" {
            onSave()
            return true
        }
        if let onCommandReturn, command, event.charactersIgnoringModifiers == "\r" {
            onCommandReturn()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

private final class EditorActionButton: NSButton {
    var callback: (() -> Void)?
    @objc func invoke() { callback?() }
}

enum RepositoryFileEditorDialogs {
    enum Answer { case yes, no, cancel }

    @MainActor static func message(_ text: String, caption: String, window: NSWindow, style: NSAlert.Style = .critical) async {
        let alert = NSAlert()
        alert.alertStyle = style
        alert.messageText = caption
        alert.informativeText = text
        _ = await alert.beginSheetModal(for: window)
    }


    @MainActor static func yesNoCancel(_ text: String, caption: String, window: NSWindow) async -> Answer {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = caption
        alert.informativeText = text
        alert.addButton(withTitle: "Yes")
        alert.addButton(withTitle: "No")
        alert.addButton(withTitle: "Cancel").keyEquivalent = "\u{1b}"
        switch await alert.beginSheetModal(for: window) {
        case .alertFirstButtonReturn: return .yes
        case .alertSecondButtonReturn: return .no
        default: return .cancel
        }
    }


    @MainActor static func okCancel(_ text: String, caption: String, window: NSWindow) async -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = caption
        alert.informativeText = text
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel").keyEquivalent = "\u{1b}"
        return await alert.beginSheetModal(for: window) == .alertFirstButtonReturn
    }

    static func image(_ resource: String, symbol: String, description: String) -> NSImage? {
        AppKitFactory.resourceImage(resource, accessibilityDescription: description)
            ?? NSImage(systemSymbolName: symbol, accessibilityDescription: description)
    }

    @MainActor static func link(_ title: String, url: String) -> NSButton {
        let button = EditorActionButton(title: title, target: nil, action: #selector(EditorActionButton.invoke))
        button.target = button
        button.callback = { if let url = URL(string: url) { NSWorkspace.shared.open(url) } }
        button.isBordered = false
        button.attributedTitle = NSAttributedString(string: title, attributes: [
            .foregroundColor: NSColor.linkColor,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
            .font: NSFont.systemFont(ofSize: NSFont.systemFontSize)
        ])
        button.toolTip = url
        return button
    }

    @MainActor static func button(_ title: String, image: NSImage? = nil, _ action: @escaping () -> Void) -> NSButton {
        let button = EditorActionButton(title: title, target: nil, action: #selector(EditorActionButton.invoke))
        button.target = button
        button.callback = action
        button.bezelStyle = .rounded
        if let image { button.image = image; button.imagePosition = .imageLeading }
        button.widthAnchor.constraint(greaterThanOrEqualToConstant: 110).isActive = true
        return button
    }
}


@MainActor
final class RepositoryFileEditorWindowController: NSWindowController, NSWindowDelegate {
    enum Kind: Equatable {
        case gitIgnore, localExclude, gitAttributes, mailMap

        var file: RepositoryEditableFile {
            switch self {
            case .gitIgnore: .gitIgnore
            case .localExclude: .localExclude
            case .gitAttributes: .gitAttributes
            case .mailMap: .mailMap
            }
        }
        var fileName: String {
            switch self {
            case .gitIgnore: ".gitignore"
            case .localExclude: ".git/info/exclude"
            case .gitAttributes: ".gitattributes"
            case .mailMap: ".mailmap"
            }
        }
        var isIgnore: Bool { self == .gitIgnore || self == .localExclude }
        var title: String { "Edit \(fileName)" }
        var noWorkingDirectory: String { "\(fileName) is only supported when there is a working directory." }
        var cannotAccess: String { "Failed to save \(fileName).\nCheck if file is accessible." }
        var cannotAccessCaption: String { "Failed to save \(fileName)" }
        var saveQuestion: String { "Save changes to \(fileName)?" }
        static let noWorkingDirectoryCaption = "No working directory"
        static let saveQuestionCaption = "Save changes?"


        var help: String {
            switch self {
            case .gitIgnore, .localExclude:
                "Specify filepatterns you want git to ignore.\n\nExample:\n" + RepositoryFileEditorWindowController.defaultIgnorePatterns.joined(separator: "\n")
            case .gitAttributes:
                "Edit the git attributes\nDefine attributes per path\n\nExamples\nMark all jpg files as binary:\n*.jpg binary\n\nMark sln files as binary:\n*.sln binary\n\nMark single file as text:\nweirdchars.txt text\n\nFor more information run\ncommand \"git help gitattributes\"\n"
            case .mailMap:
                "Edit the mailmap.\nThis file is meant to correct usernames.\n\nExample:\nHenk Westhuis <Henk@.(none)>\nHenk Westhuis <henk_westhuis@hotmail.com>\n\nFor more information run\ncommand \"git help shortlog\""
            }
        }
    }


    static let defaultIgnorePatterns = [
        "#Ignore thumbnails created by Windows", "Thumbs.db", "#Ignore files built by Visual Studio",
        "*.obj", "*.exe", "*.pdb", "*.user", "*.aps", "*.pch", "*.vspscc", "*_i.c", "*_p.c", "*.ncb", "*.suo",
        "*.tlb", "*.tlh", "*.bak", "*.cache", "*.ilk", "*.log", "[Bb]in", "[Dd]ebug*/", "*.lib", "*.sbr", "obj/",
        "[Rr]elease*/", "_ReSharper*/", "[Tt]est[Rr]esult*", ".vs/", ".idea/", "#Nuget packages folder", "packages/"
    ]


    static var defaultIgnorePatternsFile: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("GitExtensionsMac", isDirectory: true)
            .appendingPathComponent("DefaultIgnorePatterns.txt")
    }

    let kind: Kind
    let editor = EditableFileTextView()
    private let source: any RepositoryFileEditingDataSource
    private let addPattern: (NSWindow) async -> Void
    private let onSaved: () -> Void
    private let onClose: () -> Void
    private(set) var fileURL: URL?
    private let split = NSSplitView()

    private var original = ""
    private var closing = false

    var hasUnsavedChanges: Bool { original != editor.text }

    init(kind: Kind, source: any RepositoryFileEditingDataSource,
         addPattern: @escaping (NSWindow) async -> Void = { _ in },
         onSaved: @escaping () -> Void = {}, onClose: @escaping () -> Void) {
        self.kind = kind
        self.source = source
        self.addPattern = addPattern
        self.onSaved = onSaved
        self.onClose = onClose
        let size = kind.isIgnore ? NSSize(width: 634, height: 623) : NSSize(width: 634, height: 474)
        let window = RepositoryFileEditorWindow(contentRect: NSRect(origin: .zero, size: size),
                                                styleMask: [.titled, .closable, .resizable, .miniaturizable],
                                                backing: .buffered, defer: false)
        window.title = kind.title
        window.isReleasedWhenClosed = false
        if kind.isIgnore { window.contentMinSize = NSSize(width: 634, height: 459) }
        super.init(window: window)
        window.delegate = self
        window.contentView = makeContent()

        window.layoutIfNeeded()
        split.setPosition(kind.isIgnore ? 352 : 381, ofDividerAt: 0)
        window.initialFirstResponder = editor.textView

        if kind.isIgnore { editor.textView.onEscape = { [weak self] in self?.cancel(); return true } }
    }

    required init?(coder: NSCoder) { nil }


    func load() async {
        do {
            let url = try await source.editableFileURL(kind.file)
            fileURL = url
            guard FileManager.default.fileExists(atPath: url.path) else { return }
            let loaded = try await source.loadEditableFile(at: url)
            editor.text = loaded.text
            original = loaded.text
        } catch {

        }
    }

    private func makeContent() -> NSView {
        let root = NSView()
        let split = self.split
        split.isVertical = true
        split.dividerStyle = .thin
        split.translatesAutoresizingMaskIntoConstraints = false

        let left = NSView()
        let right = NSView()
        editor.translatesAutoresizingMaskIntoConstraints = false
        left.addSubview(editor)

        let help = NSTextView.scrollableTextView()
        if let textView = help.documentView as? NSTextView {
            textView.string = kind.help
            textView.isEditable = false
            textView.isSelectable = true
            textView.drawsBackground = false
            textView.font = AppSettingsStore.shared.applicationFont(size: NSFont.systemFontSize)
            textView.textContainerInset = .zero
        }
        help.drawsBackground = false
        help.borderType = .noBorder
        help.hasVerticalScroller = true
        help.autohidesScrollers = true
        help.setAccessibilityIdentifier("RepositoryFileEditor.Help")
        help.translatesAutoresizingMaskIntoConstraints = false
        right.addSubview(help)
        split.addArrangedSubview(left)
        split.addArrangedSubview(right)
        root.addSubview(split)

        let saveButton = RepositoryFileEditorDialogs.button(
            "Save", image: kind.isIgnore ? RepositoryFileEditorDialogs.image("Save", symbol: "square.and.arrow.down", description: "Save") : nil
        ) { [weak self] in self?.saveAndClose() }
        saveButton.setAccessibilityIdentifier("RepositoryFileEditor.Save")
        saveButton.translatesAutoresizingMaskIntoConstraints = false

        var helpFloor: NSView = saveButton

        if kind.isIgnore {

            let addDefault = RepositoryFileEditorDialogs.button("Add default ignores") { [weak self] in self?.addDefaultIgnores() }
            let addPatternButton = RepositoryFileEditorDialogs.button("Add pattern") { [weak self] in self?.addPatternClicked() }
            addDefault.setAccessibilityIdentifier("RepositoryFileEditor.AddDefault")
            addPatternButton.setAccessibilityIdentifier("RepositoryFileEditor.AddPattern")
            let leftButtons = NSStackView(views: [addDefault, addPatternButton])
            leftButtons.orientation = .horizontal
            leftButtons.translatesAutoresizingMaskIntoConstraints = false
            left.addSubview(leftButtons)
            let links = NSStackView(views: [
                RepositoryFileEditorDialogs.link("Generate a custom ignore file for git", url: "https://www.gitignore.io/"),
                RepositoryFileEditorDialogs.link("Example ignore patterns", url: "https://github.com/github/gitignore")
            ])
            links.orientation = .vertical
            links.alignment = .trailing
            links.spacing = 4
            links.translatesAutoresizingMaskIntoConstraints = false
            right.addSubview(links)
            helpFloor = links
            let cancelButton = RepositoryFileEditorDialogs.button("Cancel") { [weak self] in self?.cancel() }
            cancelButton.setAccessibilityIdentifier("RepositoryFileEditor.Cancel")
            let bottom = NSStackView(views: [cancelButton, saveButton])
            bottom.orientation = .horizontal
            bottom.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(bottom)
            NSLayoutConstraint.activate([
                split.topAnchor.constraint(equalTo: root.topAnchor, constant: 4),
                split.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 4),
                split.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -4),
                bottom.topAnchor.constraint(equalTo: split.bottomAnchor, constant: 6),
                bottom.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -8),
                bottom.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -8),
                editor.topAnchor.constraint(equalTo: left.topAnchor),
                editor.leadingAnchor.constraint(equalTo: left.leadingAnchor),
                editor.trailingAnchor.constraint(equalTo: left.trailingAnchor),
                leftButtons.topAnchor.constraint(equalTo: editor.bottomAnchor, constant: 6),
                leftButtons.leadingAnchor.constraint(equalTo: left.leadingAnchor),
                leftButtons.bottomAnchor.constraint(equalTo: left.bottomAnchor),
                help.topAnchor.constraint(equalTo: right.topAnchor, constant: 4),
                help.leadingAnchor.constraint(equalTo: right.leadingAnchor, constant: 8),
                help.trailingAnchor.constraint(equalTo: right.trailingAnchor, constant: -8),

                links.trailingAnchor.constraint(equalTo: right.trailingAnchor, constant: -8),
                links.bottomAnchor.constraint(equalTo: right.bottomAnchor, constant: -4),
                left.widthAnchor.constraint(greaterThanOrEqualToConstant: 250),
                right.widthAnchor.constraint(greaterThanOrEqualToConstant: 250)
            ])

            split.setHoldingPriority(.defaultLow, forSubviewAt: 0)
            split.setHoldingPriority(.defaultHigh, forSubviewAt: 1)
        } else {

            right.addSubview(saveButton)
            NSLayoutConstraint.activate([
                split.topAnchor.constraint(equalTo: root.topAnchor),
                split.leadingAnchor.constraint(equalTo: root.leadingAnchor),
                split.trailingAnchor.constraint(equalTo: root.trailingAnchor),
                split.bottomAnchor.constraint(equalTo: root.bottomAnchor),
                editor.topAnchor.constraint(equalTo: left.topAnchor),
                editor.leadingAnchor.constraint(equalTo: left.leadingAnchor),
                editor.trailingAnchor.constraint(equalTo: left.trailingAnchor),
                editor.bottomAnchor.constraint(equalTo: left.bottomAnchor),
                help.topAnchor.constraint(equalTo: right.topAnchor, constant: 8),
                help.leadingAnchor.constraint(equalTo: right.leadingAnchor, constant: 8),
                help.trailingAnchor.constraint(equalTo: right.trailingAnchor, constant: -8),

                saveButton.trailingAnchor.constraint(equalTo: right.trailingAnchor, constant: -8),
                saveButton.bottomAnchor.constraint(equalTo: right.bottomAnchor, constant: -8),
                left.widthAnchor.constraint(greaterThanOrEqualToConstant: 150),
                right.widthAnchor.constraint(greaterThanOrEqualToConstant: 150)
            ])
            split.setHoldingPriority(.defaultLow, forSubviewAt: 0)
            split.setHoldingPriority(.defaultLow + 1, forSubviewAt: 1)
        }

        let helpBottom = help.bottomAnchor.constraint(equalTo: helpFloor.topAnchor, constant: -8)
        helpBottom.priority = .defaultHigh
        helpBottom.isActive = true
        return root
    }




    func saveAndClose() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            _ = await save()
            window?.performClose(nil)
        }
    }


    func cancel() { window?.performClose(nil) }


    func save() async -> Bool {
        if kind.isIgnore && !hasUnsavedChanges { return false }
        let text = editor.text
        do {
            guard let fileURL else { throw EditableFileError.missing(kind.fileName) }
            try EditableFileIO.saveWithTrailingNewline(text, to: fileURL, createDirectory: kind.isIgnore)
            original = text
            if kind == .mailMap { onSaved() }
            return true
        } catch {
            if let window { await RepositoryFileEditorDialogs.message(kind.cannotAccess + "\n" + error.localizedDescription, caption: kind.cannotAccessCaption, window: window) }
            return false
        }
    }


    func addDefaultIgnores() {
        let defaults = (try? String(contentsOf: Self.defaultIgnorePatternsFile, encoding: .utf8))
            .map { $0.components(separatedBy: .newlines).dropLastEmpty() } ?? Self.defaultIgnorePatterns
        let current = editor.text
        var seen = Set(current.components(separatedBy: "\n").filter { !$0.isEmpty })
        let toAdd = defaults.filter { seen.insert($0).inserted }
        guard !toAdd.isEmpty else { return }
        editor.replaceAll(with: current + "\n" + toAdd.joined(separator: "\n") + "\n")
    }


    func addPatternClicked() {
        Task { @MainActor [weak self] in
            guard let self, let window else { return }
            _ = await save()
            await addPattern(window)
            await load()
        }
    }




    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if closing || !hasUnsavedChanges { return true }
        Task { @MainActor [weak self] in
            guard let self else { return }
            switch await RepositoryFileEditorDialogs.yesNoCancel(kind.saveQuestion, caption: Kind.saveQuestionCaption, window: sender) {
            case .yes:
                guard await save() else { return }
            case .no:
                break
            case .cancel:
                return
            }
            closing = true
            sender.close()
        }
        return false
    }

    func windowWillClose(_ notification: Notification) { onClose() }
}

private extension Array where Element == String {

    func dropLastEmpty() -> [String] { last == "" ? Array(dropLast()) : self }
}


@MainActor
final class FileEditorWindowController: NSWindowController, NSWindowDelegate {
    private(set) var acceptedClose = true
    static let warningText = "Here be dragons!\nChanging this file by hand can be harmful and might break something.\nIf you are not sure just close this window."

    let fileURL: URL
    let editor = EditableFileTextView()
    private let source: any RepositoryFileEditingDataSource
    private let showWarning: Bool
    private let lineNumber: Int?
    private let onClose: () -> Void
    private var loaded: EditableFileText?
    let previewPresentation = FilePreviewPresentation<EditableFileText>()
    private var closing = false
    private let saveButton = NSButton()

    private(set) var hasChanges = false {
        didSet { saveButton.isEnabled = hasChanges }
    }

    init(fileURL: URL, source: any RepositoryFileEditingDataSource, showWarning: Bool, lineNumber: Int? = nil, displayName: String? = nil, onClose: @escaping () -> Void) {
        self.fileURL = fileURL
        self.source = source
        self.showWarning = showWarning
        self.lineNumber = lineNumber
        self.onClose = onClose
        let window = RepositoryFileEditorWindow(contentRect: NSRect(x: 0, y: 0, width: 659, height: 543),
                                                styleMask: [.titled, .closable, .resizable, .miniaturizable],
                                                backing: .buffered, defer: false)
        window.title = displayName ?? fileURL.path
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        window.contentView = makeContent()
        window.initialFirstResponder = editor.textView
        window.onSave = { [weak self] in self?.saveShowingError() }
        editor.textView.onEscape = { [weak self] in self?.window?.performClose(nil); return true }
        editor.onTextChanged = { [weak self] in self?.hasChanges = true }
        hasChanges = false
    }

    required init?(coder: NSCoder) { nil }


    func load() async throws {
        editor.syntaxPath = fileURL.path
        if FileEditorHighlighting.mode(for: fileURL.path) == .commitMessage || FileEditorHighlighting.mode(for: fileURL.path) == .rebaseTodo {
            editor.commentSetting = try await source.editorCommentCharacter()
        }
        if FileManager.default.fileExists(atPath: fileURL.path) {
            let preview = try await source.prepareEditableFile(at: fileURL, encoding: editor.viewerPreferences.textEncoding)
            previewPresentation.present(preview, display: { [weak self] text in
                guard let self else { return }
                loaded = text
                editor.text = text.text
                editor.enableViewerToolbar(resolvedEncoding: text.encoding)
                if let lineNumber { editor.goToLine(lineNumber) }
                hasChanges = false
            }, failure: { [weak self] error in
                guard let self, let window else { return }
                Task { await RepositoryFileEditorDialogs.message("Cannot open file:\n" + error.localizedDescription, caption: "Error", window: window) }
            })
        } else {
            editor.text = "File \(fileURL.path) does not exist"
        }
        if let lineNumber { editor.goToLine(lineNumber) }
        hasChanges = false
    }

    private func makeContent() -> NSView {
        let root = NSView()
        saveButton.image = RepositoryFileEditorDialogs.image("Save", symbol: "square.and.arrow.down", description: "Save")
        saveButton.imagePosition = .imageOnly
        saveButton.isBordered = false
        saveButton.toolTip = "Save"
        saveButton.target = self
        saveButton.action = #selector(saveClicked)
        saveButton.setAccessibilityIdentifier("FileEditor.Save")
        let toolbar = NSStackView(views: [saveButton])
        toolbar.orientation = .horizontal
        toolbar.edgeInsets = NSEdgeInsets(top: 2, left: 4, bottom: 2, right: 4)

        toolbar.heightAnchor.constraint(equalToConstant: 25).isActive = true
        saveButton.widthAnchor.constraint(equalToConstant: 23).isActive = true
        saveButton.heightAnchor.constraint(equalToConstant: 22).isActive = true
        var rows: [NSView] = [toolbar]
        if showWarning {
            let icon = NSImageView(image: RepositoryFileEditorDialogs.image("Warning", symbol: "exclamationmark.triangle.fill", description: "Warning") ?? NSImage())
            icon.contentTintColor = .systemOrange
            let label = NSTextField(wrappingLabelWithString: Self.warningText)
            label.textColor = .black
            let panel = NSStackView(views: [icon, label])
            panel.orientation = .horizontal
            panel.alignment = .top
            panel.edgeInsets = NSEdgeInsets(top: 6, left: 8, bottom: 6, right: 8)
            panel.wantsLayer = true

            panel.layer?.backgroundColor = NSColor(calibratedRed: 1, green: 0.95, blue: 0.7, alpha: 1).cgColor
            panel.setAccessibilityIdentifier("FileEditor.Warning")
            rows.append(panel)
        }
        rows.append(editor)
        editor.enableViewerToolbar()
        let stack = NSStackView(views: rows)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)
        for row in rows { row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        editor.setContentHuggingPriority(.defaultLow, for: .vertical)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: root.topAnchor),
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor)
        ])
        previewPresentation.install(in: editor)
        return root
    }

    @objc private func saveClicked() { saveShowingError() }


    func saveShowingError() {
        do { try saveChanges() } catch {
            guard let window else { return }
            Task { await RepositoryFileEditorDialogs.message("Cannot save file:\n\(error.localizedDescription)", caption: "Error", window: window) }
        }
    }


    func saveChanges() throws {
        let encoding = loaded?.encoding ?? .utf8
        try EditableFileIO.saveInPlace(editor.text, to: fileURL, encoding: encoding, preamble: loaded?.preamble ?? [])
        hasChanges = false
    }


    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if closing || !hasChanges { return true }
        Task { @MainActor [weak self] in
            guard let self else { return }
            switch await RepositoryFileEditorDialogs.yesNoCancel("Do you want to save changes?", caption: "Save changes", window: sender) {
            case .yes:
                do { try saveChanges() } catch {
                    guard await RepositoryFileEditorDialogs.okCancel("Cannot save file:\n\(error.localizedDescription)", caption: "Error", window: sender) else { return }
                }
            case .no:
                acceptedClose = false
            case .cancel:
                return
            }
            closing = true
            sender.close()
        }
        return false
    }

    func windowWillClose(_ notification: Notification) { previewPresentation.cancel(); onClose() }
}


@MainActor
final class AddToGitIgnoreWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {
    private let source: any RepositoryFileEditingDataSource
    private let localExclude: Bool
    let patternView = EditableFileTextView()
    private let preview = NSTableView()
    let countLabel = NSTextField(labelWithString: "(matched files count)")
    let noMatchPanel = NSView()
    private(set) var previewItems: [String] = []
    private(set) var isPreviewEnabled = true
    private var loadTask: Task<Void, Never>?
    private var continuation: CheckedContinuation<Void, Never>?

    init(source: any RepositoryFileEditingDataSource, localExclude: Bool, patterns: [String]) {
        self.source = source
        self.localExclude = localExclude
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 599, height: 341), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.title = localExclude ? "Add file(s) to .git/info/exclude" : "Add file(s) to .gitignore"
        window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 420, height: 260)
        super.init(window: window)
        window.contentView = makeContent()
        window.initialFirstResponder = patternView.textView
        patternView.onTextChanged = { [weak self] in self?.patternsChanged() }
        patternView.textView.onEscape = { [weak self] in self?.finish(); return true }
        patternView.text = patterns.joined(separator: "\n")
        patternsChanged()
    }

    required init?(coder: NSCoder) { nil }


    func run(parent: NSWindow) async {
        guard let window else { return }
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            parent.beginSheet(window)
        }
    }

    private func makeContent() -> NSView {
        let root = NSView()
        let patternBox = NSBox()
        patternBox.title = "Enter a file pattern to ignore:"
        patternBox.contentView = patternView

        let column = NSTableColumn(identifier: .init("file"))
        column.resizingMask = .autoresizingMask
        preview.addTableColumn(column)
        preview.headerView = nil
        preview.dataSource = self
        preview.delegate = self
        preview.setAccessibilityIdentifier("AddToGitIgnore.Preview")
        let scroll = NSScrollView()
        scroll.documentView = preview
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder

        let icon = NSImageView(image: RepositoryFileEditorDialogs.image("Unmerged", symbol: "exclamationmark.triangle", description: "No match") ?? NSImage())
        let noMatchLabel = NSTextField(labelWithString: "No existing files match that pattern.")
        let status = NSView()
        for view in [icon, noMatchLabel] as [NSView] { view.translatesAutoresizingMaskIntoConstraints = false; noMatchPanel.addSubview(view) }
        for view in [noMatchPanel, countLabel] as [NSView] { view.translatesAutoresizingMaskIntoConstraints = false; status.addSubview(view) }
        noMatchPanel.isHidden = true
        countLabel.alignment = .right
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: noMatchPanel.leadingAnchor),
            icon.centerYAnchor.constraint(equalTo: noMatchPanel.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 16),
            icon.heightAnchor.constraint(equalToConstant: 16),
            noMatchLabel.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 4),
            noMatchLabel.trailingAnchor.constraint(equalTo: noMatchPanel.trailingAnchor),
            noMatchLabel.topAnchor.constraint(equalTo: noMatchPanel.topAnchor),
            noMatchLabel.bottomAnchor.constraint(equalTo: noMatchPanel.bottomAnchor),
            noMatchPanel.leadingAnchor.constraint(equalTo: status.leadingAnchor),
            noMatchPanel.topAnchor.constraint(equalTo: status.topAnchor),
            noMatchPanel.bottomAnchor.constraint(equalTo: status.bottomAnchor),
            countLabel.trailingAnchor.constraint(equalTo: status.trailingAnchor),
            countLabel.centerYAnchor.constraint(equalTo: status.centerYAnchor),
            countLabel.leadingAnchor.constraint(greaterThanOrEqualTo: noMatchPanel.trailingAnchor, constant: 8)
        ])
        let previewStack = NSStackView(views: [scroll, status])
        previewStack.orientation = .vertical
        previewStack.alignment = .leading
        previewStack.spacing = 4
        previewStack.edgeInsets = NSEdgeInsets(top: 2, left: 4, bottom: 2, right: 4)
        let previewBox = NSBox()
        previewBox.title = "Preview"
        previewStack.translatesAutoresizingMaskIntoConstraints = false
        previewBox.contentView?.addSubview(previewStack)

        let ignore = RepositoryFileEditorDialogs.button("Ignore") { [weak self] in self?.ignoreClicked() }
        ignore.setAccessibilityIdentifier("AddToGitIgnore.Ignore")
        let cancel = RepositoryFileEditorDialogs.button("Cancel") { [weak self] in self?.finish() }
        cancel.keyEquivalent = "\u{1b}"
        let buttons = NSStackView(views: [cancel, ignore])
        buttons.orientation = .horizontal

        buttons.setHuggingPriority(.defaultHigh, for: .vertical)

        for view in [patternBox, previewBox, buttons, scroll, status] as [NSView] { view.translatesAutoresizingMaskIntoConstraints = false }
        for view in [patternBox, previewBox, buttons] { root.addSubview(view) }
        NSLayoutConstraint.activate([
            patternBox.topAnchor.constraint(equalTo: root.topAnchor, constant: 8),
            patternBox.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 8),
            patternBox.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -8),
            patternBox.heightAnchor.constraint(equalToConstant: 93),
            previewBox.topAnchor.constraint(equalTo: patternBox.bottomAnchor, constant: 4),
            previewBox.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 8),
            previewBox.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -8),
            previewBox.heightAnchor.constraint(greaterThanOrEqualToConstant: 110),
            previewStack.topAnchor.constraint(equalTo: previewBox.contentView!.topAnchor),
            previewStack.leadingAnchor.constraint(equalTo: previewBox.contentView!.leadingAnchor),
            previewStack.trailingAnchor.constraint(equalTo: previewBox.contentView!.trailingAnchor),
            previewStack.bottomAnchor.constraint(equalTo: previewBox.contentView!.bottomAnchor),
            scroll.widthAnchor.constraint(equalTo: previewStack.widthAnchor, constant: -8),
            status.widthAnchor.constraint(equalTo: previewStack.widthAnchor, constant: -8),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 60),
            buttons.topAnchor.constraint(equalTo: previewBox.bottomAnchor, constant: 8),
            buttons.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            buttons.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -10)
        ])
        return root
    }


    var currentPatterns: [String] {
        patternView.text.components(separatedBy: .newlines).filter { !$0.isEmpty }
    }


    private func patternsChanged() {
        loadTask?.cancel()
        if isPreviewEnabled {
            countLabel.stringValue = "Updating ..."
            previewItems = ["Updating ..."]
            preview.reloadData()
            isPreviewEnabled = false
            preview.isEnabled = false
        }
        let patterns = currentPatterns
        loadTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled, let source = self?.source else { return }
            let files = (try? await source.ignoredFiles(matching: patterns)) ?? []
            guard !Task.isCancelled else { return }
            self?.updatePreview(files)
        }
    }


    private func updatePreview(_ files: [String]) {
        previewItems = files
        preview.reloadData()
        countLabel.stringValue = "\(files.count) file(s) matched"
        isPreviewEnabled = true
        preview.isEnabled = true
        noMatchPanel.isHidden = !files.isEmpty
    }


    func ignoreClicked() {
        let patterns = currentPatterns
        guard !patterns.isEmpty else { finish(); return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let url = try await source.editableFileURL(localExclude ? .localExclude : .gitIgnore)
                try EditableFileIO.appendPatterns(patterns, to: url)
            } catch {
                if let window { await RepositoryFileEditorDialogs.message(String(describing: error), caption: "Error", window: window) }
            }
            finish()
        }
    }

    func finish() {
        loadTask?.cancel()
        guard let window else { return }
        window.sheetParent?.endSheet(window)
        window.orderOut(nil)
        continuation?.resume()
        continuation = nil
    }

    func numberOfRows(in tableView: NSTableView) -> Int { previewItems.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = tableView.makeView(withIdentifier: .init("previewCell"), owner: nil) as? NSTextField
            ?? NSTextField(labelWithString: "")
        cell.identifier = .init("previewCell")
        cell.stringValue = previewItems[row]
        cell.textColor = isPreviewEnabled ? .labelColor : .disabledControlTextColor
        return cell
    }
}
