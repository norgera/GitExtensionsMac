import AppKit
import GitCommands

enum ConflictResolutionPreference: Equatable, Sendable {
    case none
    case keepLocal
    case keepRemote
    case keepBase
}

struct ConflictDecisionRequest: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case deletedLocallyModifiedRemotely
        case modifiedLocallyDeletedRemotely
        case createdBothWithoutBase
        case binary
    }

    let kind: Kind
    let path: String
    let text: String
    let applyToAllText: String
    let localButton: String
    let remoteButton: String
    let baseButton: String

    static let caption = "Solve merge conflict"
}

struct ConflictDecision: Equatable, Sendable {
    var preference: ConflictResolutionPreference
    var applyToAll: Bool

    static let cancelled = ConflictDecision(preference: .none, applyToAll: false)
}

enum TwoWayMergeAnswer: Equatable, Sendable {
    case yes
    case no
    case cancel
}

@MainActor
protocol ConflictResolutionPresenter: AnyObject {
    func decide(_ request: ConflictDecisionRequest) async -> ConflictDecision
    func confirmOpenBinary(path: String, tool: String) async -> Bool
    func confirmTwoWayMerge(path: String) async -> TwoWayMergeAnswer
    func confirmConflictSolved() async -> Bool
    func showMessage(_ text: String, title: String, isError: Bool) async
    func runInteractiveMergeTool(path: String?, tool: String?) async
    func resolveSubmodule(path: String) async -> Bool
    func progress(completed: Int, total: Int)
}

@MainActor
final class ConflictResolutionWorkflow {
    static let noMergeTool = "There is no mergetool configured.\nPlease go to settings and set a mergetool!"
    static let mergeToolNotConfigured = "The mergetool is not correctly configured.\nPlease go to settings and configure the mergetool!"
    static let askSolved = "Is the merge conflict solved?"
    static let askSolvedCaption = "Conflict solved?"

    private let source: any RepositoryConflictResolutionDataSource
    private weak var presenter: (any ConflictResolutionPresenter)?
    var rebase: Bool
    var mergeTool: RepositoryMergeToolConfiguration?
    private var applyToAll = false
    private var appliedPreference = ConflictResolutionPreference.none
    private var checkboxText = ""
    private var deletedLocallyCount = 0
    private var deletedRemotelyCount = 0
    private var remainingCount = 0
    private var deletedLocallySolved = 0
    private var deletedRemotelySolved = 0
    private var itemCount = 0
    private var completed = 0

    init(source: any RepositoryConflictResolutionDataSource, presenter: any ConflictResolutionPresenter,
         rebase: Bool, mergeTool: RepositoryMergeToolConfiguration?) {
        self.source = source
        self.presenter = presenter
        self.rebase = rebase
        self.mergeTool = mergeTool
    }

    static func loadWarning(for mergeTool: RepositoryMergeToolConfiguration?) -> String? {
        guard let mergeTool else { return noMergeTool }
        return mergeTool.executablePath == nil ? mergeToolNotConfigured : nil
    }

    var localSide: String { rebase ? "theirs" : "ours" }
    var remoteSide: String { rebase ? "ours" : "theirs" }

    func openMergeTool(_ selection: [RepositoryConflict]) async {
        let groups = group(selection)
        defer { applyToAll = false }
        applyToAll = false
        for conflict in groups.deletedLocally {
            advance()
            await resolveItem(conflict)
        }
        applyToAll = false
        for conflict in groups.deletedRemotely {
            advance()
            await resolveItem(conflict)
        }
        checkboxText = ""
        applyToAll = false
        for conflict in groups.remaining {
            advance()
            await resolveItem(conflict)
        }
    }

    func choose(_ side: RepositoryConflictSide, selection: [RepositoryConflict]) async {
        _ = group(selection)
        applyToAll = false
        defer { applyToAll = false }
        for conflict in selection {
            switch side {
            case .base:
                if await checkForBaseRevision(conflict) { await select(.base, conflict) }
            case .local:
                if await checkForLocalRevision(conflict) { await select(.local, conflict) }
            case .remote:
                if await checkForRemoteRevision(conflict) { await select(.remote, conflict) }
            }
            advance()
        }
    }

    private func group(_ selection: [RepositoryConflict]) -> (deletedLocally: [RepositoryConflict], deletedRemotely: [RepositoryConflict], remaining: [RepositoryConflict]) {
        let deletedLocally = selection.filter { $0.local == nil && $0.remote != nil }
        let deletedRemotely = selection.filter { $0.local != nil && $0.remote == nil }
        let remaining = selection.filter { !($0.local == nil && $0.remote != nil) && !($0.local != nil && $0.remote == nil) }
        itemCount = selection.count
        completed = 0
        presenter?.progress(completed: 0, total: itemCount)
        deletedLocallyCount = deletedLocally.count
        deletedRemotelyCount = deletedRemotely.count
        remainingCount = remaining.count
        deletedLocallySolved = deletedLocallyCount
        deletedRemotelySolved = deletedRemotelyCount
        return (deletedLocally, deletedRemotely, remaining)
    }

