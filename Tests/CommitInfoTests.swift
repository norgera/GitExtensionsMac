@testable import GitExtensionsCore
@testable import GitCommands
@testable import GitUI
import AppKit



@MainActor
enum CommitInfoTests {
    static func run() async throws {
        testParsers()
        testPresentation()
        try await testRepositoryCapabilities()
        try await testHostedPanel()
        print("CommitInfoTests: passed")
    }

    private static func testParsers() {
        let id = testObjectID("parsers")
        check(CommitInfoCommands.branchesContaining(id, local: true, remote: true)?.arguments == ["branch", "-a", "--contains", id.string], "branch -a")
        check(CommitInfoCommands.branchesContaining(id, local: false, remote: true)?.arguments == ["branch", "-r", "--contains", id.string], "branch -r")
        check(CommitInfoCommands.branchesContaining(id, local: true, remote: false)?.arguments == ["branch", "--contains", id.string], "branch local")
        check(CommitInfoCommands.branchesContaining(id, local: false, remote: false) == nil, "no branch query")
        check(CommitInfoCommands.describe(id).arguments == ["describe", "--tags", "--first-parent", "--abbrev=40", id.string], "describe args")
        let branches = CommitInfoCommands.parseContainingBranches("* main\n  topic\n+ linked\n  remotes/origin/HEAD -> origin/main\n  remotes/origin/main\n", remote: true)
        check(branches == ["main", "topic", "linked", "remotes/origin/HEAD", "remotes/origin/main"], "branch markers and symref targets \(branches)")
        let message = CommitInfoCommands.parseMessageAndNotes("Subject\n\nBody\n\n\u{1f}\u{1f}notes\u{1f}\u{1f}A note\n")
        check(message == RepositoryCommitMessage(body: "Subject\n\nBody", notes: "A note"), "message/notes split \(message)")
        check(CommitInfoCommands.parseTagMessage("object x\ntype commit\ntag v1\ntagger T <t@e> 1 +0000\n\nRelease one\nsecond line\n\n") == "Release one\nsecond line",
              "tag message")
        check(CommitInfoCommands.parseTagMessage("object x\ntype commit\n") == nil, "short tag object")
        let full = id.string
        check(CommitInfoCommands.parseDescribe("v1.0-3-g\(full)\n", id: id) == RepositoryCommitDescription(precedingTag: "v1.0", commitCount: "3"), "describe count")
        check(CommitInfoCommands.parseDescribe("v1.0\n", id: id) == RepositoryCommitDescription(precedingTag: "v1.0", commitCount: ""), "describe exact")
        check(CommitInfoCommands.parseDescribe("rel-2-3-g0000000\n", id: id).commitCount.isEmpty, "describe foreign hash")
        check(CommitInfoCommands.parseDescribe(nil, id: id).precedingTag.isEmpty, "describe none")
        check((try? CommitInfoCommands.parseTagOrder("refs/tags/b\nrefs/tags/a\n")) == ["refs/tags/b": 0, "refs/tags/a": 1, "": 2], "tag order")
        do { _ = try CommitInfoCommands.parseTagOrder("refs/tags/a\nwarning: ignoring broken ref refs/tags/x\n"); check(false, "broken refs") }
        catch { check(error as? RepositoryCommitInfoError == .brokenRefs("warning: ignoring broken ref refs/tags/x"), "broken refs error") }
    }

    private static func commit(_ label: String, author: String = "Ann", committer: String = "Ann", sameDates: Bool = true,
                               parents: [ObjectID] = [], references: [RevisionReference] = [], kind: Commit.Kind = .revision) -> Commit {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        return Commit(id: kind == .revision ? testRevisionID(label) : .workingDirectory, shortID: label, subject: "Subject \(label)", body: "",
                      authorName: author, authorEmail: "\(author.lowercased())@example.com", authorDate: date,
                      committerName: committer, committerEmail: "\(committer.lowercased())@example.com",
                      commitDate: sameDates ? date : date.addingTimeInterval(60), parentIDs: parents, references: references, kind: kind)
    }

