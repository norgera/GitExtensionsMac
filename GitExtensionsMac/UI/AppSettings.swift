import GitExtensionsCore
import GitCommands
import AppKit
import Foundation

enum ApplicationTheme: String, Codable, CaseIterable, Sendable {
    case system = "System default"
    case light = "Light"
    case dark = "Dark"
}

enum ApplicationFontRole: String, Codable, CaseIterable {
    case code, application, commit, monospace
    var title: String {
        switch self {
        case .code: "Code font"
        case .application: "Application font"
        case .commit: "Commit font"
        case .monospace: "Monospace font"
        }
    }
}

struct StoredApplicationFont: Codable, Equatable {
    let name: String
    let size: Double

    init(_ font: NSFont) { name = font.fontName; size = font.pointSize }
    var font: NSFont? {
        guard size.isFinite, size > 0, size <= 288 else { return nil }
        return NSFont(name: name, size: size)
    }
}

struct ApplicationFontPreferences: Codable, Equatable {
    var fonts: [ApplicationFontRole: StoredApplicationFont] = [:]
    var showEolMarkerAsGlyph = false

    init() {}
    private enum CodingKeys: String, CodingKey { case fonts, showEolMarkerAsGlyph }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        fonts = try values.decodeIfPresent([ApplicationFontRole: StoredApplicationFont].self, forKey: .fonts) ?? [:]
        showEolMarkerAsGlyph = try values.decodeIfPresent(Bool.self, forKey: .showEolMarkerAsGlyph) ?? false
    }

    func font(_ role: ApplicationFontRole, fallback: NSFont) -> NSFont {
        fonts[role]?.font ?? fallback
    }
}

struct BrowseDisplayPreferences: Codable, Equatable, Sendable {
    var showChangedFilesOnCommitButton = true
    var showArtificialRevisionCounts = true
    var showSubmoduleStatus = false
    var showAheadBehind = true
    var quickSearchTimeoutMilliseconds = 4000
    var maximumRevisionCount = 100000

    init() {}
    private enum CodingKeys: String, CodingKey { case showChangedFilesOnCommitButton, showArtificialRevisionCounts, showSubmoduleStatus, showAheadBehind, quickSearchTimeoutMilliseconds, maximumRevisionCount }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        showChangedFilesOnCommitButton = try values.decodeIfPresent(Bool.self, forKey: .showChangedFilesOnCommitButton) ?? true
        showArtificialRevisionCounts = try values.decodeIfPresent(Bool.self, forKey: .showArtificialRevisionCounts) ?? true
        showSubmoduleStatus = try values.decodeIfPresent(Bool.self, forKey: .showSubmoduleStatus) ?? false
        showAheadBehind = try values.decodeIfPresent(Bool.self, forKey: .showAheadBehind) ?? true
        quickSearchTimeoutMilliseconds = try values.decodeIfPresent(Int.self, forKey: .quickSearchTimeoutMilliseconds) ?? 4000
        maximumRevisionCount = max(0, try values.decodeIfPresent(Int.self, forKey: .maximumRevisionCount) ?? 100000)
    }

    func commitTitle(changedFiles: Int) -> String {
        showChangedFilesOnCommitButton ? "Commit (\(changedFiles))" : "Commit"
    }

    func branchCounts(ahead: Int, behind: Int) -> String {
        showAheadBehind && (ahead > 0 || behind > 0) ? " ↑\(ahead) ↓\(behind)" : ""
    }
}

struct AppPreferences: Codable, Equatable, Sendable {

    var reopenLastRepository = false

    var maximumRecentRepositories = 20
    var theme: ApplicationTheme = .system
    var mergeCommonParentLanes = true
    var straightenGraphDiagonals = true
    var renderGraphWithDiagonals = true
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

    var openSubmoduleDiffInSeparateWindow = false
    var automaticContinuousScroll = false
    var automaticContinuousScrollDelay = 600
    var outputHistoryDepth = 20
    var showOutputHistoryAsTab = true
    var outputHistoryPanelVisible = false

    init() {}
    private enum CodingKeys: String, CodingKey {
        case reopenLastRepository, maximumRecentRepositories, theme, mergeCommonParentLanes, straightenGraphDiagonals, renderGraphWithDiagonals, diffContextLines, ignoreWhitespace, defaultSignOff, defaultAllowEmpty, autoStashDuringRebase, gitExecutablePath, editorPath, shellPath, externalDiffToolPath, externalMergeToolPath, signingKey, openSubmoduleDiffInSeparateWindow, automaticContinuousScroll, automaticContinuousScrollDelay, outputHistoryDepth, showOutputHistoryAsTab, outputHistoryPanelVisible
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        func value<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T { ((try? values.decodeIfPresent(T.self, forKey: key)) ?? nil) ?? fallback }
        let defaults = AppPreferences()
        reopenLastRepository = value(.reopenLastRepository, defaults.reopenLastRepository)
        maximumRecentRepositories = value(.maximumRecentRepositories, defaults.maximumRecentRepositories)
        theme = value(.theme, defaults.theme)
        mergeCommonParentLanes = value(.mergeCommonParentLanes, defaults.mergeCommonParentLanes)
        straightenGraphDiagonals = value(.straightenGraphDiagonals, defaults.straightenGraphDiagonals)
        renderGraphWithDiagonals = value(.renderGraphWithDiagonals, defaults.renderGraphWithDiagonals)
        diffContextLines = value(.diffContextLines, defaults.diffContextLines)
        ignoreWhitespace = value(.ignoreWhitespace, defaults.ignoreWhitespace)
        defaultSignOff = value(.defaultSignOff, defaults.defaultSignOff)
        defaultAllowEmpty = value(.defaultAllowEmpty, defaults.defaultAllowEmpty)
        autoStashDuringRebase = value(.autoStashDuringRebase, defaults.autoStashDuringRebase)
        gitExecutablePath = value(.gitExecutablePath, defaults.gitExecutablePath)
        editorPath = value(.editorPath, defaults.editorPath)
        shellPath = value(.shellPath, defaults.shellPath)
        externalDiffToolPath = value(.externalDiffToolPath, defaults.externalDiffToolPath)
        externalMergeToolPath = value(.externalMergeToolPath, defaults.externalMergeToolPath)
        signingKey = value(.signingKey, defaults.signingKey)
        openSubmoduleDiffInSeparateWindow = value(.openSubmoduleDiffInSeparateWindow, defaults.openSubmoduleDiffInSeparateWindow)
        automaticContinuousScroll = value(.automaticContinuousScroll, defaults.automaticContinuousScroll)
        automaticContinuousScrollDelay = value(.automaticContinuousScrollDelay, defaults.automaticContinuousScrollDelay)
        outputHistoryDepth = max(0, value(.outputHistoryDepth, defaults.outputHistoryDepth))
        showOutputHistoryAsTab = value(.showOutputHistoryAsTab, defaults.showOutputHistoryAsTab)
        outputHistoryPanelVisible = value(.outputHistoryPanelVisible, defaults.outputHistoryPanelVisible)
    }
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


struct RevisionGridPreferences: Codable, Equatable, Sendable {
    var showGraphColumn = true
    var showNotesColumn = false

