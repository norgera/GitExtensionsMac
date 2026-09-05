import GitExtensionsCore
import GitCommands
import AppKit
import Foundation

enum ApplicationTheme: String, Codable, CaseIterable, Sendable {
    case system = "System default"
    case light = "Light"
    case dark = "Dark"
}

struct AppPreferences: Codable, Equatable, Sendable {
    var reopenLastRepository = true
    var maximumRecentRepositories = 20
    var theme: ApplicationTheme = .system
    var mergeCommonParentLanes = true
    var straightenGraphDiagonals = true
    var diffContextLines = 3
    var ignoreWhitespace = false
    var defaultSignOff = false
    var defaultAllowEmpty = false
    var autoStashDuringRebase = false
    var gitExecutablePath = "/usr/bin/git"
    var editorPath = ""
    var shellPath = "/bin/zsh"
    var externalDiffToolPath = ""
    var externalMergeToolPath = ""
    var signingKey = ""
}

enum PullActionPreference: String, Codable, CaseIterable, Sendable {
    case openDialog
    case merge
    case rebase
    case fetch
    case fetchAll
    case fetchPruneAll
}

enum PullAutoPopPreference: String, Codable, CaseIterable, Sendable {
    case ask
    case always
    case never
}

struct PullPreferences: Codable, Equatable, Sendable {
    var defaultAction: PullActionPreference = .merge
    var formAction: PullActionPreference = .merge
    var autoStash = false
    var autoPopStash: PullAutoPopPreference = .ask
    var includeUntrackedInAutoStash = false
    var recentURLs: [String] = []
    var helpExpanded = true
    var closeProcessOnSuccess = false
    var confirmFetchAndPruneAll = true
    var updateSubmodulesAfterPull: Bool? = nil
}

struct RepositoryCreationPreferences: Codable, Equatable, Sendable {
    var recentSources: [String] = []
    var cloneDestinationPath = ""
    var cloneWindowWidth = 647.0
    var cloneWindowHeight = 359.0
    var initWindowWidth = 542.0
    var initWindowHeight = 174.0
}

struct ResetPreferences: Codable, Equatable, Sendable {
    var checkoutOtherBranchAfterReset = true
}

struct RebasePreferences: Codable, Equatable, Sendable {
    var helpExpanded = true
}

struct CherryPickPreferences: Codable, Equatable, Sendable {
    var automaticallyCommit = false
    var addReference = false
}

struct StashPreferences: Codable, Equatable, Sendable {
    var keepIndex = false
    var includeUntracked = false
    var dontConfirmDrop = false
    var showStashCount = false
    var showStashesInRepositoryTree = true
    var windowWidth = 708.0
    var windowHeight = 520.0
    var dividerPosition = 280.0
}

struct TagPreferences: Codable, Equatable, Sendable {
    var showTagsInRevisionGrid = true
    var showTagsInRepositoryTree = true
}

enum RepositoryTreeRoot: String, Codable, CaseIterable, Sendable {
    case branches
    case remotes
    case worktrees
    case tags
    case submodules
    case stashes

    var title: String {
        switch self {
        case .branches: "Branches"
        case .remotes: "Remotes"
        case .worktrees: "Worktrees"
        case .tags: "Tags"
        case .submodules: "Submodules"
        case .stashes: "Stashes"
        }
    }
}

enum RepositoryTreeSortOrder: String, Codable, CaseIterable, Sendable {
    case ascending
    case descending
}

enum RepositoryTreeSortBy: String, Codable, CaseIterable, Sendable {
    case gitDefault
    case authorDate
    case committerDate
    case creatorDate
    case taggerDate
    case alphaNumeric
    case version
    case objectSize
    case originatingRemote

    var title: String {
        switch self {
        case .gitDefault: "Git default"
        case .authorDate: "Author date"
        case .committerDate: "Committer date"
        case .creatorDate: "Creator date"
        case .taggerDate: "Tagger date"
        case .alphaNumeric: "Alpha-numeric"
        case .version: "Version"
        case .objectSize: "Object size"
        case .originatingRemote: "Originating remote"
        }
    }
}

