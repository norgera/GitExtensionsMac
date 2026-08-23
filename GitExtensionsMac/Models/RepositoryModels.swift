import Foundation

struct Repository: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let path: String
    let description: String
    let isBare: Bool

    init(id: String, name: String, path: String, description: String, isBare: Bool = false) {
        self.id = id
        self.name = name
        self.path = path
        self.description = description
        self.isBare = isBare
    }
}

struct Branch: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let commitID: String
    let isCurrent: Bool
    let isRemote: Bool
    let remoteName: String?
    let ahead: Int
    let behind: Int
}

struct Tag: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let commitID: String
}

struct Remote: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let fetchURL: String
    let branches: [Branch]
}

struct Stash: Identifiable, Hashable, Sendable {
    let id: String
    let selector: String
    let subject: String
    let branchName: String
    let commitID: String
}

struct Worktree: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let path: String
    let branchName: String
    let isCurrent: Bool
}

struct Submodule: Identifiable, Hashable, Sendable {
    enum State: String, Hashable, Sendable {
        case clean
        case uninitialized
        case modified
        case conflicted
        case unknown
    }

    let id: String
    let name: String
    let path: String
    let url: String?
    let commitID: String?
    let description: String?
    let state: State
}

struct RevisionReference: Identifiable, Hashable, Sendable {
    enum Kind: Sendable {
        case head
        case currentBranch
        case localBranch
        case remoteBranch
        case tag
        case stash
    }

    let id: String
    let name: String
    let kind: Kind
    let trackingRemote: String?
    let mergeWith: String?

    init(
        id: String,
        name: String,
        kind: Kind,
        trackingRemote: String? = nil,
        mergeWith: String? = nil
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.trackingRemote = trackingRemote
        self.mergeWith = mergeWith
    }

    var remoteName: String? {
        guard kind == .remoteBranch else { return nil }
        return name.split(separator: "/", maxSplits: 1).first.map(String.init)
    }

    var localName: String {
        guard kind == .remoteBranch else { return name }
        return name.split(separator: "/", maxSplits: 1).dropFirst().first.map(String.init) ?? name
    }

    func tracks(_ remoteReference: RevisionReference) -> Bool {
        guard kind == .currentBranch || kind == .localBranch,
              remoteReference.kind == .remoteBranch,
              let trackingRemote,
              let mergeWith
        else {
            return false
        }
        return trackingRemote == remoteReference.remoteName
            && mergeWith == remoteReference.localName
    }
}

struct Commit: Identifiable, Hashable, Sendable {
    enum Kind: Hashable, Sendable {
        case revision
        case workingDirectory
        case index
    }

    let id: String
    let shortID: String
    let subject: String
    let body: String
    let authorName: String
    let authorEmail: String
    let authorDate: Date
    let committerName: String
    let committerEmail: String
    let commitDate: Date
    let parentIDs: [String]
    let references: [RevisionReference]
    let kind: Kind

    init(
        id: String,
        shortID: String,
        subject: String,
        body: String,
        authorName: String,
        authorEmail: String,
        authorDate: Date,
        committerName: String,
        committerEmail: String,
        commitDate: Date,
        parentIDs: [String],
        references: [RevisionReference],
        kind: Kind = .revision
    ) {
        self.id = id
        self.shortID = shortID
        self.subject = subject
        self.body = body
        self.authorName = authorName
        self.authorEmail = authorEmail
        self.authorDate = authorDate
        self.committerName = committerName
        self.committerEmail = committerEmail
        self.commitDate = commitDate
        self.parentIDs = parentIDs
        self.references = references
        self.kind = kind
    }

    var isMerge: Bool { parentIDs.count > 1 }
    var isHEAD: Bool { references.contains { $0.kind == .head || $0.kind == .currentBranch } }
    var isArtificial: Bool { kind != .revision }
}