    var showAuthorAvatarColumn = true
    var showAuthorNameColumn = true
    var showDateColumn = true
    var showObjectIDColumn = true
    var showAuthorDate = true
    var relativeDate = true
    var showCommitBody = true
    var showRemoteBranches = true
    var showArtificialCommits = true
    var showStashes = true
    var showGitNotes = false
    var showSessionRefs = false
    var showOnlyFirstParent = false
    var hideMergeCommits = false
    var showSimplifyByDecoration = false
    var fullHistoryInFileHistory = false
    var simplifyMergesInFileHistory = false
    var followRenamesInFileHistory = true
    var followRenamesInFileHistoryExactOnly = false
    var loadFileHistoryOnShow = true
    var loadBlameOnShow = true
    var useBrowseForFileHistory = true
    var showSuperprojectTags = false
    var showSuperprojectBranches = true
    var showSuperprojectRemoteBranches = false

    var showAnnotatedTagsMessages = true

    var showRevisionGridTooltips = true

    var revisionFilterHistory: [String] = []

    init() {}
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = RevisionGridPreferences()
        func value<T: Decodable>(_ key: CodingKeys, _ current: T) throws -> T { try values.decodeIfPresent(T.self, forKey: key) ?? current }
        showGraphColumn = try value(.showGraphColumn, fallback.showGraphColumn)
        showNotesColumn = try value(.showNotesColumn, fallback.showNotesColumn)
        showAuthorAvatarColumn = try value(.showAuthorAvatarColumn, fallback.showAuthorAvatarColumn)
        showAuthorNameColumn = try value(.showAuthorNameColumn, fallback.showAuthorNameColumn)
        showDateColumn = try value(.showDateColumn, fallback.showDateColumn)
        showObjectIDColumn = try value(.showObjectIDColumn, fallback.showObjectIDColumn)
        showAuthorDate = try value(.showAuthorDate, fallback.showAuthorDate)
        relativeDate = try value(.relativeDate, fallback.relativeDate)
        showCommitBody = try value(.showCommitBody, fallback.showCommitBody)
        showRemoteBranches = try value(.showRemoteBranches, fallback.showRemoteBranches)
        showArtificialCommits = try value(.showArtificialCommits, fallback.showArtificialCommits)
        showStashes = try value(.showStashes, fallback.showStashes)
        showGitNotes = try value(.showGitNotes, fallback.showGitNotes)
        showSessionRefs = try value(.showSessionRefs, fallback.showSessionRefs)
        showOnlyFirstParent = try value(.showOnlyFirstParent, fallback.showOnlyFirstParent)
        hideMergeCommits = try value(.hideMergeCommits, fallback.hideMergeCommits)
        showSimplifyByDecoration = try value(.showSimplifyByDecoration, fallback.showSimplifyByDecoration)
        fullHistoryInFileHistory = try value(.fullHistoryInFileHistory, fallback.fullHistoryInFileHistory)
        simplifyMergesInFileHistory = try value(.simplifyMergesInFileHistory, fallback.simplifyMergesInFileHistory)
        followRenamesInFileHistory = try value(.followRenamesInFileHistory, fallback.followRenamesInFileHistory)
        followRenamesInFileHistoryExactOnly = try value(.followRenamesInFileHistoryExactOnly, fallback.followRenamesInFileHistoryExactOnly)
        loadFileHistoryOnShow = try value(.loadFileHistoryOnShow, fallback.loadFileHistoryOnShow)
        loadBlameOnShow = try value(.loadBlameOnShow, fallback.loadBlameOnShow)
        useBrowseForFileHistory = try value(.useBrowseForFileHistory, fallback.useBrowseForFileHistory)
        showSuperprojectTags = try value(.showSuperprojectTags, fallback.showSuperprojectTags)
        showSuperprojectBranches = try value(.showSuperprojectBranches, fallback.showSuperprojectBranches)
        showSuperprojectRemoteBranches = try value(.showSuperprojectRemoteBranches, fallback.showSuperprojectRemoteBranches)
        showAnnotatedTagsMessages = try value(.showAnnotatedTagsMessages, fallback.showAnnotatedTagsMessages)
        showRevisionGridTooltips = try value(.showRevisionGridTooltips, fallback.showRevisionGridTooltips)
        revisionFilterHistory = try value(.revisionFilterHistory, fallback.revisionFilterHistory)
    }
}



struct RevisionGridRuntimeSettings: Codable, Equatable, Sendable {
    var sortOrder: RevisionSortOrder = .gitDefault
    var showCurrentBranchOnly = false
    var branchFilterEnabled = false
    var showReflogReferences = false
}


struct CommitInfoPreferences: Codable, Equatable, Sendable {
    var showContainedInBranchesLocal = true
    var showContainedInBranchesRemote = false
    var showContainedInBranchesRemoteIfNoLocal = false
    var showContainedInTags = true
    var showTagThisCommitDerivesFrom = true


    var showContainedInBranches: Bool {
        showContainedInBranchesLocal || showContainedInBranchesRemote || showContainedInBranchesRemoteIfNoLocal
    }

