import GitExtensionsCore
import GitCommands
import AppKit


@MainActor
final class RepositoryCurrentBranchNameCache {
    static let shared = RepositoryCurrentBranchNameCache()
    private var names: [String: String] = [:]

    var isEmpty: Bool { names.isEmpty }

    func cachedBranchName(_ path: String) -> String? { names[path] }


    func updatedBranchName(_ path: String) async -> String {
        guard AppSettingsStore.shared.recentRepositorySettings.showCurrentBranch else {
            names[path] = ""
            return ""
        }
        let git = GitProcess(executableURL: URL(fileURLWithPath: AppSettingsStore.shared.preferences.gitExecutablePath))
        let name = await RepositoryHistory.currentBranchName(path, git: git)
        names[path] = name
        return name
    }

    func invalidateAll() { names.removeAll() }
}


@MainActor
final class RepositoryHistoryUIService: ObservableObject {
    static let shared = RepositoryHistoryUIService()

    struct MenuItem: Identifiable, Equatable {
        let id: String
        let title: String
        let path: String
        let toolTip: String?
        let branch: String?
        let anchored: Bool
    }

    struct FavouriteCategory: Identifiable, Equatable {
        let id: String
        let items: [MenuItem]
    }


    @Published private(set) var pinned: [MenuItem] = []
    @Published private(set) var recent: [MenuItem] = []

    @Published private(set) var favourites: [FavouriteCategory] = []

    private var observers: [NSObjectProtocol] = []
    private var branchCacheTask: Task<Void, Never>?

    private init() {
        observers.append(NotificationCenter.default.addObserver(forName: .recentRepositoriesDidChange, object: nil, queue: .main) { _ in
            Task { @MainActor in RepositoryHistoryUIService.shared.reload() }
        })

        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in RepositoryHistoryUIService.shared.reload() }
        })
        reload()
    }

    static func menuMeasure(_ text: String) -> CGFloat {
        (text as NSString).size(withAttributes: [.font: NSFont.menuFont(ofSize: 0)]).width
    }


    static func menuItem(_ info: RecentRepoInfo, number: Int, group: String, anchored: Bool) -> MenuItem {
        let caption = info.caption ?? info.repo.path
        return MenuItem(id: "\(group).\(number).\(info.repo.path)", title: "\(number): \(caption)", path: info.repo.path,
                        toolTip: info.repo.path != caption ? info.repo.path : nil,
                        branch: RepositoryCurrentBranchNameCache.shared.cachedBranchName(info.repo.path).flatMap { $0.isEmpty ? nil : $0 },
                        anchored: anchored)
    }

    func reload() {
        let store = AppSettingsStore.shared
        let splitter = RecentRepoSplitter(settings: store.recentRepositorySettings, measure: Self.menuMeasure)
        let (top, others) = splitter.split(store.recentRepositories)
        var number = 0
        let pinned = top.map { info -> MenuItem in number += 1; return Self.menuItem(info, number: number, group: "top", anchored: info.anchored) }
        let recent = others.map { info -> MenuItem in number += 1; return Self.menuItem(info, number: number, group: "recent", anchored: info.anchored) }
        let (favouriteTop, favouriteOthers) = splitter.split(store.favouriteRepositories)
        var seen = Set<ObjectIdentifier>()
        let union = (favouriteTop + favouriteOthers).filter { seen.insert(ObjectIdentifier($0)).inserted }
        var groups: [String: [RecentRepoInfo]] = [:]
        var order: [String] = []
        for info in union {
            let key = info.repo.category ?? ""
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(info)
        }
        let favourites = order.sorted { $0.compare($1, locale: .current) == .orderedAscending }.map { category in
            var index = 0
            return FavouriteCategory(id: category, items: groups[category, default: []].map { info in
                index += 1
                return Self.menuItem(info, number: index, group: "favourite.\(category)", anchored: false)
            })
        }
        if self.pinned != pinned { self.pinned = pinned }
        if self.recent != recent { self.recent = recent }
        if self.favourites != favourites { self.favourites = favourites }
    }


    func triggerBranchNameCacheUpdate() {
        branchCacheTask?.cancel()
        let store = AppSettingsStore.shared
        var paths: [String] = []
        for path in (store.recentRepositories + store.favouriteRepositories).map(\.path) where !paths.contains(path) { paths.append(path) }
        branchCacheTask = Task { @MainActor [weak self] in
            for path in paths {
                guard !Task.isCancelled else { return }
                guard RepositoryHistory.isValidGitWorkingDir(path), !RepositoryHistory.isBareRepository(path) else { continue }
                _ = await RepositoryCurrentBranchNameCache.shared.updatedBranchName(path)
            }
            self?.reload()
        }
    }


    func open(_ path: String, owner: NSWindow?) {
        let modifiers = NSEvent.modifierFlags
        let url = URL(fileURLWithPath: path, isDirectory: true)
        if modifiers.contains(.control) || modifiers.contains(.command) {
            GitUICommands.launchBrowse(url) { error in
                if let owner { Task { await MutationDialogs.showError(error, title: "Open", window: owner) } }
            }
            return
        }
        if RepositoryHistory.isValidGitWorkingDir(path) {
            BrowserCommandCenter.perform(.openRecentRepository(url))
            return
        }
        InvalidRepositoryRemover.showDeleteInvalidRepositoryDialog(path, owner: owner) { _ in }
    }
}


@MainActor
enum InvalidRepositoryRemover {
    static let directoryInvalidRepository = "The selected item is not a valid git repository."

    static func showDeleteInvalidRepositoryDialog(_ path: String, owner: NSWindow?, completion: @escaping (Bool) -> Void) {
        let store = AppSettingsStore.shared
        let invalidCount = store.recentRepositories.filter { !RepositoryHistory.isValidGitWorkingDir($0.path) }.count
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = directoryInvalidRepository
        alert.informativeText = path
        alert.addButton(withTitle: "Remove the selected invalid repository")
        if invalidCount > 1 { alert.addButton(withTitle: "Remove all \(invalidCount) invalid repositories") }
        alert.addButton(withTitle: "Cancel").keyEquivalent = "\u{1b}"
        alert.window.title = "Open"
        let handler: (NSApplication.ModalResponse) -> Void = { response in
            switch response {
            case .alertFirstButtonReturn:
                store.removeRecentRepository(path: path)
                completion(true)
            case .alertSecondButtonReturn where invalidCount > 1:
                store.removeInvalidRepositories()
                completion(true)
            default:
                completion(false)
            }
        }
        if let owner { alert.beginSheetModal(for: owner, completionHandler: handler) } else { handler(alert.runModal()) }
    }
}
