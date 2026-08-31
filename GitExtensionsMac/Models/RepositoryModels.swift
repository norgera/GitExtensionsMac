import Foundation

package enum ObjectIDError: LocalizedError, Sendable {
    case invalid(String)

    package var errorDescription: String? {
        switch self {
        case .invalid(let value):
            return "Invalid Git object ID: \(value)"
        }
    }
}

package struct ObjectID: Hashable, Sendable, Comparable, CustomStringConvertible {
    package let string: String

    package init(parsing string: String) throws {
        guard Self.isValid(string) else { throw ObjectIDError.invalid(string) }
        self.string = string
    }

    package static func parse(_ string: String) throws -> ObjectID {
        try ObjectID(parsing: string)
    }

    package static func parseIfPresent(_ string: String?) throws -> ObjectID? {
        guard let string, !string.isEmpty else { return nil }
        return try parse(string)
    }

    package var description: String { string }
    package var shortString: String { String(string.prefix(8)) }

    package static func < (lhs: ObjectID, rhs: ObjectID) -> Bool { lhs.string < rhs.string }

    private static func isValid(_ value: String) -> Bool {
        (value.count == 40 || value.count == 64)
            && value.utf8.allSatisfy { byte in
                (48...57).contains(byte) || (97...102).contains(byte)
            }
    }
}

package enum RevisionID: Hashable, Sendable, CustomStringConvertible {
    case object(ObjectID)
    case workingDirectory
    case index

    package var objectID: ObjectID? {
        guard case .object(let objectID) = self else { return nil }
        return objectID
    }

    package var description: String {
        switch self {
        case .object(let objectID): objectID.string
        case .workingDirectory: "WORKTREE"
        case .index: "INDEX"
        }
    }
}

package struct Repository: Identifiable, Hashable, Sendable {
    package let id: String
    package let name: String
    package let path: String
    package let description: String
    package let isBare: Bool

    package init(id: String, name: String, path: String, description: String, isBare: Bool = false) {
        self.id = id
        self.name = name
        self.path = path
        self.description = description
        self.isBare = isBare
    }
}

package struct RepositoryReferenceSortMetadata: Hashable, Sendable {
    package let authorDate: Int64?
    package let committerDate: Int64?
    package let creatorDate: Int64?
    package let taggerDate: Int64?
    package let objectSize: Int64?

    package init(
        authorDate: Int64? = nil,
        committerDate: Int64? = nil,
        creatorDate: Int64? = nil,
        taggerDate: Int64? = nil,
        objectSize: Int64? = nil
    ) {
        self.authorDate = authorDate
        self.committerDate = committerDate
        self.creatorDate = creatorDate
        self.taggerDate = taggerDate
        self.objectSize = objectSize
    }
}

package struct Branch: Identifiable, Hashable, Sendable {
    package let id: String
    package let name: String
    package let commitID: ObjectID
    package let isCurrent: Bool
    package let isRemote: Bool
    package let remoteName: String?
    package let ahead: Int
    package let behind: Int
    package let sortMetadata: RepositoryReferenceSortMetadata

    package init(id: String, name: String, commitID: ObjectID, isCurrent: Bool, isRemote: Bool, remoteName: String?, ahead: Int, behind: Int, sortMetadata: RepositoryReferenceSortMetadata = .init()) {
        self.id = id
        self.name = name
        self.commitID = commitID
        self.isCurrent = isCurrent
        self.isRemote = isRemote
        self.remoteName = remoteName
        self.ahead = ahead
        self.behind = behind
        self.sortMetadata = sortMetadata
    }
}

package struct Tag: Identifiable, Hashable, Sendable {
    package let id: String
    package let name: String
    package let commitID: ObjectID
    package let sortMetadata: RepositoryReferenceSortMetadata

    package init(id: String, name: String, commitID: ObjectID, sortMetadata: RepositoryReferenceSortMetadata = .init()) {
        self.id = id
        self.name = name
        self.commitID = commitID
        self.sortMetadata = sortMetadata
    }
}

package struct Remote: Identifiable, Hashable, Sendable {
    package let id: String
    package let name: String
    package let fetchURL: String
    package let branches: [Branch]
    package let isDisabled: Bool

    package init(id: String, name: String, fetchURL: String, branches: [Branch], isDisabled: Bool = false) {
        self.id = id
        self.name = name
        self.fetchURL = fetchURL
        self.branches = branches
        self.isDisabled = isDisabled
    }
}

