import Foundation
import GitExtensionsCore

package struct ImpactWeek: Hashable, Comparable, Sendable {
    package let year: Int
    package let month: Int
    package let day: Int

    package init(year: Int, month: Int, day: Int) {
        self.year = year
        self.month = month
        self.day = day
    }

    package static func < (lhs: ImpactWeek, rhs: ImpactWeek) -> Bool {
        (lhs.year, lhs.month, lhs.day) < (rhs.year, rhs.month, rhs.day)
    }

    package var date: Date {
        ImpactLog.calendar.date(from: DateComponents(year: year, month: month, day: day))!
    }
}

package struct ImpactDataPoint: Hashable, Sendable {
    package var commits: Int
    package var addedLines: Int
    package var deletedLines: Int

    package init(commits: Int, addedLines: Int, deletedLines: Int) {
        self.commits = commits
        self.addedLines = addedLines
        self.deletedLines = deletedLines
    }

    package var changedLines: Int { addedLines + deletedLines }

    package static let zero = ImpactDataPoint(commits: 0, addedLines: 0, deletedLines: 0)

    package static func + (lhs: ImpactDataPoint, rhs: ImpactDataPoint) -> ImpactDataPoint {
        ImpactDataPoint(commits: lhs.commits + rhs.commits, addedLines: lhs.addedLines + rhs.addedLines,
                        deletedLines: lhs.deletedLines + rhs.deletedLines)
    }
}

package struct ImpactCommit: Hashable, Sendable {
    package let week: ImpactWeek
    package let author: String
    package let data: ImpactDataPoint

    package init(week: ImpactWeek, author: String, data: ImpactDataPoint) {
        self.week = week
        self.author = author
        self.data = data
    }
}

package enum ImpactLog {
    static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    package static var currentFirstDayOfWeek: Int { Calendar.current.firstWeekday - 1 }

    package static func command(respectMailmap: Bool) -> GitCommand {
        GitCommand(arguments: ["log", "--pretty=tformat:--- %ad --- \(respectMailmap ? "%aN" : "%an")", "--numstat",
                               "--date=short", "--find-copies", "--all", "--no-merges"],
                   accessesRemote: false, changesRepositoryState: false).logMetadata()
    }

    package static func week(of date: String, firstDayOfWeek: Int) -> ImpactWeek? {
        let parts = date.trimmingCharacters(in: .whitespaces).split(separator: "-")
        guard parts.count == 3, let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]),
              let parsed = calendar.date(from: DateComponents(year: year, month: month, day: day)),
              calendar.component(.day, from: parsed) == day else { return nil }
        let dayOfWeek = calendar.component(.weekday, from: parsed) - 1
        guard let start = calendar.date(byAdding: .day, value: firstDayOfWeek - dayOfWeek, to: parsed) else { return nil }
        let components = calendar.dateComponents([.year, .month, .day], from: start)
        return ImpactWeek(year: components.year!, month: components.month!, day: components.day!)
    }

    package static func parse(_ output: String, firstDayOfWeek: Int, isCancelled: () -> Bool = { false }) -> [ImpactCommit] {
        let lines = output.split(separator: "\n", omittingEmptySubsequences: true)
        var commits: [ImpactCommit] = []
        commits.reserveCapacity(lines.count / 6)
        var index = 0
        while !isCancelled(), index < lines.count {
            let line = lines[index]
            index += 1
            guard line.hasPrefix("--- ") else { continue }
            let header = line.dropFirst(4).components(separatedBy: " --- ")
            let fields = header.count > 2 ? [header[0], header[1...].joined(separator: " --- ")] : header
            let nonEmpty = fields.filter { !$0.isEmpty }
            guard nonEmpty.count == 2 else { continue }
            let week = ImpactLog.week(of: nonEmpty[0], firstDayOfWeek: firstDayOfWeek)
            var added = 0
            var deleted = 0
            while index < lines.count, !lines[index].hasPrefix("--- "), !isCancelled() {
                let file = lines[index].split(separator: "\t", omittingEmptySubsequences: false)
                index += 1
                guard file.count >= 2 else { continue }
                if file[0] != "-", let value = Int(file[0]) { added += value }
                if file[1] != "-", let value = Int(file[1]) { deleted += value }
            }
            if !isCancelled(), let week {
                commits.append(ImpactCommit(week: week, author: nonEmpty[1],
                                            data: ImpactDataPoint(commits: 1, addedLines: added, deletedLines: deleted)))
            }
        }
        return commits
    }
}

package protocol RepositoryImpactDataSource: Sendable {
    func impactCommits(submodulePath: String?, respectMailmap: Bool, firstDayOfWeek: Int) async throws -> [ImpactCommit]
    func impactSubmodulePaths() async throws -> [String]
}

extension GitRepositoryModule: RepositoryImpactDataSource {
    private func impactRoot() throws -> URL {
        guard let repository = resolvedRepository else { throw RepositoryDataSourceError.unavailable }
        return repository.rootURL
    }

    package func impactCommits(submodulePath: String?, respectMailmap: Bool, firstDayOfWeek: Int) async throws -> [ImpactCommit] {
        let root = try impactRoot()
        let directory = submodulePath.map { root.appendingPathComponent($0, isDirectory: true) } ?? root
        try Task.checkCancellation()
        let command = ImpactLog.command(respectMailmap: respectMailmap)
        let result = try await git.run(command, in: directory)
        try Task.checkCancellation()
        guard result.succeeded else {
            throw GitError.commandFailed(arguments: command.arguments, status: result.exitStatus, stderr: result.standardErrorString)
        }
        let commits = ImpactLog.parse(result.standardOutputString, firstDayOfWeek: firstDayOfWeek, isCancelled: { Task.isCancelled })
        try Task.checkCancellation()
        return commits
    }

    package func impactSubmodulePaths() async throws -> [String] {
        let root = try impactRoot()
        var paths: [String] = []
        func collect(_ directory: URL, parent: String) async throws {
            let modules = directory.appendingPathComponent(".gitmodules")
            guard FileManager.default.fileExists(atPath: modules.path) else { return }
            try Task.checkCancellation()
            let result = try await git.run(GitCommand(arguments: ["config", "--null", "--file", modules.path, "--get-regexp", "^submodule\\..*\\.path$"],
                                                      accessesRemote: false, changesRepositoryState: false), in: root)
            let children = result.standardOutput.split(separator: 0).compactMap { record -> String? in
                let text = String(decoding: record, as: UTF8.self)
                guard let newline = text.firstIndex(of: "\n") else { return nil }
                let path = text[text.index(after: newline)...].trimmingCharacters(in: .whitespacesAndNewlines)
                return path.isEmpty ? nil : (parent.isEmpty ? path : parent + "/" + path)
            }
            paths += children
            for child in children {
                try await collect(root.appendingPathComponent(child, isDirectory: true), parent: child)
            }
        }
        try await collect(root, parent: "")
        return paths.filter { RepositoryHistory.isValidGitWorkingDir(root.appendingPathComponent($0, isDirectory: true).path) }
    }
}