enum RevisionSelectionRestorer {
    static func restoredID(
        requestedID: String?,
        previousCommits: [Commit],
        refreshedCommits: [Commit]
    ) -> String? {
        guard !refreshedCommits.isEmpty else { return nil }
        let refreshedIDs = Set(refreshedCommits.map(\.id))
        if let requestedID, refreshedIDs.contains(requestedID) {
            return requestedID
        }

        if let requestedID,
           let previous = previousCommits.first(where: { $0.id == requestedID }) {
            let previousByID = Dictionary(uniqueKeysWithValues: previousCommits.map { ($0.id, $0) })
            var pending = Array(previous.parentIDs.prefix(50))
            var visited = Set<String>()
            while !pending.isEmpty, visited.count < 50 {
                let candidate = pending.removeFirst()
                guard visited.insert(candidate).inserted else { continue }
                if refreshedIDs.contains(candidate) { return candidate }
                if let commit = previousByID[candidate] {
                    pending.append(contentsOf: commit.parentIDs)
                }
            }
        }

        return refreshedCommits.first(where: \.isHEAD)?.id
            ?? refreshedCommits.first(where: { !$0.isArtificial })?.id
            ?? refreshedCommits.first?.id
    }
}

struct AuthorAvatarPresentation: Equatable {
    let initials: String
    let paletteIndex: Int

    static func make(name: String?, email: String?) -> AuthorAvatarPresentation {
        let cleanName = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let cleanEmail = email?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let selected = cleanName.isEmpty ? cleanEmail.split(separator: "@", maxSplits: 1).first.map(String.init) ?? "" : cleanName
        let pieces = selected
            .split(whereSeparator: { $0.isWhitespace || $0 == "." || $0 == "-" || $0 == "_" })
            .map(String.init)
            .filter { !$0.isEmpty }
        let initials: String
        if pieces.count > 1 {
            initials = String(pieces[0].prefix(1) + pieces[pieces.count - 1].prefix(1)).uppercased()
        } else if let value = pieces.first {
            let uppercase = value.filter(\.isUppercase)
            if uppercase.count > 1 {
                initials = String(uppercase.prefix(1) + uppercase.suffix(1))
            } else if value.count == 1 {
                initials = value.uppercased()
            } else {
                initials = String(value.prefix(1)).uppercased() + String(value.dropFirst().prefix(1))
            }
        } else {
            initials = "?"
        }
        var hash = Int32(23)
        for scalar in cleanEmail.unicodeScalars {
            hash = hash &* 31 &+ Int32(bitPattern: scalar.value)
        }
        let magnitude = hash == .min ? Int(Int32.max) : abs(Int(hash))
        return AuthorAvatarPresentation(initials: initials, paletteIndex: magnitude % 6)
    }
}

enum RevisionDiffSummaryResolver {
    static func summary(selected: Commit, comparison: Commit?) -> String {
        guard let comparison else {
            return "Diff with empty tree"
        }
        return "Diff with A \(description(for: comparison))"
    }

    private static func description(for commit: Commit) -> String {
        commit.shortID.isEmpty ? commit.subject : "\(commit.shortID): \(commit.subject)"
    }
}

enum FileChangeType: String, Hashable, Sendable {
    case added = "A"
    case modified = "M"
    case deleted = "D"
    case renamed = "R"
    case copied = "C"

    var description: String {
        switch self {
        case .added: "Added"
        case .modified: "Modified"
        case .deleted: "Deleted"
        case .renamed: "Renamed"
        case .copied: "Copied"
        }
    }
}

struct ChangedFile: Identifiable, Hashable, Sendable {
    let id: String
    let path: String
    let oldPath: String?
    let changeType: FileChangeType
    let additions: Int
    let deletions: Int
}

struct DiffLine: Identifiable, Hashable, Sendable {
    enum Kind: Hashable, Sendable {
        case header
        case hunk
        case context
        case addition
        case deletion
    }