package struct Stash: Identifiable, Hashable, Sendable {
    package let id: String
    package let selector: String
    package let subject: String
    package let branchName: String
    package let commitID: ObjectID

    package init(id: String, selector: String, subject: String, branchName: String, commitID: ObjectID) {
        self.id = id
        self.selector = selector
        self.subject = subject
        self.branchName = branchName
        self.commitID = commitID
    }
}

package struct Worktree: Identifiable, Hashable, Sendable {
    package let id: String
    package let name: String
    package let path: String
    package let branchName: String
    package let isCurrent: Bool

    package init(id: String, name: String, path: String, branchName: String, isCurrent: Bool) {
        self.id = id
        self.name = name
        self.path = path
        self.branchName = branchName
        self.isCurrent = isCurrent
    }
}

package struct Submodule: Identifiable, Hashable, Sendable {
    package enum State: String, Hashable, Sendable {
        case clean
        case uninitialized
        case modified
        case conflicted
        case unknown
    }

    package let id: String
    package let name: String
    package let path: String
    package let url: String?
    package let commitID: ObjectID?
    package let description: String?
    package let state: State

    package init(id: String, name: String, path: String, url: String?, commitID: ObjectID?, description: String?, state: State) {
        self.id = id
        self.name = name
        self.path = path
        self.url = url
        self.commitID = commitID
        self.description = description
        self.state = state
    }
}

