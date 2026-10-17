import AppKit
import GitCommands

@MainActor
enum RepositoryOwnershipRecovery {
    static func perform<T>(source: any RepositoryBrowsingDataSource,
                           decide: (DubiousRepositoryOwnership) async -> Bool,
                           operation: () async throws -> T) async throws -> T {
        do { return try await operation() }
        catch let failure as DubiousRepositoryOwnership {
            guard let trust = source as? any RepositoryTrustDataSource, await decide(failure) else { throw failure }
            try Task.checkCancellation()
            try await trust.trustRepository(failure)
            try Task.checkCancellation()
            return try await operation()
        }
    }

    static func load(_ source: any RepositoryBrowsingDataSource, owner: NSWindow?) async throws -> RepositoryLoadState {
        try await perform(source: source, decide: { await confirm($0, owner: owner) }) {
            try await source.loadRepositoryState()
        }
    }

    static func confirm(_ failure: DubiousRepositoryOwnership, owner: NSWindow?) async -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Trust this repository?"
        alert.informativeText = "Git detected dubious ownership in:\n\(failure.repositoryURL.path)\n\nTrusting adds only this repository to your global safe.directory configuration.\n\n\(failure.output)"
        alert.addButton(withTitle: "Trust this repository")
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Show in Finder")
        alert.addButton(withTitle: "Ownership help")
        let response: NSApplication.ModalResponse
        if let owner { response = await alert.beginSheetModal(for: owner) }
        else { response = alert.runModal() }
        if response == .alertThirdButtonReturn {
            NSWorkspace.shared.activateFileViewerSelecting([failure.repositoryURL])
        } else if response.rawValue == NSApplication.ModalResponse.alertFirstButtonReturn.rawValue + 3 {
            NSWorkspace.shared.open(URL(string: "https://git-scm.com/docs/git-config#Documentation/git-config.txt-safedirectory")!)
        }
        return response == .alertFirstButtonReturn
    }
}
