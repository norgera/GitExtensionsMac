import Foundation

package enum RepositoryVisualState: String, CaseIterable, Sendable {
    case clean = "Clean", dirty = "Dirty", dirtySubmodules = "DirtySubmodules"
    case mixed = "Mixed", staged = "Staged", untrackedOnly = "UntrackedOnly", unknown = "Unknown"

    package static func classify(index: Int, worktree: Int, untracked: Int, worktreeSubmodules: Int) -> Self {
        switch (index, worktree) {
        case (0, 0): .clean
        case (0, _) where worktree == untracked: .untrackedOnly
        case (0, _) where worktree != worktreeSubmodules: .dirty
        case (0, _): .dirtySubmodules
        case (_, 0): .staged
        default: .mixed
        }
    }

    package func imageName(enabled: Bool) -> String { "RepoState" + (enabled ? rawValue : "Clean") }
}

package extension RevisionChangeCounts {
    mutating func append(_ other: Self) {
        changed.append(contentsOf: other.changed)
        deleted.append(contentsOf: other.deleted)
        added.append(contentsOf: other.added)
        submodulesChanged.append(contentsOf: other.submodulesChanged)
        submodulesDirty.append(contentsOf: other.submodulesDirty)
    }
    func merging(_ other: Self) -> Self {
        var result = self
        result.append(other)
        return result
    }
    var summary: String {
        [(changed, "changed file"), (deleted, "deleted file"), (added, "new file"),
         (submodulesChanged, "changed submodule"), (submodulesDirty, "dirty submodule")]
            .filter { !$0.0.isEmpty }.map { paths, singular in
                var text = "\(paths.count) \(singular)\(paths.count == 1 ? "" : "s")\n"
                text += paths.prefix(5).map { "- \($0)\n" }.joined()
                if paths.count > 5 {
                    let remaining = paths.count - 5
                    text += "- (\(remaining) more file\(remaining == 1 ? "" : "s"))\n"
                }
                return text
            }.joined(separator: "\n")
    }
}