struct RepositoryTreePreferences: Codable, Equatable, Sendable {
    var visibleRoots = Set(RepositoryTreeRoot.allCases)
    var rootOrder = RepositoryTreeRoot.allCases
    var sortBy: RepositoryTreeSortBy = .gitDefault
    var sortOrder: RepositoryTreeSortOrder = .ascending

    init() {}

    private enum CodingKeys: String, CodingKey {
        case visibleRoots, rootOrder, sortBy, sortOrder
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        visibleRoots = try container.decodeIfPresent(Set<RepositoryTreeRoot>.self, forKey: .visibleRoots)
            ?? Set(RepositoryTreeRoot.allCases)
        rootOrder = try container.decodeIfPresent([RepositoryTreeRoot].self, forKey: .rootOrder)
            ?? RepositoryTreeRoot.allCases
        sortBy = try container.decodeIfPresent(RepositoryTreeSortBy.self, forKey: .sortBy) ?? .gitDefault
        sortOrder = try container.decodeIfPresent(RepositoryTreeSortOrder.self, forKey: .sortOrder) ?? .ascending
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(visibleRoots, forKey: .visibleRoots)
        try container.encode(rootOrder, forKey: .rootOrder)
        try container.encode(sortBy, forKey: .sortBy)
        try container.encode(sortOrder, forKey: .sortOrder)
    }

    mutating func normalize() {
        var seen = Set<RepositoryTreeRoot>()
        rootOrder = rootOrder.filter { seen.insert($0).inserted }
        rootOrder.append(contentsOf: RepositoryTreeRoot.allCases.filter { seen.insert($0).inserted })
        visibleRoots.formIntersection(RepositoryTreeRoot.allCases)
    }
}

struct RemoteManagementPreferences: Codable, Equatable, Sendable {
    var recentURLs: [String] = []
    var showAdvancedOptions = false
    var windowWidth = 950.0
    var windowHeight = 470.0
}

struct MergePreferences: Codable, Equatable, Sendable {
    var noCommit = false
    var noFastForward = false
    var addLogMessages = false
    var logMessagesCount = 20
    var helpExpanded = true
    var closeProcessOnSuccess = false
}

enum CheckoutLocalChangesPreference: String, Codable, CaseIterable, Sendable {
    case keep
    case merge
    case stash
    case force
}

struct CheckoutBranchPreferences: Codable, Equatable, Sendable {
    var checkForUncommittedChanges = true
    var alwaysShowDialog = false
    var localChangesAction: CheckoutLocalChangesPreference = .keep
    var useDefaultLocalChangesAction = false
    var createLocalBranchForRemote = false
    var autoPopStash: PullAutoPopPreference = .ask
    var confirmDirectCheckout = false
    var dontConfirmDeleteUnmerged = false
    var autoNormaliseBranchName = true
    var branchNameReplacement = "_"
    var updateSubmodulesOnCheckout: Bool? = nil
    var checkoutWindowWidth = 626.0
    var createWindowWidth = 580.0
    var deleteWindowWidth = 420.0
    var renameWindowWidth = 484.0
}

enum PushRejectedActionPreference: String, Codable, CaseIterable, Sendable {
    case ask
    case none
    case defaultPull
    case rebase
    case merge
}

struct PushPreferences: Codable, Equatable, Sendable {
    var recursiveSubmodules: RepositoryPushSubmoduleMode = .check
    var recentURLs: [String] = []
    var showAdvancedOptions = false
    var confirmNewBranch = true
    var confirmAddTrackingReference = true
    var rejectedAction: PushRejectedActionPreference = .ask
    var loadRemoteBranchesDirectly = false
}

struct CommitMessageTemplate: Codable, Equatable, Hashable, Sendable, Identifiable {
    var id = UUID()
    var name = ""
    var text = ""
    var expandsBranchRegularExpressions = false
}

struct CommitValidationPreferences: Codable, Equatable, Sendable {
    var maximumSubjectLength = 0
    var maximumLineLength = 0
    var requireEmptySecondLine = false
    var indentAfterFirstLine = true
    var autoWrap = true
    var regularExpression = ""
}

