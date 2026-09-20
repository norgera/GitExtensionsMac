@testable import GitExtensionsCore
@testable import GitCommands
@testable import GitUI
import Foundation
import AppKit

@MainActor
enum AppSettingsTests {
    static func run() {
        testPreferencesRoundTrip()
        testBrowseDisplayPreferences()
        testHistogramPreference()
        testPullPreferencesRoundTrip()
        testRepositoryCreationPreferencesRoundTrip()
        testResetPreferencesRoundTrip()
        testReflogReferencesPreferenceRoundTrip()
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
        testViewerRuntimeDefaults()
        testFontsRoundTrip()
        testDistributedSettings()
        testRevisionLinks()
        testHotkeys()
        testSharedViewerSearch()
        testColors()
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

    private static func testBrowseDisplayPreferences() {
        withStore { store, defaults in
            var value = store.browseDisplayPreferences
            precondition(value.commitTitle(changedFiles: 3) == "Commit (3)")
            precondition(value.branchCounts(ahead: 2, behind: 1) == " ↑2 ↓1")
            precondition(value.branchCounts(ahead: 0, behind: 0).isEmpty)
            value.showChangedFilesOnCommitButton = false
            value.showAheadBehind = false
            value.showArtificialRevisionCounts = false
            value.showSubmoduleStatus = true
            value.quickSearchTimeoutMilliseconds = 7500
            value.maximumRevisionCount = 250
            store.saveBrowseDisplayPreferences(value)
            let restored = AppSettingsStore(defaults: defaults).browseDisplayPreferences
            precondition(restored == value)
            precondition(restored.commitTitle(changedFiles: 3) == "Commit")
            precondition(restored.branchCounts(ahead: 2, behind: 1).isEmpty)
            let inherited = try! JSONDecoder().decode(BrowseDisplayPreferences.self, from: Data("{}".utf8))
            precondition(inherited == BrowseDisplayPreferences())
            let item = SubmoduleTreeItem(repositoryURL: URL(fileURLWithPath: "/fixture/module"),
                parentURL: URL(fileURLWithPath: "/fixture"), path: "module", localPath: "module",
                isCurrent: false, isTop: false, isInitialized: true, branch: "main",
                commitID: nil, recordedID: nil, commitState: .ahead, addedCommits: 2, removedCommits: 0)
            precondition(SubmoduleTreePresentation.menuTitle(item, showsStatus: false) == "module (main)")
            precondition(SubmoduleTreePresentation.menuTitle(item, showsStatus: true) == "module (main) (+2-0)")
        }
    }

    private static func testHistogramPreference() {
        withStore { store, defaults in
            let legacy = try! JSONDecoder().decode(FileViewerPreferences.self, from: Data("{\"whitespace\":\"endOfLine\",\"contextLines\":7}".utf8))
            precondition(!legacy.usesHistogram && legacy.whitespace == .endOfLine && legacy.contextLines == 7)
            var value = legacy
            value.usesHistogram = true
            store.applyFileViewerPreferences(value)
            let restored = AppSettingsStore(defaults: defaults)
            precondition(restored.fileViewerPreferences.usesHistogram)
            precondition(restored.preferencesForNewFileViewer().usesHistogram)
            precondition(value.diffOptions.gitArguments == ["--histogram", "--ignore-space-at-eol", "--unified=7"])
        }
    }

    private static func testRepositoryCreationPreferencesRoundTrip() {
        withStore { store, defaults in
            var preferences = store.repositoryCreationPreferences
            preferences.cloneDestinationPath = "/tmp/Clones"
            preferences.cloneWindowWidth = 720
            store.saveRepositoryCreationPreferences(preferences)
            store.recordCloneSource("ssh://example.test/repository.git")
            store.recordCloneSource("ssh://example.test/repository.git")
            let restored = AppSettingsStore(defaults: defaults).repositoryCreationPreferences
            precondition(restored.cloneDestinationPath == "/tmp/Clones")
            precondition(restored.cloneWindowWidth == 720)
            precondition(restored.recentSources == ["ssh://example.test/repository.git"])
            let cloned = URL(fileURLWithPath: "/tmp/Clones/repository", isDirectory: true)
            store.recordRecentRepository(cloned)
            precondition(store.recentRepositories.first?.path == cloned.path)
            precondition(store.lastRepositoryPath == nil)
        }
    }

    private static func testResetPreferencesRoundTrip() {
        withStore { store, defaults in
            var preferences = store.resetPreferences
            precondition(preferences.checkoutOtherBranchAfterReset)
            preferences.checkoutOtherBranchAfterReset = false
            store.saveResetPreferences(preferences)
            precondition(AppSettingsStore(defaults: defaults).resetPreferences == preferences)
        }
    }

    private static func testReflogReferencesPreferenceRoundTrip() {
        withStore { store, defaults in
            precondition(!store.showReflogReferences)
            store.saveShowReflogReferences(true)
            precondition(AppSettingsStore(defaults: defaults).showReflogReferences)
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

    private static func testViewerRuntimeDefaults() {
        withStore { store, defaults in
            var baseline = store.fileViewerPreferences
            baseline.whitespace = .endOfLine
            store.saveFileViewerPreferences(baseline)
            var runtime = baseline
            runtime.whitespace = .all
            runtime.showsEntireFile = true
            runtime.contextLines = 15
            store.updateFileViewerPreferences(runtime)
            precondition(AppSettingsStore(defaults: defaults).fileViewerPreferences == baseline)
            let next = store.preferencesForNewFileViewer()
            precondition(next.whitespace == .all && !next.showsEntireFile && next.contextLines == 3)
            var remember = store.fileViewerRemember
            remember.whitespace = false
            remember.entireFile = true
            remember.contextLines = true
            store.saveFileViewerRemember(remember)
            store.updateFileViewerPreferences(runtime)
            precondition(store.preferencesForNewFileViewer().whitespace == .endOfLine)
            precondition(store.preferencesForNewFileViewer().showsEntireFile)
            runtime.contextLines = 16
            store.updateFileViewerPreferences(runtime)
            precondition(AppSettingsStore(defaults: defaults).fileViewerPreferences.contextLines == 16)
            precondition(AppSettingsStore(defaults: defaults).fileViewerPreferences.whitespace == .endOfLine)
            store.saveFileViewerPreferences(runtime)
            precondition(AppSettingsStore(defaults: defaults).fileViewerPreferences == runtime)
            precondition(AppSettingsStore(defaults: defaults).fileViewerRemember == remember)
        }
    }

    private static func testFontsRoundTrip() {
        withStore { store, defaults in
            precondition(store.fontPreferences.fonts.isEmpty)
            let original = store.codeFont
            var fonts = store.fontPreferences
            fonts.fonts[.code] = StoredApplicationFont(NSFont.monospacedSystemFont(ofSize: 18, weight: .regular))
            fonts.fonts[.commit] = StoredApplicationFont(NSFont.systemFont(ofSize: 15))
            fonts.fonts[.application] = StoredApplicationFont(NSFont.systemFont(ofSize: 22))
            fonts.showEolMarkerAsGlyph = true
            store.saveFontPreferences(fonts)
            let reloaded = AppSettingsStore(defaults: defaults)
            precondition(reloaded.fontPreferences == fonts)
            let legacyFontData = try! JSONSerialization.data(withJSONObject: ["fonts": []])
            precondition(!(try! JSONDecoder().decode(ApplicationFontPreferences.self, from: legacyFontData)).showEolMarkerAsGlyph)
            precondition(FileViewerWhitespace.text("a\r\nb\nc\r", glyph: false) == "a\\r\\n\r\nb\\n\nc\\r\r")
            precondition(FileViewerWhitespace.text("a\r\nb\n", glyph: true) == "a¶\r\nb¶\n")
            precondition(FileViewerWhitespace.text("a\t b", glyph: true) == "a→·b")
            precondition(reloaded.codeFont.pointSize == 18 && reloaded.commitFont.pointSize == 15)
            precondition(reloaded.diffLineHeight >= 21)
            precondition(reloaded.applicationFont(size: 11).pointSize == 22)
            precondition(reloaded.applicationRowHeight(minimum: 18) > 22)
            let lines = [DiffLine(id: "line", oldLineNumber: 999, newLineNumber: 1000, kind: .context, text: "text")]
            let standardGutter = DiffGutterMetrics(lines: lines)
            let customGutter = DiffGutterMetrics(lines: lines, font: reloaded.diffGutterFont)
            precondition(customGutter.numberColumnWidth > standardGutter.numberColumnWidth)
            store.saveFontPreferences(ApplicationFontPreferences())
            precondition(store.codeFont == original)
            precondition(AppSettingsStore(defaults: defaults).fontPreferences.fonts.isEmpty)
            let japanese = RepositoryTextEncoding(ianaName: "shift_jis")!
            store.includedTextEncodings = [japanese]
            let encodings = AppSettingsStore(defaults: defaults).includedTextEncodings
            precondition(encodings.contains(japanese) && encodings.contains(.utf8))
            precondition(store.viewerEncodings(including: .windows1252).contains(.windows1252))
        }
    }

    private static func testColors() {
        do {
            let bundled = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("GitExtensionsMac/UI/Themes")
            let normal = try ApplicationThemeReader.load("invariant.css", colorblind: false, bundled: bundled)
            let accessible = try ApplicationThemeReader.load("invariant.css", colorblind: true, bundled: bundled)
            precondition(normal["RemoteBranch"] == 0x8B0009)
            precondition(accessible["RemoteBranch"] == 0x0600A8)
            precondition(normal["GraphBranch8"] == -1)
            let dark = try ApplicationThemeReader.load("dark+.css", colorblind: false, bundled: bundled)
            precondition(dark["GraphBranch1"] == 0xDB5B93)
            precondition(ApplicationThemeReader.parseColor("#abc") == 0xAABBCC)
            precondition(ApplicationThemeReader.parseColor("LightGoldenRodYellow") == 0xFAFAD2)
            precondition(ApplicationThemeReader.parseColor("rebeccapurple") == 0x663399)
            precondition(ApplicationThemeReader.parseColor("darkslategrey") == 0x2F4F4F)
            precondition(ApplicationThemeReader.parseColor("rgb(12, 34, 56)") == 0x0C2238)
            precondition(ApplicationThemeReader.parseColor("not a color") == nil)
            precondition(ApplicationThemeReader.parseColor("#-12345") == nil)
            precondition(ApplicationThemeReader.parseColor("rgb(12, bad, 34, 56)") == nil)
            precondition(ApplicationThemeReader.parseColor("rgb(12,,34)") == nil)
            precondition(ApplicationThemeReader.parseColor("rgb(100%, 0%, 50%)") == 0xFF0080)
            precondition(ApplicationThemeReader.parseColor("hsl(120, 100%, 50%)") == 0x00FF00)
            precondition(ApplicationThemeReader.parseColor("hsl(-120, 100%, 50%)") == 0x0000FF)
            precondition(ApplicationThemeReader.parseColor("hsl(nan, 100%, 50%)") == nil)
            withStore { store, defaults in
                var colors = store.colorPreferences
                colors.themeFile = "dark.css"; colors.colorblind = true; colors.multicolorBranches = false
                store.colorPreferences = colors
                precondition(AppSettingsStore(defaults: defaults).colorPreferences == colors)
            }
        } catch { preconditionFailure("Theme fixture failed: \(error)") }
    }

    private static func testSharedViewerSearch() {
        let lines = ["first match", "middle", "last MATCH"].enumerated().map { index, text in
            DiffLine(id: String(index), oldLineNumber: index + 1, newLineNumber: index + 1, kind: .context, text: text)
        }
        precondition(FileViewerNavigationDialogs.matchingRow(lines: lines, query: "match", after: 0) == 2)
        precondition(FileViewerNavigationDialogs.matchingRow(lines: lines, query: "match", after: 2, forward: false) == 0)
        precondition(FileViewerNavigationDialogs.matchingRow(lines: lines, query: "match", after: 0, forward: false) == 2)
        precondition(FileViewerNavigationDialogs.matchingRow(lines: lines, query: "match", after: -1, forward: false) == 2)
        precondition(FileViewerNavigationDialogs.matchingRow(lines: lines, query: "match", after: 2) == 0)
        precondition(FileViewerNavigationDialogs.matchingRow(lines: [], query: "match", after: 0) == nil)
        precondition(FileViewerNavigationDialogs.matchingRow(lines: lines, query: "absent", after: 0) == nil)
    }

    private static func testHotkeys() {
        withStore { store, defaults in
            let original = ApplicationHotkeys.chord("refresh", overrides: [:])
            precondition(original == ApplicationKeyChord("r", .command))
            store.hotkeyOverrides = ["refresh": .init("r", [.command, .shift]), "commit": .init("")]
            let saved = AppSettingsStore(defaults: defaults).hotkeyOverrides
            precondition(ApplicationHotkeys.chord("refresh", overrides: saved).title == "⇧⌘R")
            precondition(ApplicationHotkeys.chord("commit", overrides: saved).swiftUI == nil)
            precondition(ApplicationHotkeys.chord("createBranch", overrides: saved) == .init("b", .control))
            store.hotkeyOverrides = [:]
            precondition(ApplicationHotkeys.chord("refresh", overrides: store.hotkeyOverrides) == original)
            precondition(Set(ApplicationHotkeys.definitions.map(\.id)).count == ApplicationHotkeys.definitions.count)
            precondition(ApplicationHotkeys.matching(.init("n", .command), category: "Stash", overrides: [:]) == "stash.next")
            precondition(ApplicationHotkeys.matching(.init("b"), category: "Conflict resolver", overrides: [:]) == "conflict.base")
            let overrides: [String: ApplicationKeyChord] = ["conflict.base": .init("1", .command), "stash.next": .init("")]
            precondition(ApplicationHotkeys.matching(.init("b"), category: "Conflict resolver", overrides: overrides) == nil)
            precondition(ApplicationHotkeys.matching(.init("1", .command), category: "Conflict resolver", overrides: overrides) == "conflict.base")
            precondition(ApplicationHotkeys.matching(.init("n", .command), category: "Stash", overrides: overrides) == nil)
            precondition(ApplicationHotkeys.matching(.init("b"), category: "Stash", overrides: [:]) == nil)
            precondition(ApplicationHotkeys.matching(.init("\u{f705}"), category: "Repository tree", overrides: [:]) == "tree.rename")
            precondition(ApplicationHotkeys.matching(.init("\u{7f}"), category: "Repository tree", overrides: ["tree.delete": .init("")]) == nil)
            precondition(ApplicationHotkeys.matching(.init("\u{f703}", .option), category: "Commit", overrides: [:]) == "commit.nextFile.alternative")
            precondition(ApplicationHotkeys.matching(.init("\u{f703}", .option), category: "Commit", overrides: ["commit.nextFile.alternative": .init("")]) == nil)
            precondition(ApplicationHotkeys.matching(.init("s"), category: "File status list", overrides: [:]) == "file.stage")
        }
    }

    private static func testRevisionLinks() {
        var definition = RevisionLinkDefinition()
        definition.name = "Issues & reviews"
        definition.searchPattern = "issue (#[0-9]+,? ?)+"
        definition.nestedSearchPattern = "#([0-9]+)"
        definition.remoteSearchPattern = "https://([^/]+)/(.+)"
        definition.formats = [.init(caption: "Issue {2}", format: "https://{0}/{1}/issues/{2}?commit=%COMMIT_HASH%")]
        let xml = RevisionLinkDefinition.encode([definition])
        precondition(try! RevisionLinkDefinition.decode(xml) == [definition])
        let id = try! ObjectID(parsing: String(repeating: "a", count: 40))
        let links = definition.links(commitID: id, message: "Fix issue #12, #34", localRefs: [], remoteRefs: [], remotes: [
            .init(name: "origin", url: "https://example.org/fork", pushURL: ""),
            .init(name: "upstream", url: "https://example.org/project", pushURL: "")
        ])
        precondition(links.map(\.caption) == ["Issue 12", "Issue 34"])
        precondition(links[0].destination == "https://example.org/project/issues/12?commit=\(id.string)")
        precondition(RevisionLinkDefinition.format("{{{0}}}", groups: ["value"]) == "{value}")
        precondition(RevisionLinkDefinition.format("[{0,7}] [{0,-7}]", groups: ["value"]) == "[  value] [value  ]")
        precondition(RevisionLinkDefinition.format("{0:ignored}", groups: ["value"]) == "value")
        precondition(RevisionLinkDefinition.format("{0,invalid}", groups: ["value"]) == nil)
        precondition(RevisionLinkDefinition.format("{3}", groups: []) == nil)
        definition.searchPattern = "["
        precondition(definition.links(commitID: id, message: "anything", localRefs: [], remoteRefs: [], remotes: []).isEmpty)
        withStore { store, defaults in
            store.revisionLinksXML = xml
            precondition(AppSettingsStore(defaults: defaults).revisionLinksXML == xml)
            store.revisionLinksXML = nil
            precondition(AppSettingsStore(defaults: defaults).revisionLinksXML == nil)
        }
    }

    private static func testDistributedSettings() {
        precondition(DistributedSettings.normalizedMergeLogCount(" 0 ") == "0")
        precondition(DistributedSettings.normalizedMergeLogCount("-2") == "-2")
        precondition(DistributedSettings.normalizedMergeLogCount("invalid") == nil)
        precondition(DistributedSettings.normalizedMergeLogCount("2147483648") == nil)
        func require(_ condition: Bool) { precondition(condition) }
        withStore { store, _ in
            do {
                let root = FileManager.default.temporaryDirectory.appendingPathComponent("GitExtensionsMac-SettingsXML-\(UUID().uuidString)")
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                defer { try? FileManager.default.removeItem(at: root) }
                let settings = DistributedSettings(localURL: root.appendingPathComponent("local.settings"), distributedURL: root.appendingPathComponent("distributed.settings"))
                let key = DistributedSettings.mergeLog
                try DistributedSettings.write([key: "true", "unrelated": "Unicode é & <value>\nline"], to: settings.distributedURL)
                require(try settings.mergePreferences(store).addLogMessages)
                try DistributedSettings.write([key: "false"], to: settings.localURL)
                require(try !settings.mergePreferences(store).addLogMessages)
                try DistributedSettings.write([key: nil], to: settings.localURL)
                require(try settings.mergePreferences(store).addLogMessages)
                var preferences = try settings.mergePreferences(store)
                preferences.addLogMessages = false
                preferences.logMessagesCount = 42
                try settings.saveMergeLog(preferences, store: store)
                require(try DistributedSettings.read(settings.localURL)[key] == "false")
                require(try DistributedSettings.read(settings.distributedURL)[key] == "true")
                precondition(store.mergePreferences.logMessagesCount == 42)
                require(try DistributedSettings.read(settings.distributedURL)["unrelated"] == "Unicode é & <value>\nline")
                try Data("<not-a-dictionary/>".utf8).write(to: settings.localURL)
                var rejected = false
                do { try DistributedSettings.write([key: "true"], to: settings.localURL) } catch { rejected = true }
                precondition(rejected)
                require(try String(contentsOf: settings.localURL, encoding: .utf8) == "<not-a-dictionary/>")
            } catch { preconditionFailure("Distributed settings test failed: \(error)") }
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
            var application = store.preferences
            application.reopenLastRepository.toggle()
            store.save(application)
            precondition(store.fileViewerPreferences == preferences, "Unrelated app settings must not collapse detailed whitespace modes")
            precondition(AppSettingsStore(defaults: defaults).fileViewerPreferences == preferences, "Detailed viewer defaults survive relaunch")
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