package struct RevisionReference: Identifiable, Hashable, Sendable {
    package enum Kind: Sendable {
        case head
        case currentBranch
        case localBranch
        case remoteBranch
        case tag
        case stash
    }

    package let id: String
    package let name: String
    package let kind: Kind
    package let trackingRemote: String?
    package let mergeWith: String?

    package init(
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

    package var remoteName: String? {
        guard kind == .remoteBranch else { return nil }
        return name.split(separator: "/", maxSplits: 1).first.map(String.init)
    }

    package var localName: String {
        guard kind == .remoteBranch else { return name }
        return name.split(separator: "/", maxSplits: 1).dropFirst().first.map(String.init) ?? name
    }

    package func tracks(_ remoteReference: RevisionReference) -> Bool {
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

package struct Commit: Identifiable, Hashable, Sendable {
    package enum Kind: Hashable, Sendable {
        case revision
        case workingDirectory
        case index
    }

    package let id: RevisionID
    package let shortID: String
    package let subject: String
    package let body: String
    package let authorName: String
    package let authorEmail: String
    package let authorDate: Date
    package let committerName: String
    package let committerEmail: String
    package let commitDate: Date
    package let parentIDs: [ObjectID]
    package let references: [RevisionReference]
    package let kind: Kind

    package init(
        id: RevisionID,
        shortID: String,
        subject: String,
        body: String,
        authorName: String,
        authorEmail: String,
        authorDate: Date,
        committerName: String,
        committerEmail: String,
        commitDate: Date,
        parentIDs: [ObjectID],
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

    package var isMerge: Bool { parentIDs.count > 1 }
    package var isHEAD: Bool { references.contains { $0.kind == .head || $0.kind == .currentBranch } }
    package var isArtificial: Bool { kind != .revision }
    package var objectID: ObjectID? { id.objectID }
    package var graphParentIDs: [RevisionID] {
        switch kind {
        case .workingDirectory: [.index]
        case .index, .revision: parentIDs.map(RevisionID.object)
        }
    }
}

package enum RevisionSelectionRestorer {
    package static func restoredID(
        requestedID: RevisionID?,
        previousCommits: [Commit],
        refreshedCommits: [Commit]
    ) -> RevisionID? {
        guard !refreshedCommits.isEmpty else { return nil }
        let refreshedIDs = Set(refreshedCommits.map(\.id))
        if let requestedID, refreshedIDs.contains(requestedID) {
            return requestedID
        }

        if let requestedID,
           let previous = previousCommits.first(where: { $0.id == requestedID }) {
            let previousByID = Dictionary(uniqueKeysWithValues: previousCommits.map { ($0.id, $0) })
            var pending = Array(previous.parentIDs.prefix(50))
            var visited = Set<ObjectID>()
            while !pending.isEmpty, visited.count < 50 {
                let candidate = pending.removeFirst()
                guard visited.insert(candidate).inserted else { continue }
                let candidateID = RevisionID.object(candidate)
                if refreshedIDs.contains(candidateID) { return candidateID }
                if let commit = previousByID[candidateID] {
                    pending.append(contentsOf: commit.parentIDs)
                }
            }
        }

        return refreshedCommits.first(where: \.isHEAD)?.id
            ?? refreshedCommits.first(where: { !$0.isArtificial })?.id
            ?? refreshedCommits.first?.id
    }
}

package struct AuthorAvatarPresentation: Equatable {
    package let initials: String
    package let paletteIndex: Int

    package init(initials: String, paletteIndex: Int) {
        self.initials = initials
        self.paletteIndex = paletteIndex
    }

    package static func make(name: String?, email: String?) -> AuthorAvatarPresentation {
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

package enum RevisionDiffSummaryResolver {
    package static func summary(selected: Commit, comparison: Commit?) -> String {
        guard let comparison else {
            return "Diff with empty tree"
        }
        return "Diff with A \(description(for: comparison))"
    }

    private static func description(for commit: Commit) -> String {
        commit.shortID.isEmpty ? commit.subject : "\(commit.shortID): \(commit.subject)"
    }
}

package enum FileChangeType: String, Hashable, Sendable {
    case added = "A"
    case modified = "M"
    case deleted = "D"
    case renamed = "R"
    case copied = "C"

    package var description: String {
        switch self {
        case .added: "Added"
        case .modified: "Modified"
        case .deleted: "Deleted"
        case .renamed: "Renamed"
        case .copied: "Copied"
        }
    }
}

package struct ChangedFile: Identifiable, Hashable, Sendable {
    package let id: String
    package let path: String
    package let oldPath: String?
    package let changeType: FileChangeType
    package let additions: Int
    package let deletions: Int

    package init(id: String, path: String, oldPath: String?, changeType: FileChangeType, additions: Int, deletions: Int) {
        self.id = id
        self.path = path
        self.oldPath = oldPath
        self.changeType = changeType
        self.additions = additions
        self.deletions = deletions
    }
}

package struct DiffLine: Identifiable, Hashable, Sendable {
    package enum Kind: Hashable, Sendable {
        case header
        case hunk
        case context
        case addition
        case deletion
    }

    package let id: String
    package let oldLineNumber: Int?
    package let newLineNumber: Int?
    package let kind: Kind
    package let text: String

    package init(id: String, oldLineNumber: Int?, newLineNumber: Int?, kind: Kind, text: String) {
        self.id = id
        self.oldLineNumber = oldLineNumber
        self.newLineNumber = newLineNumber
        self.kind = kind
        self.text = text
    }
}

package struct FileDiff: Identifiable, Hashable, Sendable {
    package let id: String
    package let fileID: String
    package let lines: [DiffLine]

    package init(id: String, fileID: String, lines: [DiffLine]) {
        self.id = id
        self.fileID = fileID
        self.lines = lines
    }
}

package enum DiffWhitespaceMode: String, CaseIterable, Hashable, Sendable, Codable {
    case none
    case endOfLine
    case changes
    case all
}

package struct FileDiffOptions: Hashable, Sendable {
    package var whitespace: DiffWhitespaceMode
    package var contextLines: Int
    package var showsEntireFile: Bool
    package var treatsAllFilesAsText: Bool

    package init(
        whitespace: DiffWhitespaceMode = .none,
        contextLines: Int = 3,
        showsEntireFile: Bool = false,
        treatsAllFilesAsText: Bool = false
    ) {
        self.whitespace = whitespace
        self.contextLines = max(0, contextLines)
        self.showsEntireFile = showsEntireFile
        self.treatsAllFilesAsText = treatsAllFilesAsText
    }

    package var gitArguments: [String] {
        var arguments: [String] = []
        switch whitespace {
        case .none: break
        case .endOfLine: arguments.append("--ignore-space-at-eol")
        case .changes: arguments.append("--ignore-space-change")
        case .all: arguments.append("--ignore-all-space")
        }
        if showsEntireFile {
            arguments += ["--inter-hunk-context=9000", "--unified=9000"]
        } else if contextLines != 3 {
            arguments.append("--unified=\(contextLines)")
        }
        if treatsAllFilesAsText { arguments.append("--text") }
        return arguments
    }
}

package enum RepositoryTextEncoding: String, CaseIterable, Hashable, Sendable, Codable {
    case automatic
    case utf8
    case utf16LittleEndian
    case utf16BigEndian
    case westernISO88591
    case windows1252

    package var title: String {
        switch self {
        case .automatic: "Automatic"
        case .utf8: "Unicode (UTF-8)"
        case .utf16LittleEndian: "Unicode (UTF-16 LE)"
        case .utf16BigEndian: "Unicode (UTF-16 BE)"
        case .westernISO88591: "Western (ISO Latin 1)"
        case .windows1252: "Western (Windows Latin 1)"
        }
    }
}

package struct RepositoryFileContent: Hashable, Sendable {
    package enum Kind: Hashable, Sendable {
        case text
        case image
        case binary
        case missing
    }

    package let path: String
    package let kind: Kind
    package let text: String
    package let data: Data
    package let encoding: RepositoryTextEncoding?

    package init(
        path: String,
        kind: Kind,
        text: String = "",
        data: Data = Data(),
        encoding: RepositoryTextEncoding? = nil
    ) {
        self.path = path
        self.kind = kind
        self.text = text
        self.data = data
        self.encoding = encoding
    }

    package var byteCount: Int { data.count }
}

package struct RepositoryFileEntry: Identifiable, Hashable, Sendable {
    package let id: String
    package let path: String
    package let content: String
    package let byteCount: Int
    package let isExecutable: Bool
    package let gitObjectID: ObjectID?
    package let gitObjectType: String?

    package init(
        id: String? = nil,
        path: String,
        content: String,
        byteCount: Int? = nil,
        isExecutable: Bool = false,
        gitObjectID: ObjectID? = nil,
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

package struct RepositoryFileTreeNode: Identifiable, Hashable, Sendable {
    package enum Kind: Int, Hashable, Sendable {
        case folder
        case file
    }

    package let id: String
    package let name: String
    package let path: String
    package let kind: Kind
    package let file: RepositoryFileEntry?
    package let children: [RepositoryFileTreeNode]

    package init(id: String, name: String, path: String, kind: Kind, file: RepositoryFileEntry?, children: [RepositoryFileTreeNode]) {
        self.id = id
        self.name = name
        self.path = path
        self.kind = kind
        self.file = file
        self.children = children
    }
}

package enum RepositoryFileTreeBuilder {
    package static func build(files: [RepositoryFileEntry]) -> [RepositoryFileTreeNode] {
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

package enum CommitSignatureStatus: Hashable, Sendable {
    case noSignature
    case goodSignature
    case signatureError
    case missingPublicKey
}

package enum TagSignatureStatus: Hashable, Sendable {
    case noTag
    case oneGood
    case oneBad
    case many
    case missingPublicKey
    case tagNotSigned
}

package struct RevisionGPGInfo: Hashable, Sendable {
    package let commitStatus: CommitSignatureStatus
    package let commitVerificationMessage: String
    package let tagStatus: TagSignatureStatus
    package let tagVerificationMessage: String?

    package init(commitStatus: CommitSignatureStatus, commitVerificationMessage: String, tagStatus: TagSignatureStatus, tagVerificationMessage: String?) {
        self.commitStatus = commitStatus
        self.commitVerificationMessage = commitVerificationMessage
        self.tagStatus = tagStatus
        self.tagVerificationMessage = tagVerificationMessage
    }
}

package enum SignatureIndicator: Hashable, Sendable {
    case none
    case good
    case warning
    case error
    case many
}

package struct SignatureRowPresentation: Equatable, Sendable {
    package let message: String
    package let indicator: SignatureIndicator
}

package struct RevisionGPGPresentation: Equatable, Sendable {
    package let commit: SignatureRowPresentation
    package let tag: SignatureRowPresentation?
}

package enum RevisionGPGPresentationResolver {
    package static func resolve(info: RevisionGPGInfo?) -> RevisionGPGPresentation {
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

package struct CommitRelations: Equatable, Sendable {
    package let parentIDs: [ObjectID]
    package let childIDs: [ObjectID]
    package let branchNames: [String]
    package let tagNames: [String]

    package init(parentIDs: [ObjectID], childIDs: [ObjectID], branchNames: [String], tagNames: [String]) {
        self.parentIDs = parentIDs
        self.childIDs = childIDs
        self.branchNames = branchNames
        self.tagNames = tagNames
    }
}

package enum CommitRelationsResolver {
    package static func resolve(commit: Commit, history: [Commit]) -> CommitRelations {
        CommitRelations(
            parentIDs: commit.parentIDs,
            childIDs: commit.objectID.map { objectID in
                history.filter { $0.parentIDs.contains(objectID) }.compactMap(\.objectID)
            } ?? [],
            branchNames: commit.references.filter {
                $0.kind == .currentBranch || $0.kind == .localBranch || $0.kind == .remoteBranch
            }.map(\.name),
            tagNames: commit.references.filter { $0.kind == .tag }.map(\.name)
        )
    }
}

package enum FileTreeSelectionResolver {
    package static func selectedPath(previousPath: String?, files: [RepositoryFileEntry]) -> String? {
        if let previousPath, files.contains(where: { $0.path == previousPath }) {
            return previousPath
        }
        return files.sorted { $0.path.caseInsensitiveCompare($1.path) == .orderedAscending }.first?.path
    }
}

package struct RepositoryIdentityState: Sendable {
    package let repositories: [Repository]
    package let currentRepository: Repository
    package let headID: ObjectID?

    package init(repositories: [Repository], currentRepository: Repository, headID: ObjectID?) {
        self.repositories = repositories
        self.currentRepository = currentRepository
        self.headID = headID
    }
}

package struct RepositoryReferenceState: Sendable {
    package let branches: [Branch]
    package let tags: [Tag]
    package let referencesByCommit: [ObjectID: [RevisionReference]]

    package var references: [RevisionReference] { referencesByCommit.values.flatMap { $0 } }

    package init(branches: [Branch], tags: [Tag], referencesByCommit: [ObjectID: [RevisionReference]]) {
        self.branches = branches
        self.tags = tags
        self.referencesByCommit = referencesByCommit
    }
}

package struct RepositoryNavigationState: Sendable {
    package let remotes: [Remote]
    package let stashes: [Stash]
    package let worktrees: [Worktree]
    package let submodules: [Submodule]

    package init(remotes: [Remote], stashes: [Stash], worktrees: [Worktree], submodules: [Submodule]) {
        self.remotes = remotes
        self.stashes = stashes
        self.worktrees = worktrees
        self.submodules = submodules
    }
}

package struct RepositoryStatusSummary: Sendable {
    package let workingDirectoryChangeCount: Int

    package init(workingDirectoryChangeCount: Int) {
        self.workingDirectoryChangeCount = workingDirectoryChangeCount
    }
}

package struct RepositoryNetworkContext: Sendable {
    package let repository: Repository
    package let headID: ObjectID?
    package let branches: [Branch]
    package let remotes: [Remote]
    package let references: [RevisionReference]
    package let submodules: [Submodule]

    package init(repository: Repository, headID: ObjectID?, branches: [Branch], remotes: [Remote], references: [RevisionReference], submodules: [Submodule]) {
        self.repository = repository
        self.headID = headID
        self.branches = branches
        self.remotes = remotes
        self.references = references
        self.submodules = submodules
    }
}

package struct RepositoryBranchContext: Sendable {
    package let repository: Repository
    package let headID: ObjectID?
    package let branches: [Branch]
    package let remotes: [Remote]
    package let referencesByCommit: [ObjectID: [RevisionReference]]
    package let submodules: [Submodule]

    package init(repository: Repository, headID: ObjectID?, branches: [Branch], remotes: [Remote], referencesByCommit: [ObjectID: [RevisionReference]], submodules: [Submodule]) {
        self.repository = repository
        self.headID = headID
        self.branches = branches
        self.remotes = remotes
        self.referencesByCommit = referencesByCommit
        self.submodules = submodules
    }
}

package struct RepositoryMergeContext: Sendable {
    package let repository: Repository
    package let branches: [Branch]
    package let tags: [Tag]
    package let referencesByCommit: [ObjectID: [RevisionReference]]
    package let submodules: [Submodule]

    package init(repository: Repository, branches: [Branch], tags: [Tag], referencesByCommit: [ObjectID: [RevisionReference]], submodules: [Submodule]) {
        self.repository = repository
        self.branches = branches
        self.tags = tags
        self.referencesByCommit = referencesByCommit
        self.submodules = submodules
    }
}

package struct RepositoryCommitContext: Sendable {
    package let repository: Repository
    package let headID: ObjectID?
    package let branches: [Branch]
    package let submodules: [Submodule]

    package init(repository: Repository, headID: ObjectID?, branches: [Branch], submodules: [Submodule]) {
        self.repository = repository
        self.headID = headID
        self.branches = branches
        self.submodules = submodules
    }
}

package struct RepositoryStashContext: Sendable {
    package let headID: ObjectID?
    package let stashes: [Stash]

    package init(headID: ObjectID?, stashes: [Stash]) {
        self.headID = headID
        self.stashes = stashes
    }
}

package struct RepositoryRebaseContext: Sendable {
    package let branches: [Branch]
    package let tags: [Tag]

    package init(branches: [Branch], tags: [Tag]) {
        self.branches = branches
        self.tags = tags
    }
}

package struct RepositoryRevisionDetails: Sendable {
    package let files: [ChangedFile]
    package let diffsByFile: [String: FileDiff]
    package let repositoryFiles: [RepositoryFileEntry]
    package let gpgInfo: RevisionGPGInfo?

    package init(files: [ChangedFile], diffsByFile: [String: FileDiff], repositoryFiles: [RepositoryFileEntry], gpgInfo: RevisionGPGInfo?) {
        self.files = files
        self.diffsByFile = diffsByFile
        self.repositoryFiles = repositoryFiles
        self.gpgInfo = gpgInfo
    }
}
