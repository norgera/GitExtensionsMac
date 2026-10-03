import Foundation
import GitExtensionsCore

package struct BuildServerCredentials: Codable, Equatable, Sendable {
    package enum Kind: String, Codable, CaseIterable, Sendable {
        case guest, usernameAndPassword, bearerToken
    }
    package var kind: Kind = .guest
    package var username = ""
    package var password = ""
    package var bearerToken = ""
    package init(kind: Kind = .guest, username: String = "", password: String = "", bearerToken: String = "") {
        self.kind = kind; self.username = username; self.password = password; self.bearerToken = bearerToken
    }
    package var authorization: String? {
        switch kind {
        case .guest: nil
        case .usernameAndPassword: "Basic " + Data("\(username):\(password)".utf8).base64EncodedString()
        case .bearerToken: "Bearer " + bearerToken
        }
    }
}

package typealias BuildServerCredentialProvider = @Sendable (String, Bool) async -> BuildServerCredentials?

package enum CIConfiguration {
    package static func serverURL(_ value: String, jenkins: Bool = false) -> URL? {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        var address = value.contains("://") ? value : "http://" + value + (jenkins ? ":8080" : "")
        if !address.hasSuffix("/") { address += "/" }
        guard let url = URL(string: address), ["http", "https"].contains(url.scheme), url.host != nil,
              url.user == nil, url.password == nil else { return nil }
        return url
    }
    package static func regexValid(_ expression: String) -> Bool { expression.isEmpty || (try? NSRegularExpression(pattern: expression)) != nil }
    package static func gitLabRemote(_ value: String) -> (instance: String, namespace: String, repository: String)? {
        let patterns = [#"https?://([^/@]+)/(.+)/([\w_.-]+)(?:\.git)?"#,
                        #"git(?:@|://)([^/]+)[:/]([^/]+)/([\w_.-]+)\.git"#]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)),
                  let host = Range(match.range(at: 1), in: value), let owner = Range(match.range(at: 2), in: value),
                  let name = Range(match.range(at: 3), in: value) else { continue }
            return ("https://" + value[host], String(value[owner]), String(value[name]).replacingOccurrences(of: ".git", with: ""))
        }
        return nil
    }
    package static func teamCityBuildURL(_ value: String) -> (server: URL, buildType: String)? {
        guard let components = URLComponents(string: value), let scheme = components.scheme,
              let host = components.host, let type = components.queryItems?.first(where: { $0.name == "buildTypeId" })?.value,
              !type.isEmpty else { return nil }
        var server = URLComponents(); server.scheme = scheme; server.host = host; server.port = components.port
        guard let url = server.url else { return nil }
        return (url, type)
    }
}