    private static func testPresentation() {
        let now = Date(timeIntervalSince1970: 1_700_000_000 + 3 * 86_400)
        let parent = testObjectID("parent")
        var rows = CommitInfoPresentation.header(commit("a", parents: [parent]), children: [], now: now)
        check(rows.map(\.label) == ["Author", "Date", "Commit hash", "Parent"], "header same author/date \(rows.map(\.label))")
        check(rows[0].value.first?.link == .external(URL(string: "mailto:ann@example.com")!), "author mailto")
        check(rows[1].value.first?.text.hasPrefix("3 days ago (") == true, "relative date")
        check(rows[3].value.first?.link == .commit(parent), "parent link")
        rows = CommitInfoPresentation.header(commit("b", committer: "Bob", sameDates: false, parents: [parent, testObjectID("p2")]),
                                             children: [testObjectID("child")], now: now)
        check(rows.map(\.label) == ["Author", "Author date", "Committer", "Commit date", "Commit hash", "Child", "Parents"], "header differing \(rows.map(\.label))")
        let plain = CommitInfoPresentation.plainHeader(rows)
        check(!plain.contains("Child") && !plain.contains("Parents") && !plain.contains(" ago") && plain.hasPrefix("Author: Ann <ann@example.com>\nAuthor date: "),
              "plain header \(plain)")
        rows = CommitInfoPresentation.header(commit("w", kind: .workingDirectory), children: [])
        check(rows.map(\.label) == ["Author"], "artificial header")
        let base = Date(timeIntervalSince1970: 1_000_000)
        check(CommitInfoPresentation.relativeDate(now: base.addingTimeInterval(10 * 86_400), date: base) == "1 week ago", "weeks shown")
        check(CommitInfoPresentation.relativeDate(now: base.addingTimeInterval(40 * 86_400), date: base) == "1 month ago", "months")
        check(CommitInfoPresentation.bodyAndNotes("Body", notes: "n1\nn2") == "Body\n\nNotes:\n    n1\n    n2\n", "body and notes")
        check(CommitInfoPresentation.bodyAndNotes("Body", notes: "") == "Body", "no notes")
        let candidates = CommitInfoPresentation.hashCandidates(in: "fixes abc1234 and deadbeef00@example.com, not ABC1234").map(\.hash)
        check(candidates == ["abc1234"], "hash candidates \(candidates)")
        let many = (0..<14).map { "b\($0)" }
        var preferences = CommitInfoPreferences()
        var info = CommitInfoPresentation.branchesInfo(many, preferences: preferences, limit: true)
        check(info.first?.text == "Contained in branches:\n" && info.filter { $0.link != nil }.count == 11 && info.last?.link == .showAll("branches"),
              "branches limited")
        info = CommitInfoPresentation.branchesInfo(many, preferences: preferences, limit: false)
        check(info.filter { $0.link != nil }.count == 14, "branches show all")
        check(CommitInfoPresentation.branchesInfo([], preferences: preferences, limit: true) == [.init("Contained in no branch")], "no branch")
        preferences.showContainedInBranchesLocal = false
        preferences.showContainedInBranchesRemoteIfNoLocal = true
        info = CommitInfoPresentation.branchesInfo(["main", "remotes/origin/main"], preferences: preferences, limit: true)
        check(info == [.init("Contained in no branch")], "remote hidden when a local branch contains it \(info)")
        info = CommitInfoPresentation.branchesInfo(["remotes/origin/main"], preferences: preferences, limit: true)
        check(info.last == .init("origin/main", link: .branch("origin/main")), "remote shown without local")
        let tags = CommitInfoPresentation.tagsInfo((0..<13).map { "t\($0)" }, limit: true)
        check(tags.filter { $0.link != nil }.count == 11 && tags.last?.link == .showAll("tags"), "tags limited")
        check(CommitInfoPresentation.tagsInfo([], limit: true) == [.init("Contained in no tag")], "no tag")
        check(CommitInfoPresentation.describeInfo(.init(precedingTag: "v1", commitCount: "2")).map(\.text).joined() == "Derives from tag: v1 + 2 commits", "describe")
        check(CommitInfoPresentation.describeInfo(.init(precedingTag: "", commitCount: "")).map(\.text) == ["Derives from no tag"], "no describe")
        let sortedBranches = CommitInfoPresentation.sortBranches(["zeta", "remotes/fork/main", "remotes/origin/main", "master", "topic", "remotes/origin/zeta"],
                                                                  currentBranch: "topic")
        check(sortedBranches == ["topic", "master", "remotes/origin/main", "remotes/fork/main", "zeta", "remotes/origin/zeta"], "branch comparer \(sortedBranches)")
        let sortedTags = CommitInfoPresentation.sortTags(["old", "new", "unknown"], order: ["refs/tags/new": 0, "refs/tags/old": 1])
        check(sortedTags == ["unknown", "new", "old"], "tags comparer \(sortedTags)")
        for link in [CommitInfoPresentation.Link.branch("feature/a b#1"), .tag("v1.0"), .showAll("tags"), .commit(parent)] {
            check(CommitInfoPresentation.Link(url: link.url) == link, "link round trip \(link)")
        }
    }

