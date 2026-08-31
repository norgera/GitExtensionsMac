@testable import GitExtensionsCore
@testable import GitCommands
@testable import GitUI
import Foundation

@MainActor
enum AppSettingsTests {
    static func run() {
        testPreferencesRoundTrip()
        testPullPreferencesRoundTrip()
        testRebasePreferencesRoundTrip()
        testCherryPickPreferencesRoundTrip()
        testPushPreferencesRoundTrip()
        testStashPreferencesRoundTrip()
        testTagPreferencesRoundTrip()
        testRemoteManagementPreferencesRoundTrip()
        testRemoteManagementSelectionRestoration()
        testRepositoryTreePreferencesRoundTrip()
        testMergePreferencesRoundTrip()
        testCheckoutBranchPreferencesRoundTrip()
        testCommitPreferencesRoundTrip()
        testFileStatusListPreferencesRoundTrip()
        testFileViewerPreferencesRoundTrip()
        testCommitMessageRules()
        testRecentRepositories()
        print("AppSettingsTests: passed")
    }

    private static func testPreferencesRoundTrip() {
        withStore { store, defaults in
            var preferences = store.preferences
            preferences.theme = .dark
            preferences.gitExecutablePath = "/opt/homebrew/bin/git"
            preferences.defaultSignOff = true
            preferences.mergeCommonParentLanes = false
            store.save(preferences)
            precondition(AppSettingsStore(defaults: defaults).preferences == preferences)
        }
    }

    private static func testTagPreferencesRoundTrip() {
        withStore { store, defaults in
            var preferences = store.tagPreferences
            preferences.showTagsInRevisionGrid = false
            preferences.showTagsInRepositoryTree = false
            store.saveTagPreferences(preferences)
            precondition(AppSettingsStore(defaults: defaults).tagPreferences == preferences)
        }
    }

    private static func testRemoteManagementPreferencesRoundTrip() {
        withStore { store, defaults in
            var preferences = store.remoteManagementPreferences
            preferences.showAdvancedOptions = true
            preferences.windowWidth = 1_080
            preferences.windowHeight = 620
            store.saveRemoteManagementPreferences(preferences)
            store.recordRemoteURL("ssh://example/repository")
            store.recordRemoteURL("ssh://example/repository")
            store.replaceRemoteURLHistory("ssh://example/repository", with: "/tmp/repository with spaces")
            let reloaded = AppSettingsStore(defaults: defaults).remoteManagementPreferences
            precondition(reloaded.showAdvancedOptions)
            precondition(reloaded.windowWidth == 1_080 && reloaded.windowHeight == 620)
            precondition(reloaded.recentURLs == ["/tmp/repository with spaces"])
        }
    }

    private static func testRepositoryTreePreferencesRoundTrip() {
        withStore { store, defaults in
            var preferences = store.repositoryTreePreferences
            preferences.visibleRoots.remove(.submodules)
            preferences.rootOrder = [.tags, .branches, .remotes, .worktrees, .submodules, .stashes]
            preferences.sortBy = .creatorDate
            preferences.sortOrder = .descending
            store.saveRepositoryTreePreferences(preferences)
            let restored = AppSettingsStore(defaults: defaults).repositoryTreePreferences
            precondition(restored == preferences)
        }

        var malformed = RepositoryTreePreferences()
        malformed.rootOrder = [.branches, .branches]
        malformed.visibleRoots.insert(.tags)
        malformed.normalize()
        precondition(malformed.rootOrder == RepositoryTreeRoot.allCases)
    }

    private static func testRemoteManagementSelectionRestoration() {
        let remotes = [
            RepositoryRemoteConfiguration(
                name: "origin", fetchURL: "/tmp/origin", pushURL: nil,
                puttyKeyFile: nil, color: nil, prefix: nil, pushRefSpecs: [], isDisabled: false
            ),
            RepositoryRemoteConfiguration(
                name: "upstream", fetchURL: "/tmp/upstream", pushURL: nil,
                puttyKeyFile: nil, color: nil, prefix: nil, pushRefSpecs: [], isDisabled: true
            )
        ]
        precondition(RemoteManagementSelectionResolver.preferredRemoteName(configurations: remotes, requested: "upstream") == "upstream")
        precondition(RemoteManagementSelectionResolver.preferredRemoteName(configurations: remotes, requested: "deleted") == "origin")

        let tracking = [
            RepositoryBranchTrackingConfiguration(branchName: "main", remoteName: "origin", mergeBranch: "main"),
            RepositoryBranchTrackingConfiguration(branchName: "topic", remoteName: nil, mergeBranch: nil)
        ]
        precondition(RemoteManagementSelectionResolver.preferredLocalBranch(configurations: tracking, requested: "topic") == "topic")
        precondition(RemoteManagementSelectionResolver.preferredLocalBranch(configurations: tracking, requested: "deleted") == "main")
    }

