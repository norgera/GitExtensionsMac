import Foundation
import GitExtensionsCore

package protocol RepositoryHostingContextDataSource: Sendable {
    func pullRequestTemplate() async throws -> String
    func pullRequestSubject(remote: String, branch: String) async throws -> String
}

package protocol RepositoryHostingDataSource: RepositoryHostingContextDataSource {
    func runHostingCommand(_ command: GitCommand, output: @escaping GitOutputHandler) async throws -> GitCommandResult
    func hostCredentialPassword(for url: URL) async -> String?
}

extension GitRepositoryModule: RepositoryHostingDataSource {
    package func pullRequestTemplate() async throws -> String {
        let file = try await settingsDirectories().working.appendingPathComponent(".github/PULL_REQUEST_TEMPLATE.md")
        guard FileManager.default.fileExists(atPath: file.path) else { return "" }
        return try String(contentsOf: file, encoding: .utf8)
    }

    package func pullRequestSubject(remote: String, branch: String) async throws -> String {
        let directory = try await settingsDirectories().working
        let result = try await git.run(RepositoryHostingCommands.previousCommitMessage(remote.isEmpty ? branch : remote + "/" + branch), in: directory)
        guard result.succeeded else { return "" }
        let message = result.standardOutputString.split(separator: "\0", omittingEmptySubsequences: true).first.map(String.init) ?? ""
        return message.firstIndex(of: "\n").map { String(message[..<$0]) } ?? message
    }

    package func runHostingCommand(_ command: GitCommand, output: @escaping GitOutputHandler) async throws -> GitCommandResult {
        guard let repository = resolvedRepository else { throw RepositoryDataSourceError.unavailable }
        return try await git.runStreaming(command, in: repository.rootURL, output: output)
    }

    package func hostCredentialPassword(for url: URL) async -> String? {
        guard let repository = resolvedRepository, let scheme = url.scheme, let host = url.host else { return nil }
        let path = url.path.hasPrefix("/") ? String(url.path.dropFirst()) : url.path
        let input = "protocol=\(scheme)\nhost=\(host)\npath=\(path)\n\n"
        guard let result = try? await git.run(RepositoryHostingCommands.credentialFill, in: repository.rootURL,
                                              standardInput: Data(input.utf8), environment: ["GIT_TERMINAL_PROMPT": "0"]),
              result.succeeded else { return nil }
        for line in result.standardOutputString.split(separator: "\n") {
            guard let separator = line.firstIndex(of: "=") else { continue }
            let key = line[..<separator].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespaces)
            if key == "password", !value.isEmpty { return value }
        }
        return nil
    }
}

package enum RepositoryHostingCommands {
    package static func previousCommitMessage(_ revision: String) -> GitCommand {
        GitCommand(arguments: ["log", "-z", "-n", "1", "--pretty=format:%B", "--end-of-options", revision, "--"],
                   accessesRemote: false, changesRepositoryState: false)
    }
    package static func fetchPullRequest(url: String, headRef: String, localBranch: String) -> GitCommand {
        GitCommand(arguments: ["fetch", "--no-tags", "--progress", url, headRef + ":" + localBranch],
                   accessesRemote: true, changesRepositoryState: true)
    }
    package static func fetchRemoteBranch(remote: String, ref: String) -> GitCommand {
        GitCommand(arguments: ["fetch", "--no-tags", "--progress", remote, ref + ":" + remote + "/" + ref],
                   accessesRemote: true, changesRepositoryState: true)
    }
    package static func checkout(remote: String, ref: String) -> GitCommand {
        GitCommand(arguments: ["checkout", remote + "/" + ref], accessesRemote: false, changesRepositoryState: true)
    }
    package static let credentialFill = GitCommand(arguments: ["credential", "fill"], accessesRemote: false, changesRepositoryState: false)
}

package struct HostedRepositoryIdentity: Hashable, Sendable {
    package enum Provider: String, Sendable { case gitHub, azureDevOps }
    package let provider: Provider
    package let host: String
    package let owner: String
    package let project: String?
    package let repository: String

    package static func parse(_ remote: String) -> Self? {
        let host: String
        var pieces: [String]
        if let url = URLComponents(string: remote), let name = url.host,
           ["https", "http", "ssh", "git"].contains(url.scheme?.lowercased() ?? ""),
           url.query == nil, url.fragment == nil {
            host = name.lowercased()
            pieces = url.path.split(separator: "/").map(String.init)
        } else if let colon = remote.firstIndex(of: ":"), !remote.contains("://") {
            let authority = remote[..<colon].split(separator: "@").last.map(String.init) ?? ""
            host = authority.lowercased()
            pieces = remote[remote.index(after: colon)...].split(separator: "/").map(String.init)
        } else { return nil }
        guard pieces.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("\n") && !$0.contains("\r") }) else { return nil }
        if host == "github.com", pieces.count == 2 {
            if pieces[1].hasSuffix(".git") { pieces[1].removeLast(4) }
            guard !pieces[1].isEmpty else { return nil }
            return Self(provider: .gitHub, host: host, owner: pieces[0], project: nil, repository: pieces[1])
        }
        if host == "ssh.dev.azure.com" || host == "vs-ssh.visualstudio.com" {
            guard pieces.count == 4, pieces[0].first == "v", Int(pieces[0].dropFirst()) != nil else { return nil }
            let owner = pieces[1]
            guard owner.range(of: "^[A-Za-z0-9][A-Za-z0-9-]*$", options: .regularExpression) != nil else { return nil }
            return Self(provider: .azureDevOps, host: host == "ssh.dev.azure.com" ? "dev.azure.com" : "\(owner).visualstudio.com",
                        owner: owner, project: pieces[2], repository: pieces[3])
        }
        if host == "dev.azure.com", pieces.count == 4, pieces[2] == "_git" {
            return Self(provider: .azureDevOps, host: host, owner: pieces[0], project: pieces[1], repository: pieces[3])
        }
        let suffix = ".visualstudio.com"
        if host.hasSuffix(suffix), !host.dropLast(suffix.count).isEmpty, !host.dropLast(suffix.count).contains(".") {
            if pieces.first == "DefaultCollection" { pieces.removeFirst() }
            guard pieces.count == 3, pieces[1] == "_git" else { return nil }
            return Self(provider: .azureDevOps, host: host, owner: String(host.dropLast(suffix.count)), project: pieces[0], repository: pieces[2])
        }
        return nil
    }

    fileprivate static func component(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-._~")))!
    }
    package var webURL: URL {
        let segments: [String]
        switch provider {
        case .gitHub: segments = [owner, repository]
        case .azureDevOps: segments = (host == "dev.azure.com" ? [owner] : []) + [project!, "_git", repository]
        }
        return URL(string: "https://\(host)/" + segments.map(Self.component).joined(separator: "/"))!
    }
    package var projectURL: URL? {
        guard provider == .azureDevOps, let project else { return nil }
        let segments = (host == "dev.azure.com" ? [owner] : []) + [project]
        return URL(string: "https://\(host)/" + segments.map(Self.component).joined(separator: "/"))
    }
    package func createPullRequestURL(branch: String) -> URL? {
        let branch = branch.trimmingCharacters(in: .whitespacesAndNewlines)
        guard provider == .azureDevOps, !branch.isEmpty else { return nil }
        return URL(string: webURL.absoluteString + "/pullrequestcreate?sourceRef=" + Self.component(branch))
    }
    package func commitURL(_ id: ObjectID) -> URL {
        webURL.appendingPathComponent("commit").appendingPathComponent(id.string)
    }
    package func blameURL(commit: ObjectID, file: String, line: Int) -> URL? {
        guard provider == .gitHub else { return nil }
        let path = file.split(separator: "/", omittingEmptySubsequences: false).map { Self.component(String($0)) }.joined(separator: "/")
        return URL(string: webURL.absoluteString + "/blame/" + commit.string + "/" + path + "#L\(line)")
    }
}