    init() {}
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = CommitInfoPreferences()
        func value(_ key: CodingKeys, _ current: Bool) -> Bool { ((try? values.decodeIfPresent(Bool.self, forKey: key)) ?? nil) ?? current }
        showContainedInBranchesLocal = value(.showContainedInBranchesLocal, fallback.showContainedInBranchesLocal)
        showContainedInBranchesRemote = value(.showContainedInBranchesRemote, fallback.showContainedInBranchesRemote)
        showContainedInBranchesRemoteIfNoLocal = value(.showContainedInBranchesRemoteIfNoLocal, fallback.showContainedInBranchesRemoteIfNoLocal)
        showContainedInTags = value(.showContainedInTags, fallback.showContainedInTags)
        showTagThisCommitDerivesFrom = value(.showTagThisCommitDerivesFrom, fallback.showTagThisCommitDerivesFrom)
    }
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



struct BrowserLayoutPreferences: Codable, Equatable, Sendable {
    enum CommitInfoPosition: Int, Codable, Sendable, CaseIterable {
        case belowList, leftwardFromList, rightwardFromList
    }
    struct Splitter: Codable, Equatable, Sendable {
        var distance: Double
        var size: Double
    }
    var commitInfoPosition = CommitInfoPosition.belowList
    var showSplitViewLayout = true
    var leftPanelCollapsed = false

    var toolbarItemVisibility: [String: Bool] = [:]
    var splitters: [String: Splitter] = [:]

    init() {}
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        commitInfoPosition = try values.decodeIfPresent(CommitInfoPosition.self, forKey: .commitInfoPosition) ?? .belowList
        showSplitViewLayout = try values.decodeIfPresent(Bool.self, forKey: .showSplitViewLayout) ?? true
        leftPanelCollapsed = try values.decodeIfPresent(Bool.self, forKey: .leftPanelCollapsed) ?? false
        toolbarItemVisibility = try values.decodeIfPresent([String: Bool].self, forKey: .toolbarItemVisibility) ?? [:]
        splitters = try values.decodeIfPresent([String: Splitter].self, forKey: .splitters) ?? [:]
    }


    static func restoredDistance(_ saved: Splitter?, size: Double, fixed: RetainingSplitViewController.ResizeBehavior) -> Double? {
        guard let saved, saved.size > 0, saved.distance > 0, size > 0 else { return nil }
        if saved.size == size { return saved.distance }
        switch fixed {
        case .proportional: return size * saved.distance / saved.size
        case .fixedLeadingPane: return saved.distance
        case .fixedTrailingPane: return size - (saved.size - saved.distance)
        }
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


struct BlamePreferences: Codable, Equatable, Sendable {
    var ignoreWhitespace = true
    var detectCopyInFile = false
    var detectCopyInAll = false
    var displayAuthorFirst = false
    var showAuthor = true
    var showAuthorDate = true
    var showAuthorTime = true
    var showLineNumbers = false
    var showOriginalFilePath = true
    var showAuthorAvatar = true

    var useDiffViewerForBlame = false

    init() {}
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = BlamePreferences()
        ignoreWhitespace = try values.decodeIfPresent(Bool.self, forKey: .ignoreWhitespace) ?? defaults.ignoreWhitespace
        detectCopyInFile = try values.decodeIfPresent(Bool.self, forKey: .detectCopyInFile) ?? defaults.detectCopyInFile
        detectCopyInAll = try values.decodeIfPresent(Bool.self, forKey: .detectCopyInAll) ?? defaults.detectCopyInAll
        displayAuthorFirst = try values.decodeIfPresent(Bool.self, forKey: .displayAuthorFirst) ?? defaults.displayAuthorFirst
        showAuthor = try values.decodeIfPresent(Bool.self, forKey: .showAuthor) ?? defaults.showAuthor
        showAuthorDate = try values.decodeIfPresent(Bool.self, forKey: .showAuthorDate) ?? defaults.showAuthorDate
        showAuthorTime = try values.decodeIfPresent(Bool.self, forKey: .showAuthorTime) ?? defaults.showAuthorTime
        showLineNumbers = try values.decodeIfPresent(Bool.self, forKey: .showLineNumbers) ?? defaults.showLineNumbers
        showOriginalFilePath = try values.decodeIfPresent(Bool.self, forKey: .showOriginalFilePath) ?? defaults.showOriginalFilePath
        showAuthorAvatar = try values.decodeIfPresent(Bool.self, forKey: .showAuthorAvatar) ?? defaults.showAuthorAvatar
        useDiffViewerForBlame = try values.decodeIfPresent(Bool.self, forKey: .useDiffViewerForBlame) ?? defaults.useDiffViewerForBlame
    }
}

struct FileStatusListPreferences: Codable, Equatable, Sendable {
    var grouping: FileStatusGrouping = .path
    var isTreeMode = true
    var usesDenseTree = true
    var showsGroupNodesInFlatList = false
    var showsUntrackedFiles = true

    var showDiffForAllParents = true

    var showFindInCommitFilesGitGrep = false

    var findInFilesGitGrepTypeIndex = 1

    var gitGrepUserArguments = ""
    var gitGrepIgnoreCase = false
    var gitGrepMatchWholeWord = false

    var hiddenToolbarItems: [String] = []

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

    var grepOptions: GitGrepOptions {
        GitGrepOptions(userArguments: gitGrepUserArguments, ignoreCase: gitGrepIgnoreCase, matchWholeWord: gitGrepMatchWholeWord)
    }

    private enum CodingKeys: String, CodingKey {
        case grouping, isTreeMode, usesDenseTree, showsGroupNodesInFlatList, showsUntrackedFiles, showDiffForAllParents,
             showFindInCommitFilesGitGrep, findInFilesGitGrepTypeIndex, gitGrepUserArguments, gitGrepIgnoreCase,
             gitGrepMatchWholeWord, hiddenToolbarItems
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        func value<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T { ((try? values.decodeIfPresent(T.self, forKey: key)) ?? nil) ?? fallback }
        let defaults = FileStatusListPreferences()
        grouping = value(.grouping, defaults.grouping)
        isTreeMode = value(.isTreeMode, defaults.isTreeMode)
        usesDenseTree = value(.usesDenseTree, defaults.usesDenseTree)
        showsGroupNodesInFlatList = value(.showsGroupNodesInFlatList, defaults.showsGroupNodesInFlatList)
        showsUntrackedFiles = value(.showsUntrackedFiles, defaults.showsUntrackedFiles)
        showDiffForAllParents = value(.showDiffForAllParents, defaults.showDiffForAllParents)
        showFindInCommitFilesGitGrep = value(.showFindInCommitFilesGitGrep, defaults.showFindInCommitFilesGitGrep)
        findInFilesGitGrepTypeIndex = value(.findInFilesGitGrepTypeIndex, defaults.findInFilesGitGrepTypeIndex)
        gitGrepUserArguments = value(.gitGrepUserArguments, defaults.gitGrepUserArguments)
        gitGrepIgnoreCase = value(.gitGrepIgnoreCase, defaults.gitGrepIgnoreCase)
        gitGrepMatchWholeWord = value(.gitGrepMatchWholeWord, defaults.gitGrepMatchWholeWord)
        hiddenToolbarItems = value(.hiddenToolbarItems, defaults.hiddenToolbarItems)
    }
}

