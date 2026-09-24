import AppKit
import SwiftUI

struct ApplicationKeyChord: Codable, Equatable {
    let key: String
    let modifiers: UInt
    init(_ key: String, _ modifiers: NSEvent.ModifierFlags = []) {
        self.key = key.lowercased()
        self.modifiers = modifiers.intersection([.command, .control, .option, .shift]).rawValue
    }
    init(event: NSEvent) { self.init(event.charactersIgnoringModifiers ?? "", event.modifierFlags) }
    var title: String {
        guard !key.isEmpty else { return "None" }
        let flags = NSEvent.ModifierFlags(rawValue: modifiers)
        let prefix = (flags.contains(.control) ? "⌃" : "") + (flags.contains(.option) ? "⌥" : "")
            + (flags.contains(.shift) ? "⇧" : "") + (flags.contains(.command) ? "⌘" : "")
        let special = ["\r": "Return", "\u{f702}": "←", "\u{f703}": "→", "\u{f700}": "↑", "\u{f701}": "↓", "\u{f708}": "F5", "\u{1b}": "Escape", " ": "Space"]
        return prefix + (special[key] ?? key.uppercased())
    }
    var swiftUI: KeyboardShortcut? {
        guard let character = key.first else { return nil }
        let flags = NSEvent.ModifierFlags(rawValue: modifiers)
        var modifiers: EventModifiers = []
        if flags.contains(.command) { modifiers.insert(.command) }
        if flags.contains(.control) { modifiers.insert(.control) }
        if flags.contains(.option) { modifiers.insert(.option) }
        if flags.contains(.shift) { modifiers.insert(.shift) }
        return KeyboardShortcut(KeyEquivalent(character), modifiers: modifiers)
    }
}

struct ApplicationHotkeyDefinition {
    let id: String
    let category: String
    let title: String
    let defaultChord: ApplicationKeyChord
}