package struct HostedRemote: Hashable, Sendable {
    package let name: String
    package let url: String
    package let identity: HostedRepositoryIdentity
    package init(name: String, url: String, identity: HostedRepositoryIdentity) {
        self.name = name; self.url = url; self.identity = identity
    }
    package var displayData: String { identity.owner + "/" + identity.repository }
    package var usesHTTPS: Bool { Self.isHTTP(url) }
    package static func isHTTP(_ url: String) -> Bool {
        let lowercased = url.lowercased()
        return lowercased.hasPrefix("http://") || lowercased.hasPrefix("https://")
    }
    package static func gitHubRemotes(_ remotes: [RepositoryRemoteConfiguration]) -> [HostedRemote] {
        var seen: Set<HostedRemote> = []
        return remotes.compactMap { remote in
            guard !remote.isDisabled, !remote.fetchURL.isEmpty,
                  let identity = HostedRepositoryIdentity.parse(remote.fetchURL), identity.provider == .gitHub else { return nil }
            let hosted = HostedRemote(name: remote.name, url: remote.fetchURL, identity: identity)
            return seen.insert(hosted).inserted ? hosted : nil
        }
    }
}

package struct HostedUser: Decodable, Sendable, Hashable { package let login: String }

package struct HostedPullRequest: Decodable, Sendable, Identifiable {
    package let number: Int
    package let title: String
    package let body: String?
    package let state: String
    package let html_url: URL
    package let user: HostedUser
    package let created_at: Date
    package let head: Branch
    package let base: Branch
    package var id: Int { number }
    package var fetchBranch: String { "pr/n\(number)_\(head.ref)" }
    package struct Repository: Decodable, Sendable {
        package let owner: HostedUser
        package let clone_url: URL
        package let ssh_url: String
        package func cloneURL(https: Bool) -> String { https ? clone_url.absoluteString : ssh_url }
    }
    package struct Branch: Decodable, Sendable {
        package let label: String
        package let ref: String
        package let objectID: ObjectID
        package let repo: Repository?
        private enum CodingKeys: String, CodingKey { case label, ref, sha, repo }
        package init(from decoder: any Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            label = try values.decode(String.self, forKey: .label)
            ref = try values.decode(String.self, forKey: .ref)
            objectID = try ObjectID(parsing: values.decode(String.self, forKey: .sha))
            repo = try values.decodeIfPresent(Repository.self, forKey: .repo)
        }
    }
}

package struct HostedRepositoryDetails: Decodable, Sendable {
    package struct Parent: Decodable, Sendable {
        package let clone_url: URL
        package let ssh_url: String
        package let owner: HostedUser
    }
    package let name: String
    package let full_name: String
    package let description: String?
    package let homepage: String?
    package let owner: HostedUser
    package let `private`: Bool
    package let fork: Bool
    package let forks_count: Int?
    package let clone_url: URL
    package let ssh_url: String
    package let default_branch: String
    package let parent: Parent?
    package func cloneURL(https: Bool) -> String { https ? clone_url.absoluteString : ssh_url }
}

package struct HostedBranch: Decodable, Sendable {
    package let name: String
}

package struct HostedDiscussionEntry: Sendable, Equatable {
    package let author: String
    package let created: Date
    package let body: String
    package let commit: String?
}

package struct HostedIssue: Decodable, Sendable {
    package struct Repository: Decodable, Sendable {
        package let name: String
        package let owner: HostedUser
    }
    package let number: Int
    package let title: String
    package let body: String?
    package let updated_at: Date
    package let repository: Repository?
    package var commitTemplate: String { "\nFixes #\(number) : \(title)\n\n\(body ?? "")\n" }
}

package struct HostedDiscussion: Decodable, Sendable {
    package let id: Int
    package let body: String
    package let user: HostedUser
    package let html_url: URL
    package let created_at: Date
}