struct FileViewerPreferences: Codable, Equatable, Sendable {
    var usesHistogram = false
    var whitespace: DiffWhitespaceMode = .none
    var contextLines = 3
    var showsEntireFile = false
    var treatsAllFilesAsText = false
    var showsNonPrintingCharacters = false
    var showsSyntaxHighlighting = true
    var textEncoding: RepositoryTextEncoding = .automatic
    var diffAppearance: DiffDisplayAppearance = .patch
    var useGitColoring = true
    var reverseGitColoring = true

    init() {}
    private enum CodingKeys: String, CodingKey {
        case usesHistogram, whitespace, contextLines, showsEntireFile, treatsAllFilesAsText
        case showsNonPrintingCharacters, showsSyntaxHighlighting, textEncoding, diffAppearance, useGitColoring, reverseGitColoring
    }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        usesHistogram = try values.decodeIfPresent(Bool.self, forKey: .usesHistogram) ?? false
        whitespace = try values.decodeIfPresent(DiffWhitespaceMode.self, forKey: .whitespace) ?? .none
        contextLines = try values.decodeIfPresent(Int.self, forKey: .contextLines) ?? 3
        showsEntireFile = try values.decodeIfPresent(Bool.self, forKey: .showsEntireFile) ?? false
        treatsAllFilesAsText = try values.decodeIfPresent(Bool.self, forKey: .treatsAllFilesAsText) ?? false
        showsNonPrintingCharacters = try values.decodeIfPresent(Bool.self, forKey: .showsNonPrintingCharacters) ?? false
        showsSyntaxHighlighting = try values.decodeIfPresent(Bool.self, forKey: .showsSyntaxHighlighting) ?? true
        textEncoding = try values.decodeIfPresent(RepositoryTextEncoding.self, forKey: .textEncoding) ?? .automatic
        diffAppearance = (try? values.decodeIfPresent(DiffDisplayAppearance.self, forKey: .diffAppearance)) ?? .patch
        useGitColoring = try values.decodeIfPresent(Bool.self, forKey: .useGitColoring) ?? true
        reverseGitColoring = try values.decodeIfPresent(Bool.self, forKey: .reverseGitColoring) ?? true
    }

    var diffOptions: FileDiffOptions {
        FileDiffOptions(
            whitespace: whitespace,
            contextLines: contextLines,
            showsEntireFile: showsEntireFile,
            treatsAllFilesAsText: treatsAllFilesAsText,
            usesHistogram: usesHistogram,
            appearance: diffAppearance,
            difftasticSyntaxHighlighting: diffAppearance == .difftastic ? showsSyntaxHighlighting : true,
            useGitColoring: useGitColoring,
            reverseGitColoring: reverseGitColoring
        )
    }
}

struct FileViewerRememberPreferences: Codable, Equatable, Sendable {
    var whitespace = true
    var entireFile = false
    var nonPrinting = false
    var contextLines = false
    var syntaxHighlighting = true
    var diffAppearance = false

    init() {}
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        whitespace = try values.decodeIfPresent(Bool.self, forKey: .whitespace) ?? true
        entireFile = try values.decodeIfPresent(Bool.self, forKey: .entireFile) ?? false
        nonPrinting = try values.decodeIfPresent(Bool.self, forKey: .nonPrinting) ?? false
        contextLines = try values.decodeIfPresent(Bool.self, forKey: .contextLines) ?? false
        syntaxHighlighting = try values.decodeIfPresent(Bool.self, forKey: .syntaxHighlighting) ?? true
        diffAppearance = try values.decodeIfPresent(Bool.self, forKey: .diffAppearance) ?? false
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


private struct LegacyRecentRepository: Codable {
    let path: String
}

@MainActor
final class AppSettingsStore {
    static let shared = AppSettingsStore()

    private enum Key {
        static let preferences = "GitExtensionsMac.preferences.v1"
        static let fonts = "GitExtensionsMac.fonts.v1"
        static let legacyRecentRepositories = "GitExtensionsMac.recentRepositories.v1"
        static let recentHistory = "GitExtensionsMac.repositoryHistory.recent.v1"
        static let favouriteHistory = "GitExtensionsMac.repositoryHistory.favourite.v1"
        static let recentRepositorySettings = "GitExtensionsMac.recentRepositorySettings.v1"
        static let lastRepository = "GitExtensionsMac.lastRepository"
        static let pullPreferences = "GitExtensionsMac.pullPreferences.v1"
        static let pushPreferences = "GitExtensionsMac.pushPreferences.v1"
        static let commitPreferences = "GitExtensionsMac.commitPreferences.v1"
        static let fileStatusListPreferences = "GitExtensionsMac.fileStatusListPreferences.v1"
        static let blamePreferences = "GitExtensionsMac.blamePreferences.v1"
        static let fileViewerPreferences = "GitExtensionsMac.fileViewerPreferences.v1"
        static let fileViewerRemember = "GitExtensionsMac.fileViewerRemember.v1"
        static let rebasePreferences = "GitExtensionsMac.rebasePreferences.v1"
        static let cherryPickPreferences = "GitExtensionsMac.cherryPickPreferences.v1"
        static let stashPreferences = "GitExtensionsMac.stashPreferences.v1"
        static let browseDisplay = "GitExtensionsMac.browseDisplay.v1"
        static let tagPreferences = "GitExtensionsMac.tagPreferences.v1"
        static let repositoryTreePreferences = "GitExtensionsMac.repositoryTreePreferences.v1"
        static let remoteManagementPreferences = "GitExtensionsMac.remoteManagementPreferences.v1"
        static let browserLayoutPreferences = "GitExtensionsMac.browserLayoutPreferences.v1"
        static let mergePreferences = "GitExtensionsMac.mergePreferences.v1"
        static let unsetDetailedSettings = "GitExtensionsMac.detailedSettings.unset.v1"
        static let checkoutBranchPreferences = "GitExtensionsMac.checkoutBranchPreferences.v1"
        static let repositoryCreationPreferences = "GitExtensionsMac.repositoryCreationPreferences.v1"
        static let resetPreferences = "GitExtensionsMac.resetPreferences.v1"
        static let showReflogReferences = "GitExtensionsMac.showReflogReferences"
        static let revisionGridPreferences = "GitExtensionsMac.revisionGridPreferences.v1"
        static let revisionGridRuntimeDefaults = "GitExtensionsMac.revisionGridRuntimeDefaults.v1"
        static let showBuildStatusIconColumn = "GitExtensionsMac.showbuildstatusiconcolumn"
        static let showBuildStatusTextColumn = "GitExtensionsMac.showbuildstatustextcolumn"
    }