private actor CIHTTP {
    let base: URL
    let transport: HostTransport
    let provider: BuildServerCredentialProvider?
    var credentials: BuildServerCredentials?
    let teamCity: Bool
    let jenkins: Bool
    var initializedCredentials = false
    init(base: URL, transport: @escaping HostTransport, credentials: BuildServerCredentials? = nil,
         provider: BuildServerCredentialProvider? = nil, teamCity: Bool = false, jenkins: Bool = false) {
        self.base = base; self.transport = transport; self.credentials = credentials
        self.provider = provider; self.teamCity = teamCity; self.jenkins = jenkins
    }
    func get(_ path: String, headers: [String: String] = [:], missingIsEmpty: Bool = false) async throws -> (Data, HTTPURLResponse) {
        if jenkins && !initializedCredentials {
            initializedCredentials = true
            if credentials == nil, let provider { credentials = await provider(base.host ?? base.absoluteString, true) }
        }
        var attempts = 0
        while true {
            try Task.checkCancellation()
            var relative = path
            if teamCity {
                let prefix: String
                switch credentials?.kind ?? .guest {
                case .guest: prefix = "guestAuth/"
                case .usernameAndPassword: prefix = "httpAuth/"
                case .bearerToken: prefix = ""
                }
                relative = prefix + "app/rest/" + path
            }
            guard let url = URL(string: relative, relativeTo: base)?.absoluteURL else { throw BuildServerError.invalidResponse }
            var request = URLRequest(url: url, timeoutInterval: 120)
            for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
            if !jenkins || credentials?.kind != .bearerToken {
                if let authorization = credentials?.authorization { request.setValue(authorization, forHTTPHeaderField: "Authorization") }
            }
            let (data, response) = try await transport(request)
            try Task.checkCancellation()
            let loginPage = response.value(forHTTPHeaderField: "Content-Type")?.lowercased().hasPrefix("text/html") == true
            if response.statusCode == 401 || response.statusCode == 403 || ((jenkins || teamCity) && loginPage) {
                guard let provider, attempts < 3,
                      let replacement = await provider(base.host ?? base.absoluteString, teamCity && attempts == 0) else {
                    throw BuildServerError.unauthorized("The build server requires authentication.")
                }
                credentials = replacement; attempts += 1
                continue
            }
            if missingIsEmpty && response.statusCode == 404 { return (Data(), response) }
            guard (200..<300).contains(response.statusCode) else { throw BuildServerError.response(response.statusCode) }
            return (data, response)
        }
    }
}

private func ciJSON(_ data: Data) throws -> Any {
    do { return try JSONSerialization.jsonObject(with: data) }
    catch { throw BuildServerError.invalidResponse }
}
private func ciString(_ value: Any?) -> String? {
    if let value = value as? String { return value }
    if let value = value as? NSNumber { return value.stringValue }
    return nil
}
private func ciDate(_ value: Any?) -> Date {
    guard let text = ciString(value) else { return .distantPast }
    let fractional = ISO8601DateFormatter(); fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return fractional.date(from: text) ?? ISO8601DateFormatter().date(from: text) ?? .distantPast
}
private func ciObject(_ value: Any?) -> ObjectID? {
    guard let text = ciString(value), text.contains(where: { $0 != "0" }) else { return nil }
    return try? ObjectID(parsing: text)
}
private func ciAppVeyorDuration(_ row: [String: Any]) -> Int64 {
    guard let started = ciString(row["started"]) ?? ciString(row["created"]), let updated = ciString(row["updated"]) else { return 0 }
    return Int64(ciDate(updated).timeIntervalSince(ciDate(started)) * 1000)
}
private func ciMatches(_ regex: NSRegularExpression?, _ text: String) -> Bool {
    regex?.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
}
private func ciPath(_ text: String) -> String {
    text.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "?#%"))) ?? text
}