struct CommitPreferences: Codable, Equatable, Sendable {
    var historyLimit = 6
    var showOnlyMyMessages = false
    var ensureSecondLineEmpty = true
    var rememberAmendState = true
    var closeAfterCommit = true
    var closeAfterLastCommit = true
    var refreshOnFocus = false
    var selectStagedOnMessageFocus = true
    var showCommitAndPush = true
    var showResetUnstaged = true
    var showResetAll = true
    var confirmAmend = true
    var confirmDetachedHead = true
    var forceWithLeaseAfterAmend = false
    var lastCommitMessage = ""
    var templates: [CommitMessageTemplate] = []
    var validation = CommitValidationPreferences()
    var windowWidth = 918.0
    var windowHeight = 644.0
    var mainDivider = 397.0
    var fileDivider = 274.0
    var contentDivider = 426.0
    var commandDivider = 171.0
}

enum FileStatusGrouping: String, Codable, CaseIterable, Sendable {
    case path
    case fileExtension
    case status
}

struct FileStatusListPreferences: Codable, Equatable, Sendable {
    var grouping: FileStatusGrouping = .path
    var isTreeMode = true
    var usesDenseTree = true
    var showsGroupNodesInFlatList = false
    var showsUntrackedFiles = true

    init(
        grouping: FileStatusGrouping = .path,
        isTreeMode: Bool = true,
        usesDenseTree: Bool = true,
        showsGroupNodesInFlatList: Bool = false,
        showsUntrackedFiles: Bool = true
    ) {
        self.grouping = grouping
        self.isTreeMode = isTreeMode
        self.usesDenseTree = usesDenseTree
        self.showsGroupNodesInFlatList = showsGroupNodesInFlatList
        self.showsUntrackedFiles = showsUntrackedFiles
    }

    private enum CodingKeys: String, CodingKey {
        case grouping, isTreeMode, usesDenseTree, showsGroupNodesInFlatList, showsUntrackedFiles
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        grouping = try values.decodeIfPresent(FileStatusGrouping.self, forKey: .grouping) ?? .path
        isTreeMode = try values.decodeIfPresent(Bool.self, forKey: .isTreeMode) ?? true
        usesDenseTree = try values.decodeIfPresent(Bool.self, forKey: .usesDenseTree) ?? true
        showsGroupNodesInFlatList = try values.decodeIfPresent(Bool.self, forKey: .showsGroupNodesInFlatList) ?? false
        showsUntrackedFiles = try values.decodeIfPresent(Bool.self, forKey: .showsUntrackedFiles) ?? true
    }
}

struct FileViewerPreferences: Codable, Equatable, Sendable {
    var whitespace: DiffWhitespaceMode = .none
    var contextLines = 3
    var showsEntireFile = false
    var treatsAllFilesAsText = false
    var showsNonPrintingCharacters = false
    var showsSyntaxHighlighting = true
    var textEncoding: RepositoryTextEncoding = .automatic

    var diffOptions: FileDiffOptions {
        FileDiffOptions(
            whitespace: whitespace,
            contextLines: contextLines,
            showsEntireFile: showsEntireFile,
            treatsAllFilesAsText: treatsAllFilesAsText
        )
    }
}

enum CommitMessageValidationIssue: Equatable, Sendable {
    case subjectTooLong(actual: Int, maximum: Int)
    case lineTooLong(line: Int, actual: Int, maximum: Int)
    case secondLineMustBeEmpty
    case regularExpressionMismatch(String)
    case invalidRegularExpression(String)

    var localizedDescription: String {
        switch self {
        case .subjectTooLong(let actual, let maximum):
            "The first line contains \(actual) characters; the configured maximum is \(maximum)."
        case .lineTooLong(let line, let actual, let maximum):
            "Line \(line) contains \(actual) characters; the configured maximum is \(maximum)."
        case .secondLineMustBeEmpty:
            "The second line of the commit message must be empty."
        case .regularExpressionMismatch(let expression):
            "The commit message does not match the configured regular expression: \(expression)"
        case .invalidRegularExpression(let expression):
            "The configured commit-message regular expression is invalid: \(expression)"
        }
    }
}