    private let defaults: UserDefaults



    var unsetDetailedSettingKeys: Set<String> {
        get { Set(defaults.stringArray(forKey: Key.unsetDetailedSettings) ?? []) }
        set { defaults.set(newValue.sorted(), forKey: Key.unsetDetailedSettings) }
    }

    func saveDetailedSetting(_ key: String, value: String?) {
        switch key {
        case DistributedSettings.remoteBranches:
            var preferences = pushPreferences
            preferences.loadRemoteBranchesDirectly = value?.lowercased() == "true"
            savePushPreferences(preferences)
        case DistributedSettings.mergeLog:
            var preferences = mergePreferences
            preferences.addLogMessages = value?.lowercased() == "true"
            saveMergePreferences(preferences)
        case DistributedSettings.mergeLogCount:
            var preferences = mergePreferences
            preferences.logMessagesCount = value.flatMap(DistributedSettings.normalizedMergeLogCount).flatMap(Int.init) ?? 20
            saveMergePreferences(preferences)
        default: return
        }
        var unset = unsetDetailedSettingKeys
        if value == nil { unset.insert(key) } else { unset.remove(key) }
        unsetDetailedSettingKeys = unset
    }


    var checkSettingsAtStartup: Bool {
        get { defaults.object(forKey: "GitExtensionsMac.checkSettingsAtStartup") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "GitExtensionsMac.checkSettingsAtStartup") }
    }

    func recordSettingsCheck(allValid: Bool) {
        if allValid { checkSettingsAtStartup = false }
    }

    private var cachedColorPreferences: ApplicationColorPreferences?
    var colorPreferences: ApplicationColorPreferences {
        get {
            if let cachedColorPreferences { return cachedColorPreferences }
            let value = defaults.data(forKey: "GitExtensionsMac.colors.v1")
                .flatMap { try? JSONDecoder().decode(ApplicationColorPreferences.self, from: $0) } ?? .init()
            cachedColorPreferences = value
            return value
        }
        set {
            cachedColorPreferences = newValue
            defaults.set(try? JSONEncoder().encode(newValue), forKey: "GitExtensionsMac.colors.v1")
            ApplicationColors.invalidate()
        }
    }

    var hotkeyOverrides: [String: ApplicationKeyChord] {
        get {
            guard let data = defaults.data(forKey: "GitExtensionsMac.hotkeys.v1") else { return [:] }
            return (try? JSONDecoder().decode([String: ApplicationKeyChord].self, from: data)) ?? [:]
        }
        set {
            ApplicationHotkeys.shared.objectWillChange.send()
            defaults.set(try? JSONEncoder().encode(newValue), forKey: "GitExtensionsMac.hotkeys.v1")
        }
    }

    var revisionLinksXML: String? {
        get { defaults.string(forKey: "GitExtensionsMac.revisionLinks.v1") }
        set { defaults.set(newValue, forKey: "GitExtensionsMac.revisionLinks.v1") }
    }

    var includedTextEncodings: [RepositoryTextEncoding] {
        get {
            let baseline: [RepositoryTextEncoding] = [.utf8, .utf16LittleEndian, .utf16BigEndian, .westernISO88591, .windows1252]
            let saved = defaults.stringArray(forKey: "GitExtensionsMac.availableEncodings.v1")?.compactMap { RepositoryTextEncoding(rawValue: $0) } ?? baseline
            var result = Self.requiredTextEncodings
            for encoding in saved where encoding != .automatic && !result.contains(encoding) { result.append(encoding) }
            return result
        }
        set { defaults.set(newValue.map(\.rawValue), forKey: "GitExtensionsMac.availableEncodings.v1") }
    }
    static var requiredTextEncodings: [RepositoryTextEncoding] {
        [.utf8, .utf16LittleEndian, .utf16BigEndian, RepositoryTextEncoding(ianaName: "us-ascii")!]
    }
    func viewerEncodings(including selected: RepositoryTextEncoding) -> [RepositoryTextEncoding] {
        var values = [.automatic] + includedTextEncodings
        if !values.contains(selected) { values.append(selected) }
        return values
    }
    private(set) var preferences: AppPreferences
    private(set) var fontPreferences: ApplicationFontPreferences
    private(set) var browseDisplayPreferences: BrowseDisplayPreferences
    private(set) var pullPreferences: PullPreferences
    private(set) var pushPreferences: PushPreferences
    private(set) var commitPreferences: CommitPreferences
    private(set) var fileStatusListPreferences: FileStatusListPreferences
    private(set) var blamePreferences: BlamePreferences
    private(set) var fileViewerPreferences: FileViewerPreferences
    private(set) var fileViewerDefaults: FileViewerPreferences
    private(set) var fileViewerRemember: FileViewerRememberPreferences
    private(set) var rebasePreferences: RebasePreferences
    private(set) var cherryPickPreferences: CherryPickPreferences
    private(set) var stashPreferences: StashPreferences
    private(set) var tagPreferences: TagPreferences
    private(set) var repositoryTreePreferences: RepositoryTreePreferences
    private(set) var remoteManagementPreferences: RemoteManagementPreferences
    private(set) var browserLayoutPreferences: BrowserLayoutPreferences
    private(set) var mergePreferences: MergePreferences
    private(set) var checkoutBranchPreferences: CheckoutBranchPreferences
    private(set) var repositoryCreationPreferences: RepositoryCreationPreferences
    private(set) var resetPreferences: ResetPreferences