    private static func testRecentRepositories() {
        withStore { store, _ in
            var preferences = store.preferences
            preferences.maximumRecentRepositories = 1
            store.save(preferences)
            store.recordOpenedRepository(URL(fileURLWithPath: "/", isDirectory: true))
            let temporaryURL = URL(fileURLWithPath: "/private/tmp", isDirectory: true).standardizedFileURL
            store.recordOpenedRepository(temporaryURL)
            precondition(store.recentRepositories.map(\.path) == [temporaryURL.path])
            precondition(store.lastRepositoryPath == temporaryURL.path)
            store.removeRecentRepository(path: temporaryURL.path)
            precondition(store.recentRepositories.isEmpty)
            store.recordOpenedRepository(URL(fileURLWithPath: "/", isDirectory: true))
            store.clearRecentRepositories()
            precondition(store.recentRepositories.isEmpty)
        }
    }

    private static func testPullPreferencesRoundTrip() {
        withStore { store, defaults in
            var preferences = store.pullPreferences
            preferences.defaultAction = .fetchPruneAll
            preferences.formAction = .rebase
            preferences.autoStash = true
            preferences.autoPopStash = .never
            preferences.includeUntrackedInAutoStash = true
            preferences.recentURLs = ["/tmp/repository with spaces", "ssh://example/repository"]
            preferences.helpExpanded = false
            preferences.closeProcessOnSuccess = true
            preferences.confirmFetchAndPruneAll = false
            preferences.updateSubmodulesAfterPull = true
            store.savePullPreferences(preferences)
            precondition(AppSettingsStore(defaults: defaults).pullPreferences == preferences)

            store.recordPullURL("ssh://example/repository")
            precondition(store.pullPreferences.recentURLs.first == "ssh://example/repository")
            precondition(store.pullPreferences.recentURLs.filter { $0 == "ssh://example/repository" }.count == 1)
        }
    }

    private static func testPushPreferencesRoundTrip() {
        let suite = "GitExtensionsMacTests.push.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else { preconditionFailure("Could not create defaults") }
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = AppSettingsStore(defaults: defaults)
        var preferences = store.pushPreferences
        preferences.recursiveSubmodules = .onDemand
        preferences.showAdvancedOptions = true
        preferences.confirmNewBranch = false
        preferences.confirmAddTrackingReference = false
        preferences.rejectedAction = .rebase
        preferences.loadRemoteBranchesDirectly = true
        store.savePushPreferences(preferences)
        precondition(AppSettingsStore(defaults: defaults).pushPreferences == preferences)

        store.recordPushURL("ssh://example/push-repository")
        store.recordPushURL("ssh://example/push-repository")
        precondition(store.pushPreferences.recentURLs.first == "ssh://example/push-repository")
        precondition(store.pushPreferences.recentURLs.filter { $0 == "ssh://example/push-repository" }.count == 1)
    }

    private static func testMergePreferencesRoundTrip() {
        withStore { store, defaults in
            var preferences = store.mergePreferences
            preferences.noCommit = true
            preferences.noFastForward = true
            preferences.addLogMessages = true
            preferences.logMessagesCount = 37
            preferences.helpExpanded = false
            preferences.closeProcessOnSuccess = true
            store.saveMergePreferences(preferences)
            precondition(AppSettingsStore(defaults: defaults).mergePreferences == preferences)
        }
    }

    private static func testCheckoutBranchPreferencesRoundTrip() {
        withStore { store, defaults in
            var preferences = store.checkoutBranchPreferences
            preferences.checkForUncommittedChanges = false
            preferences.alwaysShowDialog = true
            preferences.localChangesAction = .stash
            preferences.useDefaultLocalChangesAction = true
            preferences.createLocalBranchForRemote = true
            preferences.autoPopStash = .always
            preferences.confirmDirectCheckout = true
            preferences.dontConfirmDeleteUnmerged = true
            preferences.autoNormaliseBranchName = true
            preferences.branchNameReplacement = "-"
            preferences.updateSubmodulesOnCheckout = false
            preferences.checkoutWindowWidth = 720
            preferences.createWindowWidth = 640
            preferences.deleteWindowWidth = 560
            preferences.renameWindowWidth = 520
            store.saveCheckoutBranchPreferences(preferences)
            precondition(AppSettingsStore(defaults: defaults).checkoutBranchPreferences == preferences)
        }
    }

    private static func testRebasePreferencesRoundTrip() {
        withStore { store, defaults in
            var preferences = store.rebasePreferences
            preferences.helpExpanded = false
            store.saveRebasePreferences(preferences)
            precondition(AppSettingsStore(defaults: defaults).rebasePreferences == preferences)
        }
    }