package actor GitLabBuildAdapter: BuildServerAdapter {
    package nonisolated let uniqueKey: String
    private let client: CIHTTP
    private let projectID: Int
    private let token: String
    private let pagesLimit: Int?
    private var loaded: [ObjectID: Date] = [:]
    package init?(instanceURL: String, projectID: Int, token: String = "", pagesLimit: Int? = nil,
                  transport: @escaping HostTransport = HostHTTP.send) {
        guard let base = CIConfiguration.serverURL(instanceURL), projectID > 0 else { return nil }
        uniqueKey = instanceURL; self.projectID = projectID; self.token = token
        self.pagesLimit = pagesLimit.flatMap { $0 > 0 ? $0 : nil }
        client = CIHTTP(base: base, transport: transport)
    }
    package func repositoryChanged() async {}
    package func finishedBuilds(since: Date?) async throws -> [BuildInfo] { try await builds(since: since, running: false) }
    package func runningBuilds() async throws -> [BuildInfo] { try await builds(since: nil, running: true) }
    private func builds(since: Date?, running: Bool) async throws -> [BuildInfo] {
        var page = 1
        var seen = Set<Int>()
        var result: [BuildInfo] = []
        while seen.insert(page).inserted {
            try Task.checkCancellation()
            var query = [URLQueryItem(name: "scope", value: running ? "running" : "finished"),
                         URLQueryItem(name: "page", value: String(page)), URLQueryItem(name: "per_page", value: "100")]
            if let since {
                let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = TimeZone(secondsFromGMT: 0)
                formatter.dateFormat = "yyyy-MM-dd HH:mm:ss'Z'"
                query.insert(.init(name: "updated_after", value: formatter.string(from: since)), at: 0)
            }
            var components = URLComponents(); components.queryItems = query
            let (data, response) = try await client.get("api/v4/projects/\(projectID)/pipelines" + (components.string ?? ""), headers: ["PRIVATE-TOKEN": token])
            guard let items = try ciJSON(data) as? [[String: Any]] else { throw BuildServerError.invalidResponse }
            for item in items {
                guard let id = ciObject(item["sha"]) else { continue }
                let updated = ciDate(item["updated_at"])
                if let previous = loaded[id], previous >= updated { continue }
                loaded[id] = updated
                result.append(Self.parsePipeline(item, id: id))
            }
            let total = response.value(forHTTPHeaderField: "X-Total-Pages").flatMap(Int.init)
            let next = response.value(forHTTPHeaderField: "X-Next-Page").flatMap(Int.init)
                ?? (total.map { page < $0 ? page + 1 : 0 } ?? 0)
            guard next > 0, pagesLimit.map({ next <= $0 }) ?? true else { break }
            page = next
        }
        return result
    }
    private static func parsePipeline(_ item: [String: Any], id: ObjectID) -> BuildInfo {
        let status: BuildStatus
        switch ciString(item["status"]) {
        case "running": status = .inProgress
        case "success": status = .success
        case "failed": status = .failure
        case "canceled": status = .stopped
        default: status = .unknown
        }
        return BuildInfo(id: ciString(item["id"]), duration: Int64((ciDate(item["updated_at"]).timeIntervalSince(ciDate(item["created_at"]))) * 10_000_000),
                         status: status, revisions: [.object(id)], url: ciString(item["web_url"]).flatMap(URL.init(string:)), showInBuildReportTab: false)
    }
    package static func projectID(instanceURL: String, namespace: String, repository: String, token: String,
                                  transport: @escaping HostTransport = HostHTTP.send) async throws -> Int? {
        guard let base = CIConfiguration.serverURL(instanceURL) else { throw BuildServerError.invalidResponse }
        let project = (namespace + "/" + repository).addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
        let (data, _) = try await CIHTTP(base: base, transport: transport).get("api/v4/projects/" + project, headers: ["PRIVATE-TOKEN": token])
        return (try ciJSON(data) as? [String: Any])?["id"] as? Int
    }
}