    private static func testRepositoryCapabilities() async throws {
        let fixture = try CommitInfoFixture.make()
        defer { fixture.remove() }
        let repo = fixture.repo
        let first = try fixture.head()
        try fixture.git(["tag", "-a", "v1", "-m", "Release one"])
        try fixture.git(["tag", "light"])
        try fixture.commit("second")
        let second = try fixture.head()
        try fixture.git(["branch", "topic", first.string])
        try fixture.git(["update-ref", "refs/remotes/origin/main", second.string])
        try fixture.git(["tag", "-a", "v2", "-m", "Release two\n\nDetails"])
        let module = GitRepositoryModule(repositoryURL: repo, git: GitProcess())
        _ = try await module.loadRepositoryState()

        let local = try await module.loadBranchesContaining(first, local: true, remote: false)
        check(Set(local) == ["main", "topic"], "local contains \(local)")
        let all = try await module.loadBranchesContaining(first, local: true, remote: true)
        check(Set(all) == ["main", "topic", "remotes/origin/main"], "all contains \(all)")
        let remote = try await module.loadBranchesContaining(second, local: false, remote: true)
        check(remote == ["origin/main"], "remote contains \(remote)")
        let tags = try await module.loadTagsContaining(first)
        check(Set(tags) == ["v1", "light", "v2"], "tags contain \(tags)")
        let tagMessage = try await module.loadTagMessage("v2")
        check(tagMessage == "Release two\n\nDetails", "annotated message \(String(describing: tagMessage))")
        let describe = try await module.loadDescribe(second)
        check(describe == RepositoryCommitDescription(precedingTag: "v2", commitCount: ""), "describe exact \(describe)")
        try fixture.commit("third")
        let third = try fixture.head()
        let derived = try await module.loadDescribe(third)
        check(derived == RepositoryCommitDescription(precedingTag: "v2", commitCount: "1"), "describe derived \(derived)")
        let order = try await module.loadTagOrder()
        check(order["refs/tags/v1"] != nil && order["refs/tags/v2"] != nil, "tag order \(order)")
        let branch = try await module.loadSelectedBranch()
        check(branch == "main", "selected branch \(branch)")
        let resolvedBranch = try await module.resolveCommit("topic")
        let resolvedTag = try await module.resolveCommit("v2")
        let resolvedPrefix = try await module.resolveCommit(String(second.string.prefix(8)))
        let missing = try await module.resolveCommit("nope")
        check(resolvedBranch == first && resolvedTag == second && resolvedPrefix == second && missing == nil, "resolve refs")


        try await module.saveNotes(second, text: "First note\n")
        let shown = try fixture.git(["notes", "show", second.string])
        check(shown == "First note\n", "note added \(shown)")
        var loaded = try await module.loadCommitMessageAndNotes(second)
        check(loaded.notes == "First note" && loaded.body.hasPrefix("second"), "message with notes \(loaded)")
        try await module.saveNotes(second, text: "Changed")
        let notes = try await module.loadNotes(second)
        check(notes == "Changed", "note replaced \(notes)")
        try await module.saveNotes(second, text: "  \n")
        let status = try fixture.gitStatus(["notes", "show", second.string])
        check(status != 0, "empty note removes it")
        loaded = try await module.loadCommitMessageAndNotes(second)
        check(loaded.notes.isEmpty, "notes gone")
        try await module.saveNotes(second, text: "")
        try fixture.git(["checkout", "-q", "--detach", first.string])
        let detached = try await module.loadSelectedBranch()
        check(detached == "(no branch)", "detached branch")
    }