    let id: String
    let oldLineNumber: Int?
    let newLineNumber: Int?
    let kind: Kind
    let text: String
}

struct FileDiff: Identifiable, Hashable, Sendable {
    let id: String
    let fileID: String
    let lines: [DiffLine]
}

struct RepositoryFileEntry: Identifiable, Hashable, Sendable {
    let id: String
    let path: String
    let content: String
    let byteCount: Int
    let isExecutable: Bool
    let gitObjectID: String?
    let gitObjectType: String?

    init(
        id: String? = nil,
        path: String,
        content: String,
        byteCount: Int? = nil,
        isExecutable: Bool = false,
        gitObjectID: String? = nil,
        gitObjectType: String? = nil
    ) {
        self.id = id ?? path
        self.path = path
        self.content = content
        self.byteCount = byteCount ?? content.utf8.count
        self.isExecutable = isExecutable
        self.gitObjectID = gitObjectID
        self.gitObjectType = gitObjectType
    }
}

struct RepositoryFileTreeNode: Identifiable, Hashable, Sendable {
    enum Kind: Int, Hashable, Sendable {
        case folder
        case file
    }

    let id: String
    let name: String
    let path: String
    let kind: Kind
    let file: RepositoryFileEntry?
    let children: [RepositoryFileTreeNode]
}

enum RepositoryFileTreeBuilder {
    static func build(files: [RepositoryFileEntry]) -> [RepositoryFileTreeNode] {
        let root = MutableRepositoryFileTreeNode(name: "", path: "", kind: .folder)

        for file in files.sorted(by: { $0.path.caseInsensitiveCompare($1.path) == .orderedAscending }) {
            let components = file.path.split(separator: "/").map(String.init)
            guard !components.isEmpty else { continue }

            var parent = root
            var accumulatedPath = ""
            for (index, component) in components.enumerated() {
                accumulatedPath = accumulatedPath.isEmpty ? component : "\(accumulatedPath)/\(component)"
                let isFile = index == components.count - 1
                if let existing = parent.children[component] {
                    if isFile { existing.file = file }
                    parent = existing
                } else {
                    let node = MutableRepositoryFileTreeNode(
                        name: component,
                        path: accumulatedPath,
                        kind: isFile ? .file : .folder,
                        file: isFile ? file : nil
                    )
                    parent.children[component] = node
                    parent = node
                }
            }
        }

        return root.immutableChildren()
    }
}

private final class MutableRepositoryFileTreeNode {
    let name: String
    let path: String
    let kind: RepositoryFileTreeNode.Kind
    var file: RepositoryFileEntry?
    var children: [String: MutableRepositoryFileTreeNode] = [:]

    init(
        name: String,
        path: String,
        kind: RepositoryFileTreeNode.Kind,
        file: RepositoryFileEntry? = nil
    ) {
        self.name = name
        self.path = path
        self.kind = kind
        self.file = file
    }

    func immutableChildren() -> [RepositoryFileTreeNode] {
        children.values
            .sorted {
                if $0.kind != $1.kind { return $0.kind.rawValue < $1.kind.rawValue }
                return $0.name.caseInsensitiveCompare($1.name) == .orderedAscending
            }
            .map { child in
                RepositoryFileTreeNode(
                    id: "\(child.kind == .folder ? "folder" : "file"):\(child.path)",
                    name: child.name,
                    path: child.path,
                    kind: child.kind,
                    file: child.file,
                    children: child.immutableChildren()
                )
            }
    }
}

enum CommitSignatureStatus: Hashable, Sendable {
    case noSignature
    case goodSignature
    case signatureError
    case missingPublicKey
}

enum TagSignatureStatus: Hashable, Sendable {
    case noTag
    case oneGood
    case oneBad
    case many
    case missingPublicKey
    case tagNotSigned
}

struct RevisionGPGInfo: Hashable, Sendable {
    let commitStatus: CommitSignatureStatus
    let commitVerificationMessage: String
    let tagStatus: TagSignatureStatus
    let tagVerificationMessage: String?
}