package actor AppVeyorBuildAdapter: BuildServerAdapter {
    package nonisolated let uniqueKey: String
    private let client: CIHTTP
    private let baseURL: URL
    private let account: String
    private let token: String
    private let projectNames: String
    private let loadTests: Bool
    private let visible: @Sendable (ObjectID) async -> Bool
    private var initialized = false
    private var pending: [(BuildInfo, [String: Any])] = []
    package init(account: String, projects: String, token: String = "", loadTests: Bool = false,
                  baseURL: URL = URL(string: "https://ci.appveyor.com/")!,
                  transport: @escaping HostTransport = HostHTTP.send,
                  isCommitVisible: @escaping @Sendable (ObjectID) async -> Bool = { _ in true }) {
        uniqueKey = baseURL.host ?? baseURL.absoluteString; client = CIHTTP(base: baseURL, transport: transport)
        self.baseURL = baseURL; self.account = account; self.token = token; projectNames = projects
        self.loadTests = loadTests; visible = isCommitVisible
    }
    package func repositoryChanged() async {}
    package func finishedBuilds(since: Date?) async throws -> [BuildInfo] { [] }
    private func get(_ path: String) async throws -> [String: Any] {
        let (data, _) = try await client.get(path, headers: token.isEmpty ? ["Accept": "application/json"] : ["Accept": "application/json", "Authorization": "Bearer " + token])
        guard let dictionary = try ciJSON(data) as? [String: Any] else { throw BuildServerError.invalidResponse }
        return dictionary
    }
    package func runningBuilds() async throws -> [BuildInfo] {
        if !initialized {
            var projects = projectNames.split(separator: "|").map(String.init)
                .filter { $0.contains("/") || !account.isEmpty }.map { $0.contains("/") ? $0 : account + "/" + $0 }
            if projects.isEmpty && !account.isEmpty && !token.isEmpty {
                let path = token.hasPrefix("v2.") ? "api/account/\(ciPath(account))/projects/" : "api/projects/"
                let (data, _) = try await client.get(path, headers: ["Authorization": "Bearer " + token])
                projects = (try ciJSON(data) as? [[String: Any]] ?? []).compactMap { ciString($0["slug"]).map { account + "/" + $0 } }
            }
            var all: [(BuildInfo, [String: Any])] = []
            for project in projects {
                try Task.checkCancellation()
                do {
                    let response = try await get("api/projects/\(ciPath(project))/history?recordsNumber=25")
                    let metadata = response["project"] as? [String: Any] ?? [:]
                    for row in response["builds"] as? [[String: Any]] ?? [] {
                        guard let objectID = ciObject(ciString(row["pullRequestHeadCommitId"]) ?? ciString(row["commitId"])), await visible(objectID) else { continue }
                        var row = row; row["_project"] = project; row["_repositoryName"] = metadata["repositoryName"]; row["_repositoryType"] = metadata["repositoryType"]
                        all.append((parse(row, objectID: objectID), row))
                    }
                } catch is CancellationError { throw CancellationError() } catch { continue }
            }
            var seen = Set<RevisionID>()
            pending = all.sorted { $0.0.startDate > $1.0.startDate }.filter { seen.insert($0.0.revisions[0]).inserted }
            initialized = true
        } else {
            pending = pending.filter { $0.0.status == .inProgress }
        }
        var result: [BuildInfo] = []
        for index in pending.indices {
            try Task.checkCancellation()
            var (info, row) = pending[index]
            if info.status == .inProgress || (loadTests && [.success, .failure].contains(info.status)) {
                do {
                    let project = ciString(row["_project"]) ?? ""
                    var version = info.id ?? ""
                    let details: [String: Any]
                    do { details = try await get("api/projects/\(ciPath(project))/build/\(ciPath(version))") }
                    catch is CancellationError { throw CancellationError() }
                    catch {
                        guard let buildID = ciString(row["buildId"]).flatMap(Int.init) else { throw error }
                        let history = try await get("api/projects/\(ciPath(project))/history?recordsNumber=1&startBuildId=\(buildID + 1)")
                        guard let first = (history["builds"] as? [[String: Any]])?.first, let newVersion = ciString(first["version"]) else { throw BuildServerError.invalidResponse }
                        version = newVersion; row["version"] = version
                        details = try await get("api/projects/\(ciPath(project))/build/\(ciPath(version))")
                    }
                    if let build = details["build"] as? [String: Any], let job = (build["jobs"] as? [[String: Any]])?.last {
                        row["status"] = job["status"]; row["started"] = ciString(build["started"]) ?? ciString(build["created"]); row["updated"] = build["updated"]
                        row["_tests"] = job
                        row["_progress"] = ((row["_progress"] as? Int ?? 0) % 3) + 1
                        info = parse(row, objectID: info.revisions[0].objectID!)
                    }
                } catch is CancellationError { throw CancellationError() } catch { }
            }
            pending[index] = (info, row); result.append(info)
        }
        return result
    }
    private func parse(_ row: [String: Any], objectID: ObjectID) -> BuildInfo {
        let status: BuildStatus
        switch ciString(row["status"]) {
        case "success": status = .success
        case "failed": status = .failure
        case "cancelled": status = .stopped
        case "queued", "running": status = .inProgress
        default: status = .unknown
        }
        let duration = ([.success, .failure].contains(status) || (row["_tests"] != nil && status != .inProgress))
            ? ciAppVeyorDuration(row) : nil
        let version = ciString(row["version"]) ?? ""
        let pr = ciString(row["pullRequestId"])
        let project = ciString(row["_project"]) ?? ""
        var tests = ""
        if let job = row["_tests"] as? [String: Any], let count = job["testsCount"] as? Int, count != 0 {
            tests = "\(count) tests"
            let failed = job["failedTestsCount"] as? Int ?? 0, skipped = count - (job["passedTestsCount"] as? Int ?? count)
            if failed != 0 || skipped != 0 { tests += " ( \(failed) failed, \(skipped) skipped )" }
        }
        let prText = pr.map { "PR#" + $0 } ?? ""
        let description = formatBuildDuration(duration) + " " + tests + (prText.isEmpty ? "" : " " + prText) + " " + version
        var prURL: URL?
        if let pr, let repository = ciString(row["_repositoryName"]) {
            switch ciString(row["_repositoryType"])?.lowercased() {
            case "github": prURL = URL(string: "https://github.com/\(repository)/pull/\(pr)")
            case "gitlab": prURL = URL(string: "https://gitlab.com/\(repository)/merge_requests/\(pr)")
            case "bitbucket": prURL = URL(string: "https://bitbucket.org/\(repository)/pull-requests/\(pr)")
            default: break
            }
        }
        let count = row["_progress"] as? Int ?? 0
        let statusText = status == .inProgress ? "In progress" + String(repeating: ".", count: count) + String(repeating: " ", count: 3 - count) : String(describing: status).capitalized
        let tooltip = [statusText, duration.map { formatBuildDuration($0) }, tests.isEmpty ? nil : tests,
                       pr.map { "PR#\($0): " + (ciString(row["pullRequestName"]) ?? "") }, version].compactMap { $0 }.joined(separator: "\n")
        return BuildInfo(id: version, startDate: ciDate(row["started"]), duration: duration, status: status,
                         description: description, revisions: [.object(objectID)],
                         url: URL(string: "project/\(ciPath(project))/build/\(ciPath(version))", relativeTo: baseURL)?.absoluteURL,
                         tooltip: tooltip, pullRequestURL: prURL)
    }
}