enum CommitMessageValidator {
    static func issues(
        in message: String,
        preferences: CommitValidationPreferences,
        skipRegularExpression: Bool = false,
        regularExpressionText: String? = nil
    ) -> [CommitMessageValidationIssue] {
        let lines = message.components(separatedBy: .newlines)
        var result: [CommitMessageValidationIssue] = []
        if preferences.maximumSubjectLength > 0,
           let subject = lines.first(where: { !$0.isEmpty }),
           subject.count > preferences.maximumSubjectLength {
            result.append(.subjectTooLong(actual: subject.count, maximum: preferences.maximumSubjectLength))
        }
        if preferences.maximumLineLength > 0 {
            for (offset, line) in lines.enumerated() where line.count > preferences.maximumLineLength {
                result.append(.lineTooLong(line: offset + 1, actual: line.count, maximum: preferences.maximumLineLength))
            }
        }
        if preferences.requireEmptySecondLine, lines.count > 2, !lines[1].isEmpty {
            result.append(.secondLineMustBeEmpty)
        }
        let expression = preferences.regularExpression.trimmingCharacters(in: .whitespacesAndNewlines)
        if !skipRegularExpression, !expression.isEmpty,
           let regex = try? NSRegularExpression(pattern: expression) {
            let text = regularExpressionText ?? message
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            if regex.firstMatch(in: text, range: range) == nil {
                result.append(.regularExpressionMismatch(expression))
            }
        }
        return result
    }
}

enum CommitTemplateExpander {
    static func expand(_ text: String, forBranch branch: String, enabled: Bool) -> String {
        guard enabled,
              let placeholder = try? NSRegularExpression(pattern: #"\{\{(.*?)\}\}(?:\[(\d+)\])?"#) else { return text }
        var result = text
        let matches = placeholder.matches(in: text, range: NSRange(text.startIndex..<text.endIndex, in: text))
        for match in matches.reversed() {
            guard let whole = Range(match.range(at: 0), in: result),
                  let patternRange = Range(match.range(at: 1), in: text) else { continue }
            let pattern = String(text[patternRange])
            let groupIndex: Int
            if match.range(at: 2).location != NSNotFound,
               let indexRange = Range(match.range(at: 2), in: text) {
                groupIndex = Int(text[indexRange]) ?? 1
            } else {
                groupIndex = 1
            }
            let replacement: String
            if let branchRegex = try? NSRegularExpression(pattern: pattern),
               let branchMatch = branchRegex.firstMatch(in: branch, range: NSRange(branch.startIndex..<branch.endIndex, in: branch)),
               groupIndex < branchMatch.numberOfRanges,
               let group = Range(branchMatch.range(at: groupIndex), in: branch) {
                replacement = String(branch[group])
            } else {
                replacement = ""
            }
            result.replaceSubrange(whole, with: replacement)
        }
        return result
    }
}

enum CommitMessageAutoFormatter {
    static func format(_ message: String, preferences: CommitValidationPreferences) -> String {
        guard !message.isEmpty else { return message }
        var lines = message.components(separatedBy: "\n")
        if preferences.requireEmptySecondLine, lines.count > 1, !lines[1].isEmpty {
            let body = (preferences.indentAfterFirstLine ? " - " : "") + lines[1]
            lines[1] = ""
            lines.insert(body, at: 2)
        }
        guard preferences.autoWrap, preferences.maximumLineLength > 0 else {
            return lines.joined(separator: "\n")
        }
        let firstBodyLine = preferences.requireEmptySecondLine ? 2 : 1
        guard lines.count > firstBodyLine else { return lines.joined(separator: "\n") }
        var index = firstBodyLine
        while index < lines.count {
            let wrapped = wrap(lines[index], limit: preferences.maximumLineLength)
            lines.replaceSubrange(index...index, with: wrapped)
            index += max(1, wrapped.count)
        }
        return lines.joined(separator: "\n")
    }

