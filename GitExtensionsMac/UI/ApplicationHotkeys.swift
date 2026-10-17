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
        let special = ["\r": "Return", "\u{f702}": "←", "\u{f703}": "→", "\u{f700}": "↑", "\u{f701}": "↓", "\u{f708}": "F5", "\u{1b}": "Escape", " ": "Space",
                       "\u{f705}": "F2", "\u{f706}": "F3", "\u{f707}": "F4", "\u{7f}": "Delete"]
        if let value = key.unicodeScalars.first?.value, key.unicodeScalars.count == 1, (0xF704...0xF726).contains(value) {
            return prefix + "F\(value - 0xF703)"
        }
        let navigation = ["\t": "Tab", "\u{8}": "Backspace", "\u{f728}": "Forward Delete", "\u{f729}": "Home", "\u{f72b}": "End", "\u{f72c}": "Page Up", "\u{f72d}": "Page Down"]
        return prefix + (special[key] ?? navigation[key] ?? key.uppercased())
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

    static let browseWindowCommands: Set<String> = ["stash", "stashPop", "stashStaged", "quickPull", "quickFetch", "quickPullOrFetch",
                                                    "quickPush", "toggleLeftPanel", "gitBash", "focusFilter", "focusNextTab",
                                                    "focusPrevTab", "goToSuperproject", "goToSubmodule", "goToChild", "goToParent",
                                                    "toggleArtificialAndHead", "openCommitsWithDifftool", "addNotes", "openWithDifftool",
                                                    "openWithDifftoolFirstToLocal", "openWithDifftoolSelectedToLocal",
                                                    "openAsTempFile", "openAsTempFileWith", "findFileInSelectedCommit", "editFile"]
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
            ("createTag", "Create tag", .init("t", .control)),
            ("manageWorktrees", "Manage worktrees", .init("w", [.control, .option])),
            ("pullFetch", "Pull/Fetch", .init("\u{f701}", .control)),
            ("push", "Push", .init("\u{f700}", .control)),
            ("quickFetch", "Quick fetch", .init("\u{f701}", [.control, .shift])),
            ("quickPull", "Quick pull", .init("p", [.control, .shift])),
            ("quickPullOrFetch", "Quick pull or fetch", .init("\u{f70b}")),
            ("quickPush", "Quick push", .init("\u{f700}", [.control, .shift])),
            ("rebase", "Rebase", .init("e", [.control, .shift])),
            ("stash", "Stash", .init("\u{f700}", [.control, .option])),
            ("stashPop", "Stash pop", .init("\u{f701}", [.control, .option])),
            ("stashStaged", "Stash staged", .init("\u{f700}", [.control, .shift, .option])),
            ("toggleLeftPanel", "Toggle left panel", .init("c", [.control, .option])),
            ("gitBash", "Terminal (Git bash)", .init("g", .control)),
            ("focusFilter", "Focus filter", .init("e", .control)),
            ("focusNextTab", "Focus next tab", .init("\t", .control)),
            ("focusPrevTab", "Focus previous tab", .init("\t", [.control, .shift])),
            ("goToSuperproject", "Go to superproject", .init("")),
            ("goToSubmodule", "Go to submodule", .init("")),
            ("goToChild", "Go to child", .init("n", .control)),
            ("goToParent", "Go to parent", .init("p", .control)),
            ("toggleArtificialAndHead", "Toggle between artificial and HEAD commits", .init("\\", .control)),
            ("openCommitsWithDifftool", "Open commits with difftool", .init("")),
            ("addNotes", "Add notes", .init("n", [.control, .shift])),
            ("findFileInSelectedCommit", "Find file in selected commit", .init("f", [.control, .shift])),
            ("openAsTempFile", "Open as temp file", .init("\u{f706}", .control)),
            ("openAsTempFileWith", "Open as temp file with", .init("\u{f706}", [.control, .shift])),
            ("openWithDifftool", "Open with difftool", .init("\u{f706}")),
            ("openWithDifftoolFirstToLocal", "Open with difftool first to local", .init("\u{f706}", .option)),
            ("openWithDifftoolSelectedToLocal", "Open with difftool selected to local", .init("\u{f706}", [.shift, .option])),
            ("editFile", "Edit file", .init("\u{f707}")),
            ("settings", "Settings", .init(",", .command))
        ]
        let unassigned: [(String, String)] = [
            ("initializeRepository", "New repository"), ("cloneRepository", "Clone repository"),
            ("gitGui", "Git GUI"), ("gitK", "GitK"),
            ("remoteRepositories", "Remote repositories"), ("manageSubmodules", "Manage submodules"),
            ("manageStashes", "Manage stashes"), ("resetChanges", "Reset changes"), ("cleanRepository", "Clean working directory"),
            ("deleteBranch", "Delete branch"), ("solveMergeConflicts", "Solve merge conflicts"),
            ("deleteTag", "Delete tag"), ("cherryPick", "Cherry-pick"),
            ("archiveRevision", "Archive revision"), ("checkoutRevision", "Checkout revision"), ("bisect", "Bisect"),
            ("reflog", "Show reflog"), ("formatPatch", "Format patch"), ("applyPatch", "Apply patch"), ("viewPatch", "View patch")
        ]
        let navigation: [(String, String, ApplicationKeyChord)] = [
            ("revision.view.highlightBranch", "Highlight selected branch", .init("b", [.control, .shift])),
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
            ("revision.other.reflog", "Show reflog references", .init("l", [.control, .shift])),
            ("revision.navigate.commit", "Go to commit", .init("g", [.control, .shift])),
            ("revision.navigate.backward", "Navigate backward", .init("\u{f702}", .option)),
            ("revision.navigate.forward", "Navigate forward", .init("\u{f703}", .option)),
            ("revision.navigate.toggleArtificial", "Toggle between artificial and HEAD commits", .init("\\", .control)),
            ("revision.navigate.forkPoint", "Select next fork point as diff base", .init("k", .control)),
            ("revision.filter.advanced", "Revision filter", .init("i", .control)),
            ("revision.filter.reset", "Reset revision filter", .init("i", [.control, .shift])),
            ("revision.filter.resetPath", "Reset revision path filter", .init("h", [.control, .shift])),
            ("revision.branches.all", "Show all branches", .init("a", [.control, .shift])),
            ("revision.branches.current", "Show current branch only", .init("u", [.control, .shift])),
            ("revision.branches.filtered", "Show filtered branches", .init("t", [.control, .shift])),
            ("revision.firstParent", "Show first parents", .init("s", [.control, .shift])),
            ("revision.view.remoteBranches", "Show remote branches", .init("r", [.control, .shift])),
            ("revision.hideMerges", "Toggle hide merge commits", .init("m", [.control, .shift])),
            ("revision.ref.delete", "Delete ref", .init("\u{7f}")),
            ("revision.ref.rename", "Rename ref", .init("\u{f705}")),
            ("revision.column.graph", "Toggle revision graph", .init("")),
            ("revision.view.authorDate", "Toggle author date / commit date", .init("")),
            ("revision.view.relativeDate", "Toggle show relative date", .init("")),
            ("revision.view.nonRelativesGray", "Toggle draw non relatives gray", .init("")),
            ("revision.view.gitNotes", "Toggle show git notes", .init("")),
            ("revision.column.notes", "Toggle show git notes column", .init("")),
            ("revision.commit.amend", "Create amend commit", .init("")),
            ("revision.compare.difftool", "Open commits with difftool", .init("")),
            ("revision.compare.setBase", "Select as BASE to compare", .init("l", .control)),
            ("revision.compare.base", "Compare to BASE", .init("r", .control)),
            ("revision.compare.worktree", "Compare to working directory", .init("d", .control)),
            ("revision.compare.branch", "Compare to branch", .init("")),
            ("revision.compare.current", "Compare with current branch", .init("")),
            ("revision.compare.selected", "Compare selected commits", .init("")),
            ("revision.sort.authorDate", "Toggle order revisions by date", .init(""))
        ]
        let commit: [(String, String, ApplicationKeyChord)] = [
            ("unstaged", "Focus unstaged files", .init("1", .command)),
            ("diff", "Focus diff", .init("2", .command)),
            ("staged", "Focus staged files", .init("3", .command)),
            ("message", "Focus commit message", .init("4", .command)),
            ("stageAll", "Stage all", .init("s", .command)),
            ("toggleSelectionFilter", "Toggle selection filter", .init("f", .command)),
            ("filter", "Filter files", .init("f", [.command, .option])),
            ("refresh", "Refresh", .init("r", .command)),
            ("createBranch", "Create branch", .init("b", .command)),
            ("openWithDifftool", "Open with difftool", .init("\u{f706}")),
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
            ("base", "Choose base", .init("3", .command)),
            ("local", "Choose local", .init("1", .command)),
            ("remote", "Choose remote", .init("2", .command)),
            ("merge", "Merge", .init("m")),
            ("rescan", "Rescan", .init("\u{f708}"))
        ]
        let tree: [(String, String, ApplicationKeyChord)] = [
            ("delete", "Delete", .init("\u{7f}")),
            ("rename", "Rename", .init("\u{f705}")),
            ("multiSelectWithChildren", "Multi-select with children", .init(" ", [.control, .shift])),
            ("search", "Search", .init("\u{f706}"))
        ]

        let files: [(String, String, ApplicationKeyChord)] = [
            ("file.copyPaths", "Copy full native paths", .init("c", .command)),
            ("file.save", "Save selected files as", .init("s", .command)),
            ("file.ignore.gitignore", "Add file to .gitignore", .init("")),
            ("file.blame", "Blame", .init("b")),
            ("file.delete", "Delete selected files", .init("\u{7f}")),
            ("file.edit.local", "Edit file", .init("\u{f707}")),
            ("file.filterGrid", "Filter file in grid", .init("f")),
            ("file.find", "Find file", .init("")),
            ("file.findCommit", "Find in commit files using git-grep (Diff tab)", .init("f", [.control, .shift])),
            ("file.findCommitFileTree", "Find in commit files using git-grep (File tree tab)", .init("")),
            ("file.goToFirstParent", "Go to first parent", .init("\u{f702}", .control)),
            ("file.goToLastParent", "Go to last parent", .init("\u{f703}", .control)),
            ("file.open.revision", "Open as temp file", .init("\u{f706}", .control)),
            ("file.open.revisionWith", "Open as temp file with", .init("\u{f706}", [.control, .shift])),
            ("file.difftool", "Open with difftool", .init("\u{f706}")),
            ("file.difftool.firstToLocal", "Open with difftool first to local", .init("\u{f706}", .option)),
            ("file.difftool.selectedToLocal", "Open with difftool selected to local", .init("\u{f706}", [.shift, .option])),
            ("file.open.local", "Open working-directory file", .init("\u{f707}", .shift)),
            ("file.open.localWith", "Open working-directory file with", .init("\u{f707}", [.control, .shift])),
            ("file.move", "Rename / move", .init("\u{f705}")),
            ("file.reset.first", "Reset selected files", .init("r")),
            ("file.selectFirstGroup", "Select first group changes", .init("a", .control)),
            ("file.showFileTree", "Show file tree", .init("t")),
            ("file.history", "Show history", .init("h")),
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
            + [.init(id: "focus.build", category: "Browse panes", title: "Focus build server status", defaultChord: .init("7", .control))]
            + [.init(id: "focus.output", category: "Browse panes", title: "Focus output history / toggle panel", defaultChord: .init("9", .control))]
            + FileViewerShortcut.allCases.map { .init(id: "viewer." + $0.rawValue, category: "File viewer", title: $0.title, defaultChord: $0.defaultChord) }
    }()

    static func chord(_ id: String, overrides: [String: ApplicationKeyChord]) -> ApplicationKeyChord {
        overrides[id] ?? definitions.first(where: { $0.id == id })?.defaultChord ?? .init("")
    }

    func chord(for id: String) -> ApplicationKeyChord? {
        let chord = Self.chord(id, overrides: AppSettingsStore.shared.hotkeyOverrides)
        return chord.key.isEmpty ? nil : chord
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
    case find, replace, findNext, findPrevious, goToLine, increaseContext, decreaseContext, nextChange, previousChange
    case nextOccurrence, previousOccurrence
    case entireFile, syntax, wordDiff, difftastic, treatAsText, ignoreWhitespace, stageLines, unstageLines, resetLines
    var title: String {
        switch self {
        case .find: "Find"
        case .replace: "Replace"
        case .findNext: "Find next or open with difftool"
        case .findPrevious: "Find previous"
        case .goToLine: "Go to line"
        case .increaseContext: "Increase the number of lines of context"
        case .decreaseContext: "Decrease the number of lines of context"
        case .nextChange: "Next change"
        case .previousChange: "Previous change"
        case .nextOccurrence: "Next occurrence"
        case .previousOccurrence: "Previous occurrence"
        case .entireFile: "Show entire file"
        case .syntax: "Show syntax highlighting"
        case .wordDiff: "Git word diff"
        case .difftastic: "Difftastic"
        case .treatAsText: "Treat all files as text"
        case .ignoreWhitespace: "Ignore all whitespace changes"
        case .stageLines: "Stage selected lines"
        case .unstageLines: "Unstage selected lines"
        case .resetLines: "Reset selected lines"
        }
    }
    var defaultChord: ApplicationKeyChord {
        switch self {
        case .find: .init("f", .command)
        case .replace: .init("f", [.command, .option])
        case .findNext: .init("\u{f706}")
        case .findPrevious: .init("\u{f706}", .shift)
        case .goToLine: .init("g", .command)
        case .increaseContext: .init("=", .command)
        case .decreaseContext: .init("-", .command)
        case .nextChange: .init("\u{f701}", .option)
        case .previousChange: .init("\u{f700}", .option)
        case .nextOccurrence: .init("\u{f703}", .option)
        case .previousOccurrence: .init("\u{f702}", .option)
        case .entireFile: .init("e", .command)
        case .syntax: .init("x")
        case .wordDiff: .init("d", .command)
        case .difftastic: .init("t", .command)
        case .treatAsText: .init("")
        case .ignoreWhitespace: .init("w", [.command, .shift])
        case .stageLines: .init("s")
        case .unstageLines: .init("u")
        case .resetLines: .init("r")
        }
    }
}