enum SignatureIndicator: Hashable, Sendable {
    case none
    case good
    case warning
    case error
    case many
}

struct SignatureRowPresentation: Equatable, Sendable {
    let message: String
    let indicator: SignatureIndicator
}

struct RevisionGPGPresentation: Equatable, Sendable {
    let commit: SignatureRowPresentation
    let tag: SignatureRowPresentation?
}

enum RevisionGPGPresentationResolver {
    static func resolve(info: RevisionGPGInfo?) -> RevisionGPGPresentation {
        guard let info else {
            return RevisionGPGPresentation(
                commit: SignatureRowPresentation(message: "Commit is not signed", indicator: .none),
                tag: nil
            )
        }

        let commitIndicator: SignatureIndicator = switch info.commitStatus {
        case .noSignature: .none
        case .goodSignature: .good
        case .signatureError: .error
        case .missingPublicKey: .warning
        }
        let commitMessage = info.commitStatus == .noSignature
            ? "Commit is not signed"
            : info.commitVerificationMessage

        let tag: SignatureRowPresentation? = switch info.tagStatus {
        case .noTag:
            nil
        case .tagNotSigned:
            SignatureRowPresentation(message: "Tag is not signed", indicator: .none)
        case .oneGood:
            SignatureRowPresentation(message: info.tagVerificationMessage ?? "", indicator: .good)
        case .oneBad:
            SignatureRowPresentation(message: info.tagVerificationMessage ?? "", indicator: .error)
        case .many:
            SignatureRowPresentation(message: info.tagVerificationMessage ?? "", indicator: .many)
        case .missingPublicKey:
            SignatureRowPresentation(message: info.tagVerificationMessage ?? "", indicator: .warning)
        }

        return RevisionGPGPresentation(
            commit: SignatureRowPresentation(message: commitMessage, indicator: commitIndicator),
            tag: tag
        )
    }
}

struct CommitRelations: Equatable, Sendable {
    let parentIDs: [String]
    let childIDs: [String]
    let branchNames: [String]
    let tagNames: [String]
}

enum CommitRelationsResolver {
    static func resolve(commit: Commit, history: [Commit]) -> CommitRelations {
        CommitRelations(
            parentIDs: commit.parentIDs,
            childIDs: history.filter { $0.parentIDs.contains(commit.id) }.map(\.id),
            branchNames: commit.references.filter {
                $0.kind == .currentBranch || $0.kind == .localBranch || $0.kind == .remoteBranch
            }.map(\.name),
            tagNames: commit.references.filter { $0.kind == .tag }.map(\.name)
        )
    }
}

enum FileTreeSelectionResolver {
    static func selectedPath(previousPath: String?, files: [RepositoryFileEntry]) -> String? {
        if let previousPath, files.contains(where: { $0.path == previousPath }) {
            return previousPath
        }
        return files.sorted { $0.path.caseInsensitiveCompare($1.path) == .orderedAscending }.first?.path
    }
}

struct RepositorySnapshot: Sendable {
    let repositories: [Repository]
    let currentRepository: Repository
    let branches: [Branch]
    let tags: [Tag]
    let remotes: [Remote]
    let stashes: [Stash]
    let worktrees: [Worktree]
    let submodules: [Submodule]
    let commits: [Commit]
    let filesByCommit: [String: [ChangedFile]]
    let diffsByFile: [String: FileDiff]
    let repositoryFilesByCommit: [String: [RepositoryFileEntry]]
    let gpgInfoByCommit: [String: RevisionGPGInfo]
    let workingDirectoryChangeCount: Int
}

struct RepositoryRevisionDetails: Sendable {
    let files: [ChangedFile]
    let diffsByFile: [String: FileDiff]
    let repositoryFiles: [RepositoryFileEntry]
    let gpgInfo: RevisionGPGInfo?
}