    private static func wrap(_ line: String, limit: Int) -> [String] {
        guard limit > 0, line.count > limit else { return [line] }
        var remaining = line
        var result: [String] = []
        while remaining.count > limit {
            let boundary = remaining.index(remaining.startIndex, offsetBy: limit)
            let prefix = remaining[..<boundary]
            let breakIndex = prefix.lastIndex(where: { $0.isWhitespace }) ?? boundary
            let rawLinePart = remaining[..<breakIndex]
            let linePart = String(rawLinePart.reversed().drop(while: { $0.isWhitespace }).reversed())
            if linePart.isEmpty {
                result.append(String(prefix))
                remaining = String(remaining[boundary...])
            } else {
                result.append(linePart)
                remaining = String(remaining[breakIndex...]).trimmingCharacters(in: .whitespaces)
            }
        }
        result.append(remaining)
        return result
    }
}

struct RecentRepository: Codable, Equatable, Sendable {
    let path: String
    var lastOpened: Date
}

@MainActor
final class AppSettingsStore {
    static let shared = AppSettingsStore()

    private enum Key {
        static let preferences = "GitExtensionsMac.preferences.v1"
        static let recentRepositories = "GitExtensionsMac.recentRepositories.v1"
        static let lastRepository = "GitExtensionsMac.lastRepository"
        static let pullPreferences = "GitExtensionsMac.pullPreferences.v1"
        static let pushPreferences = "GitExtensionsMac.pushPreferences.v1"
        static let commitPreferences = "GitExtensionsMac.commitPreferences.v1"
        static let fileStatusListPreferences = "GitExtensionsMac.fileStatusListPreferences.v1"
        static let fileViewerPreferences = "GitExtensionsMac.fileViewerPreferences.v1"
        static let rebasePreferences = "GitExtensionsMac.rebasePreferences.v1"
        static let cherryPickPreferences = "GitExtensionsMac.cherryPickPreferences.v1"
        static let stashPreferences = "GitExtensionsMac.stashPreferences.v1"
        static let tagPreferences = "GitExtensionsMac.tagPreferences.v1"
        static let repositoryTreePreferences = "GitExtensionsMac.repositoryTreePreferences.v1"
        static let remoteManagementPreferences = "GitExtensionsMac.remoteManagementPreferences.v1"
        static let mergePreferences = "GitExtensionsMac.mergePreferences.v1"
        static let checkoutBranchPreferences = "GitExtensionsMac.checkoutBranchPreferences.v1"
        static let repositoryCreationPreferences = "GitExtensionsMac.repositoryCreationPreferences.v1"
        static let resetPreferences = "GitExtensionsMac.resetPreferences.v1"
        static let showReflogReferences = "GitExtensionsMac.showReflogReferences"
    }