final class FileViewerTableView: NSTableView {
    var onCopy: (() -> Void)?
    @objc func copy(_ sender: Any?) { onCopy?() }
    var onShortcut: ((FileViewerShortcut) -> Bool)?
    var onScrollBoundary: ((Bool) -> Void)?
    private var lastBoundary = -Double.infinity
    override func scrollWheel(with event: NSEvent) {
        if let callback = onScrollBoundary, let scroll = enclosingScrollView,
           event.scrollingDeltaX == 0, event.scrollingDeltaY != 0,
           event.momentumPhase.isEmpty,
           event.modifierFlags.contains(.option) || AppSettingsStore.shared.preferences.automaticContinuousScroll {
            let forward = event.scrollingDeltaY < 0
            let bounds = scroll.contentView.bounds
            let atBoundary = forward ? bounds.maxY >= frame.height - 1 : bounds.minY <= 1
            let delay = Double(max(0, AppSettingsStore.shared.preferences.automaticContinuousScrollDelay)) / 1000
            if atBoundary && event.timestamp - lastBoundary >= delay {
                lastBoundary = event.timestamp; callback(forward); return
            }
        }
        super.scrollWheel(with: event)
    }
    func performConfiguredShortcut(_ event: NSEvent) -> Bool {
        guard let id = ApplicationHotkeys.shared.matching(event, category: "File viewer"),
              let action = FileViewerShortcut(rawValue: String(id.dropFirst("viewer.".count))) else { return false }
        return onShortcut?(action) == true
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let responder = window?.firstResponder as? NSView
        let editorOwner = (responder as? NSTextView)?.delegate as? NSView
        let ownsFocus = responder === self || responder?.isDescendant(of: self) == true || editorOwner?.isDescendant(of: self) == true
        if ownsFocus, performConfiguredShortcut(event) { return true }
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

@MainActor
final class HotkeysSettingsEditor: NSView, NSTableViewDataSource, NSTableViewDelegate {
    let categories = NSTableView()
    let commands = NSTableView()
    let recorder = SettingsHotkeyRecorder(frame: .zero)
    let applyBinding = NSButton(title: "Apply", target: nil, action: nil)
    let clearBinding = NSButton(title: "Clear", target: nil, action: nil)
    let reset = NSButton(title: "Reset all Hotkeys to defaults", target: nil, action: nil)
    private(set) var overrides: [String: ApplicationKeyChord]
    private(set) var pendingChord = ApplicationKeyChord("")
    private(set) var selectedCategory: String?
    private(set) var selectedCommand: String?
    var onChange: (([String: ApplicationKeyChord]) -> Void)?
    var onSelection: ((String?, String?) -> Void)?
    private let definitions: [ApplicationHotkeyDefinition]
    let categoryNames: [String]
    private let usedChords: [ApplicationKeyChord]
    private var recordColor: NSColor = .systemRed
    var displayedCommands: [ApplicationHotkeyDefinition] {
        let values = definitions.filter { $0.category == selectedCategory || (selectedCategory == "Browse" && $0.category == "Browse panes") }
        let order = Self.commandOrder[selectedCategory ?? ""] ?? []
        let ranks = Dictionary(uniqueKeysWithValues: order.enumerated().map { ($0.element, $0.offset) })
        return values.enumerated().sorted {
            let left = ranks[$0.element.id] ?? (order.count + $0.offset)
            let right = ranks[$1.element.id] ?? (order.count + $1.offset)
            return left < right
        }.map(\.element)
    }
    private var visibleCommands: [ApplicationHotkeyDefinition] { displayedCommands }
    private static let commandOrder: [String: [String]] = [
        "Browse": ["addNotes", "checkoutBranch", "closeToDashboard", "commit", "createBranch", "createTag", "editFile", "findFileInSelectedCommit",
                   "focus.tree", "focus.grid", "focus.details", "focus.diff", "focus.files", "focus.gpg", "focus.build", "focus.output",
                   "focusNextTab", "focusPrevTab", "focusFilter", "gitBash", "gitGui", "gitK", "goToChild", "goToParent", "goToSubmodule", "goToSuperproject",
                   "manageWorktrees", "mergeBranches", "openAsTempFile", "openAsTempFileWith", "openCommitsWithDifftool", "openRepository", "settings",
                   "openWithDifftool", "openWithDifftoolFirstToLocal", "openWithDifftoolSelectedToLocal", "pullFetch", "push", "quickFetch", "quickPull", "quickPullOrFetch", "quickPush",
                   "rebase", "stash", "stashPop", "stashStaged", "toggleArtificialAndHead", "toggleLeftPanel"],
        "Commit": ["commit.addSelectionToMessage", "commit.conventionalType", "commit.conventionalScope", "commit.createBranch", "commit.unstaged", "commit.diff", "commit.staged", "commit.message",
                   "commit.openWithDifftool", "commit.refresh.alternative", "commit.nextFile", "commit.nextFile.vertical", "commit.nextFile.alternative", "commit.previousFile", "commit.previousFile.vertical", "commit.previousFile.alternative",
                   "commit.stageAll", "commit.toggleSelectionFilter"],
        "Repository tree": ["tree.delete", "tree.rename", "tree.multiSelectWithChildren"],
        "Revision grid": ["revision.compare.selected", "revision.compare.base", "revision.compare.branch", "revision.compare.current", "revision.compare.worktree",
                          "revision.commit.amend", "revision.commit.fixup", "revision.commit.squash", "revision.ref.delete", "revision.navigate.child", "revision.navigate.commit", "revision.navigate.firstParent", "revision.navigate.lastParent", "revision.navigate.mergeBase", "revision.navigate.parent",
                          "revision.navigate.backward", "revision.navigate.forward", "revision.search.next", "revision.compare.difftool", "revision.search.previous", "revision.ref.rename", "revision.filter.resetPath", "revision.filter.reset", "revision.filter.advanced",
                          "revision.compare.setBase", "revision.navigate.current", "revision.navigate.forkPoint", "revision.branches.all", "revision.branches.current", "revision.branches.filtered", "revision.firstParent", "revision.other.reflog", "revision.view.remoteBranches",
                          "revision.view.authorDate", "revision.navigate.toggleArtificial", "revision.view.nonRelativesGray", "revision.view.highlightBranch", "revision.sort.authorDate", "revision.column.graph", "revision.view.gitNotes", "revision.column.notes", "revision.hideMerges", "revision.view.relativeDate"],
        "File viewer": ["viewer.find", "viewer.replace", "viewer.findNext", "viewer.findPrevious", "viewer.goToLine", "viewer.increaseContext", "viewer.decreaseContext", "viewer.nextChange", "viewer.previousChange",
                        "viewer.entireFile", "viewer.syntax", "viewer.wordDiff", "viewer.difftastic", "viewer.treatAsText", "viewer.nextOccurrence", "viewer.previousOccurrence", "viewer.stageLines", "viewer.unstageLines", "viewer.resetLines", "viewer.ignoreWhitespace"],
        "File status list": ["file.ignore.gitignore", "file.blame", "file.delete", "file.edit.local", "file.filterGrid", "file.find", "file.findCommit", "file.findCommitFileTree", "file.goToFirstParent", "file.goToLastParent",
                             "file.open.revision", "file.open.revisionWith", "file.difftool", "file.difftool.firstToLocal", "file.difftool.selectedToLocal", "file.open.local", "file.open.localWith", "file.move", "file.reset.first", "file.selectFirstGroup", "file.showFileTree", "file.history", "file.stage", "file.unstage"]
    ]

    init(overrides: [String: ApplicationKeyChord], category: String? = nil, command: String? = nil) {
        self.overrides = overrides
        let registry = ApplicationHotkeys.definitions
        definitions = registry
        usedChords = registry.map { overrides[$0.id] ?? $0.defaultChord }
        let names = registry.map { $0.category == "Browse panes" ? "Browse" : $0.category }.reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        let sourceOrder = ["Commit", "Browse", "Repository tree", "Revision grid", "File viewer", "Conflict resolver", "File status list", "Stash", "Scripts"]
        categoryNames = sourceOrder.filter { names.contains($0) } + names.filter { !sourceOrder.contains($0) }
        selectedCategory = category
        selectedCommand = command
        super.init(frame: .zero)
        setAccessibilityIdentifier("Hotkeys.Editor")
        func list(_ table: NSTableView, id: String) -> NSScrollView {
            table.delegate = self
            table.dataSource = self
            table.rowHeight = AppSettingsStore.shared.applicationRowHeight(minimum: 22)
            table.allowsEmptySelection = true
            table.allowsMultipleSelection = false
            table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
            table.setAccessibilityIdentifier(id)
            let scroll = NSScrollView()
            scroll.documentView = table
            scroll.hasVerticalScroller = true
            scroll.hasHorizontalScroller = true
            scroll.borderType = .bezelBorder
            return scroll
        }
        categories.addTableColumn(NSTableColumn(identifier: .init("Category")))
        categories.headerView = nil
        let categoryScroll = list(categories, id: "Hotkeys.Categories")
        let commandColumn = NSTableColumn(identifier: .init("Command"))
        commandColumn.title = "Command"
        commandColumn.width = 222
        commandColumn.resizingMask = .userResizingMask
        let keyColumn = NSTableColumn(identifier: .init("Key"))
        keyColumn.title = "Key"
        keyColumn.resizingMask = [.autoresizingMask, .userResizingMask]
        commands.addTableColumn(commandColumn)
        commands.addTableColumn(keyColumn)
        let commandScroll = list(commands, id: "Hotkeys.Commands")
        let caption = NSTextField(labelWithString: "Hotkeyable Items")
        let hotkeyCaption = NSTextField(labelWithString: "Hotkey")
        hotkeyCaption.widthAnchor.constraint(equalToConstant: 120).isActive = true
        recorder.setAccessibilityIdentifier("Hotkeys.Recorder")
        recorder.setContentHuggingPriority(.defaultLow, for: .horizontal)
        recorder.onRecord = { [weak self] chord in
            guard let self, !chord.key.isEmpty else { return }
            self.pendingChord = chord
            self.updateRecorder()
        }
        applyBinding.target = self
        applyBinding.action = #selector(applySelected)
        applyBinding.setAccessibilityIdentifier("Hotkeys.ApplyBinding")
        clearBinding.target = self
        clearBinding.action = #selector(clearSelected)
        clearBinding.setAccessibilityIdentifier("Hotkeys.ClearBinding")
        for button in [applyBinding, clearBinding] { button.widthAnchor.constraint(equalToConstant: 100).isActive = true }
        reset.target = self
        reset.action = #selector(resetDefaults)
        reset.setAccessibilityIdentifier("Hotkeys.Reset")
        let binding = NSStackView(views: [hotkeyCaption, recorder, applyBinding, clearBinding])
        binding.spacing = 6
        binding.distribution = .fill
        binding.alignment = .centerY
        for child in [caption, categoryScroll, commandScroll, binding, reset] {
            child.translatesAutoresizingMaskIntoConstraints = false
            addSubview(child)
        }
        NSLayoutConstraint.activate([
            caption.leadingAnchor.constraint(equalTo: leadingAnchor), caption.topAnchor.constraint(equalTo: topAnchor),
            categoryScroll.leadingAnchor.constraint(equalTo: leadingAnchor), categoryScroll.widthAnchor.constraint(equalToConstant: 232),
            categoryScroll.topAnchor.constraint(equalTo: caption.bottomAnchor, constant: 4), categoryScroll.bottomAnchor.constraint(equalTo: binding.topAnchor, constant: -6),
            commandScroll.leadingAnchor.constraint(equalTo: categoryScroll.trailingAnchor, constant: 6), commandScroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            commandScroll.topAnchor.constraint(equalTo: categoryScroll.topAnchor), commandScroll.bottomAnchor.constraint(equalTo: categoryScroll.bottomAnchor),
            binding.leadingAnchor.constraint(equalTo: leadingAnchor), binding.trailingAnchor.constraint(equalTo: trailingAnchor),
            binding.bottomAnchor.constraint(equalTo: reset.topAnchor, constant: -6),
            reset.leadingAnchor.constraint(equalTo: leadingAnchor), reset.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
        if let category, let index = categoryNames.firstIndex(of: category) {
            categories.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
            if let command, let row = visibleCommands.firstIndex(where: { $0.id == command }) { commands.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false) }
        }
        updateRecorder()
    }

    required init?(coder: NSCoder) { nil }

    func numberOfRows(in tableView: NSTableView) -> Int { tableView === categories ? categoryNames.count : visibleCommands.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let text: String
        if tableView === categories { text = categoryNames[row] }
        else {
            let command = visibleCommands[row]
            text = tableColumn?.identifier.rawValue == "Command" ? command.title : ApplicationHotkeys.chord(command.id, overrides: overrides).title
        }
        let label = NSTextField(labelWithString: text)
        label.lineBreakMode = .byTruncatingTail
        label.toolTip = text
        return label
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        if notification.object as? NSTableView === categories {
            selectedCategory = categoryNames.indices.contains(categories.selectedRow) ? categoryNames[categories.selectedRow] : nil
            reloadCommands()
        } else {
            selectedCommand = visibleCommands.indices.contains(commands.selectedRow) ? visibleCommands[commands.selectedRow].id : nil
            pendingChord = selectedCommand.map { ApplicationHotkeys.chord($0, overrides: overrides) } ?? .init("")
            updateRecorder()
            onSelection?(selectedCategory, selectedCommand)
        }
    }

    private func updateRecorder() {
        if !pendingChord.key.isEmpty { recordColor = usedChords.contains(pendingChord) ? .systemRed : .labelColor }
        recorder.title = pendingChord.title
        recorder.attributedTitle = NSAttributedString(string: pendingChord.title, attributes: [.font: AppSettingsStore.shared.applicationFont(size: 13), .foregroundColor: recordColor])
    }

    private func reloadCommands() {
        selectedCommand = nil
        pendingChord = .init("")
        commands.deselectAll(nil)
        commands.reloadData()
        updateRecorder()
        onSelection?(selectedCategory, nil)
    }

    @objc private func applySelected() {
        guard let selectedCommand else { return }
        window?.makeFirstResponder(commands)
        overrides[selectedCommand] = pendingChord
        onChange?(overrides)
        reloadCommands()
    }

    @objc private func clearSelected() {
        guard let selectedCommand else { return }
        window?.makeFirstResponder(commands)
        overrides[selectedCommand] = .init("")
        onChange?(overrides)
        reloadCommands()
    }

    @objc private func resetDefaults() {
        overrides = [:]
        selectedCategory = nil
        selectedCommand = nil
        categories.deselectAll(nil)
        reloadCommands()
        onChange?(overrides)
    }
}