    private func advance() {
        completed += 1
        presenter?.progress(completed: completed, total: itemCount)
    }

    private func resolveItem(_ conflict: RepositoryConflict) async {
        if conflict.isSubmodule {
            _ = await presenter?.resolveSubmodule(path: conflict.path)
            return
        }
        if let url = try? await source.conflictWorkingTreeURL(path: conflict.path) {
            var directory: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &directory), directory.boolValue { return }
        }
        await resolveFiles(conflict)
    }

    private func resolveFiles(_ conflict: RepositoryConflict) async {
        let temporary = try? await source.checkoutConflictFiles(path: conflict.path)
        defer { temporary?.all.forEach { try? FileManager.default.removeItem(at: $0) } }
        guard await checkForLocalRevision(conflict), await checkForRemoteRevision(conflict), let presenter else { return }
        if await source.isBinaryConflictFile(path: conflict.local?.path ?? conflict.path),
           !(await presenter.confirmOpenBinary(path: conflict.path, tool: mergeTool?.name ?? "")) {
            await binaryFilesChooseLocalBaseRemote(conflict)
            return
        }
        guard let tool = mergeTool, tool.runsDirectly, let command = tool.command, let path = tool.path else {
            await presenter.runInteractiveMergeTool(path: conflict.path, tool: nil)
            return
        }
        var twoWay = false
        if conflict.base == nil {
            switch await presenter.confirmTwoWayMerge(path: conflict.path) {
            case .yes: twoWay = true
            case .no: break
            case .cancel: return
            }
        }
        let executable = tool.executablePath ?? path
        let arguments: [String]
        do {
            arguments = try MergeToolInvocation.arguments(command: command, tool: tool.name, twoWay: twoWay,
                                                           base: temporary?.base?.path, local: temporary?.local?.path,
                                                           remote: temporary?.remote?.path, merged: conflict.path, executable: executable, configuredPath: path)
        } catch {
            await presenter.showMessage("Error starting mergetool: \(executable)", title: "Merge", isError: true)
            return
        }
        let merged = try? await source.conflictWorkingTreeURL(path: conflict.path)
        let before = merged.flatMap(Self.modificationDate) ?? Date()
        let status: Int32
        do {
            status = try await source.runExternalMergeTool(executable: executable, arguments: arguments)
        } catch is CancellationError {
            return
        } catch {
            await presenter.showMessage("Error starting mergetool: \(executable)", title: "Merge", isError: true)
            return
        }
        let after = merged.flatMap(Self.modificationDate) ?? before
        let changed = before != after
        if status == 0 && changed {
            await stage(conflict.path)
        }
        if (status == 1 && changed) || (status == 0 && !changed) {
            if await presenter.confirmConflictSolved() {
                await stage(conflict.path)
            }
        }
    }

    static func modificationDate(_ url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    private func stage(_ path: String) async {
        do {
            _ = try await source.stage(paths: [path])
        } catch {
            await presenter?.showMessage(error.localizedDescription, title: "Stage '\(path)'", isError: true)
        }
    }

    private func remove(_ conflict: RepositoryConflict, missing side: RepositoryConflictSide) async {
        _ = try? await source.chooseConflictSide(paths: [conflict.path], side: side)
    }

    private func select(_ side: RepositoryConflictSide, _ conflict: RepositoryConflict) async {
        let failure = switch side {
        case .base: "Choose base file failed."
        case .local: "Choose local file failed."
        case .remote: "Choose remote file failed."
        }
        guard conflict.version(for: side) != nil else {
            await presenter?.showMessage(failure, title: "Error", isError: true)
            return
        }
        do {
            _ = try await source.chooseConflictSide(paths: [conflict.path], side: side)
        } catch {
            await presenter?.showMessage(failure, title: "Error", isError: true)
        }
    }

    private func decide(_ request: ConflictDecisionRequest) async -> ConflictResolutionPreference {
        if !applyToAll {
            let decision = await presenter?.decide(request) ?? .cancelled
            appliedPreference = decision.preference
            applyToAll = decision.preference != .none && decision.applyToAll && !request.applyToAllText.isEmpty
        }
        return appliedPreference
    }

    private func applyToAllText(_ path: String, remaining: Int) -> String {
        remaining > 1 ? "Apply to '\(path)' and \(remaining - 1) other file(s)" : ""
    }

    func checkForLocalRevision(_ conflict: RepositoryConflict) async -> Bool {
        if conflict.local != nil { return true }
        var text = ""
        if !applyToAll && deletedLocallySolved == 1 {
            text = "File '\(conflict.path)' does not have a local revision.\nThe file has been deleted locally (\(localSide)) but modified remotely (\(remoteSide)).\n\nChoose to delete the file or keep the modified version."
        }
        if !applyToAll && deletedLocallySolved > 1 {
            text = deletedRemotelyCount == 0 && remainingCount == 0
                ? "'\(conflict.path)' and \(deletedLocallySolved - 1) other selected file(s) do not have a local revision.\nThe files have been deleted locally, but modified remotely\n\nChoose to delete the files or keep the modified versions."
                : "'\(conflict.path)' and \(deletedLocallySolved - 1) other out of \(itemCount) selected files do not have a local revision.\nThe files have been deleted locally, but modified remotely\n\nChoose to delete the files or keep the modified versions."
        }
        let request = ConflictDecisionRequest(
            kind: .deletedLocallyModifiedRemotely, path: conflict.path, text: text,
            applyToAllText: applyToAllText(conflict.path, remaining: deletedLocallySolved),
            localButton: "Delete file (\(localSide))", remoteButton: "Keep modified (\(remoteSide))", baseButton: "Keep base file (\(localSide))")
        switch await decide(request) {
        case .keepLocal: await remove(conflict, missing: .local)
        case .keepRemote: await select(.remote, conflict)
        case .keepBase: await select(.base, conflict)
        case .none: break
        }
        deletedLocallySolved -= 1
        return false
    }

    func checkForRemoteRevision(_ conflict: RepositoryConflict) async -> Bool {
        if conflict.remote != nil { return true }
        var text = ""
        if !applyToAll && deletedRemotelySolved == 1 {
            text = "File '\(conflict.path)' does not have a remote revision.\nThe file has been modified locally (\(localSide)) but deleted remotely (\(remoteSide)).\n\nChoose to delete the file or keep the modified version."
        }
        if !applyToAll && deletedRemotelySolved > 1 {
            text = deletedLocallyCount == 0 && remainingCount == 0
                ? "'\(conflict.path)' and \(deletedRemotelySolved - 1) other selected file(s) do not have a remote revision.\nThe files have been modified locally, but deleted remotely.\n\nChoose to delete the files or keep the modified versions."
                : "'\(conflict.path)' and \(deletedRemotelySolved - 1) other out of \(itemCount) selected files do not have a remote revision.\nThe files have been modified locally, but deleted remotely.\n\nChoose to delete the files or keep the modified versions."
        }
        let request = ConflictDecisionRequest(
            kind: .modifiedLocallyDeletedRemotely, path: conflict.path, text: text,
            applyToAllText: applyToAllText(conflict.path, remaining: deletedRemotelySolved),
            localButton: "Keep modified (\(localSide))", remoteButton: "Delete file (\(remoteSide))", baseButton: "Keep base file")
        switch await decide(request) {
        case .keepLocal: await select(.local, conflict)
        case .keepRemote: await remove(conflict, missing: .remote)
        case .keepBase: await select(.base, conflict)
        case .none: break
        }
        deletedRemotelySolved -= 1
        return false
    }

    func checkForBaseRevision(_ conflict: RepositoryConflict) async -> Bool {
        if conflict.base != nil { return true }
        let request = ConflictDecisionRequest(
            kind: .createdBothWithoutBase, path: conflict.path,
            text: "File '\(conflict.path)' does not have a base revision.\nA file with the same name has been created locally (\(localSide)) and remotely (\(remoteSide)) causing this conflict.\n\nChoose the file you want to keep, merge the files or delete the file?",
            applyToAllText: checkboxText,
            localButton: "Choose local (\(localSide))", remoteButton: "Choose remote (\(remoteSide))", baseButton: "Delete file")
        switch await decide(request) {
        case .keepLocal: await select(.local, conflict)
        case .keepRemote: await select(.remote, conflict)
        case .keepBase: await remove(conflict, missing: .base)
        case .none: break
        }
        return false
    }

    private func binaryFilesChooseLocalBaseRemote(_ conflict: RepositoryConflict) async {
        let request = ConflictDecisionRequest(
            kind: .binary, path: conflict.path,
            text: "File '\(conflict.local?.path ?? conflict.path)' appears to be binary.\nChoose to keep the local '\(localSide)', remote '\(remoteSide)' or base file.",
            applyToAllText: checkboxText,
            localButton: "Choose local (\(localSide))", remoteButton: "Choose remote (\(remoteSide))", baseButton: "Keep base file")
        switch await decide(request) {
        case .keepLocal: await select(.local, conflict)
        case .keepRemote: await select(.remote, conflict)
        case .keepBase: await select(.base, conflict)
        case .none: break
        }
    }
}