@MainActor
final class ApplicationHotkeys: ObservableObject {
    static let shared = ApplicationHotkeys()
    static var definitions: [ApplicationHotkeyDefinition] {
        baseDefinitions + ((try? ApplicationScriptsStore.shared.load()) ?? []).map {
            .init(id: "script.\($0.hotkeyCommandIdentifier)", category: "Scripts", title: $0.displayName, defaultChord: .init(""))
        }
    }
    private static let baseDefinitions: [ApplicationHotkeyDefinition] = {
        let menu: [(String, String, ApplicationKeyChord)] = [
            ("openRepository", "Open repository", .init("o", .command)),
            ("closeToDashboard", "Close to Dashboard", .init("w", [.command, .shift])),
            ("refresh", "Refresh repository", .init("r", .command)),
            ("toggleRevisionTags", "Show/hide revision tags", .init("t", [.control, .option])),
            ("commit", "Commit", .init("\r", [.command, .shift])),
            ("createBranch", "Create branch", .init("b", .control)),
            ("checkoutBranch", "Checkout branch", .init(".", .control)),
            ("mergeBranches", "Merge branches", .init("m", .control)),
            ("settings", "Settings", .init(",", .command))
        ]
        let unassigned: [(String, String)] = [
            ("initializeRepository", "New repository"), ("cloneRepository", "Clone repository"),
            ("remoteRepositories", "Remote repositories"), ("manageSubmodules", "Manage submodules"),
            ("manageWorktrees", "Manage worktrees"), ("pullFetch", "Pull/Fetch"), ("push", "Push"),
            ("manageStashes", "Manage stashes"), ("resetChanges", "Reset changes"), ("cleanRepository", "Clean working directory"),
            ("deleteBranch", "Delete branch"), ("rebase", "Rebase"), ("solveMergeConflicts", "Solve merge conflicts"),
            ("createTag", "Create tag"), ("deleteTag", "Delete tag"), ("cherryPick", "Cherry-pick"),
            ("archiveRevision", "Archive revision"), ("checkoutRevision", "Checkout revision"), ("bisect", "Bisect"),
            ("reflog", "Show reflog"), ("formatPatch", "Format patch"), ("applyPatch", "Apply patch"), ("viewPatch", "View patch")
        ]
        let navigation: [(String, String, ApplicationKeyChord)] = [
            ("revision.navigate.child", "Child", .init("n", .control)),
            ("revision.navigate.parent", "Parent", .init("p", .control)),
            ("revision.navigate.firstParent", "First parent", .init("\u{f702}", .control)),
            ("revision.navigate.lastParent", "Last parent", .init("\u{f703}", .control)),
            ("revision.navigate.mergeBase", "Merge base", .init("k", [.control, .shift])),
            ("revision.navigate.current", "Current checkout", .init("c", [.control, .shift])),
            ("revision.search.next", "Next quick-search result", .init("\u{f701}", .option)),
            ("revision.search.previous", "Previous quick-search result", .init("\u{f700}", .option)),
            ("revision.commit.fixup", "Create fixup commit", .init("x", .control)),
            ("revision.commit.squash", "Create squash commit", .init("x", [.control, .shift])),
            ("revision.other.reflog", "Reflog", .init("l", [.control, .shift]))
        ]
        let commit: [(String, String, ApplicationKeyChord)] = [
            ("unstaged", "Focus unstaged files", .init("1", .command)),
            ("diff", "Focus diff", .init("2", .command)),
            ("staged", "Focus staged files", .init("3", .command)),
            ("message", "Focus commit message", .init("4", .command)),
            ("stageAll", "Stage all", .init("s", .command)),
            ("filter", "Filter files", .init("f", .command)),
            ("refresh", "Refresh", .init("r", .command)),
            ("createBranch", "Create branch", .init("b", .command)),
            ("nextFile", "Next file", .init("n", .command)),
            ("previousFile", "Previous file", .init("p", .command)),
            ("nextFile.alternative", "Next file (alternative)", .init("\u{f703}", .option)),
            ("previousFile.alternative", "Previous file (alternative)", .init("\u{f702}", .option)),
            ("nextFile.vertical", "Next file (vertical alternative)", .init("\u{f701}", .option)),
            ("previousFile.vertical", "Previous file (vertical alternative)", .init("\u{f700}", .option)),
            ("refresh.alternative", "Refresh (alternative)", .init("\u{f708}")),
            ("addSelectionToMessage", "Add selection to message", .init("c")),
            ("conventionalType", "Conventional commit type", .init("t", .command)),
            ("conventionalScope", "Conventional commit scope", .init("t", [.command, .shift]))
        ]
        let stash: [(String, String, ApplicationKeyChord)] = [
            ("next", "Next stash", .init("n", .command)),
            ("previous", "Previous stash", .init("p", .command)),
            ("refresh", "Refresh", .init("\u{f708}"))
        ]
        let conflicts: [(String, String, ApplicationKeyChord)] = [
            ("base", "Choose base", .init("b")),
            ("local", "Choose local", .init("l")),
            ("remote", "Choose remote", .init("r")),
            ("merge", "Merge", .init("m")),
            ("rescan", "Rescan", .init("\u{f708}"))
        ]
        let tree: [(String, String, ApplicationKeyChord)] = [
            ("delete", "Delete", .init("\u{7f}")),
            ("rename", "Rename", .init("\u{f705}")),
            ("search", "Search", .init("\u{f706}"))
        ]
        let files: [(String, String, ApplicationKeyChord)] = [
            ("file.difftool", "Open with difftool", .init("\u{f706}")),
            ("file.open.local", "Open working-directory file", .init("\u{f707}", .shift)),
            ("file.stage", "Stage selected files", .init("s")),
            ("file.unstage", "Unstage selected files", .init("u"))
        ]
        let focus = [("tree", "Focus LeftPanel"), ("grid", "Focus revision grid"),
                     ("details", "Focus commit information"), ("diff", "Focus diff"),
                     ("files", "Focus file tree"), ("gpg", "Focus GPG information")]
        return menu.map { .init(id: $0.0, category: "Browse", title: $0.1, defaultChord: $0.2) }
            + unassigned.map { .init(id: $0.0, category: "Browse", title: $0.1, defaultChord: .init("")) }
            + navigation.map { .init(id: $0.0, category: "Revision grid", title: $0.1, defaultChord: $0.2) }
            + commit.map { .init(id: "commit." + $0.0, category: "Commit", title: $0.1, defaultChord: $0.2) }
            + stash.map { .init(id: "stash." + $0.0, category: "Stash", title: $0.1, defaultChord: $0.2) }
            + conflicts.map { .init(id: "conflict." + $0.0, category: "Conflict resolver", title: $0.1, defaultChord: $0.2) }
            + tree.map { .init(id: "tree." + $0.0, category: "Repository tree", title: $0.1, defaultChord: $0.2) }
            + files.map { .init(id: $0.0, category: "File status list", title: $0.1, defaultChord: $0.2) }
            + focus.enumerated().map { .init(id: "focus." + $0.element.0, category: "Browse panes", title: $0.element.1, defaultChord: .init(String($0.offset), .control)) }
            + FileViewerShortcut.allCases.map { .init(id: "viewer." + $0.rawValue, category: "File viewer", title: $0.title, defaultChord: $0.defaultChord) }
    }()