package actor JenkinsBuildAdapter: BuildServerAdapter {
    package nonisolated let uniqueKey: String
    private let client: CIHTTP
    private let projects: [String]
    private let ignore: NSRegularExpression?
    private var last: [String: Int64] = [:]
    package init?(server: String, projects: String, ignoreBranch: String = "", credentials: BuildServerCredentials? = nil,
                  credentialProvider: BuildServerCredentialProvider? = nil, transport: @escaping HostTransport = HostHTTP.send) {
        guard let base = CIConfiguration.serverURL(server, jenkins: true), !projects.isEmpty,
              CIConfiguration.regexValid(ignoreBranch) else { return nil }
        uniqueKey = base.host ?? server; self.projects = projects.split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }
        ignore = ignoreBranch.isEmpty ? nil : try? NSRegularExpression(pattern: ignoreBranch)
        client = CIHTTP(base: base, transport: transport, credentials: credentials, provider: credentialProvider, jenkins: true)
    }
    package func repositoryChanged() async {}
    package func finishedBuilds(since: Date?) async throws -> [BuildInfo] { [] }
    package static func queryPath(project: String, full: Bool) -> String {
        var name = project, tree = "lastBuild[timestamp]", depth = 1
        let fields = "number,result,timestamp,url,actions[lastBuiltRevision[SHA1,branch[name]],totalCount,failCount,skipCount],building,duration"
        if let question = name.firstIndex(of: "?") {
            var suffix = String(name[question...]); if suffix.hasSuffix("/") { suffix.removeLast() }
            name = String(name[..<question])
            if suffix == "?m" { tree = "jobs[" + tree + (full ? ",builds[" + fields + "]" : "") + "]"; depth = full ? 2 : 1 }
            else { tree = suffix }
        } else if full { tree += ",builds[" + fields + "]" }
        var components = URLComponents(); components.queryItems = [.init(name: "depth", value: String(depth)), .init(name: "tree", value: tree)]
        return "job/" + ciPath(name.trimmingCharacters(in: CharacterSet(charactersIn: "/"))) + "/api/json" + (components.string ?? "")
    }
    private func get(_ project: String, full: Bool) async throws -> [String: Any]? {
        let (data, _) = try await client.get(Self.queryPath(project: project, full: full), missingIsEmpty: true)
        return data.isEmpty ? nil : try ciJSON(data) as? [String: Any]
    }
    package func runningBuilds() async throws -> [BuildInfo] {
        var result: [BuildInfo] = []
        var statuses: [RevisionID: BuildStatus] = [:]
        for project in projects {
            try Task.checkCancellation()
            do {
                var response = try await get(project, full: (last[project] ?? -1) <= 0)
                if let previous = last[project], previous > 0 {
                    guard let preview = response, timestamp(preview) > previous else { continue }
                    response = try await get(project, full: true)
                }
                guard let response, timestamp(response) > 0 else { continue }
                last[project] = timestamp(response)
                let rows = response["builds"] as? [[String: Any]] ?? (response["jobs"] as? [[String: Any]] ?? []).flatMap { $0["builds"] as? [[String: Any]] ?? [] }
                for row in rows {
                    guard let info = parse(row) else { continue }
                    if info.status == .inProgress { last[project] = 0 }
                    var better = false
                    for revision in info.revisions {
                        let previous = statuses[revision]
                        if previous == nil || (![.success, .failure, .unstable].contains(previous!) &&
                            ([.success, .failure, .unstable].contains(info.status) || (previous != .inProgress && info.status == .inProgress))) {
                            statuses[revision] = info.status; better = true
                        }
                    }
                    if better { result.append(info) }
                }
            } catch is CancellationError { throw CancellationError() } catch { continue }
        }
        return result
    }
    private func timestamp(_ row: [String: Any]) -> Int64 {
        let root = (row["lastBuild"] as? [String: Any])?["timestamp"] as? Int64 ?? 0
        return max(root, (row["jobs"] as? [[String: Any]] ?? []).map { ($0["lastBuild"] as? [String: Any])?["timestamp"] as? Int64 ?? 0 }.max() ?? 0)
    }
    private func parse(_ row: [String: Any]) -> BuildInfo? {
        guard let time = row["timestamp"] as? Int64, let running = row["building"] as? Bool else { return nil }
        var ids: [RevisionID] = [], tests = ""
        for action in row["actions"] as? [[String: Any]] ?? [] {
            if let revision = action["lastBuiltRevision"] as? [String: Any] {
                if (revision["branch"] as? [[String: Any]] ?? []).contains(where: { ciMatches(ignore, ciString($0["name"]) ?? "") }) { return nil }
                guard let id = ciObject(revision["SHA1"]) else { return nil }; ids.append(.object(id))
            }
            if let count = action["totalCount"] as? Int, count != 0 {
                tests = "\(count) tests (\(action["failCount"] as? Int ?? 0) failed, \(action["skipCount"] as? Int ?? 0) skipped)"
            }
        }
        let status: BuildStatus
        switch running ? "RUNNING" : ciString(row["result"]) {
        case "RUNNING": status = .inProgress
        case "SUCCESS": status = .success
        case "FAILURE": status = .failure
        case "UNSTABLE": status = .unstable
        case "ABORTED": status = .stopped
        default: status = .unknown
        }
        let duration = running ? nil : row["duration"] as? Int64
        let id = ciString(row["number"]) ?? ""
        let name = status == .inProgress ? "InProgress" : String(describing: status).capitalized
        return BuildInfo(id: id, startDate: Date(timeIntervalSince1970: Double(time) / 1000), duration: duration,
                         status: status, description: "#\(id) \(formatBuildDuration(duration)) \(tests) \(name)", revisions: ids,
                         url: ciString(row["url"]).flatMap(URL.init(string:)))
    }
}