    var showReflogReferences: Bool { revisionGridRuntime.showReflogReferences }
    private(set) var revisionGridPreferences: RevisionGridPreferences

    var revisionGridRuntime: RevisionGridRuntimeSettings
    private(set) var revisionGridRuntimeDefaults: RevisionGridRuntimeSettings
    private(set) var showBuildStatusIconColumn: Bool
    private(set) var showBuildStatusTextColumn: Bool

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let decoder = JSONDecoder()
        let loadedPreferences = defaults.data(forKey: Key.preferences)
            .flatMap { try? decoder.decode(AppPreferences.self, from: $0) }
            ?? AppPreferences()
        preferences = loadedPreferences
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
        blamePreferences = defaults.data(forKey: Key.blamePreferences)
            .flatMap { try? decoder.decode(BlamePreferences.self, from: $0) }
            ?? BlamePreferences()
        fileViewerPreferences = defaults.data(forKey: Key.fileViewerPreferences)
            .flatMap { try? decoder.decode(FileViewerPreferences.self, from: $0) }
            ?? {
                var value = FileViewerPreferences()
                value.contextLines = loadedPreferences.diffContextLines
                value.whitespace = loadedPreferences.ignoreWhitespace ? .all : .none
                return value
            }()
        fontPreferences = defaults.data(forKey: Key.fonts)
            .flatMap { try? decoder.decode(ApplicationFontPreferences.self, from: $0) }
            ?? ApplicationFontPreferences()
        browseDisplayPreferences = defaults.data(forKey: Key.browseDisplay)
            .flatMap { try? decoder.decode(BrowseDisplayPreferences.self, from: $0) }
            ?? BrowseDisplayPreferences()
        fileViewerDefaults = fileViewerPreferences
        fileViewerRemember = defaults.data(forKey: Key.fileViewerRemember)
            .flatMap { try? decoder.decode(FileViewerRememberPreferences.self, from: $0) }
            ?? FileViewerRememberPreferences()
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
        browserLayoutPreferences = defaults.data(forKey: Key.browserLayoutPreferences)
            .flatMap { try? decoder.decode(BrowserLayoutPreferences.self, from: $0) }
            ?? BrowserLayoutPreferences()
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
        revisionGridPreferences = defaults.data(forKey: Key.revisionGridPreferences)
            .flatMap { try? decoder.decode(RevisionGridPreferences.self, from: $0) } ?? RevisionGridPreferences()
        var runtimeDefaults = defaults.data(forKey: Key.revisionGridRuntimeDefaults)
            .flatMap { try? decoder.decode(RevisionGridRuntimeSettings.self, from: $0) } ?? RevisionGridRuntimeSettings()
        if defaults.data(forKey: Key.revisionGridRuntimeDefaults) == nil {

            runtimeDefaults.showReflogReferences = defaults.object(forKey: Key.showReflogReferences) as? Bool ?? false
        }
        revisionGridRuntimeDefaults = runtimeDefaults
        revisionGridRuntime = runtimeDefaults
        showBuildStatusIconColumn = defaults.object(forKey: Key.showBuildStatusIconColumn) as? Bool ?? true
        showBuildStatusTextColumn = defaults.object(forKey: Key.showBuildStatusTextColumn) as? Bool ?? false
        if defaults.object(forKey: Key.unsetDetailedSettings) == nil {
            var unset: Set<String> = []


            if defaults.data(forKey: Key.pushPreferences) == nil { unset.insert(DistributedSettings.remoteBranches) }
            if defaults.data(forKey: Key.mergePreferences) == nil {
                unset.formUnion([DistributedSettings.mergeLog, DistributedSettings.mergeLogCount])
            }
            unsetDetailedSettingKeys = unset
        }
        applyAppearance()
    }

    var lastRepositoryPath: String? {
        defaults.string(forKey: Key.lastRepository)
    }

    func save(_ preferences: AppPreferences) {
        if defaults === UserDefaults.standard { CommandLog.shared.setOutputHistoryDepth(preferences.outputHistoryDepth) }
        let previous = self.preferences
        self.preferences = preferences
        defaults.set(try? JSONEncoder().encode(preferences), forKey: Key.preferences)
        var viewer = fileViewerPreferences
        if preferences.diffContextLines != previous.diffContextLines { viewer.contextLines = preferences.diffContextLines }
        if preferences.ignoreWhitespace != previous.ignoreWhitespace { viewer.whitespace = preferences.ignoreWhitespace ? .all : .none }
        if viewer != fileViewerPreferences {
            fileViewerPreferences = viewer
            fileViewerDefaults = viewer
            defaults.set(try? JSONEncoder().encode(viewer), forKey: Key.fileViewerPreferences)
            NotificationCenter.default.post(name: .fileViewerPreferencesDidChange, object: self)
        }
        applyAppearance()
        NotificationCenter.default.post(name: .appPreferencesDidChange, object: self)
    }

    func savePullPreferences(_ preferences: PullPreferences) {
        pullPreferences = preferences
        defaults.set(try? JSONEncoder().encode(preferences), forKey: Key.pullPreferences)
        NotificationCenter.default.post(name: .pullPreferencesDidChange, object: self)
    }

    func savePushPreferences(_ preferences: PushPreferences) {
        if preferences.loadRemoteBranchesDirectly != pushPreferences.loadRemoteBranchesDirectly {
            unsetDetailedSettingKeys.remove(DistributedSettings.remoteBranches)
        }
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

    func saveBlamePreferences(_ preferences: BlamePreferences) {
        blamePreferences = preferences
        defaults.set(try? JSONEncoder().encode(preferences), forKey: Key.blamePreferences)
        NotificationCenter.default.post(name: .blamePreferencesDidChange, object: self)
    }

    func saveFileViewerPreferences(_ preferences: FileViewerPreferences) {
        fileViewerDefaults = preferences
        fileViewerPreferences = preferences
        defaults.set(try? JSONEncoder().encode(preferences), forKey: Key.fileViewerPreferences)
        self.preferences.diffContextLines = preferences.contextLines
        self.preferences.ignoreWhitespace = preferences.whitespace != .none
        defaults.set(try? JSONEncoder().encode(self.preferences), forKey: Key.preferences)
        NotificationCenter.default.post(name: .fileViewerPreferencesDidChange, object: self)
    }

    func saveFileViewerRemember(_ preferences: FileViewerRememberPreferences) {
        fileViewerRemember = preferences
        defaults.set(try? JSONEncoder().encode(preferences), forKey: Key.fileViewerRemember)
    }

    func saveFontPreferences(_ preferences: ApplicationFontPreferences) {
        fontPreferences = preferences
        defaults.set(try? JSONEncoder().encode(preferences), forKey: Key.fonts)
    }

    func saveBrowseDisplayPreferences(_ preferences: BrowseDisplayPreferences) {
        browseDisplayPreferences = preferences
        defaults.set(try? JSONEncoder().encode(preferences), forKey: Key.browseDisplay)
    }

    var codeFont: NSFont { fontPreferences.font(.code, fallback: .monospacedSystemFont(ofSize: 11, weight: .regular)) }
    var diffGutterFont: NSFont { fontPreferences.font(.code, fallback: .monospacedDigitSystemFont(ofSize: 10, weight: .regular)) }
    var diffLineHeight: CGFloat {
        guard fontPreferences.fonts[.code] != nil else { return BrowserMetrics.diffRowHeight }
        let font = codeFont
        return max(BrowserMetrics.diffRowHeight, ceil(font.ascender - font.descender + font.leading + 3))
    }
    var commitFont: NSFont { fontPreferences.font(.commit, fallback: .monospacedSystemFont(ofSize: 12, weight: .regular)) }
    var monospaceFont: NSFont { fontPreferences.font(.monospace, fallback: .monospacedSystemFont(ofSize: 11, weight: .regular)) }
    func applicationFont(size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        guard let font = fontPreferences.fonts[.application]?.font else { return .systemFont(ofSize: size, weight: weight) }
        return weight >= .semibold ? NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask) : font
    }

    func applicationRowHeight(minimum: CGFloat) -> CGFloat {
        [ApplicationFontRole.application, .monospace].reduce(minimum) { height, role in
            guard let font = fontPreferences.fonts[role]?.font else { return height }
            return max(height, ceil(font.ascender - font.descender + font.leading + 4))
        }
    }

    func updateFileViewerPreferences(_ preferences: FileViewerPreferences) {
        guard preferences != fileViewerPreferences else { return }
        fileViewerPreferences = preferences
        let previousDefaults = fileViewerDefaults
        fileViewerDefaults.textEncoding = preferences.textEncoding
        fileViewerDefaults.usesHistogram = preferences.usesHistogram
        fileViewerDefaults.treatsAllFilesAsText = preferences.treatsAllFilesAsText
        fileViewerDefaults.useGitColoring = preferences.useGitColoring
        fileViewerDefaults.reverseGitColoring = preferences.reverseGitColoring
        if fileViewerRemember.contextLines {
            fileViewerDefaults.contextLines = preferences.contextLines
        }
        if fileViewerDefaults != previousDefaults {
            defaults.set(try? JSONEncoder().encode(fileViewerDefaults), forKey: Key.fileViewerPreferences)
        }
        NotificationCenter.default.post(name: .fileViewerPreferencesDidChange, object: self)
    }

    func preferencesForNewFileViewer() -> FileViewerPreferences {
        var result = fileViewerPreferences
        if !fileViewerRemember.whitespace { result.whitespace = fileViewerDefaults.whitespace }
        if !fileViewerRemember.entireFile { result.showsEntireFile = fileViewerDefaults.showsEntireFile }
        if !fileViewerRemember.nonPrinting { result.showsNonPrintingCharacters = fileViewerDefaults.showsNonPrintingCharacters }
        if !fileViewerRemember.syntaxHighlighting { result.showsSyntaxHighlighting = fileViewerDefaults.showsSyntaxHighlighting }
        if !fileViewerRemember.diffAppearance { result.diffAppearance = fileViewerDefaults.diffAppearance }
        if !fileViewerRemember.contextLines { result.contextLines = 3 }
        fileViewerPreferences = result
        return result
    }

    func applyFileViewerPreferences(_ preferences: FileViewerPreferences) {
        updateFileViewerPreferences(preferences)
        NotificationCenter.default.post(name: .fileViewerSettingsApplied, object: self)
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

    func saveBrowserLayoutPreferences(_ preferences: BrowserLayoutPreferences) {
        browserLayoutPreferences = preferences
        defaults.set(try? JSONEncoder().encode(preferences), forKey: Key.browserLayoutPreferences)
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
        if preferences.addLogMessages != mergePreferences.addLogMessages {
            unsetDetailedSettingKeys.remove(DistributedSettings.mergeLog)
        }
        if preferences.logMessagesCount != mergePreferences.logMessagesCount {
            unsetDetailedSettingKeys.remove(DistributedSettings.mergeLogCount)
        }
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

    func saveShowBuildStatus(icon: Bool, text: Bool) {
        showBuildStatusIconColumn = icon; showBuildStatusTextColumn = text
        defaults.set(icon, forKey: Key.showBuildStatusIconColumn)
        defaults.set(text, forKey: Key.showBuildStatusTextColumn)
    }


    func saveShowReflogReferences(_ show: Bool) {
        revisionGridRuntime.showReflogReferences = show
    }

    var commitInfoPreferences: CommitInfoPreferences {
        defaults.data(forKey: "GitExtensionsMac.commitInfoPreferences.v1")
            .flatMap { try? JSONDecoder().decode(CommitInfoPreferences.self, from: $0) } ?? CommitInfoPreferences()
    }

    var avatarPreferences: AvatarPreferences {
        defaults.data(forKey: "GitExtensionsMac.avatarPreferences.v1")
            .flatMap { try? JSONDecoder().decode(AvatarPreferences.self, from: $0) } ?? AvatarPreferences()
    }

    func saveAvatarPreferences(_ preferences: AvatarPreferences) {
        let previous = avatarPreferences
        let clear = previous.provider != preferences.provider || previous.fallback != preferences.fallback || previous.customTemplate != preferences.customTemplate
        defaults.set(try? JSONEncoder().encode(preferences), forKey: "GitExtensionsMac.avatarPreferences.v1")
        if defaults === UserDefaults.standard {
            Task { await AvatarService.shared.configure(preferences, clear: clear) }
        }
    }

    func saveCommitInfoPreferences(_ preferences: CommitInfoPreferences) {
        defaults.set(try? JSONEncoder().encode(preferences), forKey: "GitExtensionsMac.commitInfoPreferences.v1")
    }

    func saveRevisionGridPreferences(_ preferences: RevisionGridPreferences) {
        revisionGridPreferences = preferences
        defaults.set(try? JSONEncoder().encode(preferences), forKey: Key.revisionGridPreferences)
    }



    func saveCurrentViewSettingsAsDefault() {
        revisionGridRuntimeDefaults = revisionGridRuntime
        defaults.set(try? JSONEncoder().encode(revisionGridRuntime), forKey: Key.revisionGridRuntimeDefaults)
        saveFileViewerPreferences(fileViewerPreferences)
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
        defaults.set(RepositoryHistory.normalizedPath(url.path), forKey: Key.lastRepository)
    }




    var recentRepositorySettings: RecentRepositorySettings {
        if let data = defaults.data(forKey: Key.recentRepositorySettings),
           let settings = try? JSONDecoder().decode(RecentRepositorySettings.self, from: data) { return settings }
        var settings = RecentRepositorySettings()
        if preferences.maximumRecentRepositories != 20 {
            settings.historySize = min(max(preferences.maximumRecentRepositories, RecentRepositorySettings.historySizeRange.lowerBound),
                                       RecentRepositorySettings.historySizeRange.upperBound)
        }
        return settings
    }

    func saveRecentRepositorySettings(_ settings: RecentRepositorySettings) {
        defaults.set(try? JSONEncoder().encode(settings), forKey: Key.recentRepositorySettings)
        NotificationCenter.default.post(name: .recentRepositoriesDidChange, object: self)
    }


    var recentRepositories: [RepositoryHistoryEntry] {
        let stored: [RepositoryHistoryEntry]
        if let data = defaults.data(forKey: Key.recentHistory) {
            stored = (try? JSONDecoder().decode([RepositoryHistoryEntry].self, from: data)) ?? []
        } else {
            stored = (defaults.data(forKey: Key.legacyRecentRepositories)
                .flatMap { try? JSONDecoder().decode([LegacyRecentRepository].self, from: $0) } ?? [])
                .map { RepositoryHistoryEntry(path: $0.path) }
        }
        return RepositoryHistory.adjustHistorySize(stored, size: recentRepositorySettings.historySize)
    }


    var favouriteRepositories: [RepositoryHistoryEntry] {
        defaults.data(forKey: Key.favouriteHistory)
            .flatMap { try? JSONDecoder().decode([RepositoryHistoryEntry].self, from: $0) } ?? []
    }


    func saveRecentHistory(_ history: [RepositoryHistoryEntry]) {
        let adjusted = RepositoryHistory.adjustHistorySize(history, size: recentRepositorySettings.historySize)
        defaults.set(try? JSONEncoder().encode(adjusted), forKey: Key.recentHistory)
        NotificationCenter.default.post(name: .recentRepositoriesDidChange, object: self)
    }

    func saveFavouriteHistory(_ history: [RepositoryHistoryEntry]) {
        defaults.set(try? JSONEncoder().encode(history), forKey: Key.favouriteHistory)
        NotificationCenter.default.post(name: .recentRepositoriesDidChange, object: self)
    }


    func recordRecentRepository(_ url: URL) {

        let path = RepositoryHistory.normalizedPath(url.path)
        let history = recentRepositories
        let updated = RepositoryHistory.addAsMostRecent(path, to: history)
        guard updated != history || defaults.data(forKey: Key.recentHistory) == nil else { return }
        saveRecentHistory(updated)
    }


    func removeRecentRepository(path: String) {
        let history = recentRepositories
        let updated = RepositoryHistory.remove(path, from: history)
        if updated != history { saveRecentHistory(updated) }
    }


    func removeFavouriteRepository(path: String) {
        let history = favouriteRepositories
        let updated = RepositoryHistory.remove(path, from: history)
        if updated != history { saveFavouriteHistory(updated) }
    }


    func assignCategory(_ repository: RepositoryHistoryEntry, category: String?) {
        saveFavouriteHistory(RepositoryHistory.assignCategory(repository, category: category, favourites: favouriteRepositories))
    }


    func removeInvalidRepositories(isValid: (String) -> Bool = { RepositoryHistory.isValidGitWorkingDir($0) }) {
        let recent = recentRepositories
        let validRecent = RepositoryHistory.removeInvalid(recent, isValid: isValid)
        if validRecent.count != recent.count { saveRecentHistory(validRecent) }
        let favourites = favouriteRepositories
        let validFavourites = RepositoryHistory.removeInvalid(favourites, isValid: isValid)
        if validFavourites.count != favourites.count { saveFavouriteHistory(validFavourites) }
    }


    func clearRecentRepositories() {
        saveRecentHistory([])
    }

    private func applyAppearance() {
        ApplicationColors.invalidate()
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
    static let recentRepositoriesDidChange = Notification.Name("GitExtensionsMac.recentRepositoriesDidChange")
    static let pullPreferencesDidChange = Notification.Name("GitExtensionsMac.pullPreferencesDidChange")
    static let pushPreferencesDidChange = Notification.Name("GitExtensionsMac.pushPreferencesDidChange")
    static let commitPreferencesDidChange = Notification.Name("GitExtensionsMac.commitPreferencesDidChange")
    static let fileStatusListPreferencesDidChange = Notification.Name("GitExtensionsMac.fileStatusListPreferencesDidChange")
    static let blamePreferencesDidChange = Notification.Name("GitExtensionsMac.blamePreferencesDidChange")
    static let fileViewerPreferencesDidChange = Notification.Name("GitExtensionsMac.fileViewerPreferencesDidChange")
    static let fileViewerSettingsApplied = Notification.Name("GitExtensionsMac.fileViewerSettingsApplied")
}
