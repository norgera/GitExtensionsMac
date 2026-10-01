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

    static let browseWindowCommands: Set<String> = ["stash", "stashPop", "stashStaged", "quickPull", "quickFetch", "quickPullOrFetch",
                                                    "quickPush", "toggleLeftPanel", "gitBash", "focusFilter", "focusNextTab",
                                                    "focusPrevTab", "goToSuperproject", "addNotes", "openWithDifftool",
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
            ("multiSelectWithChildren", "Multi-select with children", .init(" ", [.control, .shift])),
            ("search", "Search", .init("\u{f706}"))
        ]

        let files: [(String, String, ApplicationKeyChord)] = [
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