    private let defaults: UserDefaults
    private(set) var preferences: AppPreferences
    private(set) var recentRepositories: [RecentRepository]
    private(set) var pullPreferences: PullPreferences
    private(set) var pushPreferences: PushPreferences
    private(set) var commitPreferences: CommitPreferences
    private(set) var fileStatusListPreferences: FileStatusListPreferences
    private(set) var fileViewerPreferences: FileViewerPreferences
    private(set) var rebasePreferences: RebasePreferences
    private(set) var cherryPickPreferences: CherryPickPreferences
    private(set) var stashPreferences: StashPreferences
    private(set) var tagPreferences: TagPreferences
    private(set) var repositoryTreePreferences: RepositoryTreePreferences
    private(set) var remoteManagementPreferences: RemoteManagementPreferences
    private(set) var mergePreferences: MergePreferences
    private(set) var checkoutBranchPreferences: CheckoutBranchPreferences
    private(set) var repositoryCreationPreferences: RepositoryCreationPreferences
    private(set) var resetPreferences: ResetPreferences
    private(set) var showReflogReferences: Bool

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let decoder = JSONDecoder()
        let loadedPreferences = defaults.data(forKey: Key.preferences)
            .flatMap { try? decoder.decode(AppPreferences.self, from: $0) }
            ?? AppPreferences()
        preferences = loadedPreferences
        recentRepositories = defaults.data(forKey: Key.recentRepositories)
            .flatMap { try? decoder.decode([RecentRepository].self, from: $0) }
            ?? []
        pullPreferences = defaults.data(forKey: Key.pullPreferences)
            .flatMap { try? decoder.decode(PullPreferences.self, from: $0) }
            ?? PullPreferences()
        pushPreferences = defaults.data(forKey: Key.pushPreferences)
            .flatMap { try? decoder.decode(PushPreferences.self, from: $0) }
            ?? PushPreferences()
        commitPreferences = defaults.data(forKey: Key.commitPreferences)
            .flatMap { try? decoder.decode(CommitPreferences.self, from: $0) }
            ?? CommitPreferences()
        fileStatusListPreferences = defaults.data(forKey: Key.fileStatusListPreferences)
            .flatMap { try? decoder.decode(FileStatusListPreferences.self, from: $0) }
            ?? FileStatusListPreferences()
        fileViewerPreferences = defaults.data(forKey: Key.fileViewerPreferences)
            .flatMap { try? decoder.decode(FileViewerPreferences.self, from: $0) }
            ?? {
                var value = FileViewerPreferences()
                value.contextLines = loadedPreferences.diffContextLines
                value.whitespace = loadedPreferences.ignoreWhitespace ? .all : .none
                return value
            }()
        rebasePreferences = defaults.data(forKey: Key.rebasePreferences)
            .flatMap { try? decoder.decode(RebasePreferences.self, from: $0) }
            ?? RebasePreferences()
        cherryPickPreferences = defaults.data(forKey: Key.cherryPickPreferences)
            .flatMap { try? decoder.decode(CherryPickPreferences.self, from: $0) }
            ?? CherryPickPreferences()
        stashPreferences = defaults.data(forKey: Key.stashPreferences)
            .flatMap { try? decoder.decode(StashPreferences.self, from: $0) }
            ?? StashPreferences()
        tagPreferences = defaults.data(forKey: Key.tagPreferences)
            .flatMap { try? decoder.decode(TagPreferences.self, from: $0) }
            ?? TagPreferences()
        repositoryTreePreferences = defaults.data(forKey: Key.repositoryTreePreferences)
            .flatMap { try? decoder.decode(RepositoryTreePreferences.self, from: $0) }
            ?? RepositoryTreePreferences()
        repositoryTreePreferences.normalize()
        if defaults.data(forKey: Key.repositoryTreePreferences) == nil {
            if !tagPreferences.showTagsInRepositoryTree { repositoryTreePreferences.visibleRoots.remove(.tags) }
            if !stashPreferences.showStashesInRepositoryTree { repositoryTreePreferences.visibleRoots.remove(.stashes) }
        }
        remoteManagementPreferences = defaults.data(forKey: Key.remoteManagementPreferences)
            .flatMap { try? decoder.decode(RemoteManagementPreferences.self, from: $0) }
            ?? RemoteManagementPreferences()
        mergePreferences = defaults.data(forKey: Key.mergePreferences)
            .flatMap { try? decoder.decode(MergePreferences.self, from: $0) }
            ?? MergePreferences()
        checkoutBranchPreferences = defaults.data(forKey: Key.checkoutBranchPreferences)
            .flatMap { try? decoder.decode(CheckoutBranchPreferences.self, from: $0) }
            ?? CheckoutBranchPreferences()
        repositoryCreationPreferences = defaults.data(forKey: Key.repositoryCreationPreferences)
            .flatMap { try? decoder.decode(RepositoryCreationPreferences.self, from: $0) }
            ?? RepositoryCreationPreferences()
        resetPreferences = defaults.data(forKey: Key.resetPreferences)
            .flatMap { try? decoder.decode(ResetPreferences.self, from: $0) }
            ?? ResetPreferences()
        showReflogReferences = defaults.object(forKey: Key.showReflogReferences) as? Bool ?? false
        recentRepositories.removeAll { !FileManager.default.fileExists(atPath: $0.path) }
        applyAppearance()
    }

    var lastRepositoryPath: String? {
        defaults.string(forKey: Key.lastRepository)
    }

    func save(_ preferences: AppPreferences) {
        self.preferences = preferences
        defaults.set(try? JSONEncoder().encode(preferences), forKey: Key.preferences)
        var viewer = fileViewerPreferences
        viewer.contextLines = preferences.diffContextLines
        viewer.whitespace = preferences.ignoreWhitespace ? .all : .none
        if viewer != fileViewerPreferences {
            fileViewerPreferences = viewer
            defaults.set(try? JSONEncoder().encode(viewer), forKey: Key.fileViewerPreferences)
            NotificationCenter.default.post(name: .fileViewerPreferencesDidChange, object: self)
        }
        trimRecentRepositories()
        applyAppearance()
        NotificationCenter.default.post(name: .appPreferencesDidChange, object: self)
    }