    private static func testHostedPanel() async throws {
        let fixture = try CommitInfoFixture.make()
        defer { fixture.remove() }
        try fixture.git(["tag", "-a", "v1", "-m", "Release one"])
        try fixture.commit("Fixes bug from \(String(try fixture.head().string.prefix(9)))")
        let head = try fixture.head()
        try fixture.git(["notes", "add", "-m", "Reviewed", head.string])
        let module = GitRepositoryModule(repositoryURL: fixture.repo, git: GitProcess())
        let state = try await module.loadRepositoryState()
        _ = state

        let store = AppSettingsStore.shared
        let savedPreferences = store.commitInfoPreferences
        let savedGrid = store.revisionGridPreferences
        defer { store.saveCommitInfoPreferences(savedPreferences); store.saveRevisionGridPreferences(savedGrid) }
        store.saveCommitInfoPreferences(CommitInfoPreferences())
        var grid = savedGrid
        grid.showAnnotatedTagsMessages = true
        store.saveRevisionGridPreferences(grid)

        let controller = CommitDetailViewController()
        controller.source = module
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        controller.repositoryChanged()
        let parentID = try fixture.revParse("HEAD~1")
        let tagRef = RevisionReference(id: "refs/tags/v1", name: "v1", kind: .tag, isAnnotated: true)
        let parentCommit = Commit(id: .object(parentID), shortID: String(parentID.string.prefix(7)), subject: "Initial", body: "",
                                  authorName: "Fixture", authorEmail: "fixture@example.com", authorDate: Date(), committerName: "Fixture",
                                  committerEmail: "fixture@example.com", commitDate: Date(), parentIDs: [], references: [tagRef])
        var navigated: [RevisionID] = []
        controller.onGoToRevision = { navigated.append($0) }
        controller.apply(commit: parentCommit, children: [head])
        for _ in 0..<500 where !(controller.revisionInfoString.contains("Derives from tag")
                                  && controller.revisionInfoString.contains("Contained in tags") && controller.revisionInfoString.contains("v1: ")) {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let info = controller.revisionInfoString
        check(info.contains("v1: Release one"), "annotated tag message \(info)")
        check(info.contains("Contained in branches:\nmain") && info.contains("Contained in tags:\nv1") && info.contains("Derives from tag: v1"),
              "contained-in and describe \(info)")
        check(controller.headerText.string.contains("Child:") && controller.headerText.string.contains("Commit hash:\t\(parentID.string)"), "header text")


        var menu = controller.contextMenu(link: nil)
        check(menu.items.map(\.title) == ["Copy commit info", "", "Show local branches containing this commit",
                                          "Show remote branches containing this commit",
                                          "Show remote branches only when no local branch contains this commit",
                                          "Show tags containing this commit", "Show messages of annotated tags",
                                          "Show the most recent tag this commit derives from", "", "Add notes"], "menu \(menu.items.map(\.title))")
        check(menu.items[2].state == .on && menu.items[3].state == .off && menu.items[5].state == .on && menu.items[6].state == .on,
              "menu check states")
        check(menu.items.last?.isEnabled == true && menu.items.last?.keyEquivalent == "n", "Add notes enabled with shortcut")
        let link = CommitInfoPresentation.Link.branch("main").url
        menu = controller.contextMenu(link: link)
        check(menu.items.first?.title == "Copy link (\(link.absoluteString))", "copy link shown for a link")


        (controller.contextMenu(link: nil).items[5] as? DashboardClosureMenuItem).map { _ = $0.target?.perform($0.action, with: $0) }
        check(store.commitInfoPreferences.showContainedInTags == false, "toggle persisted")
        for _ in 0..<300 where controller.revisionInfoString.contains("Contained in tags") || !controller.revisionInfoString.contains("Derives") {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        check(!controller.revisionInfoString.contains("Contained in tags"), "tags section hidden")


        NSPasteboard.general.clearContents()
        (controller.contextMenu(link: nil).items[0] as? DashboardClosureMenuItem).map { _ = $0.target?.perform($0.action, with: $0) }
        let copied = NSPasteboard.general.string(forType: .string) ?? ""
        check(copied.hasPrefix("Author: Fixture <fixture@example.com>") && copied.contains("\n\nInitial") && !copied.contains("Child"), "copy commit info \(copied)")


        controller.execute(CommitInfoPresentation.Link.commit(head).url)
        controller.execute(CommitInfoPresentation.Link.branch("main").url)
        for _ in 0..<200 where navigated.count < 2 { try await Task.sleep(nanoseconds: 10_000_000) }
        check(navigated == [.object(head), .object(head)], "link navigation \(navigated)")


        let headCommit = Commit(id: .object(head), shortID: String(head.string.prefix(7)), subject: "Fixes bug", body: "",
                                authorName: "Fixture", authorEmail: "fixture@example.com", authorDate: Date(), committerName: "Fixture",
                                committerEmail: "fixture@example.com", commitDate: Date(), parentIDs: [parentID], references: [])
        controller.apply(commit: headCommit, children: [])
        for _ in 0..<300 where !controller.messageText.string.contains("Notes:") { try await Task.sleep(nanoseconds: 10_000_000) }
        check(controller.messageText.string.contains("Notes:\n    Reviewed"), "notes rendered \(controller.messageText.string)")
        let storage = controller.messageText.textStorage!
        let hashRange = (storage.string as NSString).range(of: String(parentID.string.prefix(9)))
        check(hashRange.location != NSNotFound && (storage.attribute(.link, at: hashRange.location, effectiveRange: nil) as? URL)
              == CommitInfoPresentation.Link.commit(parentID).url, "hash linked")


        let worktree = commit("w", kind: .workingDirectory)
        controller.apply(commit: worktree, children: [])
        check(controller.revisionInfoString.isEmpty && controller.contextMenu(link: nil).items.last?.isEnabled == false, "artificial commit")
        window.close()
    }

    private static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else { preconditionFailure("CommitInfoTests: \(message)") }
    }
}

private final class CommitInfoFixture {
    let root: URL
    var repo: URL { root.appendingPathComponent("repo", isDirectory: true) }
    private init(root: URL) { self.root = root }

