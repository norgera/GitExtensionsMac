import AppKit
import Foundation
import Testing

@testable import GitCommands
@testable import GitExtensionsCore
@testable import GitUI

extension UIIntegrationTests {
    @MainActor
    @Suite("Conflict resolution")
    enum ConflictResolutionTests {

        @Test("Frontend dialogs") static func runFrontendDialogs() async throws {
            let missing = ConflictResolverViewController.mergeToolWarning(for: nil)!
            #expect(
                missing.alertStyle == .critical && missing.messageText == "Error" && missing.informativeText == ConflictResolutionWorkflow.noMergeTool
                    && missing.buttons.map(\.title) == ["OK"], "actual missing-tool alert is critical Error")
            let unresolved = RepositoryMergeToolConfiguration(name: "missing", usesGUISetting: true)
            let warning = ConflictResolverViewController.mergeToolWarning(for: unresolved)!
            #expect(
                warning.alertStyle == .warning && warning.messageText == "Warning"
                    && warning.informativeText == ConflictResolutionWorkflow.mergeToolNotConfigured, "actual configured unresolved-tool alert is Warning")
            #expect(
                ConflictResolverViewController.mergeToolWarning(
                    for: RepositoryMergeToolConfiguration(name: "present", usesGUISetting: true, executablePath: "/bin/echo")) == nil,
                "available tool produces no initialization alert")
        }

        @Test("Custom merge tool vectors") private static func customMergeToolVectors() throws {
            let pinnedOutputs = [
                "'git difftool --tool=<tool>' may be set to one of the following:\n\t\tvimdiff\n\t\tvimdiff2\n\t\tvimdiff3\n\t\twinmerge\n\nThe following tools are valid, but not currently available:\n\t\taraxis\n\t\tbc\n\t\tbc3\n\t\tcodecompare\n\t\tdeltawalker\n\t\tdiffmerge\n\t\tdiffuse\n\t\tecmerge\n\t\temerge\n\t\texamdiff\n\t\tguiffy\n\t\tgvimdiff\n\t\tgvimdiff2\n\t\tgvimdiff3\n\t\tkdiff3\n\t\tkompare\n\t\tmeld\n\t\topendiff\n\t\tp4merge\n\t\tsmerge\n\t\ttkdiff\n\t\txxdiff\n\nSome of the tools listed above only work in a windowed\nenvironment. If run in a terminal-only session, they will fail.\n",
                "'git difftool --tool=<tool>' may be set to one of the following:\n\t\tvimdiff\n\t\tvimdiff2\n\t\tvimdiff3\n\t\twinmerge\n",
            ]
            for output in pinnedOutputs {
                #expect(
                    MergeToolInvocation.availableTools(output: output, defaultTool: "winmerge") == ["winmerge"],
                    "pinned available/unavailable and terminal-tool exclusion vectors")
            }
            let output =
                "header\n\t\tvimdiff1\n\t\tzeta\n\t\talpha.cmd tool --args\n\t\tzeta.cmd duplicate\n\t\tbeta\nThe following tools are valid, but not currently available:\n\t\tunavailable\n"
            #expect(
                MergeToolInvocation.availableTools(output: output, defaultTool: "zeta") == ["zeta", "alpha", "beta"],
                "selected tool first, sorted alternatives, duplicate and unavailable exclusion")
        }

        private struct Failure: LocalizedError { let errorDescription: String? }

        private static func wait(_ message: String, seconds: Double = 15, until condition: () throws -> Bool) async throws {
            let deadline = ContinuousClock.now + .milliseconds(Int(seconds * 1000))
            while try !condition() {
                #expect(ContinuousClock.now < deadline, Comment(rawValue: message))
                try await Task.sleep(for: .milliseconds(10))
            }
        }

        @Test("Invocation vectors") private static func invocationVectors() throws {
            let kdiff3 = MergeToolInvocation.defaults(tool: "kdiff3", command: nil, path: "")
            #expect(
                kdiff3.command == "\"$BASE\" \"$LOCAL\" \"$REMOTE\" -o \"$MERGED\"" && kdiff3.path == "kdiff3",
                "kdiff3 built-in defaults (GE <3.3 compatibility)")
            #expect(MergeToolInvocation.defaults(tool: "meld", command: nil, path: nil) == (nil, nil), "other tools have no defaults")
            #expect(MergeToolInvocation.defaults(tool: "kdiff3", command: "x", path: "/k").command == "x", "configured kdiff3 values win")
            let three = try MergeToolInvocation.arguments(
                command: kdiff3.command!, tool: "kdiff3", twoWay: false,
                base: "/r/a b.txt.BASE", local: "/r/a b.txt.LOCAL", remote: "/r/a b.txt.REMOTE", merged: "a b.txt")
            #expect(three == ["/r/a b.txt.BASE", "/r/a b.txt.LOCAL", "/r/a b.txt.REMOTE", "-o", "a b.txt"], "3-way substitution keeps each path one argument")
            let two = try MergeToolInvocation.arguments(
                command: kdiff3.command!, tool: "kdiff3", twoWay: true,
                base: nil, local: "/r/l", remote: "/r/r", merged: "m")
            #expect(two == ["/r/l", "/r/r", "-o", "m"], "kdiff3 2-way drops the base argument")
            #expect(
                MergeToolInvocation.twoWay(["$BASE", "x"], tool: "DiffMerge") == ["x"] && MergeToolInvocation.twoWay(["$BASE"], tool: "smerge") == [],
                "diffmerge and smerge rewrite case-insensitively")
            #expect(
                MergeToolInvocation.twoWay(["/base:$BASE", "-base:$BASE", "/mine:$LOCAL", "/theirs:$REMOTE"], tool: "tortoisemerge") == [
                    "/base:$LOCAL", "/theirs:$REMOTE",
                ],
                "tortoisemerge 2-way rewrite")
            #expect(MergeToolInvocation.twoWay(["$BASE"], tool: "meld") == ["$BASE"], "unknown tools are not rewritten")
            let noBase = try MergeToolInvocation.arguments(
                command: "\"$BASE\" \"$LOCAL\"", tool: "meld", twoWay: false, base: nil, local: "/l", remote: nil, merged: "m")
            #expect(noBase == ["", "/l"], "declining 2-way does not manufacture a base file")
            let injection = try MergeToolInvocation.arguments(
                command: "--out=\"$MERGED\"", tool: "x", twoWay: false, base: nil, local: nil, remote: nil, merged: "a; rm -rf x $(id)")
            #expect(injection == ["--out=a; rm -rf x $(id)"], "substituted paths are never re-parsed")
            var threw = false
            do {
                _ = try MergeToolInvocation.arguments(command: "\"unterminated", tool: "x", twoWay: false, base: nil, local: nil, remote: nil, merged: "m")
            } catch { threw = true }
            #expect(threw, "malformed command reports an error")
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MergeToolResolve-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory.appendingPathComponent("bin"), withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            FileManager.default.createFile(atPath: directory.appendingPathComponent("bin/tool").path, contents: Data())
            FileManager.default.createFile(atPath: directory.appendingPathComponent("local-tool").path, contents: Data())
            #expect(
                MergeToolInvocation.resolveExecutable("tool", workingDirectory: directory, searchPaths: [directory.appendingPathComponent("bin").path])
                    == directory.appendingPathComponent("bin/tool").path, "PATH search")
            #expect(
                MergeToolInvocation.resolveExecutable("local-tool", workingDirectory: directory, searchPaths: [])
                    == directory.appendingPathComponent("local-tool").standardizedFileURL.path,
                "relative to the working directory")
            #expect(
                MergeToolInvocation.resolveExecutable("bin", workingDirectory: directory, searchPaths: []) == nil
                    && MergeToolInvocation.resolveExecutable("", workingDirectory: directory, searchPaths: []) == nil
                    && MergeToolInvocation.resolveExecutable("/nonexistent/tool", workingDirectory: directory, searchPaths: []) == nil,
                "directories and missing files do not resolve")
            #expect(
                ConflictResolutionWorkflow.loadWarning(for: nil) == ConflictResolutionWorkflow.noMergeTool
                    && ConflictResolutionWorkflow.loadWarning(for: RepositoryMergeToolConfiguration(name: "x", usesGUISetting: false))
                        == ConflictResolutionWorkflow.mergeToolNotConfigured
                    && ConflictResolutionWorkflow.loadWarning(for: RepositoryMergeToolConfiguration(name: "x", usesGUISetting: false, executablePath: "/bin/x"))
                        == nil,
                "InitMergetool load warnings")
        }

        @Test("Binary detection vectors") private static func binaryDetectionVectors() throws {
            func attr(_ pairs: [(String, String)]) -> String { pairs.map { "f\0\($0.0)\0\($0.1)\0" }.joined() }
            #expect(ConflictBinaryDetection.isBinary(path: "image.PNG", checkAttrOutput: nil), "extension list, case-insensitive")
            #expect(!ConflictBinaryDetection.isBinary(path: "notes.txt", checkAttrOutput: nil), "text extension")
            #expect(ConflictBinaryDetection.isBinary(path: "x.txt", checkAttrOutput: attr([("diff", "unset")])), "-diff marks binary")
            #expect(!ConflictBinaryDetection.isBinary(path: "x.png", checkAttrOutput: attr([("diff", "python")])), "known text diff driver marks text")
            #expect(
                !ConflictBinaryDetection.isBinary(path: "x.png", checkAttrOutput: attr([("diff", "unspecified"), ("text", "set")])), "text attribute marks text"
            )
            #expect(!ConflictBinaryDetection.isBinary(path: "x.png", checkAttrOutput: attr([("eol", "lf")])), "eol attribute marks text")
            #expect(
                ConflictBinaryDetection.isBinary(path: "x.png", checkAttrOutput: attr([("diff", "custom"), ("text", "unspecified")])),
                "unknown driver falls back to the extension")
            #expect(!ConflictBinaryDetection.isBinary(path: " ", checkAttrOutput: nil), "blank names are not binary")
        }

        @Test("Deleted locally decisions") private static func deletedLocallyDecisions() async throws {
            for (preference, expectation) in [(ConflictResolutionPreference.keepLocal, "deleted"), (.keepRemote, "topic dl1\n"), (.keepBase, "base dl1\n")] {
                let fixture = try Fixture()
                defer { fixture.remove() }
                let repo = try fixture.conflictRepository()
                let module = try await fixture.module(repo)
                let presenter = ScriptedPresenter(decisions: [ConflictDecision(preference: preference, applyToAll: false)])
                let workflow = ConflictResolutionWorkflow(source: module, presenter: presenter, rebase: false, mergeTool: nil)
                await workflow.openMergeTool(try await conflicts(module, ["dl1.txt"]))
                #expect(presenter.requests.count == 1 && presenter.requests[0].kind == .deletedLocallyModifiedRemotely, "DLMR dialog shown")
                let request = presenter.requests[0]
                #expect(
                    request.text
                        == "File 'dl1.txt' does not have a local revision.\nThe file has been deleted locally (ours) but modified remotely (theirs).\n\nChoose to delete the file or keep the modified version."
                        && request.applyToAllText.isEmpty && request.localButton == "Delete file (ours)" && request.remoteButton == "Keep modified (theirs)"
                        && request.baseButton == "Keep base file (ours)", "upstream single-file DLMR wording: \(request)")
                #expect(try fixture.unmerged(repo).contains("dl1.txt") == false, "\(preference): conflict resolved in the index")
                if expectation == "deleted" {
                    do {
                        let actual = try !fixture.exists(repo, "dl1.txt") && (try fixture.git(["ls-files", "--stage", "--", "dl1.txt"], in: repo)).isEmpty
                        #expect(actual, "keep local deletion runs git rm")
                    }
                } else {
                    #expect(try fixture.read(repo, "dl1.txt") == expectation, "\(preference) writes the chosen stage")
                    #expect(
                        (try fixture.git(["ls-files", "--stage", "--", "dl1.txt"], in: repo)).contains(" 0\tdl1.txt"), "\(preference) stages the chosen content"
                    )
                }
                #expect(try fixture.unmerged(repo).contains("dl2.txt"), "unselected conflicts are untouched")
            }
        }

        @MainActor
        @Test("Context menu enablement for deleted remotely") private static func contextMenuEnablementForDeletedRemotely() async throws {
            let fixture = try Fixture()
            defer { fixture.remove() }
            let repo = try fixture.conflictRepository()
            let module = try await fixture.module(repo)
            let controller = ConflictResolverViewController(source: module, offerMergeCommit: nil)
            let window = NSWindow(contentViewController: controller)
            window.setContentSize(NSSize(width: 619, height: 392))
            window.orderFront(nil)
            defer { window.orderOut(nil) }
            try await wait("conflicts loaded") { controller.conflicts.contains { $0.path == "md1.txt" } && controller.conflictTable.numberOfRows > 0 }
            #expect(controller.conflictTable.tableColumns.map(\.title) == ["Filename"], "filename-only conflict grid")
            let controls = DialogBehaviorTests.allSubviews(controller.view)
            let buttons = controls.compactMap { $0 as? NSButton }
            let merge = try requireRow(buttons.first { $0.title == "Merge" })
            #expect(window.defaultButtonCell === merge.cell && merge.isEnabled, "first-class Merge default independent of configured tool")
            #expect(
                buttons.first { $0.title == "Start mergetool" }?.isEnabled == true && buttons.first { $0.title == "Open in" }?.isEnabled == false,
                "Start enabled without configuration; Open in extras disabled")
            #expect(
                buttons.filter { !$0.isHidden }.map(\.title) == ["Merge", "Open in", "Start mergetool", "Rescan merge conflicts", "Reset", "Help"],
                "source hierarchy without inline choose/preview/Close controls: \(buttons.map(\.title))")
            #expect(
                !controls.contains { $0 is NSSegmentedControl || $0 is NSPopUpButton || $0 is NSTextView },
                "conflict selection does not create an attributed file preview")
            #expect(
                controls.contains { $0 is NSImageView }
                    && ConflictResolverViewController.helpURL.absoluteString.hasSuffix("modify_history#handle-merge-conflicts"),
                "information icon and exact Help section")
            let row = try requireRow(controller.conflicts.firstIndex { $0.path == "md1.txt" })
            controller.conflictTable.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            let labels = DialogBehaviorTests.allTextFields(in: controller.view).map(\.stringValue)
            #expect(
                labels.contains("Local/current (ours)") && labels.contains("md1.txt") && labels.contains("Remote/incoming (theirs)")
                    && labels.contains("deleted") && !labels.contains { $0.contains("@") }, "ordinary side rows use filenames, no object hashes")
            for size in [NSSize(width: 619, height: 392), NSSize(width: 450, height: 299)] {
                window.setContentSize(size)
                window.contentView?.layoutSubtreeIfNeeded()
                let grid = controller.conflictTable.enclosingScrollView!
                #expect(
                    grid.frame.width > 200 && grid.frame.height >= 50 && merge.frame.width >= 130
                        && buttons.allSatisfy { controller.view.bounds.contains($0.convert($0.bounds, to: controller.view)) },
                    "controls remain usable at initial and minimum size")
                let fields = DialogBehaviorTests.allTextFields(in: controller.view)
                let captions = ["Local/current (ours)", "Base", "Remote/incoming (theirs)"].map { title in fields.first { $0.stringValue == title }! }
                let captionFrames = captions.map { $0.convert($0.bounds, to: controller.view) }
                #expect(
                    zip(captionFrames, captionFrames.dropFirst()).allSatisfy { abs($0.midY - $1.midY) <= 30 },
                    "side rows keep compact vertical spacing while file grid expands")
                let filename = fields.first { $0.stringValue == "md1.txt" && $0.superview is NSGridView }!
                #expect(
                    filename.convert(filename.bounds, to: controller.view).minX - captionFrames.map(\.maxX).max()! <= 12,
                    "filename column stays beside side captions")
            }
            let menu = try requireRow(controller.conflictTable.menu)
            controller.menuNeedsUpdate(menu)
            menu.update()
            func item(_ title: String) -> NSMenuItem? { menu.items.first { $0.title == title } }
            #expect(!menu.autoenablesItems, "conflict context menu does not auto-enable")
            #expect(
                item("Open remote with")?.isEnabled == false && item("Save remote as…")?.isEnabled == false,
                "missing remote side keeps Open/Save remote disabled after AppKit validation")
            #expect(item("Open local with")?.isEnabled == true, "local side remains available")
            #expect(
                menu.items.map(\.title) == [
                    "Open in mergetool", "Open in mergetool", "Mark conflict as solved", "", "Choose local/current (ours)", "Choose remote/incoming (theirs)",
                    "Choose base", "", "Open local with", "Open remote with", "Open base with", "", "Save local as…", "Save remote as…", "Save base as…", "",
                    "Open", "Open With", "Show in Finder", "", "File history",
                ], "exact source sections and order without surplus/trailing entries")
            #expect(
                item("Choose local/current (ours)")?.keyEquivalent == "1" && item("Choose remote/incoming (theirs)")?.keyEquivalent == "2"
                    && item("Choose base")?.keyEquivalent == "3"
                    && item("Choose base")?.keyEquivalentModifierMask == .command, "native Command1/2/3 cues")
            let previousDescription = RepositoryConflictDescription.text(for: .deletedRemotely, rebase: false)
            let other = controller.conflicts.firstIndex { $0.path == "both.txt" }!
            controller.conflictTable.selectRowIndexes(IndexSet([row, other]), byExtendingSelection: false)
            controller.menuNeedsUpdate(menu)
            #expect(
                menu.items.count == 21 && item("Open local with")?.isEnabled == false && item("Open With")?.isEnabled == false
                    && menu.items[1].isEnabled == false && item("Mark conflict as solved")?.isEnabled == true,
                "multi-selection preserves menu entries and disables single-file commands")
            let fields = DialogBehaviorTests.allTextFields(in: controller.view)
            #expect(
                fields.contains { $0.stringValue == previousDescription }
                    && fields.filter { $0.accessibilityIdentifier().hasPrefix("ConflictResolver.") }.allSatisfy { $0.stringValue.isEmpty },
                "multiple selection retains source description and clears individual filenames")
            #expect(
                buttons.first { $0.title == "Merge" }?.isEnabled == true && buttons.first { $0.title == "Open in" }?.isEnabled == false,
                "multiple selection preserves Merge and disables single-file Open in")
            try fixture.git(["config", "mergetool.toolbeta.cmd", "true"], in: repo)
            try fixture.git(["config", "mergetool.toolbeta.path", "/usr/bin/true"], in: repo)
            try fixture.git(["config", "mergetool.toolalpha.cmd", "true"], in: repo)
            try fixture.git(["config", "merge.tool", "toolbeta"], in: repo)
            let tools = try await module.loadMergeTools()
            #expect(tools.first == "toolbeta" && tools.contains("toolalpha"), "real Git tool-help returns the default before configured alternatives")
            let configured = ConflictResolverViewController(source: module, offerMergeCommit: nil)
            let configuredWindow = NSWindow(contentViewController: configured)
            configuredWindow.isReleasedWhenClosed = false
            configured.panel = configuredWindow
            configuredWindow.orderFront(nil)
            defer { configuredWindow.orderOut(nil) }
            try await wait("configured conflict menu loaded") { configured.conflictTable.numberOfRows > 0 }
            let configuredMenu = configured.conflictTable.menu!
            configured.menuNeedsUpdate(configuredMenu)
            let custom = configuredMenu.items[1]
            #expect(
                custom.submenu?.items.map(\.title) == tools && custom.submenu?.items.first?.attributedTitle != nil && custom.isEnabled,
                "custom tools preserve source order and bold the default")
            let openWith = configuredMenu.items.first { $0.title == "Open local with" }!
            let selectedPath = configured.conflicts[configured.conflictTable.selectedRow].path
            NSApp.sendAction(openWith.action!, to: openWith.target, from: openWith)
            try await wait("side Open With opens a sheet") { configuredWindow.attachedSheet != nil }
            #expect(
                configuredWindow.attachedSheet is NSOpenPanel,
                "application chooser sheet type \(String(describing: configuredWindow.attachedSheet)) / \(DialogBehaviorTests.allTextFields(in: configuredWindow.attachedSheet!.contentView!).map(\.stringValue))"
            )
            let chooser = configuredWindow.attachedSheet as! NSOpenPanel
            #expect(
                chooser.allowedContentTypes == [.application] && chooser.message.contains(URL(fileURLWithPath: selectedPath).lastPathComponent),
                "side action reuses the native application chooser for the selected file")
            configuredWindow.endSheet(chooser, returnCode: .cancel)
            chooser.orderOut(nil)
            #expect(try fixture.unmerged(repo).contains("both.txt"), "inspecting/cancelling the application chooser preserves unresolved Git state")
        }

        @Test("Owned modal conflict loads and cancels") private static func ownedModalConflictLoadsAndCancels() async throws {
            let fixture = try Fixture()
            defer { fixture.remove() }
            let repo = try fixture.conflictRepository()
            let module = try await fixture.module(repo)
            let owner = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
            owner.isReleasedWhenClosed = false
            owner.makeKeyAndOrderFront(nil)
            defer { owner.close() }
            let expected = try fixture.unmerged(repo)
            let completion = Task { await WorkflowManagementDialogs.resolveConflicts(source: module, window: owner) }
            let deadline = ContinuousClock.now + .seconds(10)
            let presentation = CommandLinePresentation(owner: owner)
            presentation.hidesOwner = true
            defer { presentation.finish() }
            let monitorCompletion = Task { try await presentation.wait() }
            defer { monitorCompletion.cancel() }
            var panel: NSWindow?
            while panel == nil {
                panel = NSApp.windows.first { $0.title == "Resolve merge conflicts" && $0.isVisible }
                guard ContinuousClock.now < deadline else { throw Failure(errorDescription: "owned modal conflict window did not open") }
                try await Task.sleep(for: .milliseconds(20))
            }
            let window = panel!
            let controller = window.contentViewController as! ConflictResolverViewController
            try await wait("async repository loading during owned modality") {
                controller.conflicts.contains { $0.path == "both.txt" } && controller.conflictTable.numberOfRows > 0
            }
            #expect(
                window.sheetParent == nil && owner.attachedSheet == nil && NSApp.modalWindow === window
                    && window.contentLayoutRect.size == NSSize(width: 619, height: 392), "standalone owned modal window with upstream initial geometry")
            try await wait("no-tool warning is presented") { window.attachedSheet != nil }
            let alert = window.attachedSheet!
            let fields = DialogBehaviorTests.allTextFields(in: alert.contentView!).map(\.stringValue)
            #expect(fields.contains("There is no mergetool configured.\nPlease go to settings and set a mergetool!"), "source-defined no-tool error preserved")
            #expect(fields.contains("Error") && !fields.contains("Warning"), "no configured tool uses the Error presentation")
            let ok = DialogBehaviorTests.allSubviews(alert.contentView!).compactMap { $0 as? NSButton }.first { $0.title == "OK" }!
            ok.performClick(nil)
            try await wait("warning acknowledged and owned modality restored") { window.attachedSheet == nil && NSApp.modalWindow === window }
            #expect(
                window.isVisible && window.canBecomeMain && !owner.isVisible && NSApp.modalWindow === window,
                "standalone resolver survives acknowledgment with hidden CLI owner: visible=\(window.isVisible), main=\(window.canBecomeMain), ownerVisible=\(owner.isVisible), modal=\(NSApp.modalWindow?.title ?? "none")"
            )
            let expectedCenter = NSPoint(x: owner.frame.midX, y: owner.frame.midY)
            #expect(abs(window.frame.midX - expectedCenter.x) <= 1 && abs(window.frame.midY - expectedCenter.y) <= 1, "initial CenterParent positioning")
            controller.cancelOperation(nil)
            let changed = await completion.value
            do {
                let actual = try !changed && !window.isVisible && expected == fixture.unmerged(repo)
                #expect(actual, "cancellation leaves all conflicts and reports no repository change")
            }
            try await wait("modal session ends after close") { NSApp.modalWindow !== window }
            let presentationChanged = try await monitorCompletion.value
            #expect(!presentationChanged, "cancelling hidden-owner command presentation reports no mutation")
        }

        private static func requireRow<T>(_ value: T?) throws -> T {
            guard let value else { throw Failure(errorDescription: "missing value") }
            return value
        }

        @Test("Deleted remotely decisions") private static func deletedRemotelyDecisions() async throws {
            for (preference, expectation) in [(ConflictResolutionPreference.keepLocal, "main md1\n"), (.keepRemote, "deleted"), (.keepBase, "base md1\n")] {
                let fixture = try Fixture()
                defer { fixture.remove() }
                let repo = try fixture.conflictRepository()
                let module = try await fixture.module(repo)
                let presenter = ScriptedPresenter(decisions: [ConflictDecision(preference: preference, applyToAll: false)])
                let workflow = ConflictResolutionWorkflow(source: module, presenter: presenter, rebase: true, mergeTool: nil)
                await workflow.openMergeTool(try await conflicts(module, ["md1.txt"]))
                let request = presenter.requests.first
                #expect(
                    request?.kind == .modifiedLocallyDeletedRemotely && request?.localButton == "Keep modified (theirs)"
                        && request?.remoteButton == "Delete file (ours)"
                        && request?.text.contains("modified locally (theirs) but deleted remotely (ours)") == true,
                    "MLDR dialog with rebase side names: \(String(describing: request))")
                #expect(try !fixture.unmerged(repo).contains("md1.txt"), "\(preference): resolved")
                if expectation == "deleted" {
                    #expect(!fixture.exists(repo, "md1.txt"), "keep remote deletion runs git rm")
                } else {
                    #expect(try fixture.read(repo, "md1.txt") == expectation, "\(preference) content")
                }
            }
        }

        @Test("Apply to all stays within its group") private static func applyToAllStaysWithinItsGroup() async throws {
            let fixture = try Fixture()
            defer { fixture.remove() }
            let repo = try fixture.conflictRepository()
            let module = try await fixture.module(repo)
            let presenter = ScriptedPresenter(decisions: [
                ConflictDecision(preference: .keepRemote, applyToAll: true), ConflictDecision(preference: .keepLocal, applyToAll: false),
                ConflictDecision(preference: .keepRemote, applyToAll: false),
            ])
            let workflow = ConflictResolutionWorkflow(source: module, presenter: presenter, rebase: false, mergeTool: nil)
            let selection = try await conflicts(module, ["dl1.txt", "dl2.txt", "md1.txt", "md2.txt"])
            await workflow.openMergeTool(selection)
            #expect(
                presenter.requests.map(\.kind) == [.deletedLocallyModifiedRemotely, .modifiedLocallyDeletedRemotely, .modifiedLocallyDeletedRemotely],
                "apply-to-all answers the remaining DLMR file only: \(presenter.requests.map(\.kind))")
            #expect(
                presenter.requests[0].applyToAllText == "Apply to 'dl1.txt' and 1 other file(s)"
                    && presenter.requests[0].text.hasPrefix("'dl1.txt' and 1 other out of 4 selected files do not have a local revision."),
                "plural DLMR wording")
            #expect(
                presenter.requests[1].applyToAllText == "Apply to 'md1.txt' and 1 other file(s)" && presenter.requests[2].applyToAllText.isEmpty
                    && presenter.requests[2].text.hasPrefix("File 'md2.txt' does not have a remote revision."), "MLDR counter counts down")
            #expect(try fixture.read(repo, "dl1.txt") == "topic dl1\n" && fixture.read(repo, "dl2.txt") == "topic dl2\n", "DLMR group kept remote")
            #expect(try fixture.read(repo, "md1.txt") == "main md1\n" && !fixture.exists(repo, "md2.txt"), "MLDR files received their own answers")
            #expect(try fixture.unmerged(repo) == ["added.txt", "bin.png", "both.txt"], "refresh retains unresolved conflicts only")

            let only = try Fixture()
            defer { only.remove() }
            let onlyRepo = try only.conflictRepository()
            let onlyModule = try await only.module(onlyRepo)
            let onlyPresenter = ScriptedPresenter(decisions: [
                ConflictDecision(preference: .keepLocal, applyToAll: false), ConflictDecision(preference: .keepLocal, applyToAll: false),
            ])
            await ConflictResolutionWorkflow(source: onlyModule, presenter: onlyPresenter, rebase: false, mergeTool: nil)
                .openMergeTool(try await conflicts(onlyModule, ["dl1.txt", "dl2.txt"]))
            #expect(
                onlyPresenter.requests.count == 2
                    && onlyPresenter.requests[0].text.hasPrefix("'dl1.txt' and 1 other selected file(s) do not have a local revision."),
                "NoOtherFilesSelected wording when only DLMR files are selected")
            #expect(!only.exists(onlyRepo, "dl1.txt") && !only.exists(onlyRepo, "dl2.txt"), "unchecked apply-to-all asks per file")
        }

        @Test("Cancellation leaves conflicts") private static func cancellationLeavesConflicts() async throws {
            let fixture = try Fixture()
            defer { fixture.remove() }
            let repo = try fixture.conflictRepository()
            let module = try await fixture.module(repo)
            let before = try fixture.git(["ls-files", "-u"], in: repo)
            let presenter = ScriptedPresenter(decisions: [.cancelled, ConflictDecision(preference: .none, applyToAll: true)])
            await ConflictResolutionWorkflow(source: module, presenter: presenter, rebase: false, mergeTool: nil)
                .openMergeTool(try await conflicts(module, ["dl1.txt", "dl2.txt"]))
            #expect(presenter.requests.count == 2, "cancelling one file still asks for the next, as upstream")
            #expect(try fixture.git(["ls-files", "-u"], in: repo) == before, "cancelled decisions leave every stage untouched")
            #expect(try fixture.read(repo, "both.txt").contains("<<<<<<<"), "worktree untouched")
        }

        @Test("Choose side workflow") private static func chooseSideWorkflow() async throws {
            let fixture = try Fixture()
            defer { fixture.remove() }
            let repo = try fixture.conflictRepository()
            let module = try await fixture.module(repo)
            let presenter = ScriptedPresenter(decisions: [ConflictDecision(preference: .keepRemote, applyToAll: false)])
            let workflow = ConflictResolutionWorkflow(source: module, presenter: presenter, rebase: false, mergeTool: nil)
            await workflow.choose(.local, selection: try await conflicts(module, ["both.txt", "dl1.txt", "md1.txt"]))
            #expect(presenter.requests.map(\.kind) == [.deletedLocallyModifiedRemotely], "Choose local asks only for the file without a local revision")
            #expect(
                try fixture.read(repo, "both.txt") == "main both\n" && fixture.read(repo, "md1.txt") == "main md1\n"
                    && fixture.read(repo, "dl1.txt") == "topic dl1\n",
                "choose local writes stage 2; the DLMR answer kept remote")
            #expect(try fixture.unmerged(repo) == ["added.txt", "bin.png", "dl2.txt", "md2.txt"], "only the selection resolved")
            let progress = presenter.progressEvents.last
            #expect(progress?.completed == 3 && progress?.total == 3, "progress reaches the selection size")

            let remote = ScriptedPresenter(decisions: [ConflictDecision(preference: .keepBase, applyToAll: false)])
            await ConflictResolutionWorkflow(source: module, presenter: remote, rebase: false, mergeTool: nil).choose(
                .remote, selection: try await conflicts(module, ["md2.txt"]))
            do {
                let actual = try remote.requests.map(\.kind) == [.modifiedLocallyDeletedRemotely] && fixture.read(repo, "md2.txt") == "base md2\n"
                #expect(actual, "choose remote on MLDR offers keep base")
            }
        }

        @Test("Created both without base") private static func createdBothWithoutBase() async throws {
            let fixture = try Fixture()
            defer { fixture.remove() }
            let repo = try fixture.conflictRepository()
            let module = try await fixture.module(repo)
            let added = try await conflicts(module, ["added.txt"])
            #expect(added.first?.base == nil && added.first?.local != nil && added.first?.remote != nil, "created on both sides has no stage 1")
            let presenter = ScriptedPresenter(decisions: [ConflictDecision(preference: .keepBase, applyToAll: true)])
            await ConflictResolutionWorkflow(source: module, presenter: presenter, rebase: false, mergeTool: nil).choose(.base, selection: added)
            let request = presenter.requests.first
            #expect(
                request?.kind == .createdBothWithoutBase && request?.baseButton == "Delete file" && request?.applyToAllText.isEmpty == true
                    && request?.text.hasPrefix("File 'added.txt' does not have a base revision.") == true, "no-base dialog offers delete instead of base")
            do {
                let actual = try !fixture.exists(repo, "added.txt") && (try fixture.git(["ls-files", "--stage", "--", "added.txt"], in: repo)).isEmpty
                #expect(actual, "delete runs git rm")
            }

            let second = try Fixture()
            defer { second.remove() }
            let secondRepo = try second.conflictRepository()
            let secondModule = try await second.module(secondRepo)
            let local = ScriptedPresenter(decisions: [ConflictDecision(preference: .keepLocal, applyToAll: false)])
            await ConflictResolutionWorkflow(source: secondModule, presenter: local, rebase: false, mergeTool: nil).choose(
                .base, selection: try await conflicts(secondModule, ["added.txt"]))
            #expect(try second.read(secondRepo, "added.txt") == "main added\n" && !second.unmerged(secondRepo).contains("added.txt"), "no-base choose local")

            let binary = ScriptedPresenter(decisions: [ConflictDecision(preference: .keepBase, applyToAll: false)], openBinary: false)
            await ConflictResolutionWorkflow(source: secondModule, presenter: binary, rebase: false, mergeTool: nil).choose(
                .base, selection: try await conflicts(secondModule, ["both.txt"]))
            do {
                let actual = try binary.requests.isEmpty && second.read(secondRepo, "both.txt") == "base both\n"
                #expect(actual, "choose base with a base revision needs no dialog")
            }
        }

        @Test("Binary conflict") private static func binaryConflict() async throws {
            let fixture = try Fixture()
            defer { fixture.remove() }
            let repo = try fixture.conflictRepository()
            let module = try await fixture.module(repo)
            let pngBinary = await module.isBinaryConflictFile(path: "bin.png")
            let textBinary = await module.isBinaryConflictFile(path: "both.txt")
            #expect(pngBinary && !textBinary, "binary detection on real paths")
            try "*.txt -diff\n".write(to: repo.appendingPathComponent(".gitattributes"), atomically: true, encoding: .utf8)
            let attributeBinary = await module.isBinaryConflictFile(path: "both.txt")
            #expect(attributeBinary, "gitattributes -diff marks a .txt as binary")
            try FileManager.default.removeItem(at: repo.appendingPathComponent(".gitattributes"))
            let tool = try fixture.fakeTool(in: repo, name: "fake", mode: "write0")
            let configuration = try await module.loadMergeToolConfiguration()
            let presenter = ScriptedPresenter(decisions: [ConflictDecision(preference: .keepRemote, applyToAll: true)], openBinary: false)
            await ConflictResolutionWorkflow(source: module, presenter: presenter, rebase: false, mergeTool: configuration).openMergeTool(
                try await conflicts(module, ["bin.png"]))
            #expect(
                presenter.binaryPrompts == ["bin.png"] && presenter.requests.map(\.kind) == [.binary],
                "declining to open a binary file shows the local/remote/base chooser")
            #expect(
                presenter.requests[0].applyToAllText.isEmpty && presenter.requests[0].remoteButton == "Choose remote (theirs)",
                "binary chooser has no apply-to-all")
            #expect(
                try Data(contentsOf: repo.appendingPathComponent("bin.png")) == Data([0, 0xFF, 3]) && !fixture.unmerged(repo).contains("bin.png"),
                "remote bytes chosen and staged")
            #expect(!FileManager.default.fileExists(atPath: tool.log.path), "the merge tool was not started")
            #expect(try !fixture.listing(repo).contains { $0.hasPrefix("bin.png.") }, "temporary stage files removed")

            let accept = try Fixture()
            defer { accept.remove() }
            let acceptRepo = try accept.conflictRepository()
            let acceptModule = try await accept.module(acceptRepo)
            let acceptTool = try accept.fakeTool(in: acceptRepo, name: "fake", mode: "write0")
            let opened = ScriptedPresenter(decisions: [], openBinary: true)
            await ConflictResolutionWorkflow(
                source: acceptModule, presenter: opened, rebase: false, mergeTool: try await acceptModule.loadMergeToolConfiguration()
            )
            .openMergeTool(try await conflicts(acceptModule, ["bin.png"]))
            #expect(opened.requests.isEmpty && FileManager.default.fileExists(atPath: acceptTool.log.path), "accepting opens the binary file in the tool")
        }

        @Test("Direct tool outcomes") private static func directToolOutcomes() async throws {
            let cases: [(mode: String, solvedAnswer: Bool, asks: Bool, staged: Bool)] = [
                ("write0", false, false, true),
                ("write1", true, true, true),
                ("write1", false, true, false),
                ("noop0", true, true, true),
                ("noop0", false, true, false),
                ("noop1", true, false, false),
                ("write2", true, false, false),
                ("delete0", true, true, true),
                ("delete0", false, true, false),
            ]
            for item in cases {
                let fixture = try Fixture()
                defer { fixture.remove() }
                let repo = try fixture.conflictRepository()
                let module = try await fixture.module(repo)
                let tool = try fixture.fakeTool(in: repo, name: "fake", mode: item.mode)
                let configuration = try await module.loadMergeToolConfiguration()
                #expect(
                    configuration?.name == "fake" && configuration?.runsDirectly == true && configuration?.executablePath == tool.script.path,
                    "configured tool selected from isolated config: \(String(describing: configuration))")
                let presenter = ScriptedPresenter(decisions: [], solved: item.solvedAnswer)
                await ConflictResolutionWorkflow(source: module, presenter: presenter, rebase: false, mergeTool: configuration).openMergeTool(
                    try await conflicts(module, ["both.txt"]))
                let label = "\(item.mode)/\(item.solvedAnswer)"
                #expect(presenter.solvedPrompts == (item.asks ? 1 : 0), "\(label): ambiguous-success prompt \(item.asks ? "asked" : "not asked")")
                #expect(try fixture.unmerged(repo).contains("both.txt") == !item.staged, "\(label): staged only when upstream would")
                let arguments = try tool.arguments()
                let root = realPath(repo.path)
                #expect(
                    arguments.count == 8 && arguments[0] == "--base" && arguments[1].hasSuffix("/both.txt.BASE") && arguments[3].hasSuffix("/both.txt.LOCAL")
                        && arguments[5].hasSuffix("/both.txt.REMOTE") && arguments[6] == "-o" && arguments[7] == "both.txt",
                    "\(label): 3-way arguments \(arguments)")
                #expect(
                    realPath(URL(fileURLWithPath: arguments[1]).deletingLastPathComponent().path) == root, "\(label): stage files live beside the merged file")
                #expect(
                    try tool.seen("base") == "base both\n" && tool.seen("local") == "main both\n" && tool.seen("remote") == "topic both\n",
                    "\(label): stage files contain stages 1-3")
                #expect(try tool.seen("cwd") == root, "\(label): tool runs in the working directory")
                #expect(try !fixture.listing(repo).contains { $0.hasPrefix("both.txt.") }, "\(label): temporary files deleted")
                if item.mode.hasPrefix("write") && item.staged {
                    #expect(try fixture.git(["show", ":both.txt"], in: repo) == "merged by tool", "\(label): merged content staged")
                }
                if item.mode == "delete0" && item.staged {
                    do {
                        let actual = try !fixture.exists(repo, "both.txt") && (try fixture.git(["ls-files", "--stage", "--", "both.txt"], in: repo)).isEmpty
                        #expect(actual, "deleted merged file stages the deletion")
                    }
                }
                #expect(try fixture.git(["log", "-1", "--format=%s"], in: repo) == "main", "\(label): no commit created")
            }
        }

        @Test("Two way fallback") private static func twoWayFallback() async throws {
            for (answer, expectedArguments) in [(TwoWayMergeAnswer.yes, 4), (.no, 5), (.cancel, 0)] {
                let fixture = try Fixture()
                defer { fixture.remove() }
                let repo = try fixture.conflictRepository()
                let module = try await fixture.module(repo)
                let tool = try fixture.fakeTool(in: repo, name: "kdiff3", mode: "write0", command: nil)
                let configuration = try await module.loadMergeToolConfiguration()
                #expect(configuration?.command == MergeToolInvocation.kdiff3DefaultCommand, "kdiff3 default command applies when only the path is configured")
                let presenter = ScriptedPresenter(decisions: [], twoWay: answer)
                await ConflictResolutionWorkflow(source: module, presenter: presenter, rebase: false, mergeTool: configuration).openMergeTool(
                    try await conflicts(module, ["added.txt"]))
                #expect(presenter.twoWayPrompts == ["added.txt"], "\(answer): 2-way question asked for the no-base conflict")
                if expectedArguments == 0 {
                    do {
                        let actual = try !FileManager.default.fileExists(atPath: tool.log.path) && fixture.unmerged(repo).contains("added.txt")
                        #expect(actual, "cancel does not start the tool")
                    }
                    continue
                }
                let arguments = try tool.arguments()
                #expect(arguments.count == expectedArguments, "\(answer): argument count \(arguments)")
                if answer == .yes {
                    #expect(
                        arguments[0].hasSuffix("/added.txt.LOCAL") && arguments[1].hasSuffix("/added.txt.REMOTE") && arguments[2] == "-o"
                            && arguments[3] == "added.txt", "2-way drops BASE")
                } else {
                    #expect(arguments[0] == "" && arguments[1].hasSuffix("/added.txt.LOCAL"), "3-way without a base passes an empty argument, no base file")
                }
                #expect(try !fixture.listing(repo).contains("added.txt.BASE"), "no base file manufactured")
                #expect(try !fixture.unmerged(repo).contains("added.txt"), "\(answer): successful tool staged the result")
            }
        }

        @Test("Special character paths") private static func specialCharacterPaths() async throws {
            let fixture = try Fixture()
            defer { fixture.remove() }
            let name = "sub dir/it's $HOME & (x).txt"
            let repo = try fixture.conflictRepository(extra: name)
            let module = try await fixture.module(repo)
            let tool = try fixture.fakeTool(in: repo, name: "fake", mode: "write0")
            #expect(tool.script.path.contains(" "), "tool path contains spaces")
            let configuration = try await module.loadMergeToolConfiguration()
            let presenter = ScriptedPresenter(decisions: [])
            await ConflictResolutionWorkflow(source: module, presenter: presenter, rebase: false, mergeTool: configuration).openMergeTool(
                try await conflicts(module, [name]))
            let arguments = try tool.arguments()
            #expect(arguments[7] == name && arguments[3].hasSuffix("/\(name).LOCAL"), "special characters survive as single arguments: \(arguments)")
            #expect(try fixture.read(repo, name) == "merged by tool" && !fixture.unmerged(repo).contains(name), "merged and staged")
        }

        @Test("Tool cancellation and start failure") private static func toolCancellationAndStartFailure() async throws {
            let fixture = try Fixture()
            defer { fixture.remove() }
            let repo = try fixture.conflictRepository()
            let module = try await fixture.module(repo)
            let tool = try fixture.fakeTool(in: repo, name: "fake", mode: "sleep")
            let configuration = try await module.loadMergeToolConfiguration()
            let presenter = ScriptedPresenter(decisions: [], solved: true)
            let workflow = ConflictResolutionWorkflow(source: module, presenter: presenter, rebase: false, mergeTool: configuration)
            let selection = try await conflicts(module, ["both.txt"])
            let task = Task { await workflow.openMergeTool(selection) }
            try await wait("tool started") { FileManager.default.fileExists(atPath: tool.log.path) }
            let started = ContinuousClock.now
            task.cancel()
            await task.value
            #expect(ContinuousClock.now - started < .seconds(5), "cancellation terminates the tool")
            do {
                let actual = try presenter.solvedPrompts == 0 && fixture.unmerged(repo).contains("both.txt")
                #expect(actual, "cancelled tool neither prompts nor stages")
            }
            #expect(try !fixture.listing(repo).contains { $0.hasPrefix("both.txt.") }, "temporary files removed after cancellation")

            try fixture.git(["config", "mergetool.fake.path", "/nonexistent/merge tool"], in: repo)
            let broken = try await module.loadMergeToolConfiguration()
            #expect(
                broken?.executablePath == nil && ConflictResolutionWorkflow.loadWarning(for: broken) == ConflictResolutionWorkflow.mergeToolNotConfigured,
                "unresolvable path warns like InitMergetool")
            let failing = ScriptedPresenter(decisions: [])
            await ConflictResolutionWorkflow(source: module, presenter: failing, rebase: false, mergeTool: broken).openMergeTool(
                try await conflicts(module, ["both.txt"]))
            #expect(failing.messages.map(\.text) == ["Error starting mergetool: /nonexistent/merge tool"], "start failure reported: \(failing.messages)")
            #expect(try fixture.unmerged(repo).contains("both.txt"), "start failure leaves the conflict")
        }

        @Test("Interactive merge tool fallback") static func interactiveMergeToolFallback() async throws {
            let fixture = try Fixture()
            defer { fixture.remove() }
            let repo = try fixture.conflictRepository()
            let runner = RecordingGit(fixture: fixture)
            let module = GitRepositoryModule(repositoryURL: repo, git: runner)
            _ = try await module.loadRepositoryState()
            try fixture.git(["config", "merge.tool", "scripted"], in: repo)
            try fixture.git(["config", "mergetool.scripted.cmd", "printf 'interactive result\\n' > \"$MERGED\""], in: repo)
            try fixture.git(["config", "mergetool.scripted.trustExitCode", "true"], in: repo)
            try fixture.git(["config", "mergetool.prompt", "true"], in: repo)
            let configuration = try await module.loadMergeToolConfiguration()
            #expect(configuration?.runsDirectly == false && configuration?.command != nil && configuration?.path == nil, "cmd without path is not run directly")
            let presenter = ScriptedPresenter(decisions: [])
            await ConflictResolutionWorkflow(source: module, presenter: presenter, rebase: false, mergeTool: configuration).openMergeTool(
                try await conflicts(module, ["both.txt"]))
            #expect(
                presenter.interactive.count == 1 && presenter.interactive[0].path == "both.txt" && presenter.interactive[0].tool == nil,
                "falls back to interactive git mergetool")
            do {
                let actual = try presenter.solvedPrompts == 0 && fixture.unmerged(repo).contains("both.txt")
                #expect(actual, "the fallback itself never stages")
            }
            await ConflictResolutionWorkflow(source: module, presenter: presenter, rebase: false, mergeTool: nil).openMergeTool(
                try await conflicts(module, ["both.txt"]))
            #expect(presenter.interactive.count == 2, "no configured tool also falls back to git mergetool")

            let session = GitInteractiveSession { _ in nil }
            defer { session.close() }
            let output = MergeToolOutput()
            let task = Task { try await session.bind { try await module.runMergeTool(path: "both.txt", tool: nil, output: { output.append($0) }) } }
            defer { task.cancel() }
            try await wait("git mergetool waits for its prompt") {
                session.hasActiveInput && output.text.contains("Hit return to start merge resolution tool (scripted):")
            }
            do {
                let actual = try fixture.unmerged(repo).contains("both.txt") && fixture.read(repo, "both.txt") != "interactive result\n"
                #expect(
                    actual,
                    "mergetool waits for explicit input before modifying or staging the conflict")
            }
            do {
                let actual = session.send("")
                #expect(actual, "prompt answered through process input")
            }
            let result = try await task.value
            do {
                let actual = try result.succeeded && fixture.read(repo, "both.txt") == "interactive result\n" && !fixture.unmerged(repo).contains("both.txt")
                #expect(
                    actual,
                    "interactive mergetool resolves after the prompt is answered: \(result.standardErrorString)")
            }
            let mergetoolCommands = runner.commands.filter { $0.contains("mergetool") }
            do {
                let actual = mergetoolCommands == [["mergetool", "--gui", "--", "both.txt"]]
                #expect(actual, "no unconditional --no-prompt: \(mergetoolCommands)")
            }
            _ = try? await module.runMergeTool(path: "both.txt", tool: "custom", output: { _ in })
            #expect(runner.commands.last == ["mergetool", "--tool=custom", "--", "both.txt"], "custom tool shape: \(String(describing: runner.commands.last))")

            let automatic = try Fixture()
            defer { automatic.remove() }
            let automaticRepo = try automatic.conflictRepository()
            try automatic.git(["config", "merge.tool", "scripted"], in: automaticRepo)
            try automatic.git(["config", "mergetool.scripted.cmd", "printf 'automatic result\\n' > \"$MERGED\""], in: automaticRepo)
            try automatic.git(["config", "mergetool.scripted.trustExitCode", "true"], in: automaticRepo)
            try automatic.git(["config", "mergetool.prompt", "false"], in: automaticRepo)
            let automaticModule = try await automatic.module(automaticRepo)
            let automaticOutput = MergeToolOutput()
            let automaticResult = try await session.bind {
                try await automaticModule.runMergeTool(path: "both.txt", tool: nil, output: { automaticOutput.append($0) })
            }
            #expect(
                automaticResult.succeeded && !automaticOutput.text.contains("Hit return to start merge resolution tool"),
                "mergetool.prompt=false completes without sending input")
            do {
                let actual = try automatic.read(automaticRepo, "both.txt") == "automatic result\n" && !automatic.unmerged(automaticRepo).contains("both.txt")
                #expect(
                    actual,
                    "non-prompting mergetool result is written and staged")
            }
        }

        private final class MergeToolOutput: @unchecked Sendable {
            private let lock = NSLock()
            private var bytes = Data()
            var text: String { lock.withLock { String(decoding: bytes, as: UTF8.self) } }
            func append(_ event: GitOutputEvent) { lock.withLock { bytes.append(event.data) } }
        }

        @Test("File history action") private static func fileHistoryAction() async throws {
            let fixture = try Fixture()
            defer { fixture.remove() }
            let repo = try fixture.conflictRepository()
            let module = try await fixture.module(repo)
            let all = try await module.loadConflicts()
            let single = ConflictResolverActionState(selectedConflicts: [all[0]], conflictCount: all.count, mergeToolConfiguration: nil)
            let multiple = ConflictResolverActionState(selectedConflicts: Array(all.prefix(2)), conflictCount: all.count, mergeToolConfiguration: nil)
            do {
                let actual =
                    single.canShowFileHistory(available: true) && !multiple.canShowFileHistory(available: true)
                    && !single.canShowFileHistory(available: false)
                #expect(
                    actual,
                    "File history is enabled for a single selection, like SetAvailableCommands")
            }
            #expect(ConflictResolverFileHistory.handler(for: module) == nil, "no handler without a repository UI context")
            let store = AppSettingsStore.shared
            let saved = store.revisionGridPreferences
            defer { store.saveRevisionGridPreferences(saved) }
            var preferences = saved
            preferences.useBrowseForFileHistory = false
            store.saveRevisionGridPreferences(preferences)
            let browser = RepositoryBrowserViewController(repositoryModule: module)
            let owner = NSWindow(contentViewController: browser)
            owner.isReleasedWhenClosed = false
            defer { owner.close() }
            let commands = GitUICommands(repositoryModule: module, browser: browser)
            #expect(GitUICommands.commands(for: module) === commands, "repository UI commands registered for the module")
            guard let handler = ConflictResolverFileHistory.handler(for: module) else { throw Failure(errorDescription: "file history handler available") }
            let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
            panel.isReleasedWhenClosed = false
            defer { panel.close() }
            for path in ["dl1.txt", "both.txt"] {
                let window = handler(path, panel) as? FileHistoryWindowController
                defer { window?.close() }
                #expect(window?.controller.file == path, "File History opened for the conflicted path \(path)")
                #expect(window?.window?.isVisible == true, "existing File History window shown")
            }
        }

        private static func realPath(_ path: String) -> String {
            guard let resolved = Darwin.realpath(path, nil) else { return path }
            defer { free(resolved) }
            return String(cString: resolved)
        }

        private static func conflicts(_ module: GitRepositoryModule, _ paths: [String]) async throws -> [RepositoryConflict] {
            let all = try await module.loadConflicts()
            return try paths.map { path in
                guard let conflict = all.first(where: { $0.path == path }) else {
                    throw Failure(errorDescription: "missing conflict \(path) in \(all.map(\.path))")
                }
                return conflict
            }
        }

        @MainActor
        private final class ScriptedPresenter: ConflictResolutionPresenter {
            var decisions: [ConflictDecision]
            let openBinary: Bool
            let twoWay: TwoWayMergeAnswer
            let solved: Bool
            var requests: [ConflictDecisionRequest] = []
            var binaryPrompts: [String] = []
            var twoWayPrompts: [String] = []
            var solvedPrompts = 0
            var messages: [(text: String, title: String)] = []
            var interactive: [(path: String?, tool: String?)] = []
            var progressEvents: [(completed: Int, total: Int)] = []

            init(decisions: [ConflictDecision], openBinary: Bool = true, twoWay: TwoWayMergeAnswer = .yes, solved: Bool = false) {
                self.decisions = decisions
                self.openBinary = openBinary
                self.twoWay = twoWay
                self.solved = solved
            }

            func decide(_ request: ConflictDecisionRequest) async -> ConflictDecision {
                requests.append(request)
                return decisions.isEmpty ? .cancelled : decisions.removeFirst()
            }
            func confirmOpenBinary(path: String, tool: String) async -> Bool {
                binaryPrompts.append(path)
                return openBinary
            }
            func confirmTwoWayMerge(path: String) async -> TwoWayMergeAnswer {
                twoWayPrompts.append(path)
                return twoWay
            }
            func confirmConflictSolved() async -> Bool {
                solvedPrompts += 1
                return solved
            }
            func showMessage(_ text: String, title: String, isError: Bool) async { messages.append((text, title)) }
            func runInteractiveMergeTool(path: String?, tool: String?) async { interactive.append((path, tool)) }
            func resolveSubmodule(path: String) async -> Bool { false }
            func progress(completed: Int, total: Int) { progressEvents.append((completed, total)) }
        }

        private final class RecordingGit: GitCommandRunning, @unchecked Sendable {
            private let lock = NSLock()
            private var recorded: [[String]] = []
            private let environment: [String: String]
            var commands: [[String]] { lock.withLock { recorded } }

            init(fixture: Fixture) { environment = fixture.environment }

            func run(arguments: [String], in directory: URL, standardInput: Data?, environment: [String: String]) async throws -> GitCommandResult {
                lock.withLock { recorded.append(arguments) }
                return try await GitProcess().run(
                    arguments: arguments, in: directory, standardInput: standardInput, environment: self.environment.merging(environment) { _, new in new })
            }

            func runStreaming(
                arguments: [String], in directory: URL, standardInput: Data?, environment: [String: String],
                output: @escaping GitOutputHandler
            ) async throws -> GitCommandResult {
                lock.withLock { recorded.append(arguments) }
                return try await GitProcess().runStreaming(
                    arguments: arguments, in: directory, standardInput: standardInput,
                    environment: self.environment.merging(environment) { _, new in new }, output: output)
            }
        }

        private struct FakeTool {
            let script: URL
            let log: URL
            let directory: URL

            func arguments() throws -> [String] {
                let data = try Data(contentsOf: log)
                return data.split(separator: 0, omittingEmptySubsequences: false).dropLast().map { String(decoding: $0, as: UTF8.self) }
            }

            func seen(_ name: String) throws -> String {
                try String(contentsOf: directory.appendingPathComponent("seen.\(name)"), encoding: .utf8)
            }
        }

        private final class Fixture {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("GitExtensionsMac-Conflicts-\(UUID().uuidString)", isDirectory: true)
            lazy var home = root.appendingPathComponent("home", isDirectory: true)
            lazy var environment: [String: String] = [
                "GIT_CONFIG_GLOBAL": home.appendingPathComponent(".gitconfig").path,
                "GIT_CONFIG_NOSYSTEM": "1",
                "HOME": home.path,
                "XDG_CONFIG_HOME": home.appendingPathComponent(".config").path,
            ]

            init() throws {
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
                FileManager.default.createFile(atPath: home.appendingPathComponent(".gitconfig").path, contents: Data())
            }

            func remove() { try? FileManager.default.removeItem(at: root) }

            func module(_ repo: URL) async throws -> GitRepositoryModule {
                let module = GitRepositoryModule(repositoryURL: repo, git: IsolatedGit(environment: environment))
                _ = try await module.loadRepositoryState()
                return module
            }

            func conflictRepository(extra: String? = nil) throws -> URL {
                let repo = root.appendingPathComponent("repo", isDirectory: true)
                try git(["init", "-q", "-b", "main", repo.path], in: root)
                for (key, value) in [
                    ("user.name", "Conflict Parity"), ("user.email", "conflict@example.com"), ("commit.gpgsign", "false"), ("core.autocrlf", "false"),
                ] {
                    try git(["config", key, value], in: repo)
                }
                var files = ["dl1.txt", "dl2.txt", "md1.txt", "md2.txt", "both.txt"]
                if let extra { files.append(extra) }
                for file in files { try write(repo, file, "base \(label(file))\n") }
                try Data([0, 1, 2]).write(to: repo.appendingPathComponent("bin.png"))
                try git(["add", "-A"], in: repo)
                try git(["commit", "-q", "-m", "base"], in: repo)
                try git(["checkout", "-q", "-b", "topic"], in: repo)
                for file in ["dl1.txt", "dl2.txt", "both.txt"] + (extra.map { [$0] } ?? []) { try write(repo, file, "topic \(label(file))\n") }
                try git(["rm", "-q", "--", "md1.txt", "md2.txt"], in: repo)
                try write(repo, "added.txt", "topic added\n")
                try Data([0, 0xFF, 3]).write(to: repo.appendingPathComponent("bin.png"))
                try git(["add", "-A"], in: repo)
                try git(["commit", "-q", "-m", "topic"], in: repo)
                try git(["checkout", "-q", "main"], in: repo)
                try git(["rm", "-q", "--", "dl1.txt", "dl2.txt"], in: repo)
                for file in ["md1.txt", "md2.txt", "both.txt"] + (extra.map { [$0] } ?? []) { try write(repo, file, "main \(label(file))\n") }
                try write(repo, "added.txt", "main added\n")
                try Data([0, 0xEE, 4]).write(to: repo.appendingPathComponent("bin.png"))
                try git(["add", "-A"], in: repo)
                try git(["commit", "-q", "-m", "main"], in: repo)
                _ = try? git(["merge", "topic"], in: repo)
                return repo
            }

            private func label(_ file: String) -> String { file.hasSuffix(".txt") && !file.contains("/") ? String(file.dropLast(4)) : "extra" }

            func fakeTool(
                in repo: URL, name: String, mode: String, command: String? = "--base \"$BASE\" --local \"$LOCAL\" --remote \"$REMOTE\" -o \"$MERGED\""
            ) throws -> FakeTool {
                let directory = root.appendingPathComponent("fake tool dir", isDirectory: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let script = directory.appendingPathComponent("merge tool.sh")
                let log = directory.appendingPathComponent("args.log")
                let body = """
                    #!/bin/sh
                    dir='\(directory.path)'
                    for a in "$@"; do printf '%s\\0' "$a"; done > "$dir/args.tmp"
                    pwd -P > "$dir/seen.cwd.tmp"; tr -d '\\n' < "$dir/seen.cwd.tmp" > "$dir/seen.cwd"
                    merged=""; previous=""; index=0
                    for a in "$@"; do
                      case "$previous" in
                        --base) [ -n "$a" ] && cat "$a" > "$dir/seen.base" ;;
                        --local) cat "$a" > "$dir/seen.local" ;;
                        --remote) cat "$a" > "$dir/seen.remote" ;;
                        -o) merged="$a" ;;
                      esac
                      previous="$a"
                    done
                    mv "$dir/args.tmp" "$dir/args.log"
                    mode='\(mode)'
                    case "$mode" in
                      write0) printf 'merged by tool' > "$merged"; exit 0 ;;
                      write1) printf 'merged by tool' > "$merged"; exit 1 ;;
                      write2) printf 'merged by tool' > "$merged"; exit 2 ;;
                      noop0) exit 0 ;;
                      noop1) exit 1 ;;
                      delete0) rm -f "$merged"; exit 0 ;;
                      sleep) sleep 30; exit 0 ;;
                    esac
                    """
                try body.write(to: script, atomically: true, encoding: .utf8)
                try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
                try git(["config", "merge.tool", name], in: repo)
                try git(["config", "mergetool.\(name).path", script.path], in: repo)
                if let command { try git(["config", "mergetool.\(name).cmd", command], in: repo) }
                try? FileManager.default.removeItem(at: log)
                return FakeTool(script: script, log: log, directory: directory)
            }

            func write(_ repo: URL, _ file: String, _ text: String) throws {
                let url = repo.appendingPathComponent(file)
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try text.write(to: url, atomically: true, encoding: .utf8)
            }

            func read(_ repo: URL, _ file: String) throws -> String { try String(contentsOf: repo.appendingPathComponent(file), encoding: .utf8) }
            func exists(_ repo: URL, _ file: String) -> Bool { FileManager.default.fileExists(atPath: repo.appendingPathComponent(file).path) }

            func listing(_ repo: URL) throws -> [String] {
                (FileManager.default.enumerator(atPath: repo.path)?.allObjects as? [String] ?? []).filter { !$0.hasPrefix(".git") }
            }

            func unmerged(_ repo: URL) throws -> [String] {
                let output = try git(["ls-files", "-u", "-z"], in: repo, trim: false)
                return Array(Set(output.split(separator: "\0").compactMap { $0.split(separator: "\t", maxSplits: 1).last.map(String.init) })).sorted()
            }

            @discardableResult
            func git(_ arguments: [String], in directory: URL, trim: Bool = true) throws -> String {
                let process = FixtureProcess()
                let output = Pipe()
                let errors = Pipe()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
                process.arguments = arguments
                process.currentDirectoryURL = directory
                process.standardOutput = output
                process.standardError = errors
                process.standardInput = FileHandle.nullDevice
                process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }.merging(["GIT_TERMINAL_PROMPT": "0"]) {
                    _, new in new
                }
                try process.run()
                let data = output.fileHandleForReading.readDataToEndOfFile()
                let errorData = errors.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                guard process.terminationStatus == 0 else {
                    throw Failure(errorDescription: "git \(arguments.joined(separator: " ")) failed: \(String(decoding: errorData, as: UTF8.self))")
                }
                let text = String(decoding: data, as: UTF8.self)
                return trim ? text.trimmingCharacters(in: .whitespacesAndNewlines) : text
            }
        }

        private struct IsolatedGit: GitCommandRunning {
            let environment: [String: String]

            func run(arguments: [String], in directory: URL, standardInput: Data?, environment: [String: String]) async throws -> GitCommandResult {
                try await GitProcess().run(
                    arguments: arguments, in: directory, standardInput: standardInput, environment: self.environment.merging(environment) { _, new in new })
            }

            func runStreaming(
                arguments: [String], in directory: URL, standardInput: Data?, environment: [String: String],
                output: @escaping GitOutputHandler
            ) async throws -> GitCommandResult {
                try await GitProcess().runStreaming(
                    arguments: arguments, in: directory, standardInput: standardInput,
                    environment: self.environment.merging(environment) { _, new in new }, output: output)
            }
        }
    }
}

typealias ConflictResolutionTests = UIIntegrationTests.ConflictResolutionTests
