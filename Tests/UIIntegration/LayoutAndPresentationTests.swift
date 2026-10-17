import AppKit
import Foundation
import Testing

@testable import GitCommands
@testable import GitExtensionsCore
@testable import GitUI

extension UIIntegrationTests {
    @MainActor
    @Suite("Layout and presentation")
    enum LayoutAndPresentationTests {

        @Test("Push minimum size") static func pushMinimumSize() async throws {
            let fixture = try FileStatusFixture.make()
            defer { fixture.remove() }
            try fixture.write("a.txt", "base\n")
            try fixture.commitAll("base")
            let module = GitRepositoryModule(repositoryURL: fixture.repo, git: GitProcess())
            let context = try await module.loadRepositoryState().networkContext
            let saved = AppSettingsStore.shared.pushPreferences
            defer { AppSettingsStore.shared.savePushPreferences(saved) }
            var hidden = saved
            hidden.showAdvancedOptions = false
            AppSettingsStore.shared.savePushPreferences(hidden)
            let controller = PushDialog.present(source: module, context: context, onManageRemotes: { _, _ in }, onRepositoryChanged: { _ in }, onClose: {})
            let window = controller.window!
            defer { window.close() }
            func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
            func buttons() -> [NSButton] {
                descendants(window.contentView!).compactMap { $0 as? NSButton }.filter {
                    !$0.isHidden && $0.window != nil && !$0.title.isEmpty && $0.alphaValue > 0
                }
            }
            func assertAccessible(_ state: String) {
                window.contentView!.layoutSubtreeIfNeeded()
                let bounds = window.contentView!.bounds
                for button in buttons() where ["Manage remotes", "Browse…", "Pull", "Push", "Show options"].contains(button.title) {
                    let frame = button.convert(button.bounds, to: window.contentView)
                    #expect(
                        bounds.contains(frame.insetBy(dx: 1, dy: 1)), "\(button.title) fully inside the Push window at minimum (\(state)) \(frame) \(bounds)")
                    #expect(
                        frame.width + 0.5 >= button.intrinsicContentSize.width,
                        "\(button.title) caption not compressed (\(state)) \(frame.width) < \(button.intrinsicContentSize.width)")
                }
            }
            let minimum = window.contentMinSize
            #expect(
                minimum.width >= PushDialog.upstreamMinimumClientSize.width && minimum.height >= PushDialog.upstreamMinimumClientSize.height,
                "never below upstream client minimum")
            #expect(window.contentRect(forFrameRect: window.frame).width + 0.5 >= minimum.width, "opens at or above its computed minimum")
            window.setContentSize(minimum)
            assertAccessible("options hidden")
            window.setContentSize(NSSize(width: minimum.width + 300, height: minimum.height + 150))
            window.contentView!.layoutSubtreeIfNeeded()
            #expect(
                abs(window.contentRect(forFrameRect: window.frame).width - (minimum.width + 300)) <= 1,
                "Push widens instead of being pinned by fixed grid columns")
            window.setContentSize(minimum)
            let showOptions = buttons().first { $0.title == "Show options" }!
            showOptions.performClick(nil)
            #expect(window.contentMinSize.height > minimum.height, "showing options raises the computed minimum height")
            #expect(window.contentRect(forFrameRect: window.frame).height + 0.5 >= window.contentMinSize.height, "window grows to fit the options")
            window.setContentSize(window.contentMinSize)
            assertAccessible("options shown")
            #expect(PushDialog.minimumContentHeight(destination: 80, tabHeader: 30, tabContent: 60, footer: 34) == 235, "preferred heights plus margins")
        }

        @Test("Conflict presentation") static func conflictPresentation() async throws {
            for bothModified in [false, true] {
                let fixture = try FileStatusFixture.make()
                defer { fixture.remove() }
                try fixture.write("keep.txt", "keep\n")
                if bothModified { try fixture.write("c.txt", "base\n") }
                try fixture.commitAll("base")
                try fixture.git(["checkout", "-q", "-b", "side"])
                try fixture.write("c.txt", "side\n")
                try fixture.commitAll("side")
                try fixture.git(["checkout", "-q", "main"])
                try fixture.write("c.txt", "main\n")
                try fixture.commitAll("main")
                _ = try? fixture.git(["merge", "side"])
                let module = GitRepositoryModule(repositoryURL: fixture.repo, git: FileStatusFixtureGit())
                _ = try await module.loadRepositoryState()
                let revisions = RevisionCommitBuilder.artificialRevisions(headID: try fixture.head())
                let worktree = try await module.loadRevisionDetails(for: revisions.first { $0.kind == .workingDirectory }!).files.filter { $0.path == "c.txt" }
                let index = try await module.loadRevisionDetails(for: revisions.first { $0.kind == .index }!).files.filter { $0.path == "c.txt" }
                if bothModified {
                    #expect(index.isEmpty, "UU conflicts only list the worktree item")
                    #expect(
                        worktree.count == 1 && worktree[0].isConflict && ChangedFilesViewController.imageName(for: worktree[0], isGrep: false) == "Unmerged",
                        "UU conflict uses the Unmerged icon")
                    #expect(!CommitFileContentPresentation.viewsAsFileContent(worktree[0], headless: false), "UU conflict is shown as a diff")
                } else {
                    #expect(index.count == 1 && worktree.count == 1, "AA conflicts list both items")
                    for file in index + worktree {
                        #expect(
                            file.changeType == .added && ChangedFilesViewController.imageName(for: file, isGrep: false) == "FileStatusAdded",
                            "AA conflict items are new files with the added icon")
                        #expect(CommitFileContentPresentation.viewsAsFileContent(file, headless: false), "AA conflict items are viewed as file content")
                    }
                }
            }
            let text = CommitFileContentPresentation.numberedText("one\ntwo\n", id: "x")
            #expect(
                text.isTextOnly && text.lines.map(\.newLineNumber) == [1, 2] && text.lines.allSatisfy { $0.kind == .context && $0.oldLineNumber == nil },
                "file content view numbers plain lines")
        }

        @Test("Diff text appearance") static func diffTextAppearance() {
            let highlight = NSColor.systemGreen.withAlphaComponent(0.2)
            #expect(
                DiffTextColors.contrastingText(over: highlight, editor: NSColor(white: 0.12, alpha: 1)) == .white,
                "translucent highlight over a dark editor uses light text")
            #expect(DiffTextColors.contrastingText(over: highlight, editor: .white) == .black, "translucent highlight over a light editor uses dark text")
            let dynamic = DiffTextColors.contrastingText(for: highlight)
            var dark: NSColor?
            var light: NSColor?
            NSAppearance(named: .darkAqua)!.performAsCurrentDrawingAppearance { dark = dynamic.usingColorSpace(.sRGB) }
            NSAppearance(named: .aqua)!.performAsCurrentDrawingAppearance { light = dynamic.usingColorSpace(.sRGB) }
            #expect(
                dark.map { $0.redComponent > 0.9 } == true && light.map { $0.redComponent < 0.1 } == true,
                "diff highlight text follows the effective appearance")
        }

        @Test("Layout") static func layout() async throws {
            #expect(SplitterManager.restoredDistance(saved: nil, size: 500, fixedPanel: .proportional) == nil)
            #expect(SplitterManager.restoredDistance(saved: SplitterSetting(distance: 200, size: 500), size: 500, fixedPanel: .fixedTrailingPane) == 200)
            #expect(SplitterManager.restoredDistance(saved: SplitterSetting(distance: 200, size: 500), size: 1000, fixedPanel: .proportional) == 400)
            #expect(SplitterManager.restoredDistance(saved: SplitterSetting(distance: 200, size: 500), size: 1000, fixedPanel: .fixedLeadingPane) == 200)
            #expect(SplitterManager.restoredDistance(saved: SplitterSetting(distance: 200, size: 500), size: 1000, fixedPanel: .fixedTrailingPane) == 700)

            let defaults = UserDefaults.standard
            let key = "GitExtensionsMac.splitters.v1"
            let savedSplitters = defaults.object(forKey: key)
            defaults.removeObject(forKey: key)
            defer { if let savedSplitters { defaults.set(savedSplitters, forKey: key) } else { defaults.removeObject(forKey: key) } }
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            defer { window.close() }
            let split = NSSplitView()
            split.isVertical = true
            split.addArrangedSubview(NSView())
            split.addArrangedSubview(NSView())
            let container = NSView()
            window.contentView = container
            split.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(split)
            NSLayoutConstraint.activate([
                split.leadingAnchor.constraint(equalTo: container.leadingAnchor), split.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                split.topAnchor.constraint(equalTo: container.topAnchor), split.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            ])
            let manager = SplitterManager(settingsPath: "LayoutTest")
            manager.addSplitter(split, name: "split", fixedPanel: .fixedLeadingPane, defaultDistance: 220)
            container.layoutSubtreeIfNeeded()
            manager.restoreSplitters()
            container.layoutSubtreeIfNeeded()
            #expect(SplitterManager.distance(of: split) == 220, "restored default \(SplitterManager.distance(of: split))")
            window.setContentSize(NSSize(width: 900, height: 400))
            container.layoutSubtreeIfNeeded()
            #expect(SplitterManager.distance(of: split) == 220, "panel1 fixed on grow \(SplitterManager.distance(of: split))")
            manager.saveSplitters()
            #expect(AppSettingsStore.shared.splitterSetting("LayoutTest.split") == SplitterSetting(distance: 220, size: 900))
            #expect(
                RepositoryBrowserViewController.leftPanelMinSize == 192 && RepositoryBrowserViewController.splitterPanelMinSize == 25,
                "upstream MainSplitContainer.Panel1MinSize 192 and default SplitContainer 25")
            let retaining = RetainingSplitViewController(resizeBehavior: .fixedLeadingPane)
            for minimum in [RepositoryBrowserViewController.leftPanelMinSize, RepositoryBrowserViewController.splitterPanelMinSize] {
                let pane = NSViewController()
                pane.view = NSView()
                let item = NSSplitViewItem(viewController: pane)
                item.minimumThickness = minimum
                retaining.addSplitViewItem(item)
            }
            retaining.view.frame = NSRect(x: 0, y: 0, width: 800, height: 400)
            #expect(retaining.splitView(retaining.splitView, constrainMinCoordinate: 5, ofSubviewAt: 0) == 192, "left panel drag stops at its upstream minimum")
            #expect(
                retaining.splitView(retaining.splitView, constrainMaxCoordinate: 799, ofSubviewAt: 0) <= 800 - retaining.splitView.dividerThickness - 25,
                "trailing pane keeps its upstream minimum")
            let collapsible = RetainingSplitViewController(resizeBehavior: .fixedLeadingPane)
            collapsible.splitView.isVertical = true
            let leftPane = NSViewController()
            leftPane.view = NSView()
            let rightPane = NSViewController()
            rightPane.view = NSView()
            let leftItem = NSSplitViewItem(viewController: leftPane)
            collapsible.addSplitViewItem(leftItem)
            collapsible.addSplitViewItem(NSSplitViewItem(viewController: rightPane))
            let collapseWindow = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 900, height: 400), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
            collapseWindow.isReleasedWhenClosed = false
            defer { collapseWindow.close() }
            collapseWindow.contentViewController = collapsible
            collapseWindow.setContentSize(NSSize(width: 900, height: 400))
            collapsible.setRetainedPosition(260)
            collapsible.view.layoutSubtreeIfNeeded()
            collapsible.setCollapsed(true, for: leftItem)
            collapsible.view.layoutSubtreeIfNeeded()
            #expect(collapsible.splitView(collapsible.splitView, shouldHideDividerAt: 0), "divider next to a collapsed pane is hidden")
            #expect(
                leftPane.view.superview == nil && collapsible.splitView.arrangedSubviews == [rightPane.view],
                "collapsed pane leaves the split so no divider is drawn")
            #expect(
                rightPane.view.frame.minX == 0 && abs(rightPane.view.frame.width - 900) <= 1,
                "collapsed left panel leaves no stale divider or frame over the content \(leftPane.view.frame) \(rightPane.view.frame)")
            collapsible.setCollapsed(false, for: leftItem)
            #expect(
                abs((collapsible.dividerPosition ?? 0) - 260) <= 1,
                "width is back immediately so a layout save right after showing records it \(collapsible.dividerPosition ?? -1)")
            let reopenDeadline = ContinuousClock.now + .seconds(2)
            while abs((collapsible.dividerPosition ?? 0) - 260) > 1, ContinuousClock.now < reopenDeadline {
                try await Task.sleep(for: .milliseconds(20))
                collapsible.view.layoutSubtreeIfNeeded()
            }
            #expect(
                !collapsible.splitView(collapsible.splitView, shouldHideDividerAt: 0)
                    && collapsible.splitView.arrangedSubviews == [leftPane.view, rightPane.view] && abs((collapsible.dividerPosition ?? 0) - 260) <= 1,
                "showing the panel restores its width and divider")
            let leading = LeadingImageButton(title: "Reset unstaged changes", target: nil, action: nil)
            leading.image = NSImage(size: NSSize(width: 16, height: 16))
            leading.imagePosition = .imageLeft
            let titleWidth = ceil(leading.attributedTitle.size().width)
            #expect(
                leading.intrinsicContentSize.width == titleWidth + 2 * (LeadingImageButtonCell.imageInset + 16 + LeadingImageButtonCell.imageSpacing),
                "icon/text buttons reserve equal margins so a centered caption never touches the icon")
            leading.frame = NSRect(x: 0, y: 0, width: 260, height: 26)
            let leadingCell = leading.cell as! LeadingImageButtonCell
            #expect(
                leadingCell.imageRect(forBounds: leading.bounds).minX == LeadingImageButtonCell.imageInset
                    && abs(leadingCell.titleRect(forBounds: leading.bounds).midX - leading.bounds.midX) <= 1,
                "upstream MiddleLeft image with caption centered across the button")
            let trailingMinimum = split.arrangedSubviews[1].widthAnchor.constraint(greaterThanOrEqualToConstant: 300)
            trailingMinimum.isActive = true
            window.setContentSize(NSSize(width: 420, height: 400))
            container.layoutSubtreeIfNeeded()
            #expect(
                SplitterManager.distance(of: split) < 220,
                "fixed pane compressed below its size when the window is too small \(SplitterManager.distance(of: split))")
            window.setContentSize(NSSize(width: 900, height: 400))
            container.layoutSubtreeIfNeeded()
            #expect(
                abs(SplitterManager.distance(of: split) - 220) <= 1,
                "fixed pane returns to its size when the window grows \(SplitterManager.distance(of: split))")
            split.setPosition(260, ofDividerAt: 0)
            NotificationCenter.default.post(name: NSSplitView.didResizeSubviewsNotification, object: split, userInfo: ["NSSplitViewDividerIndex": 0])
            window.setContentSize(NSSize(width: 420, height: 400))
            container.layoutSubtreeIfNeeded()
            window.setContentSize(NSSize(width: 900, height: 400))
            container.layoutSubtreeIfNeeded()
            #expect(abs(SplitterManager.distance(of: split) - 260) <= 1, "user drag defines the remembered fixed size \(SplitterManager.distance(of: split))")
            trailingMinimum.isActive = false
            #expect(
                SplitterManager.positionRestoringFixedPanel(184, size: 620, divider: 10, fixedPanel: .fixedTrailingPane) == 426
                    && SplitterManager.positionRestoringFixedPanel(184, size: 620, divider: 10, fixedPanel: .proportional) == nil)
            defaults.removeObject(forKey: key)

            let diff = RevisionDiffViewController()
            var requested: CGFloat?
            diff.restoredFileListWidth = {
                requested = $0
                return 420
            }
            let diffWindow = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 1000, height: 500), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
            diffWindow.isReleasedWhenClosed = false
            defer { diffWindow.close() }
            diffWindow.contentViewController = diff
            diffWindow.setContentSize(NSSize(width: 1000, height: 500))
            diff.view.layoutSubtreeIfNeeded()
            let deadlineDiff = ContinuousClock.now + .seconds(2)
            while diff.dividerPosition.map({ abs($0 - 420) > 1 }) ?? true, ContinuousClock.now < deadlineDiff {
                try await Task.sleep(for: .milliseconds(20))
                diff.view.layoutSubtreeIfNeeded()
            }
            #expect(requested != nil && abs((diff.dividerPosition ?? 0) - 420) <= 1, "Browse Diff file list restores its persisted width")

            let fixture = try FileStatusFixture.make()
            defer { fixture.remove() }
            try fixture.write("a.txt", "base\n")
            try fixture.commitAll("base")
            try fixture.write("a.txt", "changed\n")
            let module = GitRepositoryModule(repositoryURL: fixture.repo, git: FileStatusFixtureGit())
            _ = try await module.loadRepositoryState()
            let owner = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled, .closable], backing: .buffered, defer: false)
            owner.isReleasedWhenClosed = false
            defer { owner.close() }
            let savedCommitPreferences = AppSettingsStore.shared.commitPreferences
            var commitPreferences = savedCommitPreferences
            commitPreferences.windowWidth = 918
            commitPreferences.windowHeight = 644
            AppSettingsStore.shared.saveCommitPreferences(commitPreferences)
            defer { AppSettingsStore.shared.saveCommitPreferences(savedCommitPreferences) }
            let controller = CommitWorkflowDialog.present(
                source: module, initialMode: .normal, head: nil, draft: nil, owner: owner, onRepositoryChanged: { _ in }, onClose: {})
            let commit = controller.window!
            defer { commit.close() }
            func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
            let deadline = ContinuousClock.now + .seconds(10)
            func labels() -> [String] { descendants(commit.contentView!).compactMap { ($0 as? NSTextField)?.stringValue } }
            while !labels().contains("0/1"), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
            commit.contentView!.layoutSubtreeIfNeeded()
            let views = descendants(commit.contentView!)
            let splits = views.compactMap { $0 as? NSSplitView }
            let main = splits.first { $0.isVertical }!
            let right = splits.first { !$0.isVertical && $0.isDescendant(of: main.arrangedSubviews[1]) }!
            #expect(SplitterManager.distance(of: main) == 397, "Commit splitMain default distance")
            #expect(
                abs(right.arrangedSubviews[1].frame.height - (SplitterManager.size(of: right) - 426 - right.dividerThickness)) < 1,
                "Commit splitRight default distance")
            let buttons = views.compactMap { $0 as? NSButton }
            #expect(
                buttons.first { $0.title == "Cancel" }.map { $0.alphaValue == 0 && $0.keyEquivalent == "\u{1b}" } == true,
                "Cancel is only the hidden Escape target")
            #expect(!buttons.contains { $0.title.hasPrefix("Manage tracking") }, "no extra Manage tracking toolbar button")
            let commitButton = buttons.first { $0 is CommitShortcutButton }!
            #expect(commitButton.keyEquivalent.isEmpty, "Commit is not a default button")
            let column =
                ["Commit & push", "Stash staged changes", "Reset all changes", "Reset unstaged changes"].compactMap { title in
                    buttons.first { $0.title == title }
                } + [commitButton]
            #expect(
                column.count == 5
                    && column.allSatisfy {
                        abs($0.frame.width - commitButton.frame.width) < 0.5 && $0.frame.width + 0.5 >= $0.fittingSize.width && $0.frame.width >= 171
                    },
                "command buttons share one width that fits every caption: \(column.map { ($0.title, $0.frame.width, $0.fittingSize.width) })")
            #expect(commitButton.imagePosition == .imageLeft && !commitButton.imageHugsTitle, "Commit image is aligned left like ImageAlign.MiddleLeft")
            #expect(["Staged", "0/1", "Ln", "Col"].allSatisfy(labels().contains), "upstream status strip items")
            #expect(!labels().contains { $0.contains("unstaged") && $0.contains("staged /") }, "no combined Mac status summary")
            let width = SplitterManager.distance(of: main)
            commit.setContentSize(NSSize(width: commit.contentLayoutRect.width + 200, height: commit.contentLayoutRect.height + 100))
            commit.contentView!.layoutSubtreeIfNeeded()
            #expect(SplitterManager.distance(of: main) == width, "file pane keeps its width when the window grows")
            #expect(
                abs(right.arrangedSubviews[1].frame.height - (SplitterManager.size(of: right) - 426 - 100 - right.dividerThickness)) < 1,
                "commit message pane keeps its height when the window grows \(right.arrangedSubviews[1].frame.height) \(SplitterManager.size(of: right))")
        }

        static func duringModal(_ action: @escaping @MainActor () -> Void) {
            let timer = Timer(timeInterval: 0.05, repeats: false) { _ in MainActor.assumeIsolated { action() } }
            RunLoop.main.add(timer, forMode: .modalPanel)
        }

        @Test("Tools") static func tools() throws {
            struct Vector: Decodable {
                let output: String
                let expected: [String]
            }
            let fixture = TestResources.fixtures.appendingPathComponent("FrontendToolHelpUpstream.json")
            let vectors = try JSONDecoder().decode([Vector].self, from: Data(contentsOf: fixture))
            #expect(vectors.count == 3)
            for vector in vectors {
                let actual = MergeToolInvocation.availableTools(output: vector.output, defaultTool: "winmerge")
                #expect(Set(actual) == Set(vector.expected) && actual.count == vector.expected.count && actual.first == "winmerge")
            }
            let output =
                "header\n\t\tvimdiff\n\t\taudit-alpha.cmd true\n\t\taudit-zeta.cmd true\n\t\taudit-alpha.cmd duplicate\nThe following tools are valid, but not currently available:\n\t\tmissing\n"
            #expect(MergeToolInvocation.availableTools(output: output, defaultTool: "audit-zeta") == ["audit-zeta", "audit-alpha"])
            var context = ChangedFileContextMenuContext(selectedFiles: [
                ChangedFile(id: "a", path: "a", oldPath: nil, changeType: .modified, additions: 1, deletions: 0)
            ])
            context.diffTools = ["audit-zeta", "audit-alpha"]
            context.firstToSelectedEnabled = true
            let entries = ChangedFileContextMenuBuilder.build(context)
            let tools = entries.entry(id: "file.difftool.tools")!.children
            #expect(
                tools.map { entry in
                    switch entry {
                    case .command(_, let title, _), .submenu(_, let title, _, _): return title
                    case .separator: return ""
                    }
                } == ["audit-zeta", "audit-alpha", "", "Disable"])
            #expect(tools.first?.id == "file.difftool.tool:audit-zeta")
        }

        @Test("Reports") static func reports() {
            #expect(!ErrorReportContent.containsInformation(""))
            #expect(!ErrorReportContent.containsInformation("\t\r\n\t\t   \r   \n   \r"))
            #expect(ErrorReportContent.containsInformation("\t\r\n\t\t  a \r   \n   \r"))
            let inner = ExceptionReportSnapshot(type: "Inner", message: "underlying")
            let snapshot = ExceptionReportSnapshot(
                type: "ExampleException", message: "message", targetSite: "perform()", source: "application", stackTrace: "one\ntwo",
                data: [.init(name: "key", value: "value")], extended: [.init(name: "Code", value: "1", extended: true)], children: [inner])
            #expect(
                snapshot.properties.map(\.name) == ["Exception", "Message", "Target Site", "Inner Exception", "Source", "Stack Trace", "Data[\"key\"]", "Code"])
            let content = ErrorReportContent(exception: snapshot, environment: "environment")
            let url = URLComponents(url: content.issueURL(description: "  Reproduce λ + &  ")!, resolvingAgainstBaseURL: false)!
            let values = Dictionary(uniqueKeysWithValues: url.queryItems!.map { ($0.name, $0.value!) })
            #expect(values["title"] == "[NBug] message" && values["template"] == "bug_report.yml" && values["labels"] == "type: NBug")
            #expect(values["description"] == "```\n" + snapshot.details + "\n```\n\nReproduce λ + &\n")
            #expect(content.copyText(description: "") == "environment```\n" + snapshot.details + "\n```\n\n")
            #expect(content.issueURL(description: "a", base: "file:///tmp/report") == nil)
            let long = ErrorReportContent(exception: .init(type: "T", message: String(repeating: "a", count: 100)), environment: "")
            let title = URLComponents(url: long.issueURL(description: "a")!, resolvingAgainstBaseURL: false)!.queryItems!.first!.value!
            #expect(title.count == 69 && title.hasSuffix("..."))
            let error = NSError(
                domain: "Outer", code: 1, userInfo: [NSLocalizedDescriptionKey: "outer", NSUnderlyingErrorKey: NSError(domain: "Inner", code: 2)])
            #expect(ExceptionReportSnapshot.capture(error).children.first?.type == "Inner")
            let native = NSException(name: .invalidArgumentException, reason: "native", userInfo: ["key": "value"])
            #expect(ExceptionReportSnapshot.capture(native).type == "NSInvalidArgumentException")
            #expect(NSClassFromString("GitExtensionsApplication") == GitExtensionsApplication.self)
            let window = ErrorReportWindow(content: content, context: .init(isExternalOperation: true))
            #expect(window.tabs.tabViewItems.map(\.label) == ["General", "Exception"])
            #expect(window.ignore.isEnabled && !window.ignore.isHidden && window.send.isEnabled)
            var copied = ""
            var validations = 0
            window.copyAction = { copied = $0 }
            window.validation = { _ in validations += 1 }
            window.confirmSend = { false }
            window.openAction = { _ in
                Issue.record("Cancelled send opened a URL")
                return false
            }
            duringModal {
                window.window!.contentView!.layoutSubtreeIfNeeded()
                @MainActor func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
                let grid = descendants(window.window!.contentView!).compactMap { $0 as? NSGridView }.first!
                #expect(grid.cell(atColumnIndex: 1, rowIndex: 0).contentView!.frame.width > 400)
                #expect(grid.cell(atColumnIndex: 3, rowIndex: 1).contentView!.frame.width > 150)
                window.sendReport()
                #expect(validations == 1)
                window.descriptionInput.string = "steps"
                window.copyReport()
                #expect(copied == content.copyText(description: "steps"))
                window.sendReport()
                #expect(window.result == .resume)
                window.tabs.selectTabViewItem(at: 1)
                window.window!.contentView!.layoutSubtreeIfNeeded()
                #expect(window.tree.enclosingScrollView!.frame.width >= 135 && window.tree.enclosingScrollView!.frame.width < 220)
                #expect(window.properties.enclosingScrollView!.frame.width > 250)
                window.tree.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
                #expect(window.displayed.first?.value == "Inner")
                window.properties.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
                duringModal {
                    #expect(NSApp.modalWindow?.title == "Property Details")
                    NSApp.modalWindow?.performClose(nil)
                }
                window.openProperty()
                #expect(NSApp.modalWindow === window.window)
                window.ignoreReport()
            }
            #expect(window.run(owner: nil) == .resume)
            let user = ErrorReportWindow(content: content, context: .init(isExternalOperation: true, isUserExternalOperation: true))
            #expect(user.tabs.selectedTabViewItem?.label == "Exception" && !user.send.isEnabled)
            let terminating = ErrorReportWindow(content: content, context: .init(isExternalOperation: true, isTerminating: true))
            #expect(!terminating.ignore.isEnabled && !terminating.window!.styleMask.contains(.closable))
            #expect(!terminating.windowShouldClose(terminating.window!))
            let detail = ExceptionPropertyWindow(snapshot.properties.last!)
            #expect(
                detail.window?.title == "Property Details" && detail.property.stringValue == "Code" && detail.information.string == "1"
                    && !detail.information.isEditable)
        }

        @Test("Scripts") static func scripts() async throws {
            let named = ScriptInputPresentation(scriptName: "Audit named input", label: "Audit input")
            #expect(named.caption == "User input for script 'Audit named input'" && named.label == "Audit input:")
            #expect(ScriptInputPresentation(scriptName: "a", label: nil).label == "Please specify your input:")
            #expect(ScriptInputPresentation(scriptName: "a", label: " ").label == "Please specify your input:")
            #expect(ScriptInputPresentation.escape(NSRange(location: 2, length: 3)) == NSRange(location: 2, length: 0))
            #expect(ScriptInputPresentation.escape(NSRange(location: 2, length: 0)) == nil)
            let input = ScriptInputWindow(scriptName: "named", label: "Value", initial: "hello world")
            duringModal {
                let editor = input.input.currentEditor() as! NSTextView
                editor.setSelectedRange(NSRange(location: 0, length: 11))
                input.window?.cancelOperation(nil)
                #expect(input.window?.isVisible == true && editor.selectedRange() == NSRange(location: 0, length: 0))
                #expect(input.input.stringValue == "hello world")
                input.window?.cancelOperation(nil)
            }
            #expect(input.run() == nil)
            let ordinary = ScriptInputWindow(scriptName: "empty accepted", label: nil, initial: "")
            duringModal { ordinary.acceptInput() }
            #expect(ordinary.run() == "")
            for value in ["", " ", "../raw path/日本語 missing", #""one two" "λ""#] {
                let files = ScriptInputWindow(scriptName: "files", label: nil, initial: value, files: true)
                duringModal { files.acceptInput() }
                #expect(files.run() == (value.isEmpty ? nil : value))
            }
            let raw = #""/tmp/a b" /tmp/nonexistent λ"#
            var script = ScriptDefinition()
            script.arguments = "command {UserFiles}"
            let expanded = await ScriptPrompts.resolve(
                script, options: [:],
                input: { _, _ in
                    Issue.record("Unexpected success")
                    return nil
                }, files: { raw })
            #expect(expanded?.arguments == "command " + raw)
            let quoted = ScriptInputWindow.filePayload([URL(fileURLWithPath: "/tmp/a b"), URL(fileURLWithPath: "/tmp/λ")])
            #expect(quoted == #""/tmp/a b" "/tmp/λ""#)
            #expect(ScriptInputWindow.filePayload([URL(fileURLWithPath: #"/tmp/a"b"#)]) == #""/tmp/a\"b""#)
            let options = ["sLocalBranch": ["z/local", "a/local"], "sTag": ["v1"]]
            let values = ["origin/z", "z/local", "v1", "a/local"]
            let refs = ScriptChoicePresentation(option: "sBranch", values: values, options: options)
            #expect(refs.rows.compactMap(\.originalIndex) == [3, 1, 0, 2])
            #expect(refs.rows.filter { $0.originalIndex == nil }.map { String($0.label.prefix(5)) } == ["local", "remot", "tag ―"])
            #expect(refs.initialRow == 1)
            let chooser = ScriptChoiceWindow(presentation: refs)
            #expect(chooser.window?.styleMask == [.borderless] && chooser.window?.canBecomeKey == true)
            duringModal { chooser.window?.cancelOperation(nil) }
            #expect(chooser.run(owner: nil, anchor: nil) == 3 && !chooser.accepted)
            let strings = ScriptChoicePresentation(option: "sRemote", values: ["origin", "audit-mirror"], options: [:])
            #expect(strings.rows.map(\.label) == ["audit-mirror", "origin"] && strings.initialRow == 0)
            let stringChooser = ScriptChoiceWindow(presentation: strings)
            duringModal {
                stringChooser.table.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
                stringChooser.acceptChoice()
            }
            #expect(stringChooser.run(owner: nil, anchor: nil) == 0 && stringChooser.accepted)
            #expect(ScriptChoicePresentation(option: "sBranch", values: [], options: [:]).initialRow == -1)
            let header = ScriptChoiceWindow(presentation: refs)
            duringModal {
                header.table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
                header.acceptChoice()
            }
            #expect(header.run(owner: nil, anchor: nil) == nil)
        }
    }
}

typealias LayoutAndPresentationTests = UIIntegrationTests.LayoutAndPresentationTests
