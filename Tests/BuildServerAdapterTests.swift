import AppKit
import Foundation
@testable import GitExtensionsCore
@testable import GitCommands
@testable import GitUI

enum BuildServerAdapterTests {
    static func check(_ condition: Bool, _ message: String = "", file: StaticString = #filePath, line: UInt = #line) {
        precondition(condition, "CI adapter assertion " + message, file: file, line: line)
    }
    actor Fixture {
        struct Response: Sendable {
            var status = 200
            var body: String
            var headers: [String: String] = [:]
        }
        var requests: [URLRequest] = []
        var handler: @Sendable (URLRequest, Int) -> Response
        init(_ handler: @escaping @Sendable (URLRequest, Int) -> Response) { self.handler = handler }
        func send(_ request: URLRequest) -> (Data, HTTPURLResponse) {
            requests.append(request)
            let result = handler(request, requests.count)
            return (Data(result.body.utf8), HTTPURLResponse(url: request.url!, statusCode: result.status, httpVersion: nil, headerFields: result.headers)!)
        }
    }
    static let sha = String(repeating: "a", count: 40)
    static let sha2 = String(repeating: "b", count: 40)
    static func run() async throws {
        try configuration()
        for (name, test) in [("Gitlab", gitLab), ("AppVeyor", appVeyor), ("Jenkins", jenkins), ("TeamCity", teamCity), ("Credentials", credentialsAndErrors)] {
            do { try await test() }
            catch { throw NSError(domain: "CI adapter tests", code: 1, userInfo: [NSLocalizedDescriptionKey: name + ": " + error.localizedDescription]) }
        }
        try await settingsAndUI()
        print("BuildServerAdapterTests: passed")
    }
    static func configuration() throws {
        check(BuildServerType.allCases.map(\.rawValue) == ["AppVeyor", "Azure DevOps and Team Foundation Server (since TFS2015)", "GitHub Actions", "Gitlab", "Jenkins", "TeamCity"])
        check(CIConfiguration.serverURL("jenkins", jenkins: true)?.absoluteString == "http://jenkins:8080/")
        check(CIConfiguration.serverURL("https://host/context")?.absoluteString == "https://host/context/")
        check(CIConfiguration.serverURL("https://u:secret@host") == nil)
        check(CIConfiguration.gitLabRemote("git@self-hosted.test:owner/repo.git")?.instance == "https://self-hosted.test")
        check(CIConfiguration.gitLabRemote("https://host/group/nested/repo.git")?.namespace == "group/nested")
        check(CIConfiguration.gitLabRemote("https://host/group/nested/repo.git")?.repository == "repo")
        check(CIConfiguration.gitLabRemote("local/path") == nil)
        let url = CIConfiguration.teamCityBuildURL("https://tc:8443/viewLog.html?buildId=3&buildTypeId=Build%20A")
        check(url?.server.absoluteString == "https://tc:8443" && url?.buildType == "Build A")
        check(CIConfiguration.teamCityBuildURL("https://tc/viewLog.html?buildId=3") == nil)
        check(!CIConfiguration.regexValid("["))
        let credentials = BuildServerCredentials(kind: .usernameAndPassword, username: "λ", password: "not-real")
        check(credentials.authorization == "Basic " + Data("λ:not-real".utf8).base64EncodedString())
        check(try JSONDecoder().decode(BuildServerCredentials.self, from: JSONEncoder().encode(credentials)) == credentials)
        check(BuildServerCredentials().authorization == nil)
        check(BuildServerCredentials(kind: .bearerToken, bearerToken: "fixture").authorization == "Bearer fixture")
    }
    static func pipeline(_ id: Int, _ object: String, status: String, updated: String = "2026-01-02T00:02:00Z") -> String {
        #"{"id":\#(id),"sha":"\#(object)","status":"\#(status)","created_at":"2026-01-02T00:00:00Z","updated_at":"\#(updated)","web_url":"https://gitlab.test/pipelines/\#(id)"}"#
    }
    static func gitLab() async throws {
        let fixture = Fixture { request, _ in
            let page = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!.first { $0.name == "page" }!.value!
            return .init(body: page == "1" ? "[" + pipeline(2, sha, status: "success") + "]" : "[" + pipeline(1, sha2, status: "running") + "]",
                         headers: ["X-Total-Pages": "2"])
        }
        let adapter = GitLabBuildAdapter(instanceURL: "https://gitlab.test", projectID: 42, token: "fixture", transport: { await fixture.send($0) })!
        let since = ISO8601DateFormatter().date(from: "2026-01-01T00:00:00Z")!
        let builds = try await adapter.finishedBuilds(since: since)
        check(builds.map(\.status) == [.success, .inProgress] && builds.map(\.id) == ["2", "1"])
        check(builds[0].revisions == [.object(try ObjectID(parsing: sha))] && builds[0].duration == 1_200_000_000)
        check(builds[0].startDate == .distantPast && !builds[0].showInBuildReportTab)
        check(try await adapter.runningBuilds().isEmpty)
        let requests = await fixture.requests
        check(requests.count == 4 && requests.allSatisfy { $0.value(forHTTPHeaderField: "PRIVATE-TOKEN") == "fixture" })
        check(requests[0].url!.absoluteString.contains("scope=finished") && requests[0].url!.absoluteString.contains("per_page=100"))
        check(URLComponents(url: requests[0].url!, resolvingAgainstBaseURL: false)!.queryItems!.first { $0.name == "updated_after" }!.value == "2026-01-01 00:00:00Z")
        let limited = GitLabBuildAdapter(instanceURL: "https://gitlab.test", projectID: 42, pagesLimit: 1, transport: { await fixture.send($0) })!
        check(try await limited.finishedBuilds(since: nil).count == 1)
        let nextOnly = Fixture { request, _ in
            let page = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!.first { $0.name == "page" }!.value!
            return .init(body: "[" + pipeline(Int(page)!, page == "1" ? sha : sha2, status: page == "1" ? "canceled" : "pending") + "]",
                         headers: ["X-Next-Page": page == "1" ? "2" : ""])
        }
        let next = GitLabBuildAdapter(instanceURL: "https://gitlab.test", projectID: 1, transport: { await nextOnly.send($0) })!
        check(try await next.runningBuilds().map(\.status) == [.stopped, .unknown])
        let project = Fixture { _, _ in .init(body: #"{"id":42}"#) }
        check(try await GitLabBuildAdapter.projectID(instanceURL: "https://gitlab.test", namespace: "group/sub", repository: "repo", token: "fixture", transport: { await project.send($0) }) == 42)
        check(await project.requests.first?.url?.absoluteString == "https://gitlab.test/api/v4/projects/group%2Fsub%2Frepo")
    }
    static func appHistory(status: String = "success") -> String {
        #"{"project":{"repositoryName":"owner/repo","repositoryType":"github"},"builds":[{"version":"2","buildId":12,"commitId":"\#(sha2)","pullRequestHeadCommitId":"\#(sha)","pullRequestId":7,"pullRequestName":"Fix","status":"\#(status)","started":"2026-01-02T00:00:00Z","updated":"2026-01-02T00:02:00Z"},{"version":"1","commitId":"\#(sha)","status":"failed","started":"2026-01-01T00:00:00Z"}]}"#
    }
    static func appVeyor() async throws {
        let fixture = Fixture { request, _ in
            switch request.url!.path {
            case "/api/account/account/projects": return .init(body: #"[{"slug":"repo"}]"#)
            case "/api/projects/account/repo/history": return .init(body: appHistory())
            case "/api/projects/account/repo/build/2": return .init(body: #"{"build":{"started":"2026-01-02T00:00:00Z","updated":"2026-01-02T00:02:00Z","jobs":[{"status":"success","testsCount":8,"failedTestsCount":1,"passedTestsCount":6}]}}"#)
            default: return .init(status: 404, body: "")
            }
        }
        let adapter = AppVeyorBuildAdapter(account: "account", projects: "", token: "v2.fixture", loadTests: true, transport: { await fixture.send($0) })
        check(try await adapter.finishedBuilds(since: nil).isEmpty)
        let result = try await adapter.runningBuilds()
        check(result.count == 1 && result[0].id == "2" && result[0].status == .success && result[0].duration == 120_000)
        check(result[0].revisions == [.object(try ObjectID(parsing: sha))] && result[0].showInBuildReportTab)
        check(result[0].description!.contains("8 tests ( 1 failed, 2 skipped )") && result[0].tooltip!.contains("PR#7: Fix"))
        check(result[0].pullRequestURL?.absoluteString == "https://github.com/owner/repo/pull/7")
        check(try await adapter.runningBuilds().isEmpty)
        let requests = await fixture.requests
        check(requests.count == 3 && requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "Bearer v2.fixture" })
        let excluded = AppVeyorBuildAdapter(account: "account", projects: "repo", transport: { await fixture.send($0) }, isCommitVisible: { _ in false })
        check(try await excluded.runningBuilds().isEmpty)
        let running = Fixture { request, count in
            if request.url!.path.hasSuffix("history") { return .init(body: appHistory(status: "running")) }
            return .init(body: #"{"build":{"started":"2026-01-02T00:00:00Z","updated":"2026-01-02T00:02:00Z","jobs":[{"status":"\#(count <= 2 ? "running" : "failed")","testsCount":0}]}}"#)
        }
        let active = AppVeyorBuildAdapter(account: "account", projects: "repo", transport: { await running.send($0) })
        check(try await active.runningBuilds().first?.status == .inProgress)
        check(try await active.runningBuilds().first?.status == .failure)
        check(try await active.runningBuilds().isEmpty)
        let versionChanged = Fixture { request, _ in
            if request.url!.path.hasSuffix("history") {
                return .init(body: request.url!.query?.contains("startBuildId") == true
                    ? #"{"builds":[{"version":"renamed"}]}"# : appHistory(status: "running"))
            }
            if request.url!.path.hasSuffix("/2") { return .init(status: 404, body: "") }
            return .init(body: #"{"build":{"started":"2026-01-02T00:00:00Z","updated":"2026-01-02T00:02:00Z","jobs":[{"status":"cancelled","testsCount":0}]}}"#)
        }
        let renamed = AppVeyorBuildAdapter(account: "account", projects: "repo", transport: { await versionChanged.send($0) })
        let updated = try await renamed.runningBuilds()
        check(updated.first?.id == "renamed" && updated.first?.url?.absoluteString.hasSuffix("/renamed") == true && updated.first?.status == .stopped)
        let nullHead = Fixture { _, _ in
            .init(body: #"{"builds":[{"commitId":"\#(sha)","pullRequestHeadCommitId":null,"version":"1","status":"success","started":null,"created":"2026-01-02T00:00:00Z","updated":"2026-01-02T00:02:00Z"}]}"#)
        }
        let regular = AppVeyorBuildAdapter(account: "account", projects: "repo", transport: { await nullHead.send($0) })
        check(try await regular.runningBuilds().first?.duration == 120_000)
    }
    static func jenkinsBuild(_ id: Int = 7, status: String = "SUCCESS", running: Bool = false, branch: String = "origin/main") -> String {
        #"{"number":\#(id),"result":"\#(status)","timestamp":1767312000000,"url":"https://jenkins.test/job/project/\#(id)/","building":\#(running),"duration":120000,"actions":[{"lastBuiltRevision":{"SHA1":"\#(sha)","branch":[{"name":"\#(branch)"}]}},{"totalCount":8,"failCount":1,"skipCount":2}]}"#
    }
    static func jenkins() async throws {
        let fixture = Fixture { request, _ in
            let tree = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!.first { $0.name == "tree" }!.value!
            if tree == "lastBuild[timestamp]" { return .init(body: #"{"lastBuild":{"timestamp":1767312000000}}"#) }
            return .init(body: #"{"lastBuild":{"timestamp":1767312000000},"builds":[\#(jenkinsBuild())]}"#)
        }
        let adapter = JenkinsBuildAdapter(server: "https://jenkins.test", projects: "project", credentials: .init(kind: .usernameAndPassword, username: "user", password: "fixture"), transport: { await fixture.send($0) })!
        check(try await adapter.finishedBuilds(since: nil).isEmpty)
        let result = try await adapter.runningBuilds()
        check(result.count == 1 && result[0].status == .success && result[0].duration == 120_000)
        check(try result[0].description == "#7 02:00 8 tests (1 failed, 2 skipped) Success" && result[0].revisions == [.object(ObjectID(parsing: sha))])
        check(try await adapter.runningBuilds().isEmpty)
        let requests = await fixture.requests
        check(requests.count == 2 && requests[0].value(forHTTPHeaderField: "Authorization") == "Basic " + Data("user:fixture".utf8).base64EncodedString())
        let branches = Fixture { _, _ in
            .init(body: #"{"jobs":[{"lastBuild":{"timestamp":1767312000000},"builds":[\#(jenkinsBuild(status: "ABORTED")),\#(jenkinsBuild(6,status: "UNSTABLE")),\#(jenkinsBuild(5,status: "FAILURE"))]}]}"#)
        }
        let multi = JenkinsBuildAdapter(server: "https://jenkins.test", projects: "pipeline?m", credentials: .init(), transport: { await branches.send($0) })!
        check(try await multi.runningBuilds().map(\.status) == [.stopped, .unstable])
        let query = URLComponents(string: "https://host/" + JenkinsBuildAdapter.queryPath(project: "pipeline?m", full: true))!
        check(query.queryItems!.first { $0.name == "depth" }!.value == "2" && query.queryItems!.last!.value!.hasPrefix("jobs["))
        let ignored = JenkinsBuildAdapter(server: "https://jenkins.test", projects: "project", ignoreBranch: "origin/main", credentials: .init(), transport: { await fixture.send($0) })!
        check(try await ignored.runningBuilds().isEmpty)
        check(JenkinsBuildAdapter(server: "host", projects: "p", ignoreBranch: "[") == nil)
    }
    static func teamCity() async throws {
        let fixture = Fixture { request, _ in
            switch request.url!.path {
            case "/guestAuth/app/rest/projects": return .init(body: #"<projects><project id="root" name="Root"/><project id="P" name="Project" parentProjectId="root"/><project id="old" name="Old" archived="true"/></projects>"#)
            case "/guestAuth/app/rest/projects/P": return .init(body: #"<project><buildTypes><buildType id="B" name="Build" projectId="P"/><buildType id="Skip" name="Skip" projectId="P"/></buildTypes></project>"#)
            case "/guestAuth/app/rest/buildTypes/id:B": return .init(body: #"<buildType id="B" name="Build" projectId="P"/>"#)
            case "/guestAuth/app/rest/buildTypes/id:B/builds": return .init(body: #"<builds><build id="2"/><build id="3"/></builds>"#)
            default: return .init(body: #"<build id="\#(request.url!.path.hasSuffix("3") ? "3" : "2")" status="SUCCESS" running="true" webUrl="https://tc.test/viewLog.html?buildId=3"><startDate>20260102T030405+0230</startDate><statusText>Success</statusText><running-info currentStageText="Testing"/><revisions><revision version="\#(sha)"/><revision version="\#(sha2)"/></revisions></build>"#)
            }
        }
        let adapter = TeamCityBuildAdapter(server: "https://tc.test", projects: "P", buildFilter: "^B$", logAsGuest: true, transport: { await fixture.send($0) })!
        check(try await adapter.availableProjects().count == 2)
        check(try await adapter.projectBuilds("P").map(\.id) == ["B", "Skip"])
        check(try await adapter.buildType("B").projectID == "P")
        let date = ISO8601DateFormatter().date(from: "2026-01-01T00:00:00Z")!
        let builds = try await adapter.finishedBuilds(since: date)
        check(builds.map(\.id) == ["3", "2"] && builds[0].status == .success && builds[0].description == "Testing")
        check(builds[0].revisions == [.object(try ObjectID(parsing: sha)), .object(try ObjectID(parsing: sha2))])
        check(builds[0].startDate == ISO8601DateFormatter().date(from: "2026-01-02T05:34:05Z") && builds[0].url!.absoluteString.hasSuffix("&guest=1"))
        let requests = await fixture.requests
        check(requests.allSatisfy { $0.value(forHTTPHeaderField: "Accept") == "application/xml" })
        let locator = URLComponents(url: requests.first { $0.url!.path.hasSuffix("builds") }!.url!, resolvingAgainstBaseURL: false)!.queryItems!.first!.value!
        check(locator == "branch:(default:any),sinceDate:20260101T000000-0000,running:False")
        let _ = try await adapter.runningBuilds()
        let after = await fixture.requests
        check(after.filter { $0.url!.path == "/guestAuth/app/rest/projects/P" }.count == 2)
        check(TeamCityBuildAdapter(server: "host", projects: "P", buildFilter: "[") == nil)
        actor BatchFixture {
            var active = 0
            var maximum = 0
            var completed = 0
            func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
                let path = request.url!.path
                let body: String
                if path.contains("projects/") {
                    body = "<project><buildTypes><buildType id=\"B\"/></buildTypes></project>"
                } else if path.hasSuffix("builds") {
                    body = "<builds>" + (1...17).map { "<build id=\"\($0)\"/>" }.joined() + "</builds>"
                } else {
                    active += 1; maximum = max(maximum, active)
                    defer { active -= 1 }
                    try await Task.sleep(for: .milliseconds(20))
                    completed += 1
                    let id = path.split(separator: ":").last!
                    body = "<build id=\"\(id)\" status=\"SUCCESS\"><revisions><revision version=\"\(BuildServerAdapterTests.sha)\"/></revisions></build>"
                }
                return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }
        }
        let batches = BatchFixture()
        let batched = TeamCityBuildAdapter(server: "https://tc.test", projects: "P", transport: { try await batches.send($0) })!
        check(try await batched.runningBuilds().map(\.id) == (1...17).reversed().map(String.init))
        let maximum = await batches.maximum
        let completed = await batches.completed
        check(maximum == 8 && completed == 17)
    }
    static func credentialsAndErrors() async throws {
        let fixture = Fixture { request, _ in
            if request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture" { return .init(body: "<projects/>") }
            return .init(body: "<html>login</html>", headers: ["Content-Type": "text/html"])
        }
        let adapter = TeamCityBuildAdapter(server: "https://tc.test", projects: "", credentialProvider: { _, _ in .init(kind: .bearerToken, bearerToken: "fixture") }, transport: { await fixture.send($0) })!
        check(try await adapter.availableProjects().isEmpty)
        let requests = await fixture.requests
        check(requests.map { $0.url!.path } == ["/guestAuth/app/rest/projects", "/app/rest/projects"])
        let canceled = TeamCityBuildAdapter(server: "https://tc.test", projects: "", credentialProvider: { _, _ in nil }, transport: { await fixture.send($0) })!
        do { _ = try await canceled.availableProjects(); preconditionFailure("guest rejection") }
        catch BuildServerError.unauthorized { }
        let basic = Fixture { request, _ in
            if request.value(forHTTPHeaderField: "Authorization")?.hasPrefix("Basic ") == true { return .init(body: "<projects/>") }
            return .init(status: 401, body: "")
        }
        let basicAdapter = TeamCityBuildAdapter(server: "https://tc.test", projects: "", credentialProvider: { _, _ in .init(kind: .usernameAndPassword, username: "u", password: "fixture") }, transport: { await basic.send($0) })!
        check(try await basicAdapter.availableProjects().isEmpty)
        check(await basic.requests.last?.url?.path == "/httpAuth/app/rest/projects")
        let jenkinAuth = Fixture { request, _ in
            if request.value(forHTTPHeaderField: "Authorization")?.hasPrefix("Basic ") == true { return .init(body: #"{"lastBuild":{"timestamp":1767312000000},"builds":[\#(jenkinsBuild())]}"#) }
            return .init(status: 403, body: "")
        }
        actor Credentials {
            var calls: [Bool] = []
            func request(_ useStored: Bool) -> BuildServerCredentials {
                calls.append(useStored)
                return useStored ? .init() : .init(kind: .usernameAndPassword, username: "u", password: "fixture")
            }
        }
        let credentials = Credentials()
        let jenkins = JenkinsBuildAdapter(server: "https://j.test", projects: "p", credentialProvider: { _, stored in await credentials.request(stored) }, transport: { await jenkinAuth.send($0) })!
        check(try await jenkins.runningBuilds().first?.status == .success)
        check(await credentials.calls == [true, false])
        let missing = Fixture { _, _ in .init(status: 404, body: "") }
        let missingJenkins = JenkinsBuildAdapter(server: "https://j.test", projects: "gone", credentials: .init(), transport: { await missing.send($0) })!
        check(try await missingJenkins.runningBuilds().isEmpty)
        for status in [401, 403, 404, 500] {
            let failed = Fixture { _, _ in .init(status: status, body: "{}") }
            let gitlab = GitLabBuildAdapter(instanceURL: "https://gl.test", projectID: 1, transport: { await failed.send($0) })!
            do { _ = try await gitlab.runningBuilds(); preconditionFailure("HTTP \(status)") }
            catch is BuildServerError { }
        }
        let malformed = Fixture { _, _ in .init(body: "not json") }
        let invalid = GitLabBuildAdapter(instanceURL: "https://gl.test", projectID: 1, transport: { await malformed.send($0) })!
        do { _ = try await invalid.runningBuilds(); preconditionFailure("bad JSON") } catch BuildServerError.invalidResponse { }
        let task = Task {
            let slow = GitLabBuildAdapter(instanceURL: "https://gl.test", projectID: 1, transport: { request in
                try await Task.sleep(for: .seconds(10)); return await malformed.send(request)
            })!
            return try await slow.runningBuilds()
        }
        task.cancel()
        do { _ = try await task.value; preconditionFailure("cancellation") } catch is CancellationError { }
    }
    @MainActor
    static func settingsAndUI() async throws {
        let suite = "GitExtensionsMac.tests.CI.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = BuildServerSettingsStore(locations: nil, defaults: defaults)
        for type in [BuildServerType.appVeyor, .gitLab, .jenkins, .teamCity] {
            var values = [BuildServerSettingKeys.type: type.rawValue, BuildServerSettingKeys.enabled: "true"]
            values[BuildServerSettingKeys.adapter(type.rawValue, "BuildServerUrl")] = "https://ci.test"
            values[BuildServerSettingKeys.adapter(type.rawValue, "ProjectName")] = "repo"
            if type == .appVeyor { values[BuildServerSettingKeys.adapter(type.rawValue, "AppVeyorProjectName")] = "owner/repo" }
            if type == .teamCity { values[BuildServerSettingKeys.adapter(type.rawValue, "LogAsGuest")] = "false" }
            if type == .gitLab { values[BuildServerSettingKeys.adapter(type.rawValue, "InstanceUrl")] = "https://ci.test"; values[BuildServerSettingKeys.adapter(type.rawValue, "ProjectId")] = "42"; values[BuildServerSettingKeys.adapter(type.rawValue, "PagesLimit")] = "0" }
            let edits = values.mapValues { Optional($0) }
            try store.write(edits, scope: .global)
            let page = BuildServerSettingsPageController(store: store, remoteURLs: [], workingDirectoryName: "repo", transport: { request in (Data("{}".utf8), HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!) })
            let window = NSWindow(contentViewController: page); window.setContentSize(NSSize(width: 820, height: 560)); window.makeKeyAndOrderFront(nil)
            _ = page.view
            check(try! page.save() == false)
            check(try! store.values(.global)[BuildServerSettingKeys.type] == type.rawValue)
            window.close()
            let resolved = await BuildServerAdapterResolver.resolve(settings: values, remotes: [], currentRemote: nil, credential: { _ in nil }, token: { _ in nil }, buildCredentials: { _, _ in .init() })
            check(resolved.adapter != nil)
        }
        let credentials = BuildServerCredentialsController(key: "ci.test", value: .init(kind: .usernameAndPassword, username: "user", password: "fixture"))
        let window = NSWindow(contentViewController: credentials); window.setContentSize(NSSize(width: 580, height: 310)); window.makeKeyAndOrderFront(nil)
        _ = credentials.view
        check(credentials.enabledFields.username && credentials.enabledFields.password && !credentials.enabledFields.token)
        check(credentials.value.username == "user" && credentials.value.password == "fixture")
        window.close()
        let bearer = BuildServerCredentialsController(key: "ci.test", value: .init(kind: .bearerToken, bearerToken: "fixture"))
        _ = bearer.view; check(!bearer.enabledFields.username && bearer.enabledFields.token && bearer.value.bearerToken == "fixture")
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        let buttons = descendants(bearer.view).compactMap { $0 as? NSButton }
        buttons.first { $0.title == "Guest access" }!.performClick(nil)
        check(!bearer.enabledFields.username && !bearer.enabledFields.password && !bearer.enabledFields.token && bearer.value.kind == .guest)
        buttons.first { $0.title == "Authenticated user" }!.performClick(nil)
        check(bearer.enabledFields.username && bearer.enabledFields.password && !bearer.enabledFields.token)
        var completed = false
        bearer.onComplete = { completed = $0 == nil }
        buttons.first { $0.title == "Cancel" }!.performClick(nil)
        check(completed && buttons.first { $0.title == "OK" }!.keyEquivalent == "\r")
        let projectFixture = Fixture { request, _ in
            if request.url!.path.hasSuffix("/projects") {
                return .init(body: #"<projects><project id="root" name="Root"/><project id="P" name="Project" parentProjectId="root"/></projects>"#)
            }
            if request.url!.path.hasSuffix("/root") { return .init(body: "<project><buildTypes/></project>") }
            return .init(body: #"<project><buildTypes><buildType id="B" name="Build" projectId="P"/></buildTypes></project>"#)
        }
        let adapter = TeamCityBuildAdapter(server: "https://tc.test", projects: "", transport: { await projectFixture.send($0) })!
        let chooser = TeamCityBuildChooserController(adapter: adapter, project: "P", build: "B")
        let chooserWindow = NSWindow(contentViewController: chooser); chooserWindow.setContentSize(NSSize(width: 460, height: 420)); chooserWindow.makeKeyAndOrderFront(nil)
        let tree = descendants(chooser.view).compactMap { $0 as? NSOutlineView }.first!
        for _ in 0..<100 where (tree.item(atRow: tree.selectedRow) as? TeamCityBuildChooserController.Node)?.build?.id != "B" { try await Task.sleep(for: .milliseconds(10)) }
        check((tree.item(atRow: tree.selectedRow) as? TeamCityBuildChooserController.Node)?.build?.id == "B",
              "selected=\(tree.selectedRow), rows=\((0..<tree.numberOfRows).map { (tree.item(atRow: $0) as? TeamCityBuildChooserController.Node)?.title ?? "?" })")
        var chosen: TeamCityBuildType?
        chooser.onComplete = { chosen = $0 }
        descendants(chooser.view).compactMap { $0 as? NSButton }.first { $0.title == "OK" }!.performClick(nil)
        check(chosen?.id == "B" && chosen?.projectID == "P")
        chooserWindow.close()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("GitExtensionsMac-CIScope-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let scoped = BuildServerSettingsStore(locations: .init(localURL: root.appendingPathComponent("local"), distributedURL: root.appendingPathComponent("distributed")), defaults: defaults)
        let key = BuildServerSettingKeys.adapter("TeamCity", "ProjectName")
        try scoped.write([key: "global"], scope: .global); try scoped.write([key: "shared"], scope: .distributed); try scoped.write([key: "local"], scope: .local)
        check(try scoped.values(.effective)[key] == "local")
        try scoped.write([key: nil], scope: .local); check(try scoped.values(.effective)[key] == "shared")
        try scoped.write([key: nil], scope: .distributed); check(try scoped.values(.effective)[key] == "global")
        let report = BuildReportViewController()
        report.show(BuildInfo(status: .success, revisions: [.object(try ObjectID(parsing: sha))], url: URL(string: "about:blank"), showInBuildReportTab: false))
        _ = report.view
        check(!report.embedsReport && report.url?.absoluteString == "about:blank")
        report.show(BuildInfo(status: .success, revisions: [], url: URL(string: "about:blank")))
        check(report.embedsReport && descendants(report.view).contains { String(describing: type(of: $0)) == "WKWebView" })
        report.show(nil); check(!report.embedsReport && report.url == nil)
    }
}
