import Foundation
import AppKit
@testable import GitExtensionsCore
@testable import GitCommands
@testable import GitUI

enum RepositoryHostingTests {
    actor Router {
        var requests: [URLRequest] = []
        private var routes: [(String, String, Int, String, String?)] = []
        func on(_ method: String, _ path: String, query: String? = nil, status: Int = 200, _ body: String) { routes.insert((method, path, status, body, query), at: 0) }
        func send(_ request: URLRequest) throws -> (Data, HTTPURLResponse) {
            requests.append(request)
            let path = request.url!.path
            guard let route = routes.first(where: { $0.0 == (request.httpMethod ?? "GET") && $0.1 == path
                && ($0.4 == nil || (request.url!.query ?? "").contains($0.4!)) }) else {
                return (Data("{}".utf8), HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!)
            }
            return (Data(route.3.utf8), HTTPURLResponse(url: request.url!, statusCode: route.2, httpVersion: "HTTP/1.1", headerFields: nil)!)
        }
        func matching(_ method: String, _ path: String) -> [URLRequest] { requests.filter { $0.httpMethod == method && $0.url?.path == path } }
    }

    static let sha = String(repeating: "a", count: 40)
    static let sha2 = String(repeating: "b", count: 40)

    static func repositoryJSON(_ owner: String, _ name: String = "repo", defaultBranch: String = "main", fork: Bool = false,
                               parent: String? = nil, homepage: String? = nil) -> String {
        let parentJSON = parent.map { #","parent":{"clone_url":"https://github.com/\#($0)/\#(name).git","ssh_url":"git@github.com:\#($0)/\#(name).git","owner":{"login":"\#($0)"}}"# } ?? ""
        let home = homepage.map { "\"\($0)\"" } ?? "null"
        return #"{"name":"\#(name)","full_name":"\#(owner)/\#(name)","description":"About \#(name)","homepage":\#(home),"owner":{"login":"\#(owner)"},"private":false,"fork":\#(fork),"forks_count":3,"clone_url":"https://github.com/\#(owner)/\#(name).git","ssh_url":"git@github.com:\#(owner)/\#(name).git","default_branch":"\#(defaultBranch)"\#(parentJSON)}"#
    }
    static func pullRequestJSON(number: Int = 7, headOwner: String? = "contributor") -> String {
        let repo = headOwner.map { #"{"owner":{"login":"\#($0)"},"clone_url":"https://github.com/\#($0)/repo.git","ssh_url":"git@github.com:\#($0)/repo.git"}"# } ?? "null"
        return """
        {"number":\(number),"title":"Fix λ","body":"Description","state":"open","html_url":"https://github.com/owner/repo/pull/\(number)",
         "user":{"login":"contributor"},"created_at":"2026-01-02T03:04:05Z",
         "head":{"label":"contributor:topic","ref":"topic","sha":"\(sha)","repo":\(repo)},
         "base":{"label":"owner:main","ref":"main","sha":"\(sha2)","repo":null}}
        """
    }

    static func run() async throws {
        try testIdentityAndCommands()
        try await testClient()
        try await testBuildAdapters()
        try await testRealRepositoryHandoffs()
        try await MainActor.run { try testRegistryMenusAndGrid() }
        try await testResolverAndWatcher()
        try await testSettingsStore()
        try await testPullRequestsWindow()
        try await testCreatePullRequestWindow()
        try await testForkAndCloneWindow()
        try await testGitHubPluginIssueTemplates()
        print("RepositoryHostingTests: passed")
    }

    private static func testIdentityAndCommands() throws {
        let github = HostedRepositoryIdentity.parse("git@github.com:owner/repo.git")!
        precondition(github.webURL.absoluteString == "https://github.com/owner/repo")
        precondition(github == HostedRepositoryIdentity.parse("https://discard-me:never-display@github.com/owner/repo.git"))
        precondition(github.createPullRequestURL(branch: "topic") == nil, "GitHub PRs use the Create Pull Request form")
        precondition(github.blameURL(commit: try! ObjectID(parsing: sha), file: "dir/a b.txt", line: 12)?.absoluteString
                     == "https://github.com/owner/repo/blame/\(sha)/dir/a%20b.txt#L12")
        for remote in ["https://evil.example/dev.azure.com/org/project/_git/repo", "https://dev.azure.com.evil.example/org/project/_git/repo", "https://github.com.evil.example/owner/repo", "file:///github.com/owner/repo", "https://github.com/owner/repo?token=secret", "https://github.com/owner/repo/extra"] {
            precondition(HostedRepositoryIdentity.parse(remote) == nil, "False host detection: \(remote)")
        }
        let azure = HostedRepositoryIdentity.parse("https://user:discard-me@dev.azure.com/org/Project%20Name/_git/repo")!
        precondition(azure.webURL.absoluteString == "https://dev.azure.com/org/Project%20Name/_git/repo")
        precondition(azure.projectURL?.absoluteString == "https://dev.azure.com/org/Project%20Name")
        precondition(azure.createPullRequestURL(branch: "topic/one")?.absoluteString
                     == "https://dev.azure.com/org/Project%20Name/_git/repo/pullrequestcreate?sourceRef=topic%2Fone")
        precondition(azure.createPullRequestURL(branch: "topic/one")?.user == nil)
        precondition(HostedRepositoryIdentity.parse("git@ssh.dev.azure.com:v3/org/project/repo")?.webURL.absoluteString == "https://dev.azure.com/org/project/_git/repo")
        precondition(HostedRepositoryIdentity.parse("git@vs-ssh.visualstudio.com:v3/org/project/repo")?.projectURL?.absoluteString == "https://org.visualstudio.com/project")
        precondition(HostedRepositoryIdentity.parse("https://org.visualstudio.com/DefaultCollection/project/_git/repo")?.webURL.absoluteString == "https://org.visualstudio.com/project/_git/repo")
        precondition(HostedRepositoryIdentity.parse("git@vs-ssh.visualstudio.com:v3/user@evil/project/repo") == nil)

        func remote(_ name: String, _ url: String, disabled: Bool = false) -> RepositoryRemoteConfiguration {
            .init(name: name, fetchURL: url, pushURL: nil, puttyKeyFile: nil, color: nil, prefix: nil, pushRefSpecs: [], isDisabled: disabled)
        }
        let hosted = HostedRemote.gitHubRemotes([remote("origin", "https://github.com/me/repo.git"), remote("azure", "https://dev.azure.com/o/p/_git/r"),
                                                 remote("old", "git@github.com:x/y.git", disabled: true), remote("upstream", "git@github.com:owner/repo.git")])
        precondition(hosted.map(\.name) == ["origin", "upstream"] && hosted[0].usesHTTPS && !hosted[1].usesHTTPS && hosted[1].displayData == "owner/repo")

        precondition(RepositoryHostingCommands.fetchPullRequest(url: "https://github.com/c/r.git", headRef: "topic", localBranch: "pr/n7_topic").arguments
                     == ["fetch", "--no-tags", "--progress", "https://github.com/c/r.git", "topic:pr/n7_topic"])
        precondition(RepositoryHostingCommands.fetchRemoteBranch(remote: "contributor", ref: "topic").arguments
                     == ["fetch", "--no-tags", "--progress", "contributor", "topic:contributor/topic"])
        precondition(RepositoryHostingCommands.checkout(remote: "contributor", ref: "topic").arguments == ["checkout", "contributor/topic"])
        precondition(RepositoryHostingCommands.fetchPullRequest(url: "u", headRef: "r", localBranch: "b").accessesRemote)
        precondition(RepositoryHostingCommands.previousCommitMessage("origin/topic").arguments
                     == ["log", "-z", "-n", "1", "--pretty=format:%B", "--end-of-options", "origin/topic", "--"])

        let clone = GitRepositoryCreationCommands.clone(source: "git@github.com:o/r.git", destination: URL(fileURLWithPath: "/tmp/x"),
            isBare: false, initializesSubmodules: false, downloadsFullHistory: true, branch: .remoteHEAD, depth: 5)
        precondition(clone.arguments == ["clone", "-v", "--depth", "5", "--progress", "git@github.com:o/r.git", "/tmp/x"])

        precondition(formatBuildDuration(nil) == "" && formatBuildDuration(3_723_000) == "02:03", "TimeSpan mm:ss drops hours")
        precondition(replaceBuildServerVariables("https://x/{cRepoProject}/{cRepoShortName}", remoteURL: "https://h/group/name.git") == "https://x/group/name")
        precondition(AzureDevOpsProjectURL.project(fromRemote: "https://org.visualstudio.com/DefaultCollection/Proj/_git/repo") == "https://org.visualstudio.com/Proj")
        precondition(AzureDevOpsProjectURL.project(fromRemote: "git@ssh.dev.azure.com:v3/org/Proj/repo") == "https://dev.azure.com/org/Proj")
        precondition(AzureDevOpsProjectURL.project(fromRemote: "https://host:8080/tfs/DefaultCollection/Proj/_git/repo") == "https://host:8080/tfs/DefaultCollection/Proj")
        precondition(AzureDevOpsProjectURL.tokenManagementURL(project: "https://dev.azure.com/org/Proj")?.absoluteString == "https://dev.azure.com/org/_details/security/tokens")
        precondition(AzureDevOpsProjectURL.parseBuildURL("https://dev.azure.com/org/Proj/_build/results?buildId=42&view=logs")! == ("https://dev.azure.com/org/Proj", 42))
        precondition(AzureDevOpsProjectURL.parseBuildURL("https://dev.azure.com/org/Proj/_build") == nil)
    }

    private static func testClient() async throws {
        let github = HostedRepositoryIdentity.parse("git@github.com:owner/repo.git")!
        let router = Router()
        await router.on("GET", "/repos/owner/repo/pulls", "[\(pullRequestJSON())]")
        await router.on("POST", "/repos/owner/repo/pulls", status: 201, pullRequestJSON())
        await router.on("PATCH", "/repos/owner/repo/pulls/7", pullRequestJSON())
        await router.on("GET", "/repos/owner/repo/pulls/7/commits", #"[{"sha":"\#(sha2)","commit":{"author":{"name":"Author <x>","date":"2026-01-02T03:05:00Z"},"message":"Commit message"}}]"#)
        await router.on("GET", "/repos/owner/repo/issues/7/comments", #"[{"id":1,"body":"Later comment","user":{"login":"reviewer"},"html_url":"https://github.com/c","created_at":"2026-01-03T00:00:00Z"},{"id":2,"body":"Early comment","user":{"login":"early"},"html_url":"https://github.com/c","created_at":"2026-01-01T00:00:00Z"}]"#)
        await router.on("GET", "/issues", #"[{"number":3,"title":"Bug","body":"Details","updated_at":"2026-01-01T00:00:00Z","repository":{"name":"repo","owner":{"login":"owner"}}}]"#)
        await router.on("GET", "/user/repos", "[\(repositoryJSON("me"))]")
        let client = RepositoryHostClient(identity: github, token: "fixture-only-token", transport: { try await router.send($0) })
        let list = try await client.pullRequests()
        precondition(list.count == 1 && list[0].number == 7 && list[0].user.login == "contributor" && list[0].fetchBranch == "pr/n7_topic")
        precondition(list[0].head.repo?.cloneURL(https: false) == "git@github.com:contributor/repo.git" && list[0].base.repo == nil)
        precondition(list[0].created_at == ISO8601DateFormatter().date(from: "2026-01-02T03:04:05Z"))
        _ = try await client.createPullRequest(head: "contributor:topic", base: "main", title: " Fix λ ", body: " body ")
        _ = try await client.closePullRequest(7)
        let entries = try await client.discussion(list[0])
        precondition(entries.map(\.author) == ["early", "contributor", "Author <x>", "reviewer"], "discussion ordered by creation")
        precondition(entries[2].commit == sha2 && entries[1].body == "Description")
        let issues = try await client.assignedIssues()
        precondition(issues.first?.commitTemplate == "\nFixes #3 : Bug\n\nDetails\n")
        _ = try await client.myRepositories()
        let requests = await router.requests
        precondition(requests[0].url?.absoluteString == "https://api.github.com/repos/owner/repo/pulls?per_page=100&page=1")
        precondition(requests[0].value(forHTTPHeaderField: "Authorization") == "Bearer fixture-only-token")
        let create = await router.matching("POST", "/repos/owner/repo/pulls")[0]
        let payload = try JSONSerialization.jsonObject(with: create.httpBody!) as! [String: String]
        precondition(payload == ["head": "contributor:topic", "base": "main", "title": "Fix λ", "body": "body"])
        let issueQuery = URLComponents(url: await router.matching("GET", "/issues")[0].url!, resolvingAgainstBaseURL: false)!.queryItems!
        precondition(issueQuery.contains(.init(name: "filter", value: "assigned")) && issueQuery.contains(.init(name: "state", value: "open")) && issueQuery.contains(.init(name: "pulls", value: "false")))
        let userRepositories = await router.matching("GET", "/user/repos")
        precondition(userRepositories[0].url!.query!.contains("type=all"))

        for status in [401, 403, 404, 422, 500, 302] {
            let failure = Router(); await failure.on("GET", "/repos/owner/repo/pulls", status: status, "server diagnostic containing a secret")
            let client = RepositoryHostClient(identity: github, token: "fixture-only-token", transport: { try await failure.send($0) })
            do { _ = try await client.pullRequests(); preconditionFailure("HTTP failure accepted") }
            catch { precondition(!error.localizedDescription.contains("secret") && !error.localizedDescription.contains("fixture-only-token")) }
        }
        let malformed = Router(); await malformed.on("GET", "/repos/owner/repo/pulls", "not JSON")
        do { _ = try await RepositoryHostClient(identity: github, token: "", transport: { try await malformed.send($0) }).pullRequests(); preconditionFailure("Malformed response accepted") }
        catch RepositoryHostError.invalidResponse { }
        let cancelled = Task {
            try await RepositoryHostClient(identity: github, token: "", transport: { _ in
                try await Task.sleep(for: .seconds(60)); throw RepositoryHostError.invalidResponse
            }).pullRequests()
        }
        cancelled.cancel()
        do { _ = try await cancelled.value; preconditionFailure("Cancelled request completed") }
        catch is CancellationError { }
    }

    private static func testBuildAdapters() async throws {
        let runs = Router()
        await runs.on("GET", "/api/v3/repos/owner/repo/actions/runs", """
        {"workflow_runs":[
         {"id":11,"name":"CI","head_sha":"\(sha)","status":"completed","conclusion":"failure","html_url":"https://ghe/r/1","created_at":"2026-01-01T00:00:00Z","updated_at":"2026-01-01T00:02:05Z","run_started_at":"2026-01-01T00:00:05Z","run_number":4},
         {"id":12,"name":null,"head_sha":"\(sha2)","status":"completed","conclusion":"skipped","html_url":null,"created_at":"2026-01-01T00:00:00Z","updated_at":"2026-01-01T00:00:00Z","run_number":5}]}
        """)
        let actions = GitHubActionsBuildAdapter(apiURL: "https://ghe.example/api/v3/", owner: "owner", repository: "repo", token: "gha-fixture", transport: { try await runs.send($0) })!
        precondition(actions.uniqueKey == "https://ghe.example/api/v3/repos/owner/repo")
        let since = ISO8601DateFormatter().date(from: "2026-01-01T10:00:00Z")!
        let finished = try await actions.finishedBuilds(since: since)
        precondition(finished.count == 2 && finished[0].status == .failure && finished[0].description == "CI #4 (failure)")
        precondition(finished[0].duration == 120_000 && finished[0].revisions == [.object(try! ObjectID(parsing: sha))] && !finished[0].showInBuildReportTab)
        precondition(finished[1].status == .success && finished[1].description == "workflow #5 (skipped)" && finished[1].url == nil)
        let repeated = try await actions.finishedBuilds(since: nil)
        precondition(repeated.isEmpty, "unchanged runs are not re-emitted")
        let request = await runs.requests[0]
        precondition(request.url!.absoluteString == "https://ghe.example/api/v3/repos/owner/repo/actions/runs?page=1&per_page=100&status=completed&created=%3E%3D2026-01-01T10%3A00%3A00Z")
        precondition(request.value(forHTTPHeaderField: "Authorization") == "Bearer gha-fixture" && request.value(forHTTPHeaderField: "Accept") == "application/json")
        precondition(GitHubActionsBuildAdapter(apiURL: nil, owner: " ", repository: "r", token: nil) == nil)
        let running = Router(); await running.on("GET", "/repos/o/r/actions/runs", #"{"workflow_runs":[{"id":1,"head_sha":"\#(sha)","status":"queued","conclusion":null,"created_at":"2026-01-01T00:00:00Z","updated_at":"2026-01-01T00:00:00Z","run_number":1}]}"#)
        let queued = try await GitHubActionsBuildAdapter(apiURL: nil, owner: "o", repository: "r", token: nil, transport: { try await running.send($0) })!.runningBuilds()
        precondition(queued.first?.status == .inProgress && queued.first?.description == "workflow #1 (queued)")
        let runningRequest = await running.requests[0]
        precondition(runningRequest.url!.query!.contains("status=in_progress") && runningRequest.value(forHTTPHeaderField: "Authorization") == nil)
        let missing = Router()
        do { _ = try await GitHubActionsBuildAdapter(apiURL: nil, owner: "o", repository: "r", token: nil, transport: { try await missing.send($0) })!.runningBuilds(); preconditionFailure() }
        catch BuildServerError.notFound(let message) { precondition(message.contains("Check owner/repository settings")) }

        let azure = Router()
        await azure.on("GET", "/org/Proj/_apis/git/repositories/repo", #"{"id":"repo-guid"}"#)
        await azure.on("GET", "/org/Proj/_apis/build/builds", """
        {"value":[
         {"sourceVersion":"\(sha)","status":"completed","buildNumber":"20260101.1","result":"failed","definition":{"id":1,"name":"CI"},"_links":{"web":{"href":"https://dev.azure.com/b/1"}},"startTime":"2026-01-01T00:00:00.1234567Z","finishTime":"2026-01-01T00:01:30Z"},
         {"sourceVersion":"\(sha)","status":"completed","buildNumber":"20260101.2","result":"succeeded","definition":{"id":1,"name":"CI"},"_links":{"web":{"href":"https://dev.azure.com/b/2"}},"startTime":"2026-01-01T01:00:00Z","finishTime":"2026-01-01T01:00:10Z"},
         {"sourceVersion":"\(sha2)","status":"completed","buildNumber":"PR.1","result":"partiallySucceeded","reason":"validateShelveset","parameters":"{\\"system.pullRequest.sourceCommitId\\":\\"\(String(repeating: "c", count: 40))\\",\\"system.pullRequest.pullRequestId\\":\\"9\\"}","repository":{"url":"https://dev.azure.com/org/Proj/_git/repo"},"definition":{"id":1,"name":"CI"},"startTime":"2026-01-01T00:00:00Z","finishTime":"2026-01-01T00:00:01Z"}]}
        """)
        let settings = AzureDevOpsBuildAdapter.Settings(projectURL: "https://dev.azure.com/org/Proj", buildDefinitionFilter: "C.*", repositoryName: "repo")
        precondition(!AzureDevOpsBuildAdapter.Settings(projectURL: "https://x", buildDefinitionFilter: "(").isValid)
        let adapter = try AzureDevOpsBuildAdapter(settings: settings, projectURL: settings.projectURL, pat: "pat-fixture", credentialPassword: "unused", transport: { try await azure.send($0) })
        await azure.on("GET", "/org/Proj/_apis/build/definitions", #"{"count":2,"value":[{"id":1,"name":"CI"},{"id":2,"name":"Nightly"}]}"#)
        await azure.on("GET", "/org/Proj/_apis/build/definitions", query: "name=", #"{"count":0,"value":[]}"#)
        let ignored = try await adapter.finishedBuilds(since: nil)
        precondition(ignored.isEmpty, "Azure ignores the first finished-builds call")
        let azureFinished = try await adapter.finishedBuilds(since: nil)
        precondition(azureFinished.count == 2)
        precondition(azureFinished[0].id == "20260101.2" && azureFinished[0].status == .success && azureFinished[0].description == "00:10 20260101.2")
        precondition(azureFinished[0].tooltip == "20260101.2 ✔ - 00:10 [CI]")
        precondition(azureFinished[1].revisions == [.object(try! ObjectID(parsing: String(repeating: "c", count: 40)))] && azureFinished[1].status == .unstable)
        precondition(azureFinished[1].pullRequestURL?.absoluteString == "https://dev.azure.com/org/Proj/_git/repo/pullrequest/9" && azureFinished[1].tooltip!.hasSuffix("\nPR #9"))
        let azureRequests = await azure.requests
        precondition(azureRequests.first!.value(forHTTPHeaderField: "Authorization") == "Basic " + Data(":pat-fixture".utf8).base64EncodedString())
        precondition(azureRequests.contains { $0.url!.query == "api-version=6.0&name=C.*&repositoryId=repo-guid&repositoryType=TfsGit" })
        precondition(azureRequests.last!.url!.query!.contains("definitions=1&statusFilter=completed&api-version=2.0"))
        let second = try AzureDevOpsBuildAdapter(settings: settings, projectURL: settings.projectURL, pat: nil, credentialPassword: "helper-token", transport: { try await azure.send($0) })
        let before = await azure.requests.count
        _ = try await second.finishedBuilds(since: nil)
        let cached = try await second.finishedBuilds(since: nil)
        precondition(cached.count >= 2)
        let after = await azure.requests
        precondition(after.count == before + 1 && after.last!.url!.query!.contains("minTime=2026-01-01T01:00:11&api-version=4.1"))
        precondition(after.last!.value(forHTTPHeaderField: "Authorization") == "Bearer helper-token")
        await second.repositoryChanged()
        func build(_ source: String, _ start: String?) -> AzureDevOpsBuildAdapter.Build {
            try! HostHTTP.decoder().decode(AzureDevOpsBuildAdapter.Build.self, from: Data(#"{"sourceVersion":"\#(source)","status":"inProgress"\#(start.map { #","startTime":"\#($0)""# } ?? "")}"#.utf8))
        }
        let filtered = AzureDevOpsBuildAdapter.filterRunning([build(sha, nil), build(sha, "2026-01-01T02:00:00Z"), build(sha, "2026-01-01T01:00:00Z"), build(sha2, nil)])
        precondition(filtered.count == 2 && filtered[0].startTime == ISO8601DateFormatter().date(from: "2026-01-01T01:00:00Z"))
        let inProgress = AzureDevOpsBuildAdapter.buildInfo(build(sha, "2026-01-01T00:00:00Z"), now: ISO8601DateFormatter().date(from: "2026-01-01T00:01:05Z")!)!
        precondition(inProgress.status == .inProgress && inProgress.description == "01:05 " && inProgress.tooltip == " ▶️ - 01:05 []")
        let denied = Router(); await denied.on("GET", "/o/P/_apis/build/definitions", status: 401, "denied")
        let deniedAdapter = try AzureDevOpsBuildAdapter(settings: .init(projectURL: "https://dev.azure.com/o/P"), projectURL: "https://dev.azure.com/o/P", pat: "bad", credentialPassword: nil, transport: { try await denied.send($0) })
        do { _ = try await deniedAdapter.runningBuilds(); preconditionFailure() }
        catch BuildServerError.initialization(let message, let badToken, _) { precondition(badToken && message == AzureDevOpsBuildAdapter.badTokenMessage) }
        let afterDenied = try await deniedAdapter.runningBuilds()
        let deniedCount = await denied.requests.count
        precondition(afterDenied.isEmpty && deniedCount == 1)
        do { _ = try AzureDevOpsBuildAdapter(settings: .init(projectURL: "not a url"), projectURL: "not a url", pat: nil, credentialPassword: nil); preconditionFailure() } catch { }
        await adapter.repositoryChanged()
    }

    private static func git(_ arguments: [String], in directory: URL, input: String? = nil) -> (Int32, String) {
        let process = Process(); let out = Pipe(); let inPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git"); process.arguments = arguments
        process.currentDirectoryURL = directory; process.standardOutput = out; process.standardError = Pipe(); process.standardInput = inPipe
        var environment = ProcessInfo.processInfo.environment; environment["GIT_TERMINAL_PROMPT"] = "0"; process.environment = environment
        try! process.run(); try? inPipe.fileHandleForWriting.write(contentsOf: Data((input ?? "").utf8)); try? inPipe.fileHandleForWriting.close()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
    }

    private static func testRealRepositoryHandoffs() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("GitExtensionsMac-Hosting-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fork = root.appendingPathComponent("fork"), main = root.appendingPathComponent("main repo")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        precondition(git(["init", "-q", "--initial-branch=main", fork.path], in: root).0 == 0)
        for directory in [fork] {
            _ = git(["config", "user.name", "Hosting Fixture"], in: directory); _ = git(["config", "user.email", "hosting@example.com"], in: directory)
        }
        precondition(git(["commit", "-q", "--allow-empty", "-m", "Base"], in: fork).0 == 0)
        precondition(git(["checkout", "-q", "-b", "topic"], in: fork).0 == 0)
        precondition(git(["commit", "-q", "--allow-empty", "-m", "Topic subject\nsecond line\n\nBody"], in: fork).0 == 0)
        let topic = git(["rev-parse", "topic"], in: fork).1.trimmingCharacters(in: .whitespacesAndNewlines)
        precondition(git(["checkout", "-q", "main"], in: fork).0 == 0)
        precondition(git(["clone", "-q", fork.path, main.path], in: root).0 == 0)
        try FileManager.default.createDirectory(at: main.appendingPathComponent(".github"), withIntermediateDirectories: true)
        try "## Template".write(to: main.appendingPathComponent(".github/PULL_REQUEST_TEMPLATE.md"), atomically: true, encoding: .utf8)

        let module = GitRepositoryModule(repositoryURL: main)
        _ = try await module.loadRepositoryState()
        let template = try await module.pullRequestTemplate()
        let subject = try await module.pullRequestSubject(remote: "origin", branch: "topic")
        let missingSubject = try await module.pullRequestSubject(remote: "origin", branch: "missing")
        precondition(template == "## Template" && subject == "Topic subject" && missingSubject == "", "first line of %B")

        let fetched = try await module.runHostingCommand(RepositoryHostingCommands.fetchPullRequest(url: fork.path, headRef: "topic", localBranch: "pr/n7_topic"), output: { _ in })
        precondition(fetched.succeeded && git(["rev-parse", "refs/heads/pr/n7_topic"], in: main).1.hasPrefix(topic))
        try await module.saveRemote(.init(originalName: nil, name: "contributor", fetchURL: fork.path, pushURL: nil, puttyKeyFile: nil, color: nil, prefix: nil))
        let fetchedBranch = try await module.runHostingCommand(RepositoryHostingCommands.fetchRemoteBranch(remote: "contributor", ref: "topic"), output: { _ in })
        let checkedOut = try await module.runHostingCommand(RepositoryHostingCommands.checkout(remote: "contributor", ref: "topic"), output: { _ in })
        precondition(fetchedBranch.succeeded && checkedOut.succeeded)
        precondition(git(["symbolic-ref", "HEAD"], in: main).1.trimmingCharacters(in: .whitespacesAndNewlines) == "refs/heads/contributor/topic")
        precondition(git(["rev-parse", "HEAD"], in: main).1.hasPrefix(topic))
        precondition(git(["config", "remote.contributor.url"], in: main).1.trimmingCharacters(in: .whitespacesAndNewlines) == fork.path)
        let missingCheckout = try await module.runHostingCommand(RepositoryHostingCommands.checkout(remote: "contributor", ref: "missing"), output: { _ in })
        precondition(!missingCheckout.succeeded)

        _ = git(["config", "--add", "credential.helper", ""], in: main)
        _ = git(["config", "--add", "credential.helper", "!f() { test \"$1\" = get && printf \"username=u\\\\npassword=helper-fixture\\\\n\"; }; f"], in: main)
        let helperPassword = await module.hostCredentialPassword(for: URL(string: "https://dev.azure.com.invalid/org/Proj")!)
        precondition(helperPassword == "helper-fixture")
        _ = git(["config", "--unset-all", "credential.helper"], in: main)
        _ = git(["config", "--add", "credential.helper", ""], in: main)
        let noPassword = await module.hostCredentialPassword(for: URL(string: "https://dev.azure.com.invalid/org/Proj")!)
        precondition(noPassword == nil)
    }

    @MainActor
    private static func testRegistryMenusAndGrid() throws {
        var notifications = 0
        let observer = NotificationCenter.default.addObserver(forName: CommitTemplateRegistry.didChange, object: nil, queue: nil) { _ in notifications += 1 }
        defer { NotificationCenter.default.removeObserver(observer) }
        var evaluated = 0
        CommitTemplateRegistry.register("3: Bug", text: { evaluated += 1; return "Fixes #3" }, icon: nil, isRegex: false)
        CommitTemplateRegistry.register("3: Bug", text: { "duplicate" }, icon: nil, isRegex: false)
        precondition(CommitTemplateRegistry.templates.filter { $0.name == "3: Bug" }.count == 1 && evaluated == 0)
        precondition(CommitTemplateRegistry.templates.first { $0.name == "3: Bug" }!.text() == "Fixes #3" && evaluated == 1)
        CommitTemplateRegistry.unregister("3: Bug"); CommitTemplateRegistry.unregister("3: Bug")
        precondition(!CommitTemplateRegistry.templates.contains { $0.name == "3: Bug" } && notifications == 2)

        let commit = Commit(id: testRevisionID("h1"), shortID: "h1", subject: "s", body: "", authorName: "a", authorEmail: "e",
                            authorDate: Date(), committerName: "a", committerEmail: "e", commitDate: Date(), parentIDs: [], references: [], kind: .revision)
        func titles(_ status: BuildInfo?) -> [String] {
            var context = RevisionContextMenuContext(focusedCommit: commit, selectedCommits: [commit], history: [commit], currentBranchName: nil)
            context.buildStatus = status
            return RevisionContextMenuBuilder.build(context).compactMap { if case .command(let id, _, _) = $0 { return id } else { return nil } }
        }
        precondition(!titles(nil).contains("revision.buildReport") && !titles(nil).contains("revision.pullRequestPage"))
        let info = BuildInfo(status: .failure, description: "CI #1", revisions: [commit.id], url: URL(string: "https://ci/1"), pullRequestURL: URL(string: "https://pr/1"))
        let ids = titles(info)
        precondition(ids.contains("revision.buildReport") && ids.contains("revision.pullRequestPage"))
        precondition(ids.firstIndex(of: "revision.script")! < ids.firstIndex(of: "revision.buildReport")!)

        precondition(RevisionGridViewController.buildStatusText(info, icon: true, text: false) == "❌")
        precondition(RevisionGridViewController.buildStatusText(info, icon: true, text: true) == "❌CI #1")
        precondition(RevisionGridViewController.buildStatusText(info, icon: false, text: true) == "CI #1")
        precondition(RevisionGridViewController.buildStatusColor(.unknown) == nil && RevisionGridViewController.buildStatusColor(.success) == .systemGreen)
        var older = info; older.startDate = Date(timeIntervalSince1970: 10)
        var newer = info; newer.startDate = Date(timeIntervalSince1970: 20)
        precondition(newer.replaces(older) && newer.replaces(newer) && !older.replaces(newer) && older.replaces(nil))
        let grid = RevisionGridViewController(); _ = grid.view
        grid.beginIncrementalLoad(); grid.appendIncrementalBatch([commit])
        grid.applyBuildInfos([newer]); grid.applyBuildInfos([older])
        precondition(grid.buildStatus(for: commit.id)?.startDate == newer.startDate, "an older build does not replace a newer one")
        grid.applyBuildInfos([BuildInfo(revisions: [testRevisionID("not loaded")])])
        precondition(grid.buildStatus(for: testRevisionID("not loaded")) == nil)
        grid.beginIncrementalLoad()
        precondition(grid.buildStatus(for: commit.id) == nil, "statuses reset with the revisions")
    }

    private final class FakeAdapter: BuildServerAdapter, @unchecked Sendable {
        let lock = NSLock()
        var finishedCalls: [Date?] = []
        var runningCalls = 0
        var failRunning: BuildServerError?
        let running: [BuildInfo]
        init(running: [BuildInfo]) { self.running = running }
        var uniqueKey: String { "fake" }
        func finishedBuilds(since: Date?) async throws -> [BuildInfo] {
            lock.withLock { finishedCalls.append(since) }
            return [BuildInfo(startDate: since ?? .distantPast, status: .success, description: "finished", revisions: [.object(try! ObjectID(parsing: sha))])]
        }
        func runningBuilds() async throws -> [BuildInfo] {
            try lock.withLock { runningCalls += 1; if let failRunning { throw failRunning } }
            return running
        }
        func repositoryChanged() async {}
    }

    @MainActor
    private static func testResolverAndWatcher() async throws {
        func remote(_ name: String, _ url: String) -> RepositoryRemoteConfiguration {
            .init(name: name, fetchURL: url, pushURL: nil, puttyKeyFile: nil, color: nil, prefix: nil, pushRefSpecs: [], isDisabled: false)
        }
        let remotes = [remote("origin", "https://github.com/me/repo.git"), remote("upstream", "git@github.com:owner/repo.git")]
        precondition(BuildServerAutoDetector.orderedRemoteURLs(remotes) == ["git@github.com:owner/repo.git", "https://github.com/me/repo.git"])
        var tokens: [String] = []
        func resolve(_ settings: [String: String], _ remotes: [RepositoryRemoteConfiguration]) async -> BuildServerAdapterResolver.Resolution {
            await BuildServerAdapterResolver.resolve(settings: settings, remotes: remotes, currentRemote: "origin", credential: { _ in "helper" },
                transport: { _ in throw CancellationError() }, token: { tokens.append($0); return nil })
        }
        let detected = await resolve([:], remotes)
        precondition((detected.adapter as? GitHubActionsBuildAdapter)?.uniqueKey == "https://api.github.com/repos/owner/repo" && !detected.explicitlyEnabled)
        precondition(tokens.last == "GitHub Actions|https://api.github.com/owner/repo")
        let disabled = await resolve([BuildServerSettingKeys.enabled: "false"], remotes)
        let enabledOnly = await resolve([BuildServerSettingKeys.enabled: "true"], remotes)
        precondition(disabled.adapter == nil && enabledOnly.adapter == nil && enabledOnly.explicitlyEnabled, "touched settings disable auto-detection")
        let typed = [BuildServerSettingKeys.type: BuildServerType.gitHubActions.rawValue, "BuildServer.GitHub Actions.GitHubActionsOwner": "configured"]
        let configured = await resolve(typed, remotes)
        let configuredDisabled = await resolve(typed.merging([BuildServerSettingKeys.enabled: "False"]) { $1 }, remotes)
        precondition((configured.adapter as? GitHubActionsBuildAdapter)?.uniqueKey == "https://api.github.com/repos/configured/repo" && configuredDisabled.adapter == nil)
        let azureRemote = [remote("origin", "https://dev.azure.com/org/Proj/_git/repo")]
        let azure = await resolve([BuildServerSettingKeys.type: BuildServerType.azureDevOps.rawValue,
                                   "BuildServer.\(BuildServerType.azureDevOps.rawValue).ProjectUrl": "https://dev.azure.com/org/{cRepoProject}"], azureRemote)
        precondition((azure.adapter as? AzureDevOpsBuildAdapter)?.uniqueKey == "https://dev.azure.com/org/{cRepoProject}")
        let azureDetected = await resolve([:], azureRemote)
        let unknownType = await resolve([BuildServerSettingKeys.type: "AppVeyor"], remotes)
        precondition((azureDetected.adapter as? AzureDevOpsBuildAdapter)?.uniqueKey == "https://dev.azure.com/org/Proj" && unknownType.adapter == nil)

        let sha = try ObjectID(parsing: Self.sha)
        let adapter = FakeAdapter(running: [BuildInfo(status: .inProgress, revisions: [.object(sha)])])
        let watcher = BuildServerWatcher()
        watcher.shortInterval = .milliseconds(20); watcher.longInterval = .milliseconds(60)
        var updates: [[BuildInfo]] = []
        watcher.onUpdate = { updates.append($0) }
        let now = ISO8601DateFormatter().date(from: "2026-01-10T12:00:00Z")!
        watcher.launch(adapter, now: now)
        for _ in 0..<200 where adapter.lock.withLock({ adapter.finishedCalls.count < 3 || adapter.runningCalls < 3 }) { try await Task.sleep(for: .milliseconds(10)) }
        watcher.cancel()
        let calls = adapter.lock.withLock { adapter.finishedCalls }
        precondition(calls.count >= 3 && calls[0] == Calendar.current.date(byAdding: .day, value: -3, to: Calendar.current.startOfDay(for: now)) && calls[1] == nil && calls[2] == now)
        precondition(updates.contains { $0.first?.status == .inProgress } && updates.contains { $0.first?.description == "finished" })
        let failing = FakeAdapter(running: [])
        failing.failRunning = .initialization(message: "bad", badToken: true, key: "k")
        var reported: [BuildServerError] = []
        let second = BuildServerWatcher()
        second.onUpdate = { updates.append($0) }; second.onInitializationError = { reported.append($0) }
        updates = []
        second.launch(failing)
        for _ in 0..<200 where reported.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        second.cancel()
        precondition(reported.count == 1 && updates.contains { $0.first?.revisions == [.workingDirectory] && $0.first?.description == "bad" && $0.first?.status == .failure })
        second.launch(nil)
        precondition(second.adapter == nil)
    }

    @MainActor
    private static func testSettingsStore() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("GitExtensionsMac-BuildSettings-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "GitExtensionsMac.tests.buildServer.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = BuildServerSettingsStore(locations: DistributedSettings(localURL: root.appendingPathComponent("local.settings"),
                                                                             distributedURL: root.appendingPathComponent("GitExtensions.settings")),
                                             defaults: defaults)
        try store.write([BuildServerSettingKeys.type: "GitHub Actions", BuildServerSettingKeys.enabled: "true"], scope: .global)
        try store.write([BuildServerSettingKeys.enabled: "false", "Unrelated": "x"], scope: .distributed)
        try store.write([BuildServerSettingKeys.showBuildResultPage: "true"], scope: .local)
        let effective = try store.values(.effective)
        precondition(effective[BuildServerSettingKeys.type] == "GitHub Actions" && effective[BuildServerSettingKeys.enabled] == "false")
        precondition(effective[BuildServerSettingKeys.showBuildResultPage] == "true" && effective["Unrelated"] == nil)
        precondition(try! DistributedSettings.read(root.appendingPathComponent("GitExtensions.settings"))[BuildServerSettingKeys.enabled] == "false")
        try store.write([BuildServerSettingKeys.enabled: nil], scope: .distributed)
        precondition(try! store.values(.effective)[BuildServerSettingKeys.enabled] == "true")
        precondition(BuildServerSettingsStore.bool("True") == true && BuildServerSettingsStore.bool("FALSE") == false && BuildServerSettingsStore.bool(nil) == nil)
        precondition(BuildServerSettingsStore.azureTokenKey(projectURL: "https://Dev.Azure.com/Org/P") == "Azure DevOps and Team Foundation Server (since TFS2015)|https://dev.azure.com/org/p")
    }

    private final class FakeHostingSource: RepositoryHostingDataSource, @unchecked Sendable {
        let lock = NSLock()
        var commands: [[String]] = []
        var saved: [RepositoryRemoteSaveRequest] = []
        var failCommands: Set<String> = []
        func pullRequestTemplate() async throws -> String { "## Test plan" }
        func pullRequestSubject(remote: String, branch: String) async throws -> String { "\(remote)/\(branch) subject" }
        func runHostingCommand(_ command: GitCommand, output: @escaping GitOutputHandler) async throws -> GitCommandResult {
            lock.withLock { commands.append(command.arguments) }
            let status: Int32 = failCommands.contains(command.arguments[0]) ? 1 : 0
            return GitCommandResult(arguments: command.arguments, standardOutput: Data(), standardError: Data(), exitStatus: status, executionClass: command.executionClass)
        }
        func hostCredentialPassword(for url: URL) async -> String? { nil }
        func saveRemote(_ request: RepositoryRemoteSaveRequest) async throws { lock.withLock { saved.append(request) } }
    }

    @MainActor private static var messages: [(String, String)] = []
    @MainActor private static func installStubs() {
        _ = NSApplication.shared
        messages = []
        HostingMessages.present = { message, title, _ in messages.append((message, title)) }
        HostingProcessDialog.run = { _, _, operation in (try? await operation({ _ in })) ?? false }
    }
    @MainActor private static func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    @MainActor private static func button(_ title: String, in window: NSWindow) -> NSButton {
        descendants(window.contentView!).compactMap { $0 as? NSButton }.first { $0.title == title }!
    }
    @MainActor private static func click(_ button: NSButton, line: Int = #line) {
        precondition(button.isEnabled, "button \(button.title) disabled at line \(line)")
        NSApp.sendAction(button.action!, to: button.target, from: button)
    }
    @MainActor private static func wait(line: Int = #line, _ condition: @MainActor () async -> Bool) async throws {
        for _ in 0..<300 { if await condition() { return }; try await Task.sleep(for: .milliseconds(10)) }
        preconditionFailure("Timed out waiting for the fixture at line \(line); messages: \(messages)")
    }

    @MainActor
    private static func pullRequestContext(_ router: Router, source: FakeHostingSource, remotes: [HostedRemote], changed: @escaping () -> Void) -> GitHubHostingContext {
        GitHubHostingContext(remotes: remotes, currentRemote: "upstream", protocolRemoteURL: "https://github.com/contributor/repo.git",
                             source: source, saveRemote: { try await source.saveRemote($0) },
                             client: { RepositoryHostClient(identity: $0, token: "fixture", transport: { try await router.send($0) }) },
                             changed: changed)
    }

    @MainActor
    private static func testPullRequestsWindow() async throws {
        installStubs()
        let origin = HostedRemote(name: "origin", url: "https://github.com/contributor/repo.git", identity: .parse("https://github.com/contributor/repo.git")!)
        let upstream = HostedRemote(name: "upstream", url: "https://github.com/owner/repo.git", identity: .parse("https://github.com/owner/repo.git")!)
        let router = Router()
        await router.on("GET", "/repos/contributor/repo", repositoryJSON("contributor"))
        await router.on("GET", "/repos/owner/repo", repositoryJSON("owner"))
        await router.on("GET", "/repos/owner/repo/pulls", "[\(pullRequestJSON())]")
        await router.on("GET", "/repos/owner/repo/pulls/7", "diff --git a/file.txt b/file.txt\nindex 1..2 100644\n--- a/file.txt\n+++ b/file.txt\n@@ -1 +1 @@\n-old\n+new\n")
        await router.on("GET", "/repos/owner/repo/pulls/7/commits", "[]")
        await router.on("GET", "/repos/owner/repo/issues/7/comments", #"[{"id":1,"body":"Looks good","user":{"login":"reviewer"},"html_url":"https://github.com/c","created_at":"2026-01-03T00:00:00Z"}]"#)
        await router.on("PATCH", "/repos/owner/repo/pulls/7", pullRequestJSON())
        let source = FakeHostingSource()
        var changes = 0
        let controller = PullRequestsWindowController(context: pullRequestContext(router, source: source, remotes: [origin, upstream]) { changes += 1 })
        controller.showWindow(nil)
        let window = controller.window!
        let tables = descendants(window.contentView!).compactMap { $0 as? NSTableView }
        let list = tables.first { $0.tableColumns.first?.title == "#" }!
        try await wait { list.numberOfRows == 1 && list.selectedRow == 0 && !controller.busy }
        precondition(list.tableColumns.map(\.title) == ["#", "Heading", "By", "Created", "Will be fetched to branch"])
        let popup = descendants(window.contentView!).compactMap { $0 as? NSPopUpButton }.first!
        precondition(popup.itemTitles == ["contributor/repo", "owner/repo"] && popup.titleOfSelectedItem == "owner/repo", "current remote selected")
        func cell(_ column: Int) -> String { (list.view(atColumn: column, row: 0, makeIfNecessary: true) as? NSTextField)?.stringValue ?? "" }
        precondition(cell(0) == "7" && cell(1) == "Fix λ" && cell(2) == "contributor" && cell(4) == "pr/n7_topic")
        let files = tables.first { $0.tableColumns.first?.title == "File" }!
        let tabView = descendants(window.contentView!).compactMap { $0 as? NSTabView }.first!
        precondition(tabView.tabViewItems.map(\.label) == ["Diffs", "Comments"])
        let discussion = descendants(tabView.tabViewItems[1].view!).compactMap { $0 as? NSTextView }.first { !$0.isEditable }!
        try await wait { files.numberOfRows == 1 && discussion.string.contains("Looks good") }
        precondition(discussion.string.contains("contributor") && discussion.string.contains("Description"))
        precondition(messages.isEmpty, "no errors: \(messages)")

        click(button("Close pull request", in: window))
        try await wait { await router.matching("PATCH", "/repos/owner/repo/pulls/7").count == 1 }
        try await wait { await router.matching("GET", "/repos/owner/repo/pulls").count == 2 && list.numberOfRows == 1 && list.selectedRow == 0 }

        click(button("Fetch to pr/ branch", in: window))
        try await wait { !window.isVisible }
        precondition(source.commands == [["fetch", "--no-tags", "--progress", "https://github.com/contributor/repo.git", "topic:pr/n7_topic"]] && changes == 1)

        let second = PullRequestsWindowController(context: pullRequestContext(router, source: source, remotes: [origin, upstream]) { changes += 1 })
        second.showWindow(nil)
        let secondList = descendants(second.window!.contentView!).compactMap { $0 as? NSTableView }.first { $0.tableColumns.first?.title == "#" }!
        try await wait { secondList.numberOfRows == 1 && secondList.selectedRow == 0 && !second.busy }
        source.commands = []
        click(button("Add remote and fetch", in: second.window!))
        try await wait { !second.window!.isVisible }
        precondition(source.saved.map(\.name) == ["contributor"] && source.saved[0].fetchURL == "https://github.com/contributor/repo.git")
        precondition(source.commands == [["fetch", "--no-tags", "--progress", "contributor", "topic:contributor/topic"], ["checkout", "contributor/topic"]])
        precondition(changes == 4)

        let conflicting = HostedRemote(name: "contributor", url: "https://github.com/other/repo.git", identity: .parse("https://github.com/other/repo.git")!)
        await router.on("GET", "/repos/other/repo", repositoryJSON("other"))
        let third = PullRequestsWindowController(context: pullRequestContext(router, source: source, remotes: [conflicting, upstream]) { changes += 1 })
        third.showWindow(nil)
        let thirdList = descendants(third.window!.contentView!).compactMap { $0 as? NSTableView }.first { $0.tableColumns.first?.title == "#" }!
        try await wait { thirdList.numberOfRows == 1 && !third.busy }
        source.commands = []; messages = []
        click(button("Add remote and fetch", in: third.window!))
        try await wait { !messages.isEmpty }
        precondition(messages[0].0.hasPrefix("ERROR: Remote with name contributor already exists but it points to a different repository!"))
        precondition(source.commands.isEmpty && third.window!.isVisible)
        third.close()
    }

    @MainActor
    private static func testCreatePullRequestWindow() async throws {
        installStubs()
        let mine = HostedRemote(name: "origin", url: "https://github.com/contributor/repo.git", identity: .parse("https://github.com/contributor/repo.git")!)
        let target = HostedRemote(name: "upstream", url: "git@github.com:owner/repo.git", identity: .parse("git@github.com:owner/repo.git")!)
        let router = Router()
        await router.on("GET", "/user", #"{"login":"contributor"}"#)
        await router.on("GET", "/repos/contributor/repo", repositoryJSON("contributor", defaultBranch: "topic"))
        await router.on("GET", "/repos/contributor/repo/branches", #"[{"name":"topic"},{"name":"Alpha"}]"#)
        await router.on("GET", "/repos/owner/repo", repositoryJSON("owner"))
        await router.on("GET", "/repos/owner/repo/branches", #"[{"name":"stable"},{"name":"main"}]"#)
        await router.on("POST", "/repos/owner/repo/pulls", status: 201, pullRequestJSON())
        let source = FakeHostingSource()
        let controller = CreateHostedPullRequestWindowController(context: pullRequestContext(router, source: source, remotes: [mine, target]) {}, chooseRemote: "upstream")
        controller.showWindow(nil)
        let window = controller.window!
        let views = descendants(window.contentView!)
        let yours = views.first { $0.identifier?.rawValue == "pullRequest.sourceBranch" } as! NSComboBox
        let targetBranch = views.first { $0.identifier?.rawValue == "pullRequest.targetBranch" } as! NSComboBox
        let title = views.first { $0.identifier?.rawValue == "pullRequest.title" } as! NSTextField
        let repository = views.first { $0.identifier?.rawValue == "pullRequest.targetRepository" } as! NSPopUpButton
        let create = button("Create", in: window)
        try await wait { create.isEnabled && yours.stringValue == "topic" && targetBranch.stringValue == "main" && title.stringValue == "origin/topic subject" }
        precondition(repository.itemTitles == ["owner/repo"], "only foreign remotes are targets")
        precondition(yours.objectValues as? [String] == ["Alpha", "topic"] && targetBranch.objectValues as? [String] == ["main", "stable"])
        let body = views.first { $0.identifier?.rawValue == "pullRequest.body" } as! NSTextView
        try await wait { body.string == "## Test plan" }
        title.stringValue = " User title "
        yours.selectItem(at: 0)
        controller.comboBoxSelectionDidChange(Notification(name: NSComboBox.selectionDidChangeNotification, object: yours))
        for _ in 0..<10 { await Task.yield() }
        precondition(title.stringValue == " User title ")
        click(create)
        try await wait { !window.isVisible }
        precondition(messages.map(\.0) == ["Done"] && messages[0].1 == "Pull request")
        let post = await router.matching("POST", "/repos/owner/repo/pulls")[0]
        let payload = try JSONSerialization.jsonObject(with: post.httpBody!) as! [String: String]
        precondition(payload == ["head": "contributor:Alpha", "base": "main", "title": "User title", "body": "## Test plan"])

        messages = []
        let ownOnly = CreateHostedPullRequestWindowController(context: pullRequestContext(router, source: source, remotes: [mine]) {})
        ownOnly.showWindow(nil)
        try await wait { !ownOnly.window!.isVisible }
        precondition(messages.first?.0 == "Failed to create pull request.\nPlease clone GitHub repository before pull request.")
    }

    private final class FakeCreator: RepositoryCreating, @unchecked Sendable {
        var requests: [RepositoryCloneRequest] = []
        func suggestedCloneSubdirectory(for source: String) -> String { "" }
        func remoteBranches(at source: String) async throws -> [String] { [] }
        func clone(_ request: RepositoryCloneRequest, output: @escaping GitOutputHandler) async throws -> RepositoryCreationResult {
            requests.append(request)
            return RepositoryCreationResult(repositoryURL: request.destinationURL,
                command: GitCommandResult(arguments: [], standardOutput: Data(), standardError: Data(), exitStatus: 0, executionClass: .remote), isBare: false)
        }
        func initialize(_ request: RepositoryInitRequest, output: @escaping GitOutputHandler) async throws -> RepositoryCreationResult { fatalError() }
    }

    @MainActor
    private static func testForkAndCloneWindow() async throws {
        installStubs()
        let router = Router()
        await router.on("GET", "/user/repos", "[\(repositoryJSON("me", "zeta")),\(repositoryJSON("me", "alpha", fork: true))]")
        await router.on("GET", "/repos/me/alpha", repositoryJSON("me", "alpha", fork: true, parent: "origin-owner"))
        await router.on("GET", "/search/repositories", #"{"items":[\#(repositoryJSON("someone", "found", homepage: "ftp://nope"))]}"#)
        await router.on("POST", "/repos/someone/found/forks", status: 202, repositoryJSON("me", "found", fork: true))
        let creator = FakeCreator()
        var added: [(URL, String, String)] = []
        var opened: [URL] = []
        let environment = ForkAndCloneWindowController.Environment(
            creator: creator, addRemote: { added.append(($0, $1, $2)) }, opened: { opened.append($0) },
            client: { RepositoryHostClient(identity: .parse("https://github.com/api/api")!, token: "fixture", transport: { try await router.send($0) }) },
            initialDestination: "/tmp/destination")
        let controller = ForkAndCloneWindowController(environment: environment)
        controller.showWindow(nil)
        let window = controller.window!
        precondition(window.title == "GitHub: Remote repository fork and clone")
        let firstTabs = descendants(window.contentView!).compactMap { $0 as? NSTabView }.first!
        precondition(firstTabs.tabViewItems.map(\.label) == ["My repositories", "Search for repositories"])
        let tables = firstTabs.tabViewItems.flatMap { descendants($0.view!) }.compactMap { $0 as? NSTableView }
        let mineTable = tables.first { $0.tableColumns.map(\.title) == ["Name", "Is fork", "# Forks", "Private"] }!
        let searchTable = tables.first { $0.tableColumns.map(\.title) == ["Name", "Owner", "Is fork", "# Forks"] }!
        try await wait { mineTable.numberOfRows == 2 && (mineTable.view(atColumn: 0, row: 0, makeIfNecessary: true) as? NSTextField)?.stringValue == "alpha" }
        let clone = button("Clone", in: window)
        precondition(!clone.isEnabled, "nothing selected")
        mineTable.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        let fields = descendants(window.contentView!).compactMap { $0 as? NSTextField }
        let upstream = descendants(window.contentView!).compactMap { $0 as? NSComboBox }.first!
        try await wait { upstream.stringValue == "origin-owner" }
        precondition(upstream.objectValues as? [String] == ["origin-owner", "upstream"])
        precondition(fields.contains { $0.stringValue == "alpha" }, "create directory from the repository name")
        let info = fields.first { $0.stringValue.hasPrefix("Will clone") }!
        precondition(info.stringValue == "Will clone git@github.com:me/alpha.git into /tmp/destination/alpha.\nYou will have push access. \"origin-owner\" will be added as a remote.")
        let protocolChoice = descendants(window.contentView!).compactMap { $0 as? NSPopUpButton }.first { $0.itemTitles == ["Ssh", "Https"] }!
        protocolChoice.selectItem(at: 1); _ = protocolChoice.target?.perform(protocolChoice.action, with: protocolChoice)
        let depth = fields.first { $0.stringValue == "0" }!
        depth.stringValue = "12"
        click(clone)
        try await wait { !opened.isEmpty }
        precondition(creator.requests.count == 1 && creator.requests[0].source == "https://github.com/me/alpha.git" && creator.requests[0].depth == 12)
        precondition(creator.requests[0].destinationURL.path == "/tmp/destination/alpha" && !creator.requests[0].initializesSubmodules)
        precondition(added.count == 1 && added[0].1 == "origin-owner" && added[0].2 == "https://github.com/origin-owner/alpha.git")
        precondition(opened == [URL(fileURLWithPath: "/tmp/destination/alpha", isDirectory: true)] && !window.isVisible)

        let second = ForkAndCloneWindowController(environment: environment)
        second.showWindow(nil)
        let tabs = descendants(second.window!.contentView!).compactMap { $0 as? NSTabView }.first!
        tabs.selectTabViewItem(at: 1)
        let secondTables = tabs.tabViewItems.flatMap { descendants($0.view!) }.compactMap { $0 as? NSTableView }
        let results = secondTables.first { $0.tableColumns.map(\.title) == searchTable.tableColumns.map(\.title) }!
        let search = descendants(second.window!.contentView!).compactMap { $0 as? NSTextField }.first { $0.isEditable && $0.stringValue.isEmpty && !($0 is NSComboBox) }!
        search.stringValue = "found"
        click(button("Search", in: second.window!))
        try await wait { results.numberOfRows == 1 && (results.view(atColumn: 1, row: 0, makeIfNecessary: true) as? NSTextField)?.stringValue == "someone" }
        results.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        precondition(button("Fork!", in: second.window!).isEnabled)
        messages = []
        click(button("Open github page", in: second.window!))
        precondition(messages.first?.0 == "No homepage defined")
        let before = await router.matching("GET", "/user/repos").count
        click(button("Fork!", in: second.window!))
        try await wait { await router.matching("POST", "/repos/someone/found/forks").count == 1 && tabs.indexOfTabViewItem(tabs.selectedTabViewItem!) == 0 }
        try await wait { await router.matching("GET", "/user/repos").count == before + 1 }
        second.close()
    }

    @MainActor
    private static func testGitHubPluginIssueTemplates() async throws {
        installStubs()
        let saved = GitHubRepositoryPlugin.tokenProvider
        defer { GitHubRepositoryPlugin.tokenProvider = saved }
        let router = Router()
        await router.on("GET", "/issues", """
        [{"number":4,"title":"Old","body":"b4","updated_at":"2026-01-01T00:00:00Z","repository":{"name":"repo","owner":{"login":"owner"}}},
         {"number":5,"title":"New","body":"b5","updated_at":"2026-01-05T00:00:00Z","repository":{"name":"repo","owner":{"login":"owner"}}},
         {"number":6,"title":"Elsewhere","body":"b6","updated_at":"2026-01-06T00:00:00Z","repository":{"name":"other","owner":{"login":"x"}}}]
        """)
        var values: [String: String] = [GitHubRepositoryPlugin.helperMaxCount: "1"]
        let host = GitExtensionPluginHost(refresh: {}, navigate: { _ in },
            readSetting: { name, _ in values[name] }, writeSetting: { name, value, _ in values[name] = value },
            executeCommand: { arguments, _, _, _ in
                precondition(arguments == ["config", "--get-regexp", #"^remote\..*\.url$"#])
                return (0, Data("remote.origin.url https://github.com/owner/repo.git\nremote.azure.url https://dev.azure.com/o/p/_git/r\n".utf8), Data())
            })
        let plugin = GitHubRepositoryPlugin()
        plugin.clientFactory = { token in
            precondition(token == "fixture-token")
            return RepositoryHostClient(identity: .parse("https://github.com/api/api")!, token: token, transport: { try await router.send($0) })
        }
        try plugin.register(with: host)
        defer { plugin.unregister(from: host) }

        GitHubRepositoryPlugin.tokenProvider = { "" }
        precondition(try! host.dispatch("PreCommit"))
        precondition(CommitTemplateRegistry.templates.contains { $0.name == GitHubRepositoryPlugin.noToken })
        CommitTemplateRegistry.unregister(GitHubRepositoryPlugin.noToken)

        GitHubRepositoryPlugin.tokenProvider = { "fixture-token" }
        precondition(try! host.dispatch("PreCommit"))
        await plugin.issueTask?.value
        let names = CommitTemplateRegistry.templates.map(\.name)
        precondition(names.contains("5: New") && !names.contains("4: Old") && !names.contains("6: Elsewhere"), "most recent matching issue, limited by the setting: \(names)")
        precondition(CommitTemplateRegistry.templates.first { $0.name == "5: New" }!.text() == "\nFixes #5 : New\n\nb5\n")
        precondition(try! host.dispatch("PostCommit", succeeded: true))
        precondition(!CommitTemplateRegistry.templates.contains { $0.name == "5: New" })

        values[GitHubRepositoryPlugin.helperEnabled] = "false"
        let requests = await router.requests.count
        precondition(try! host.dispatch("PreCommit"))
        await plugin.issueTask?.value
        let afterDisabled = await router.requests.count
        precondition(afterDisabled == requests, "disabled helper makes no request")

        messages = []
        _ = try await plugin.execute(in: host)
        precondition(messages.first?.0 == "You already have an personal access token. To get a new one, delete your old one in Plugins > Plugin Settings first.")
    }
}