package struct TeamCityProject: Sendable, Equatable {
    package let id: String
    package let name: String
    package let parent: String?
}
package struct TeamCityBuildType: Sendable, Equatable {
    package let id: String
    package let name: String
    package let projectID: String
}

package actor TeamCityBuildAdapter: BuildServerAdapter {
    package nonisolated let uniqueKey: String
    private let client: CIHTTP
    private let projects: [String]
    private let filter: NSRegularExpression
    private let logAsGuest: Bool
    private var buildTypes: [String]?
    package init?(server: String, projects: String, buildFilter: String = "", logAsGuest: Bool = false,
                  credentials: BuildServerCredentials? = nil, credentialProvider: BuildServerCredentialProvider? = nil,
                  transport: @escaping HostTransport = HostHTTP.send) {
        guard let base = CIConfiguration.serverURL(server), let filter = try? NSRegularExpression(pattern: buildFilter.isEmpty ? "(?:)" : buildFilter) else { return nil }
        uniqueKey = base.host ?? server; self.projects = projects.split(separator: "|").map(String.init)
        self.filter = filter; self.logAsGuest = logAsGuest
        client = CIHTTP(base: base, transport: transport, credentials: credentials, provider: credentialProvider, teamCity: true)
    }
    package func repositoryChanged() async {}
    private func xml(_ path: String) async throws -> XMLDocument {
        let (data, _) = try await client.get(path, headers: ["Accept": "application/xml"])
        do { return try XMLDocument(data: data, options: .nodeLoadExternalEntitiesNever) }
        catch { throw BuildServerError.invalidResponse }
    }
    private func nodes(_ document: XMLDocument, _ path: String) -> [XMLElement] { (try? document.nodes(forXPath: path))?.compactMap { $0 as? XMLElement } ?? [] }
    package func availableProjects() async throws -> [TeamCityProject] {
        let document = try await xml("projects")
        return nodes(document, "/projects/project").filter { $0.attribute(forName: "archived")?.stringValue != "true" }.compactMap {
            guard let id = $0.attribute(forName: "id")?.stringValue else { return nil }
            return TeamCityProject(id: id, name: $0.attribute(forName: "name")?.stringValue ?? id, parent: $0.attribute(forName: "parentProjectId")?.stringValue)
        }
    }
    package func projectBuilds(_ id: String) async throws -> [TeamCityBuildType] {
        let document = try await xml("projects/" + ciPath(id))
        return nodes(document, "/project/buildTypes/buildType").compactMap {
            guard let buildID = $0.attribute(forName: "id")?.stringValue else { return nil }
            return TeamCityBuildType(id: buildID, name: $0.attribute(forName: "name")?.stringValue ?? buildID,
                                     projectID: $0.attribute(forName: "projectId")?.stringValue ?? id)
        }
    }
    package func buildType(_ id: String) async throws -> TeamCityBuildType {
        let document = try await xml("buildTypes/id:" + ciPath(id))
        guard let root = document.rootElement(), let project = root.attribute(forName: "projectId")?.stringValue else { throw BuildServerError.invalidResponse }
        return TeamCityBuildType(id: id, name: root.attribute(forName: "name")?.stringValue ?? id, projectID: project)
    }
    package func runningBuilds() async throws -> [BuildInfo] { try await builds(since: nil, running: true) }
    package func finishedBuilds(since: Date?) async throws -> [BuildInfo] { try await builds(since: since, running: false) }
    private func builds(since: Date?, running: Bool) async throws -> [BuildInfo] {
        guard !projects.isEmpty else { return [] }
        if buildTypes == nil {
            var types: [String] = []
            for project in projects { types += try await projectBuilds(project).map(\.id).filter { ciMatches(filter, $0) } }
            buildTypes = types
        }
        var ids: [String] = []
        for type in buildTypes ?? [] {
            var locator = ["branch:(default:any)"]
            if let since {
                let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = TimeZone(secondsFromGMT: 0)
                formatter.dateFormat = "yyyyMMdd'T'HHmmss'-0000'"; locator.append("sinceDate:" + formatter.string(from: since))
            }
            locator.append("running:" + (running ? "True" : "False"))
            var components = URLComponents(); components.queryItems = [.init(name: "locator", value: locator.joined(separator: ","))]
            let document = try await xml("buildTypes/id:\(ciPath(type))/builds/" + (components.string ?? ""))
            ids += nodes(document, "/builds/build").compactMap { $0.attribute(forName: "id")?.stringValue }
        }
        var result: [BuildInfo] = []
        let ordered = ids.sorted(by: { (Int($0) ?? 0) > (Int($1) ?? 0) })
        for start in stride(from: 0, to: ordered.count, by: 8) {
            try Task.checkCancellation()
            let batch = Array(ordered[start..<min(start + 8, ordered.count)])
            let loaded = try await withThrowingTaskGroup(of: (Int, BuildInfo?).self) { group in
                for (index, id) in batch.enumerated() {
                    group.addTask { (index, try await self.buildInfo(id)) }
                }
                var values: [(Int, BuildInfo?)] = []
                for try await value in group { values.append(value) }
                return values.sorted { $0.0 < $1.0 }.compactMap { $0.1 }
            }
            result += loaded
        }
        return result
    }
    private func buildInfo(_ id: String) async throws -> BuildInfo? {
        let document = try await xml("builds/id:" + ciPath(id))
        guard let info = parse(document), !info.revisions.isEmpty else { return nil }
        return info
    }
    private func parse(_ document: XMLDocument) -> BuildInfo? {
        guard let root = document.rootElement(), let id = root.attribute(forName: "id")?.stringValue else { return nil }
        let revisions = nodes(document, "/build/revisions/revision").compactMap { ciObject($0.attribute(forName: "version")?.stringValue).map(RevisionID.object) }
        let status: BuildStatus
        switch root.attribute(forName: "status")?.stringValue {
        case "SUCCESS": status = .success
        case "FAILURE": status = .failure
        default: status = .unknown
        }
        var text = root.elements(forName: "statusText").first?.stringValue
        if root.attribute(forName: "running")?.stringValue?.lowercased() == "true" {
            text = root.elements(forName: "running-info").first?.attribute(forName: "currentStageText")?.stringValue ?? text
        }
        let start = root.elements(forName: "startDate").first?.stringValue ?? ""
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd'T'HHmmss"
        let prefix = String(start.prefix(15))
        var date = formatter.date(from: prefix) ?? .distantPast
        if start.count >= 20 {
            let offset = String(start.dropFirst(15))
            if let hours = Int(offset.prefix(3)), let minutes = Int(offset.suffix(2)) {
                date = date.addingTimeInterval(Double(hours * 3600 + (offset.hasPrefix("-") ? -minutes : minutes) * 60))
            }
        }
        let url = root.attribute(forName: "webUrl")?.stringValue.map { $0 + (logAsGuest ? "&guest=1" : "") }.flatMap(URL.init(string:))
        return BuildInfo(id: id, startDate: date, status: status, description: text, revisions: revisions, url: url)
    }
}
