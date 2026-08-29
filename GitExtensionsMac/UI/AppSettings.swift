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
        static let rebasePreferences = "GitExtensionsMac.rebasePreferences.v1"
        static let cherryPickPreferences = "GitExtensionsMac.cherryPickPreferences.v1"
        static let stashPreferences = "GitExtensionsMac.stashPreferences.v1"
        static let mergePreferences = "GitExtensionsMac.mergePreferences.v1"
        static let checkoutBranchPreferences = "GitExtensionsMac.checkoutBranchPreferences.v1"
    }

    private let defaults: UserDefaults
    private(set) var preferences: AppPreferences
    private(set) var recentRepositories: [RecentRepository]
    private(set) var pullPreferences: PullPreferences
    private(set) var pushPreferences: PushPreferences
    private(set) var commitPreferences: CommitPreferences
    private(set) var fileStatusListPreferences: FileStatusListPreferences
    private(set) var rebasePreferences: RebasePreferences
    private(set) var cherryPickPreferences: CherryPickPreferences
    private(set) var stashPreferences: StashPreferences
    private(set) var mergePreferences: MergePreferences
    private(set) var checkoutBranchPreferences: CheckoutBranchPreferences

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let decoder = JSONDecoder()
        preferences = defaults.data(forKey: Key.preferences)
            .flatMap { try? decoder.decode(AppPreferences.self, from: $0) }
            ?? AppPreferences()
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
        rebasePreferences = defaults.data(forKey: Key.rebasePreferences)
            .flatMap { try? decoder.decode(RebasePreferences.self, from: $0) }
            ?? RebasePreferences()
        cherryPickPreferences = defaults.data(forKey: Key.cherryPickPreferences)
            .flatMap { try? decoder.decode(CherryPickPreferences.self, from: $0) }
            ?? CherryPickPreferences()
        stashPreferences = defaults.data(forKey: Key.stashPreferences)
            .flatMap { try? decoder.decode(StashPreferences.self, from: $0) }
            ?? StashPreferences()
        mergePreferences = defaults.data(forKey: Key.mergePreferences)
            .flatMap { try? decoder.decode(MergePreferences.self, from: $0) }
            ?? MergePreferences()
        checkoutBranchPreferences = defaults.data(forKey: Key.checkoutBranchPreferences)
            .flatMap { try? decoder.decode(CheckoutBranchPreferences.self, from: $0) }
            ?? CheckoutBranchPreferences()
        recentRepositories.removeAll { !FileManager.default.fileExists(atPath: $0.path) }
        applyAppearance()
    }

    var lastRepositoryPath: String? {
        defaults.string(forKey: Key.lastRepository)
    }

    func save(_ preferences: AppPreferences) {
        self.preferences = preferences
        defaults.set(try? JSONEncoder().encode(preferences), forKey: Key.preferences)
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

    func saveMergePreferences(_ preferences: MergePreferences) {
        mergePreferences = preferences
        defaults.set(try? JSONEncoder().encode(preferences), forKey: Key.mergePreferences)
    }

    func saveCheckoutBranchPreferences(_ preferences: CheckoutBranchPreferences) {
        checkoutBranchPreferences = preferences
        defaults.set(try? JSONEncoder().encode(preferences), forKey: Key.checkoutBranchPreferences)
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
        let path = url.standardizedFileURL.path
        recentRepositories.removeAll { $0.path == path }
        recentRepositories.insert(RecentRepository(path: path, lastOpened: Date()), at: 0)
        defaults.set(path, forKey: Key.lastRepository)
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
}