package enum RepositoryHostError: LocalizedError, Equatable {
    case unsupported, authentication(Int), response(Int), invalidResponse, notFound
    package var errorDescription: String? {
        switch self {
        case .unsupported: "This host action is not supported for the selected repository."
        case .authentication(let status): "Host authentication failed (HTTP \(status)). Check the token and its repository permissions."
        case .response(let status): "The repository host returned HTTP \(status)."
        case .invalidResponse: "The repository host returned an invalid response."
        case .notFound: "The repository host returned HTTP 404."
        }
    }
}

private final class HostRedirectPolicy: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        guard let origin = task.originalRequest?.url, let destination = request.url,
              destination.scheme == origin.scheme, destination.host == origin.host,
              destination.port == origin.port, destination.user == nil, destination.password == nil else {
            completionHandler(nil); return
        }
        completionHandler(request)
    }
}

package typealias HostTransport = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)

package enum HostHTTP {
    package static func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCredentialStorage = nil
        configuration.httpCookieStorage = nil
        let session = URLSession(configuration: configuration, delegate: HostRedirectPolicy(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw RepositoryHostError.invalidResponse }
        return (data, response)
    }
    package static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            guard let date = parseDate(text) else {
                throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Invalid date"))
            }
            return date
        }
        return decoder
    }
    package static func parseDate(_ text: String) -> Date? {
        let plain = ISO8601DateFormatter()
        if let date = plain.date(from: text) { return date }
        guard let dot = text.firstIndex(of: "."), let zone = text[dot...].firstIndex(where: { $0 == "Z" || $0 == "+" || $0 == "-" }) else { return nil }
        let fraction = text[text.index(after: dot)..<zone]
        guard !fraction.isEmpty, fraction.allSatisfy(\.isNumber), let base = plain.date(from: String(text[..<dot]) + String(text[zone...])) else { return nil }
        return base.addingTimeInterval(Double("0." + fraction) ?? 0)
    }
}