    private static func testStashPreferencesRoundTrip() {
        withStore { store, defaults in
            var preferences = store.stashPreferences
            preferences.keepIndex = true
            preferences.includeUntracked = true
            preferences.dontConfirmDrop = true
            preferences.showStashCount = true
            preferences.showStashesInRepositoryTree = false
            preferences.windowWidth = 812
            preferences.windowHeight = 601
            preferences.dividerPosition = 312
            store.saveStashPreferences(preferences)
            precondition(AppSettingsStore(defaults: defaults).stashPreferences == preferences)
        }
    }

    private static func testCherryPickPreferencesRoundTrip() {
        withStore { store, defaults in
            let preferences = CherryPickPreferences(
                automaticallyCommit: true,
                addReference: true
            )
            store.saveCherryPickPreferences(preferences)
            precondition(AppSettingsStore(defaults: defaults).cherryPickPreferences == preferences)
        }
    }

    private static func testCommitPreferencesRoundTrip() {
        withStore { store, defaults in
            var preferences = store.commitPreferences
            preferences.historyLimit = 12
            preferences.showOnlyMyMessages = true
            preferences.ensureSecondLineEmpty = false
            preferences.rememberAmendState = false
            preferences.closeAfterCommit = false
            preferences.refreshOnFocus = true
            preferences.confirmAmend = false
            preferences.forceWithLeaseAfterAmend = true
            preferences.lastCommitMessage = "Remembered message"
            preferences.templates = [CommitMessageTemplate(
                name: "Issue",
                text: "fix: {{issue-(\\d+)}}[1]",
                expandsBranchRegularExpressions: true
            )]
            preferences.validation.maximumSubjectLength = 72
            preferences.validation.regularExpression = #"^(feat|fix):"#
            preferences.windowWidth = 1040
            preferences.mainDivider = 420
            store.saveCommitPreferences(preferences)
            precondition(AppSettingsStore(defaults: defaults).commitPreferences == preferences)
        }
    }

    private static func testFileStatusListPreferencesRoundTrip() {
        withStore { store, defaults in
            let preferences = FileStatusListPreferences(
                grouping: .status,
                isTreeMode: false,
                usesDenseTree: false,
                showsGroupNodesInFlatList: true,
                showsUntrackedFiles: false
            )
            store.saveFileStatusListPreferences(preferences)
            precondition(AppSettingsStore(defaults: defaults).fileStatusListPreferences == preferences)
        }
    }

    private static func testFileViewerPreferencesRoundTrip() {
        withStore { store, defaults in
            var preferences = store.fileViewerPreferences
            preferences.whitespace = .changes
            preferences.contextLines = 8
            preferences.showsEntireFile = true
            preferences.treatsAllFilesAsText = true
            preferences.showsNonPrintingCharacters = true
            preferences.showsSyntaxHighlighting = false
            preferences.textEncoding = .windows1252
            store.saveFileViewerPreferences(preferences)
            precondition(AppSettingsStore(defaults: defaults).fileViewerPreferences == preferences)
        }
    }

    private static func testCommitMessageRules() {
        var validation = CommitValidationPreferences()
        validation.maximumSubjectLength = 8
        validation.maximumLineLength = 12
        validation.requireEmptySecondLine = true
        validation.regularExpression = #"^(feat|fix):"#
        let issues = CommitMessageValidator.issues(
            in: "not a valid subject\nbody without separator\ntail",
            preferences: validation
        )
        precondition(issues.contains(.subjectTooLong(actual: 19, maximum: 8)))
        precondition(issues.contains(.lineTooLong(line: 1, actual: 19, maximum: 12)))
        precondition(issues.contains(.lineTooLong(line: 2, actual: 22, maximum: 12)))
        precondition(issues.contains(.secondLineMustBeEmpty))
        precondition(issues.contains(.regularExpressionMismatch(#"^(feat|fix):"#)))

        validation.regularExpression = "["
        precondition(!CommitMessageValidator.issues(in: "feat: valid", preferences: validation).contains(.invalidRegularExpression("[")))
        precondition(CommitTemplateExpander.expand(
            "fix: {{issue-(\\d+)}}[1]",
            forBranch: "issue-428-polish",
            enabled: true
        ) == "fix: 428")
        precondition(CommitTemplateExpander.expand("{{missing-(\\d+)}}[1]", forBranch: "main", enabled: true).isEmpty)

        var formatting = CommitValidationPreferences()
        formatting.maximumLineLength = 12
        formatting.requireEmptySecondLine = true
        formatting.indentAfterFirstLine = true
        formatting.autoWrap = true
        precondition(CommitMessageAutoFormatter.format(
            "Subject\nbody words that wrap",
            preferences: formatting
        ) == "Subject\n\n - body\nwords that\nwrap")
    }

    private static func withStore(_ body: (AppSettingsStore, UserDefaults) -> Void) {
        let suite = "GitExtensionsMac.AppSettingsTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else { preconditionFailure("Could not create defaults suite") }
        defaults.removePersistentDomain(forName: suite)
        body(AppSettingsStore(defaults: defaults), defaults)
        defaults.removePersistentDomain(forName: suite)
    }
}
