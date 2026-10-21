import Foundation

package struct RepositoryConflictTemporaryFiles: Hashable, Sendable {
    package let base: URL?
    package let local: URL?
    package let remote: URL?

    package init(base: URL?, local: URL?, remote: URL?) {
        self.base = base
        self.local = local
        self.remote = remote
    }

    package var all: [URL] { [base, local, remote].compactMap { $0 } }
}

package enum MergeToolInvocationError: LocalizedError, Equatable, Sendable {
    case invalidCommand(String)

    package var errorDescription: String? {
        switch self {
        case .invalidCommand(let command): "The merge tool command cannot be parsed: \(command)"
        }
    }
}

package enum MergeToolInvocation {
    package static let kdiff3DefaultCommand = "\"$BASE\" \"$LOCAL\" \"$REMOTE\" -o \"$MERGED\""

    package static func availableTools(output: String, defaultTool: String) -> [String] {
        var tools: [String] = []
        for line in output.components(separatedBy: "\n") {
            if line == "The following tools are valid, but not currently available:" { break }
            guard line.hasPrefix("\t\t") else { continue }
            let value = String(line.dropFirst(2))
            let end = [value.range(of: " ")?.lowerBound, value.range(of: ".cmd")?.lowerBound].compactMap { $0 }.min() ?? value.endIndex
            let name = String(value[..<end])
            if !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !tools.contains(name), !["vimdiff", "vimdiff1", "vimdiff2", "vimdiff3"].contains(name) { tools.append(name) }
        }
        return tools.sorted {
            if ($0 == defaultTool) != ($1 == defaultTool) { return $0 == defaultTool }
            return $0.localizedCompare($1) == .orderedAscending
        }
    }

    package static func defaults(tool: String, command: String?, path: String?) -> (command: String?, path: String?) {
        guard tool == "kdiff3" else { return (command, path) }
        return ((command?.isEmpty ?? true) ? kdiff3DefaultCommand : command, (path?.isEmpty ?? true) ? "kdiff3" : path)
    }

    package static func resolveExecutable(_ path: String, workingDirectory: URL, searchPaths: [String]) -> String? {
        guard !path.isEmpty else { return nil }
        let manager = FileManager.default
        func isFile(_ candidate: String) -> Bool {
            var directory: ObjCBool = false
            return manager.fileExists(atPath: candidate, isDirectory: &directory) && !directory.boolValue
        }
        let direct = path.hasPrefix("/") ? path : workingDirectory.appendingPathComponent(path).path
        if isFile(direct) { return URL(fileURLWithPath: direct).standardizedFileURL.path }
        guard !path.contains("/") else { return nil }
        for directory in searchPaths where !directory.isEmpty {
            let candidate = URL(fileURLWithPath: directory, isDirectory: true).appendingPathComponent(path).path
            if isFile(candidate) { return candidate }
        }
        return nil
    }

    package static func twoWay(_ arguments: [String], tool: String) -> [String] {
        switch tool.lowercased() {
        case "kdiff3", "diffmerge", "smerge":
            return arguments.filter { $0 != "$BASE" }
        case "tortoisemerge":
            return arguments
                .filter { $0 != "-base:$BASE" && $0 != "/base:$BASE" }
                .map { $0.replacingOccurrences(of: "mine:$LOCAL", with: "base:$LOCAL") }
        default:
            return arguments
        }
    }

    package static func arguments(command: String, tool: String, twoWay useTwoWay: Bool,
                                  base: String?, local: String?, remote: String?, merged: String, executable: String? = nil, configuredPath: String? = nil) throws -> [String] {
        guard var tokens = try? ScriptExecution.arguments(command) else { throw MergeToolInvocationError.invalidCommand(command) }
        if let first = tokens.first, first == executable || first == configuredPath { tokens.removeFirst() }
        let template = useTwoWay ? twoWay(tokens, tool: tool) : tokens
        return template.map { token in
            token.replacingOccurrences(of: "$BASE", with: base ?? "")
                .replacingOccurrences(of: "$LOCAL", with: local ?? "")
                .replacingOccurrences(of: "$REMOTE", with: remote ?? "")
                .replacingOccurrences(of: "$MERGED", with: merged)
        }
    }
}

package enum ConflictPartFileName {
    package static func `extension`(of path: String) -> Substring {
        let name = path.split(separator: "/", omittingEmptySubsequences: false).last ?? Substring(path)
        guard let dot = name.lastIndex(of: "."), name.index(after: dot) != name.endIndex else { return "" }
        return name[dot...]
    }

    package static func name(for fileName: String, side: String, processID: Int32) -> String {
        let fileExtension = `extension`(of: fileName)
        return "\(fileName.dropLast(fileExtension.count))_\(side)_\(processID)\(fileExtension)"
    }

    package static func available(_ basePath: String, exists: (String) -> Bool) -> String {
        let fileExtension = `extension`(of: basePath)
        let stem = basePath.dropLast(fileExtension.count)
        var test = basePath
        var index = 1
        while exists(test), index < 50 {
            test = "\(stem)_\(index)\(fileExtension)"
            index += 1
        }
        return test
    }
}

package enum ConflictBinaryDetection {
    package static let binaryExtensions = LostObjectsCommands.binaryExtensions

    static let textDiffDrivers: Set<String> = [
        "set", "astextplain", "ada", "bibtext", "cpp", "csharp", "css", "dts", "elixir", "fortran", "html", "java", "kotlin",
        "markdown", "matlab", "objc", "pascal", "perl", "php", "python", "ruby", "rust", "scheme", "tex"
    ]

    package static func attributes(fromCheckAttr output: String) -> [String: String] {
        let fields = output.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "\0" || $0 == "\n" }).map(String.init)
        var values: [String: String] = [:]
        var index = 0
        while index + 2 < fields.count {
            values[fields[index + 1].trimmingCharacters(in: .whitespaces)] = fields[index + 2].trimmingCharacters(in: .whitespaces)
            index += 3
        }
        return values
    }

    package static func isBinaryAccordingToAttributes(_ attributes: [String: String]) -> Bool? {
        if let diff = attributes["diff"] {
            if diff == "unset" { return true }
            if textDiffDrivers.contains(diff) { return false }
        }
        if let text = attributes["text"], text != "unset", text != "unspecified" { return false }
        if let crlf = attributes["crlf"], crlf != "unset", crlf != "unspecified" { return false }
        if let eol = attributes["eol"], eol != "unset", eol != "unspecified" { return false }
        return nil
    }

    package static func hasBinaryExtension(_ path: String) -> Bool {
        let lower = path.lowercased()
        return binaryExtensions.contains { lower.hasSuffix($0) }
    }

    package static func isBinary(path: String, checkAttrOutput: String?) -> Bool {
        guard !path.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        let byAttributes = checkAttrOutput.flatMap { isBinaryAccordingToAttributes(attributes(fromCheckAttr: $0)) }
        return byAttributes ?? hasBinaryExtension(path)
    }
}