package struct RepositoryHostClient: Sendable {
    package typealias Transport = HostTransport
    private let identity: HostedRepositoryIdentity
    private let token: String
    private let transport: Transport

    package init(identity: HostedRepositoryIdentity, token: String, transport: @escaping Transport = HostHTTP.send) {
        self.identity = identity; self.token = token; self.transport = transport
    }

    package func with(_ identity: HostedRepositoryIdentity) -> Self { Self(identity: identity, token: token, transport: transport) }

    private func request(_ segments: [String], method: String = "GET", body: [String: String]? = nil,
                         query: [URLQueryItem] = [], accept: String? = nil) async throws -> Data {
        guard identity.provider == .gitHub else { throw RepositoryHostError.unsupported }
        var components = URLComponents()
        components.scheme = "https"; components.host = "api.github.com"
        components.percentEncodedPath = "/" + segments.map(HostedRepositoryIdentity.component).joined(separator: "/")
        components.queryItems = query.isEmpty ? nil : query
        var request = URLRequest(url: components.url!, timeoutInterval: 120)
        request.httpMethod = method
        request.setValue("GitExtensionsMac", forHTTPHeaderField: "User-Agent")
        request.setValue(accept ?? "application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        if !token.isEmpty { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let body {
            request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        try Task.checkCancellation()
        let (data, response) = try await transport(request)
        try Task.checkCancellation()
        if [401, 403].contains(response.statusCode) { throw RepositoryHostError.authentication(response.statusCode) }
        if response.statusCode == 404 { throw RepositoryHostError.notFound }
        guard (200..<300).contains(response.statusCode) else { throw RepositoryHostError.response(response.statusCode) }
        return data
    }
    private var repositoryPath: [String] { ["repos", identity.owner, identity.repository] }
    private func decode<T: Decodable>(_ type: T.Type, _ data: Data) throws -> T {
        do { return try HostHTTP.decoder().decode(type, from: data) }
        catch { throw RepositoryHostError.invalidResponse }
    }
    private func list<T: Decodable>(_ type: T.Type, path: [String], query: [URLQueryItem] = []) async throws -> [T] {
        var result: [T] = []
        var page = 1
        while true {
            let data = try await request(path, query: query + [.init(name: "per_page", value: "100"), .init(name: "page", value: String(page))])
            let batch = try decode([T].self, data)
            result += batch
            if batch.count < 100 { return result }
            page += 1
        }
    }
    package func repository() async throws -> HostedRepositoryDetails {
        try decode(HostedRepositoryDetails.self, await request(repositoryPath))
    }
    package func currentUser() async throws -> String {
        try decode(HostedUser.self, await request(["user"])).login
    }
    package func branches() async throws -> [HostedBranch] {
        try await list(HostedBranch.self, path: repositoryPath + ["branches"])
            .sorted { $0.name.compare($1.name, options: .caseInsensitive) == .orderedAscending }
    }
    package func pullRequests() async throws -> [HostedPullRequest] {
        try await list(HostedPullRequest.self, path: repositoryPath + ["pulls"])
    }
    package func createPullRequest(head: String, base: String, title: String, body: String) async throws -> HostedPullRequest {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, !head.isEmpty, !base.isEmpty else { throw RepositoryHostError.invalidResponse }
        let created = try decode(HostedPullRequest.self, await request(repositoryPath + ["pulls"], method: "POST",
            body: ["head": head, "base": base, "title": title, "body": body.trimmingCharacters(in: .whitespacesAndNewlines)]))
        guard created.number > 0 else { throw RepositoryHostError.invalidResponse }
        return created
    }
    package func closePullRequest(_ number: Int) async throws -> HostedPullRequest {
        try decode(HostedPullRequest.self, await request(repositoryPath + ["pulls", String(number)], method: "PATCH", body: ["state": "closed"]))
    }
    package func discussion(_ pullRequest: HostedPullRequest) async throws -> [HostedDiscussionEntry] {
        struct PullCommit: Decodable {
            struct Details: Decodable {
                struct Signature: Decodable { let name: String; let date: Date }
                let author: Signature
                let message: String
            }
            let sha: String
            let commit: Details
        }
        let commits = try await list(PullCommit.self, path: repositoryPath + ["pulls", String(pullRequest.number), "commits"])
        let comments = try await list(HostedDiscussion.self, path: repositoryPath + ["issues", String(pullRequest.number), "comments"])
        let entries = [HostedDiscussionEntry(author: pullRequest.user.login, created: pullRequest.created_at, body: pullRequest.body ?? "", commit: nil)]
            + commits.map { .init(author: $0.commit.author.name, created: $0.commit.author.date, body: $0.commit.message, commit: $0.sha) }
            + comments.map { .init(author: $0.user.login, created: $0.created_at, body: $0.body, commit: nil) }
        return entries.enumerated().sorted { ($0.element.created, $0.offset) < ($1.element.created, $1.offset) }.map(\.element)
    }
    package func pullRequestDiff(_ number: Int) async throws -> Data {
        try await request(repositoryPath + ["pulls", String(number)], accept: "application/vnd.github.diff")
    }
    package func postComment(_ number: Int, body: String) async throws -> HostedDiscussion {
        try decode(HostedDiscussion.self, await request(repositoryPath + ["issues", String(number), "comments"], method: "POST", body: ["body": body]))
    }
    package func fork() async throws -> HostedRepositoryDetails {
        try decode(HostedRepositoryDetails.self, await request(repositoryPath + ["forks"], method: "POST"))
    }
    package func myRepositories() async throws -> [HostedRepositoryDetails] {
        try await list(HostedRepositoryDetails.self, path: ["user", "repos"], query: [.init(name: "type", value: "all")])
    }
    package func repositories(user: String) async throws -> [HostedRepositoryDetails] {
        try await list(HostedRepositoryDetails.self, path: ["users", user, "repos"])
    }
    package func searchRepositories(_ text: String) async throws -> [HostedRepositoryDetails] {
        struct SearchResult: Decodable { let items: [HostedRepositoryDetails] }
        var repositories: [HostedRepositoryDetails] = []
        for page in 1...10 {
            let data = try await request(["search", "repositories"], query: [
                .init(name: "q", value: text), .init(name: "per_page", value: "100"), .init(name: "page", value: String(page))])
            let batch = try decode(SearchResult.self, data).items
            repositories += batch
            if batch.count < 100 { break }
        }
        return repositories
    }
    package func assignedIssues() async throws -> [HostedIssue] {
        try await list(HostedIssue.self, path: ["issues"], query: [
            .init(name: "state", value: "open"), .init(name: "filter", value: "assigned"), .init(name: "pulls", value: "false")])
    }
}

package enum BuildStatus: Sendable, Equatable {
    case unknown, inProgress, success, failure, unstable, stopped
    package var symbol: String {
        switch self {
        case .success: "✔"
        case .failure: "❌"
        case .inProgress: "▶️"
        case .stopped: "⏹️"
        case .unstable: "❗"
        case .unknown: "❓"
        }
    }
}

package struct BuildInfo: Sendable, Equatable {
    package var id: String?
    package var startDate: Date
    package var duration: Int64?
    package var status: BuildStatus
    package var description: String?
    package var revisions: [RevisionID]
    package var url: URL?
    package var showInBuildReportTab: Bool
    package var tooltip: String?
    package var pullRequestURL: URL?
    package init(id: String? = nil, startDate: Date = .distantPast, duration: Int64? = nil, status: BuildStatus = .unknown,
                 description: String? = nil, revisions: [RevisionID], url: URL? = nil, showInBuildReportTab: Bool = true,
                 tooltip: String? = nil, pullRequestURL: URL? = nil) {
        self.id = id; self.startDate = startDate; self.duration = duration; self.status = status
        self.description = description; self.revisions = revisions; self.url = url
        self.showInBuildReportTab = showInBuildReportTab; self.tooltip = tooltip; self.pullRequestURL = pullRequestURL
    }
    package func replaces(_ existing: BuildInfo?) -> Bool { existing.map { startDate >= $0.startDate } ?? true }
}

package enum BuildServerError: LocalizedError, Equatable {
    case unauthorized(String)
    case notFound(String)
    case response(Int)
    case invalidResponse
    case initialization(message: String, badToken: Bool, key: String)
    package var errorDescription: String? {
        switch self {
        case .unauthorized(let message), .notFound(let message): message
        case .response(let status): "Response status code does not indicate success: \(status)."
        case .invalidResponse: "The build server returned an invalid response."
        case .initialization(let message, _, _): message
        }
    }
}

package protocol BuildServerAdapter: AnyObject, Sendable {
    var uniqueKey: String { get }
    func finishedBuilds(since: Date?) async throws -> [BuildInfo]
    func runningBuilds() async throws -> [BuildInfo]
    func repositoryChanged() async
}

package enum BuildServerType: String, CaseIterable, Sendable {
    case azureDevOps = "Azure DevOps and Team Foundation Server (since TFS2015)"
    case gitHubActions = "GitHub Actions"
}

package enum BuildServerSettingKeys {
    package static let type = "BuildServer.Type"
    package static let enabled = "BuildServer.EnableIntegration"
    package static let showBuildResultPage = "BuildServer.ShowBuildResultPage"
    package static func adapter(_ type: String, _ key: String) -> String { "BuildServer.\(type).\(key)" }
    package static let gitHubApiURL = "GitHubActionsApiUrl"
    package static let gitHubOwner = "GitHubActionsOwner"
    package static let gitHubRepository = "GitHubActionsRepository"
    package static let azureProjectURL = "ProjectUrl"
    package static let azureDefinitionFilter = "BuildDefinitionNameFilter"
    package static let azureRepositoryName = "RepositoryName"
}

package enum BuildServerAutoDetector {
    package static func detect(_ remoteURLs: [String], only type: BuildServerType? = nil) -> (BuildServerType, [String: String])? {
        for candidate in [BuildServerType.azureDevOps, .gitHubActions] where type == nil || type == candidate {
            for url in remoteURLs {
                guard let identity = HostedRepositoryIdentity.parse(url) else { continue }
                switch (candidate, identity.provider) {
                case (.gitHubActions, .gitHub):
                    return (candidate, [BuildServerSettingKeys.gitHubOwner: identity.owner, BuildServerSettingKeys.gitHubRepository: identity.repository])
                case (.azureDevOps, .azureDevOps):
                    return (candidate, [BuildServerSettingKeys.azureProjectURL: identity.projectURL!.absoluteString,
                                        BuildServerSettingKeys.azureRepositoryName: identity.repository])
                default: continue
                }
            }
        }
        return nil
    }
    package static func orderedRemoteURLs(_ remotes: [RepositoryRemoteConfiguration], prioritized: String = "upstream|origin|remote") -> [String] {
        let names = prioritized.split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        func rank(_ name: String) -> Int { names.firstIndex { $0.caseInsensitiveCompare(name) == .orderedSame } ?? names.count }
        return remotes.filter { !$0.isDisabled }.enumerated()
            .sorted { (rank($0.element.name), $0.offset) < (rank($1.element.name), $1.offset) }
            .map(\.element.fetchURL).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    }
}

package func formatBuildDuration(_ milliseconds: Int64?) -> String {
    guard let milliseconds else { return "" }
    let seconds = milliseconds / 1000
    return String(format: "%02lld:%02lld", (seconds / 60) % 60, seconds % 60)
}

private func buildHTTPGet<T: Decodable>(_ type: T.Type, url: URL, headers: [String: String], transport: HostTransport,
                                        notFound: String? = nil) async throws -> T {
    var request = URLRequest(url: url, timeoutInterval: 120)
    for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
    try Task.checkCancellation()
    let (data, response) = try await transport(request)
    try Task.checkCancellation()
    switch response.statusCode {
    case 401: throw BuildServerError.unauthorized("Unauthorized (HTTP 401).")
    case 403 where notFound != nil: throw BuildServerError.unauthorized("Forbidden (HTTP 403).")
    case 404 where notFound != nil: throw BuildServerError.notFound(notFound!)
    case 200..<300: break
    default: throw BuildServerError.response(response.statusCode)
    }
    do { return try HostHTTP.decoder().decode(type, from: data) }
    catch { throw BuildServerError.invalidResponse }
}

package final class GitHubActionsBuildAdapter: BuildServerAdapter, @unchecked Sendable {
    package static let defaultApiURL = "https://api.github.com"
    private let baseURL: String
    private let token: String?
    private let transport: HostTransport
    private let lock = NSLock()
    private var loadedItems: [String: Date] = [:]

    package init?(apiURL: String?, owner: String?, repository: String?, token: String?, transport: @escaping HostTransport = HostHTTP.send) {
        guard let owner = owner?.trimmingCharacters(in: .whitespaces), !owner.isEmpty,
              let repository = repository?.trimmingCharacters(in: .whitespaces), !repository.isEmpty else { return nil }
        var api = (apiURL?.isEmpty == false ? apiURL! : Self.defaultApiURL)
        while api.hasSuffix("/") { api.removeLast() }
        guard let scheme = URL(string: api)?.scheme?.lowercased(), ["http", "https"].contains(scheme) else { return nil }
        baseURL = api + "/repos/" + HostedRepositoryIdentity.component(owner) + "/" + HostedRepositoryIdentity.component(repository)
        self.token = token?.isEmpty == false ? token : nil
        self.transport = transport
    }
    package var uniqueKey: String { baseURL }
    package func finishedBuilds(since: Date?) async throws -> [BuildInfo] { try await builds(since: since, running: false) }
    package func runningBuilds() async throws -> [BuildInfo] { try await builds(since: nil, running: true) }
    package func repositoryChanged() async {}

    struct Run: Decodable {
        let id: Int64
        let name: String?
        let head_sha: String
        let status: String?
        let conclusion: String?
        let html_url: String?
        let created_at: Date
        let updated_at: Date
        let run_started_at: Date?
        let run_number: Int
    }
    private struct Runs: Decodable { let workflow_runs: [Run] }

    private func builds(since: Date?, running: Bool) async throws -> [BuildInfo] {
        var result: [BuildInfo] = []
        var page = 1
        var headers = ["Accept": "application/json", "User-Agent": "GitExtensions", "X-GitHub-Api-Version": "2022-11-28"]
        if let token { headers["Authorization"] = "Bearer \(token)" }
        while true {
            var query = "page=\(page)&per_page=100&status=" + (running ? "in_progress" : "completed")
            if let since {
                let formatter = ISO8601DateFormatter()
                formatter.formatOptions = [.withInternetDateTime]
                query += "&created=" + (">=" + formatter.string(from: since)).addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-._~")))!
            }
            let url = URL(string: baseURL + "/actions/runs?" + query)!
            let response = try await buildHTTPGet(Runs.self, url: url, headers: headers, transport: transport,
                notFound: "Repository not found at \(url.absoluteString). Check owner/repository settings.")
            for run in response.workflow_runs {
                let emit: Bool = lock.withLock {
                    guard loadedItems[run.head_sha].map({ $0 < run.updated_at }) ?? true else { return false }
                    loadedItems[run.head_sha] = run.updated_at
                    return true
                }
                if emit, let info = Self.buildInfo(run) { result.append(info) }
            }
            if response.workflow_runs.count < 100 { return result }
            page += 1
        }
    }

    static func buildInfo(_ run: Run) -> BuildInfo? {
        guard let objectID = try? ObjectID(parsing: run.head_sha) else { return nil }
        let status: BuildStatus
        if ["in_progress", "queued", "requested", "waiting", "pending"].contains(run.status ?? "") {
            status = .inProgress
        } else {
            switch run.conclusion {
            case "success", "skipped", "neutral": status = .success
            case "failure", "timed_out": status = .failure
            case "cancelled": status = .stopped
            case "action_required", "stale": status = .unstable
            default: status = .unknown
            }
        }
        let started = run.run_started_at ?? run.created_at
        let statusText = status == .inProgress ? (run.status ?? "in progress") : (run.conclusion ?? run.status ?? "unknown")
        return BuildInfo(id: String(run.id), startDate: started, duration: Int64((run.updated_at.timeIntervalSince(started) * 1000).rounded(.towardZero)),
                         status: status, description: "\(run.name ?? "workflow") #\(run.run_number) (\(statusText))",
                         revisions: [.object(objectID)], url: run.html_url.flatMap(URL.init(string:)), showInBuildReportTab: false)
    }
}

package enum AzureDevOpsProjectURL {
    private static let remoteToProject: [(String, (NSTextCheckingResult, NSString) -> String)] = [
        (#"^(?<prot>(?:http|https))://(?<user>[^.@]+)(?:@[^.]*)?\.visualstudio\.com(?<port>:\d*)?(?:/DefaultCollection)?(?<project>(/[^/]+)?/[^/]+)/_(git|ssh)/(.+)$"#,
         { m, s in "\(group(m, s, "prot"))://\(group(m, s, "user")).visualstudio.com\(group(m, s, "port"))\(group(m, s, "project"))" }),
        (#"^(?<user>[^.@]+)@vs-ssh\.visualstudio.com:v3(?:/[^/]*)?(?<project>/[^/]+)"#,
         { m, s in "https://\(group(m, s, "user")).visualstudio.com\(group(m, s, "project"))" }),
        (#"^(?<prot>(?:http|https))://(?:[^.@]+@)?dev\.azure\.com(?<port>:\d*)?(?<project>(?:/[^/]+)?/[^/]+)/_(?:git|ssh)/(?:.+)$"#,
         { m, s in "\(group(m, s, "prot"))://dev.azure.com\(group(m, s, "port"))\(group(m, s, "project"))" }),
        (#"^[^.@]+@ssh\.dev\.azure\.com:v3(?<project>(?:/[^/]+)?/[^/]+)"#,
         { m, s in "https://dev.azure.com\(group(m, s, "project"))" }),
        (#"^(?<instanceurl>(?:http|https)://[^/]+(?::\d*)?(?:/[^/]+)+/DefaultCollection)(?<project>/[^/]+)/_(?:git|ssh)"#,
         { m, s in "\(group(m, s, "instanceurl"))\(group(m, s, "project"))" }),
        (#"^(?<instanceurl>(?:http|https)://[^/]+(?::\d*)?(?:/[^/]+)+/DefaultCollection)/_(?:git|ssh)(?<project>/[^/]+)"#,
         { m, s in "\(group(m, s, "instanceurl"))\(group(m, s, "project"))" })
    ]
    private static let projectToTokenManagement = [
        #"^(?<instanceurl>(?:http|https)://[^.@]+(?:@[^.]*)?\.visualstudio\.com(?::\d*)?)"#,
        #"^(?<instanceurl>(?:http|https)://dev\.azure\.com(?::\d*)?/[^/]+)"#,
        #"^(?<instanceurl>(?:http|https)://[^/]+(?::\d*)?(?:/[^/]+)+)/[^/]+"#
    ]
    private static func group(_ match: NSTextCheckingResult, _ text: NSString, _ name: String) -> String {
        let range = match.range(withName: name)
        return range.location == NSNotFound ? "" : text.substring(with: range)
    }
    private static func firstMatch(_ pattern: String, _ value: String) -> NSTextCheckingResult? {
        (try? NSRegularExpression(pattern: pattern))?.firstMatch(in: value, range: NSRange(value.startIndex..., in: value))
    }
    package static func project(fromRemote url: String) -> String? {
        for (pattern, convert) in remoteToProject {
            if let match = firstMatch(pattern, url) { return convert(match, url as NSString) }
        }
        return nil
    }
    package static func project(fromRemotes urls: [String]) -> String? { urls.lazy.compactMap(project(fromRemote:)).first }
    package static func tokenManagementURL(project: String) -> URL? {
        for pattern in projectToTokenManagement {
            if let match = firstMatch(pattern, project) {
                return URL(string: group(match, project as NSString, "instanceurl") + "/_details/security/tokens")
            }
        }
        return nil
    }
    package static func parseBuildURL(_ url: String) -> (project: String, buildID: Int)? {
        guard let match = firstMatch(#"^(?<projecturl>(?:http|https)://[^/]+(?::\d*)?(?:/[^/]+)+)/_build.*(?:&|\?)buildId=(?<buildid>\d+)"#, url),
              let id = Int(group(match, url as NSString, "buildid")) else { return nil }
        return (group(match, url as NSString, "projecturl"), id)
    }
    package static func isRegexValid(_ pattern: String) -> Bool { pattern.isEmpty || (try? NSRegularExpression(pattern: pattern)) != nil }
}

private final class AzureBuildsCache: @unchecked Sendable {
    static let shared = AzureBuildsCache()
    let lock = NSLock()
    var id: String?
    var buildDefinitions: String?
    var finishedBuilds: [BuildInfo] = []
    var lastCall = Date.distantPast
    func reset() { lock.withLock { id = nil; buildDefinitions = nil; finishedBuilds = []; lastCall = .distantPast } }
}

package final class AzureDevOpsBuildAdapter: BuildServerAdapter, @unchecked Sendable {
    package struct Settings: Sendable, Equatable {
        package var projectURL: String
        package var buildDefinitionFilter: String
        package var repositoryName: String
        package init(projectURL: String, buildDefinitionFilter: String = "", repositoryName: String = "") {
            self.projectURL = projectURL; self.buildDefinitionFilter = buildDefinitionFilter; self.repositoryName = repositoryName
        }
        package var isValid: Bool {
            !projectURL.trimmingCharacters(in: .whitespaces).isEmpty && AzureDevOpsProjectURL.isRegexValid(buildDefinitionFilter)
        }
    }
    package static let badTokenMessage = """
    The personal access token is invalid or has expired. Update it in the 'Build server integration' settings.

    The build server integration has been disabled for this session.
    """
    package static let genericErrorMessage = """
    An error occurred when requesting build server results.

    As a consequence, the build server integration has been disabled for this session.

    Detail of the error:
    """
    private let settings: Settings
    private let projectURL: String
    private let baseURL: URL
    private let authorization: String?
    private let transport: HostTransport
    private let lock = NSLock()
    private var firstFinishedCallIgnored = false
    private var disabled = false
    private var buildDefinitions: String?
    private var buildDefinitionsLoaded = false
    private var cacheKey: String { projectURL + "|" + settings.buildDefinitionFilter }

    package init(settings: Settings, projectURL: String, pat: String?, credentialPassword: String?, transport: @escaping HostTransport = HostHTTP.send) throws {
        guard settings.isValid else { throw BuildServerError.invalidResponse }
        guard let url = URL(string: projectURL), url.scheme != nil, url.host != nil,
              let base = URL(string: projectURL.hasSuffix("/") ? projectURL + "_apis/" : projectURL + "/_apis/") else {
            throw BuildServerError.invalidResponse
        }
        self.settings = settings; self.projectURL = projectURL; baseURL = base; self.transport = transport
        if let pat, !pat.isEmpty { authorization = "Basic " + Data(":\(pat)".utf8).base64EncodedString() }
        else if let credentialPassword, !credentialPassword.isEmpty { authorization = "Bearer \(credentialPassword)" }
        else { authorization = nil }
        let cache = AzureBuildsCache.shared
        cache.lock.withLock {
            if cache.id == cacheKey { buildDefinitions = cache.buildDefinitions; buildDefinitionsLoaded = true }
            else { cache.id = nil; cache.buildDefinitions = nil; cache.finishedBuilds = []; cache.lastCall = .distantPast }
        }
    }
    package var uniqueKey: String { settings.projectURL }
    package func repositoryChanged() async { AzureBuildsCache.shared.reset() }

    struct Build: Decodable {
        struct Definition: Decodable { let id: Int?; let name: String? }
        struct Links: Decodable { struct Link: Decodable { let href: String? }; let web: Link? }
        struct Repository: Decodable { let url: String? }
        var sourceVersion: String?
        let status: String?
        let buildNumber: String?
        let result: String?
        let reason: String?
        let repository: Repository?
        let parameters: String?
        let definition: Definition?
        let _links: Links?
        let startTime: Date?
        let finishTime: Date?
        var isInProgress: Bool { status != "completed" }
    }
    private struct ListWrapper<T: Decodable>: Decodable { let count: Int?; let value: [T]? }
    private struct GitRepository: Decodable { let id: String? }

    private func get<T: Decodable>(_ type: T.Type, _ relative: String) async throws -> T {
        guard let encoded = relative.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed.subtracting(CharacterSet(charactersIn: "+"))),
              let url = URL(string: encoded, relativeTo: baseURL)?.absoluteURL else { throw BuildServerError.invalidResponse }
        var headers = ["Accept": "application/json"]
        if let authorization { headers["Authorization"] = authorization }
        return try await buildHTTPGet(type, url: url, headers: headers, transport: transport)
    }

    private func loadBuildDefinitions() async throws -> String? {
        let filter = settings.buildDefinitionFilter
        var repositoryFilter = ""
        if !settings.repositoryName.trimmingCharacters(in: .whitespaces).isEmpty {
            let name = settings.repositoryName.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-._~"))) ?? settings.repositoryName
            if let id = try? await get(GitRepository.self, "git/repositories/\(name)?api-version=6.0").id {
                repositoryFilter = "&repositoryId=\(id)&repositoryType=TfsGit"
            }
        }
        let unfiltered = filter.trimmingCharacters(in: .whitespaces).isEmpty
        let named = try await get(ListWrapper<Build.Definition>.self,
            "build/definitions?api-version=6.0" + (unfiltered ? "" : "&name=" + filter) + repositoryFilter)
        if (named.count ?? 0) != 0 { return ids(named.value) }
        if unfiltered { return nil }
        let all = try await get(ListWrapper<Build.Definition>.self, "build/definitions?api-version=6.0" + repositoryFilter)
        let regex = try NSRegularExpression(pattern: filter)
        return ids(all.value?.filter { definition in
            guard let name = definition.name else { return false }
            return regex.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)) != nil
        })
    }
    private func ids(_ definitions: [Build.Definition]?) -> String? {
        let ids = (definitions ?? []).compactMap(\.id).map(String.init)
        return ids.isEmpty ? nil : ids.joined(separator: ",")
    }

    private func definitions() async throws -> String? {
        if lock.withLock({ disabled }) { return nil }
        if lock.withLock({ buildDefinitionsLoaded }) { return lock.withLock { buildDefinitions } }
        do {
            let loaded = try await loadBuildDefinitions()
            lock.withLock { buildDefinitions = loaded; buildDefinitionsLoaded = true }
            if let loaded {
                let cache = AzureBuildsCache.shared
                cache.lock.withLock { cache.id = cacheKey; cache.buildDefinitions = loaded; cache.finishedBuilds = []; cache.lastCall = .distantPast }
            }
            return loaded
        } catch is CancellationError {
            throw CancellationError()
        } catch BuildServerError.unauthorized {
            lock.withLock { disabled = true }
            throw BuildServerError.initialization(message: Self.badTokenMessage, badToken: true, key: cacheKey)
        } catch {
            lock.withLock { disabled = true }
            throw BuildServerError.initialization(message: Self.genericErrorMessage + "\n" + (error.localizedDescription), badToken: false, key: cacheKey)
        }
    }

    private static let properties = "properties=sourceVersion,status,buildNumber,result,definition,_links,startTime,finishTime"
    package func runningBuilds() async throws -> [BuildInfo] {
        guard let definitions = try await definitions() else { return [] }
        let builds = try await get(ListWrapper<Build>.self, "build/builds?\(Self.properties)&definitions=\(definitions)&statusFilter=cancelling,inProgress,none,notStarted,postponed&api-version=2.0").value ?? []
        return Self.filterRunning(builds).compactMap { Self.buildInfo($0) }
    }

    package func finishedBuilds(since: Date?) async throws -> [BuildInfo] {
        let ignore: Bool = lock.withLock {
            if firstFinishedCallIgnored { return false }
            firstFinishedCallIgnored = true; return true
        }
        if ignore { return [] }
        guard let definitions = try await definitions() else { return [] }
        let cache = AzureBuildsCache.shared
        var result: [BuildInfo] = []
        var since = since
        if since == nil {
            let cached = cache.lock.withLock { (cache.finishedBuilds, cache.lastCall) }
            if !cached.0.isEmpty { result = cached.0; since = cached.1 }
        }
        var query = "build/builds?\(Self.properties)&definitions=\(definitions)&statusFilter=completed"
        if let since {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withFullDate, .withTime, .withColonSeparatorInTime, .withDashSeparatorInDate]
            query += "&minTime=\(formatter.string(from: since))&api-version=4.1"
        } else { query += "&api-version=2.0" }
        let builds = try await get(ListWrapper<Build>.self, query).value ?? []
        var order: [String] = []
        var groups: [String: [Build]] = [:]
        for build in builds {
            let key = build.sourceVersion ?? ""
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(build)
        }
        for key in order {
            guard let latest = groups[key]!.enumerated().max(by: {
                (($0.element.finishTime ?? .distantPast), -$0.offset) < (($1.element.finishTime ?? .distantPast), -$1.offset)
            })?.element, let info = Self.buildInfo(latest) else { continue }
            result.append(info)
            cache.lock.withLock {
                cache.finishedBuilds.append(info)
                if let finish = latest.finishTime, finish >= cache.lastCall { cache.lastCall = finish.addingTimeInterval(1) }
            }
        }
        return result
    }

    static func filterRunning(_ builds: [Build]) -> [Build] {
        guard builds.count >= 2 else { return builds }
        var order: [String] = []
        var groups: [String: [Build]] = [:]
        for build in builds {
            let key = build.sourceVersion ?? ""
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(build)
        }
        return order.map { key in
            let group = groups[key]!
            return group.filter { $0.startTime != nil }.min { $0.startTime! < $1.startTime! } ?? group[0]
        }
    }

    private static func convertResult(_ value: String?) -> String {
        switch value {
        case "failed": "❌"
        case "canceled", "cancelling": "⏹️"
        case "succeeded": "✔"
        case "partiallySucceeded": "❗"
        case "inProgress": "▶️"
        case "notStarted": "⏸"
        case "postponed": "⏱"
        default: "❓"
        }
    }

    static func buildInfo(_ build: Build, now: Date = Date()) -> BuildInfo? {
        var build = build
        var duration = ""
        if let status = build.status, !["none", "notStarted", "postponed"].contains(status), let start = build.startTime {
            if status == "inProgress" {
                duration = formatBuildDuration(Int64(now.timeIntervalSince(start) * 1000))
            } else {
                duration = build.finishTime.map { formatBuildDuration(Int64($0.timeIntervalSince(start) * 1000)) } ?? "???"
            }
        }
        let tooltip = "\(build.buildNumber ?? "") \(convertResult(build.isInProgress ? build.status : build.result)) - \(duration) [\(build.definition?.name ?? "")]"
        var pullRequestTooltip = ""
        var pullRequestURL: URL?
        if build.reason == "validateShelveset" {
            let parameters = build.parameters.flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
            if let commit = parameters?["system.pullRequest.sourceCommitId"] as? String, !commit.isEmpty { build.sourceVersion = commit }
            if let id = parameters?["system.pullRequest.pullRequestId"] as? String, !id.trimmingCharacters(in: .whitespaces).isEmpty {
                pullRequestTooltip = "\nPR #\(id)"
                pullRequestURL = URL(string: "\(build.repository?.url ?? "")/pullrequest/\(id)")
            }
        }
        guard let source = build.sourceVersion, let objectID = try? ObjectID(parsing: source) else { return nil }
        let status: BuildStatus
        if build.isInProgress { status = .inProgress }
        else {
            switch build.result {
            case "failed": status = .failure
            case "canceled": status = .stopped
            case "succeeded": status = .success
            case "partiallySucceeded": status = .unstable
            default: status = .unknown
            }
        }
        return BuildInfo(id: build.buildNumber, startDate: build.startTime ?? .distantPast, status: status,
                         description: duration + " " + (build.buildNumber ?? ""), revisions: [.object(objectID)],
                         url: build._links?.web?.href.flatMap(URL.init(string:)), showInBuildReportTab: false,
                         tooltip: tooltip + pullRequestTooltip, pullRequestURL: pullRequestURL)
    }

    package func buildDefinitionName(buildID: Int) async throws -> String? {
        try await get(Build.self, "build/builds/\(buildID)?api-version=2.0").definition?.name
    }
}

package func replaceBuildServerVariables(_ value: String, remoteURL: String?) -> String {
    guard let remoteURL, !remoteURL.isEmpty else { return value }
    let file = (remoteURL as NSString).lastPathComponent
    let name = (file as NSString).deletingPathExtension
    let project = (((remoteURL as NSString).deletingLastPathComponent as NSString).lastPathComponent as NSString).deletingPathExtension
    var result = value
    if !project.trimmingCharacters(in: .whitespaces).isEmpty { result = result.replacingOccurrences(of: "{cRepoProject}", with: project) }
    if !name.trimmingCharacters(in: .whitespaces).isEmpty { result = result.replacingOccurrences(of: "{cRepoShortName}", with: name) }
    return result
}