    static func chord(_ id: String, overrides: [String: ApplicationKeyChord]) -> ApplicationKeyChord {
        overrides[id] ?? definitions.first(where: { $0.id == id })?.defaultChord ?? .init("")
    }
    func shortcut(_ id: String) -> KeyboardShortcut? { Self.chord(id, overrides: AppSettingsStore.shared.hotkeyOverrides).swiftUI }
    func matching(_ event: NSEvent, category: String) -> String? {
        Self.matching(ApplicationKeyChord(event: event), category: category, overrides: AppSettingsStore.shared.hotkeyOverrides)
    }
    static func matching(_ chord: ApplicationKeyChord, category: String, overrides: [String: ApplicationKeyChord]) -> String? {
        guard !chord.key.isEmpty else { return nil }
        return Self.definitions.first { $0.category == category && Self.chord($0.id, overrides: overrides) == chord }?.id
    }
}

enum FileViewerShortcut: String, CaseIterable {
    case find, findNext, findPrevious, goToLine, increaseContext, decreaseContext, nextChange, previousChange
    case entireFile, syntax, treatAsText, ignoreWhitespace, stageLines, unstageLines
    var title: String {
        switch self {
        case .find: "Find"
        case .findNext: "Find next or open with difftool"
        case .findPrevious: "Find previous"
        case .goToLine: "Go to line"
        case .increaseContext: "Increase the number of lines of context"
        case .decreaseContext: "Decrease the number of lines of context"
        case .nextChange: "Next change"
        case .previousChange: "Previous change"
        case .entireFile: "Show entire file"
        case .syntax: "Show syntax highlighting"
        case .treatAsText: "Treat all files as text"
        case .ignoreWhitespace: "Ignore all whitespace changes"
        case .stageLines: "Stage selected lines"
        case .unstageLines: "Unstage selected lines"
        }
    }
    var defaultChord: ApplicationKeyChord {
        switch self {
        case .find: .init("f", .command)
        case .findNext: .init("\u{f706}")
        case .findPrevious: .init("\u{f706}", .shift)
        case .goToLine: .init("g", .command)
        case .increaseContext: .init("=", .command)
        case .decreaseContext: .init("-", .command)
        case .nextChange: .init("\u{f701}", .option)
        case .previousChange: .init("\u{f700}", .option)
        case .entireFile: .init("e", .command)
        case .syntax: .init("x")
        case .treatAsText: .init("")
        case .ignoreWhitespace: .init("w", [.command, .shift])
        case .stageLines: .init("s")
        case .unstageLines: .init("u")
        }
    }
}

final class FileViewerTableView: NSTableView {
    var onShortcut: ((FileViewerShortcut) -> Bool)?
    func performConfiguredShortcut(_ event: NSEvent) -> Bool {
        guard let id = ApplicationHotkeys.shared.matching(event, category: "File viewer"),
              let action = FileViewerShortcut(rawValue: String(id.dropFirst("viewer.".count))) else { return false }
        return onShortcut?(action) == true
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if window?.firstResponder === self, performConfiguredShortcut(event) { return true }
        return super.performKeyEquivalent(with: event)
    }
    override func keyDown(with event: NSEvent) {
        if !performConfiguredShortcut(event) { super.keyDown(with: event) }
    }
}

@MainActor
final class SettingsHotkeyRecorder: NSButton {
    var onRecord: ((ApplicationKeyChord) -> Void)?
    private var keyMonitor: Any?
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityRole(.button)
        setAccessibilityLabel("Record shortcut")
        setAccessibilityHelp("Activate, then press the desired key combination.")
        bezelStyle = .rounded
        target = self
        action = #selector(beginRecording)
    }
    required init?(coder: NSCoder) { nil }
    @objc private func beginRecording() {
        window?.makeKey()
        window?.makeFirstResponder(self)
    }
    override func accessibilityPerformPress() -> Bool { beginRecording(); return window?.firstResponder === self }
    override var needsPanelToBecomeKey: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func becomeFirstResponder() -> Bool {
        if keyMonitor == nil {
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, self.window?.firstResponder === self,
                      event.window === self.window else { return event }
                self.keyDown(with: event)
                return nil
            }
        }
        return true
    }
    override func resignFirstResponder() -> Bool {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        return true
    }
    deinit { if let keyMonitor { NSEvent.removeMonitor(keyMonitor) } }
    override func mouseDown(with event: NSEvent) { beginRecording() }
    override func keyDown(with event: NSEvent) {
        let chord = ApplicationKeyChord(event: event)
        title = chord.title
        onRecord?(chord)
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self else { return super.performKeyEquivalent(with: event) }
        keyDown(with: event)
        return true
    }
}