    static func make() throws -> CommitInfoFixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("GitExtensionsMac-CommitInfo-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let fixture = CommitInfoFixture(root: root.resolvingSymlinksInPath())
        try fixture.run(["init", "-q", "-b", "main", fixture.repo.path], in: fixture.root)
        for (key, value) in [("user.name", "Fixture"), ("user.email", "fixture@example.com"), ("commit.gpgsign", "false"), ("tag.gpgsign", "false")] {
            try fixture.git(["config", key, value])
        }
        try fixture.commit("Initial")
        return fixture
    }

    func remove() { try? FileManager.default.removeItem(at: root) }

    func commit(_ message: String) throws {
        try git(["commit", "-q", "--allow-empty", "-m", message])
    }

    func head() throws -> ObjectID { try revParse("HEAD") }

    func revParse(_ expression: String) throws -> ObjectID {
        try ObjectID.parse(try git(["rev-parse", expression]).trimmingCharacters(in: .whitespacesAndNewlines))
    }

    @discardableResult
    func git(_ arguments: [String]) throws -> String { try run(arguments, in: repo) }

    func gitStatus(_ arguments: [String]) throws -> Int32 {
        let process = try launch(arguments, in: repo)
        process.waitUntilExit()
        return process.terminationStatus
    }

    private func launch(_ arguments: [String], in directory: URL, stdout: Pipe? = nil) throws -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = directory
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_EDITOR"] = "true"
        environment["LC_ALL"] = "C"
        process.environment = environment
        process.standardOutput = stdout ?? FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        return process
    }

    @discardableResult
    private func run(_ arguments: [String], in directory: URL) throws -> String {
        let pipe = Pipe()
        let process = try launch(arguments, in: directory, stdout: pipe)
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { preconditionFailure("git \(arguments.joined(separator: " ")) failed") }
        return String(decoding: data, as: UTF8.self)
    }
}