    func savePullPreferences(_ preferences: PullPreferences) {
        pullPreferences = preferences
        defaults.set(try? JSONEncoder().encode(preferences), forKey: Key.pullPreferences)
        NotificationCenter.default.post(name: .pullPreferencesDidChange, object: self)
    }

    func savePushPreferences(_ preferences: PushPreferences) {
        pushPreferences = preferences
        defaults.set(try? JSONEncoder().encode(preferences), forKey: Key.pushPreferences)
        NotificationCenter.default.post(name: .pushPreferencesDidChange, object: self)
    }

    func saveCommitPreferences(_ preferences: CommitPreferences) {
        commitPreferences = preferences
        defaults.set(try? JSONEncoder().encode(preferences), forKey: Key.commitPreferences)
        NotificationCenter.default.post(name: .commitPreferencesDidChange, object: self)
    }

    func saveFileStatusListPreferences(_ preferences: FileStatusListPreferences) {
        fileStatusListPreferences = preferences
        defaults.set(try? JSONEncoder().encode(preferences), forKey: Key.fileStatusListPreferences)
        NotificationCenter.default.post(name: .fileStatusListPreferencesDidChange, object: self)
    }

    func saveFileViewerPreferences(_ preferences: FileViewerPreferences) {
        fileViewerPreferences = preferences
        defaults.set(try? JSONEncoder().encode(preferences), forKey: Key.fileViewerPreferences)
        self.preferences.diffContextLines = preferences.contextLines
        self.preferences.ignoreWhitespace = preferences.whitespace != .none
        defaults.set(try? JSONEncoder().encode(self.preferences), forKey: Key.preferences)
        NotificationCenter.default.post(name: .fileViewerPreferencesDidChange, object: self)
    }

    func saveRebasePreferences(_ preferences: RebasePreferences) {
        rebasePreferences = preferences
        defaults.set(try? JSONEncoder().encode(preferences), forKey: Key.rebasePreferences)
    }

    func saveCherryPickPreferences(_ preferences: CherryPickPreferences) {
        cherryPickPreferences = preferences
        defaults.set(try? JSONEncoder().encode(preferences), forKey: Key.cherryPickPreferences)
    }

    func saveStashPreferences(_ preferences: StashPreferences) {
        stashPreferences = preferences
        defaults.set(try? JSONEncoder().encode(preferences), forKey: Key.stashPreferences)
    }

    func saveTagPreferences(_ preferences: TagPreferences) {
        tagPreferences = preferences
        defaults.set(try? JSONEncoder().encode(preferences), forKey: Key.tagPreferences)
    }

    func saveRepositoryTreePreferences(_ preferences: RepositoryTreePreferences) {
        var preferences = preferences
        preferences.normalize()
        repositoryTreePreferences = preferences
        defaults.set(try? JSONEncoder().encode(preferences), forKey: Key.repositoryTreePreferences)
    }

    func saveRemoteManagementPreferences(_ preferences: RemoteManagementPreferences) {
        remoteManagementPreferences = preferences
        defaults.set(try? JSONEncoder().encode(preferences), forKey: Key.remoteManagementPreferences)
    }

    func recordRemoteURL(_ value: String) {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        var preferences = remoteManagementPreferences
        preferences.recentURLs.removeAll { $0 == value }
        preferences.recentURLs.insert(value, at: 0)
        preferences.recentURLs = Array(preferences.recentURLs.prefix(20))
        saveRemoteManagementPreferences(preferences)
    }

    func replaceRemoteURLHistory(_ oldValue: String?, with newValue: String) {
        let oldValue = oldValue?.trimmingCharacters(in: .whitespacesAndNewlines)
        let newValue = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
        var preferences = remoteManagementPreferences
        if let oldValue, !oldValue.isEmpty, oldValue != newValue {
            preferences.recentURLs.removeAll { $0 == oldValue }
        }
        if !newValue.isEmpty {
            preferences.recentURLs.removeAll { $0 == newValue }
            preferences.recentURLs.insert(newValue, at: 0)
        }
        preferences.recentURLs = Array(preferences.recentURLs.prefix(20))
        saveRemoteManagementPreferences(preferences)
    }

    func saveMergePreferences(_ preferences: MergePreferences) {
        mergePreferences = preferences
        defaults.set(try? JSONEncoder().encode(preferences), forKey: Key.mergePreferences)
    }

    func saveCheckoutBranchPreferences(_ preferences: CheckoutBranchPreferences) {
        checkoutBranchPreferences = preferences
        defaults.set(try? JSONEncoder().encode(preferences), forKey: Key.checkoutBranchPreferences)
    }

    func saveRepositoryCreationPreferences(_ preferences: RepositoryCreationPreferences) {
        repositoryCreationPreferences = preferences
        defaults.set(try? JSONEncoder().encode(preferences), forKey: Key.repositoryCreationPreferences)
    }

    func saveResetPreferences(_ preferences: ResetPreferences) {
        resetPreferences = preferences
        defaults.set(try? JSONEncoder().encode(preferences), forKey: Key.resetPreferences)
    }

    func saveShowReflogReferences(_ show: Bool) {
        showReflogReferences = show
        defaults.set(show, forKey: Key.showReflogReferences)
    }

    func recordCloneSource(_ source: String) {
        let source = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !source.isEmpty else { return }
        var preferences = repositoryCreationPreferences
        preferences.recentSources.removeAll { $0 == source }
        preferences.recentSources.insert(source, at: 0)
        preferences.recentSources = Array(preferences.recentSources.prefix(20))
        saveRepositoryCreationPreferences(preferences)
    }

    func recordPullURL(_ value: String) {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        var preferences = pullPreferences
        preferences.recentURLs.removeAll { $0 == value }
        preferences.recentURLs.insert(value, at: 0)
        preferences.recentURLs = Array(preferences.recentURLs.prefix(20))
        savePullPreferences(preferences)
    }

    func recordPushURL(_ value: String) {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        var preferences = pushPreferences
        preferences.recentURLs.removeAll { $0 == value }
        preferences.recentURLs.insert(value, at: 0)
        preferences.recentURLs = Array(preferences.recentURLs.prefix(20))
        savePushPreferences(preferences)
    }

    func recordOpenedRepository(_ url: URL) {
        recordRecentRepository(url)
        defaults.set(url.standardizedFileURL.path, forKey: Key.lastRepository)
    }

    func recordRecentRepository(_ url: URL) {
        let path = url.standardizedFileURL.path
        recentRepositories.removeAll { $0.path == path }
        recentRepositories.insert(RecentRepository(path: path, lastOpened: Date()), at: 0)
        trimRecentRepositories()
    }

    func removeRecentRepository(path: String) {
        recentRepositories.removeAll { $0.path == path }
        persistRecentRepositories()
    }

    func clearRecentRepositories() {
        recentRepositories.removeAll()
        persistRecentRepositories()
    }

    private func trimRecentRepositories() {
        recentRepositories = Array(recentRepositories.prefix(max(1, preferences.maximumRecentRepositories)))
        persistRecentRepositories()
    }

    private func persistRecentRepositories() {
        defaults.set(try? JSONEncoder().encode(recentRepositories), forKey: Key.recentRepositories)
    }

    private func applyAppearance() {
        guard let application = NSApp else { return }
        switch preferences.theme {
        case .system: application.appearance = nil
        case .light: application.appearance = NSAppearance(named: .aqua)
        case .dark: application.appearance = NSAppearance(named: .darkAqua)
        }
    }
}

extension Notification.Name {
    static let appPreferencesDidChange = Notification.Name("GitExtensionsMac.appPreferencesDidChange")
    static let pullPreferencesDidChange = Notification.Name("GitExtensionsMac.pullPreferencesDidChange")
    static let pushPreferencesDidChange = Notification.Name("GitExtensionsMac.pushPreferencesDidChange")
    static let commitPreferencesDidChange = Notification.Name("GitExtensionsMac.commitPreferencesDidChange")
    static let fileStatusListPreferencesDidChange = Notification.Name("GitExtensionsMac.fileStatusListPreferencesDidChange")
    static let fileViewerPreferencesDidChange = Notification.Name("GitExtensionsMac.fileViewerPreferencesDidChange")
}
