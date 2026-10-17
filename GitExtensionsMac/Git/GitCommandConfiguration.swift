import Foundation

package struct GitConfigItem: Sendable, Equatable {
    package let key: String
    package let value: String

    package init(_ key: String, _ value: String) {
        self.key = key
        self.value = value
    }
}

package struct GitCommandConfiguration: Sendable {
    private var itemsByCommand: [String: [GitConfigItem]] = [:]

    package init() {}

    package static let `default`: GitCommandConfiguration = {
        var configuration = GitCommandConfiguration()
        configuration.add(GitConfigItem("rebase.autosquash", "false"), commands: "rebase")
        configuration.add(GitConfigItem("log.showsignature", "false"), commands: "log", "show", "whatchanged")
        configuration.add(GitConfigItem("color.ui", "never"), commands: "diff", "range-diff", "grep")
        configuration.add(GitConfigItem("diff.submodule", "short"), commands: "diff")
        configuration.add(GitConfigItem("diff.noprefix", "false"), commands: "diff")
        configuration.add(GitConfigItem("diff.mnemonicprefix", "false"), commands: "diff")
        configuration.add(GitConfigItem("diff.ignoresubmodules", "none"), commands: "diff", "status")
        configuration.add(GitConfigItem("core.safecrlf", "false"), commands: "diff")
        return configuration
    }()

    package mutating func add(_ item: GitConfigItem, commands: String...) {
        for command in commands {
            itemsByCommand[command, default: []].append(item)
        }
    }

    package func items(for command: String) -> [GitConfigItem] {
        itemsByCommand[command] ?? []
    }

    package func apply(to arguments: [String]) -> [String] {
        guard let index = Self.subcommandIndex(in: arguments) else { return arguments }
        let defaults = items(for: arguments[index])
        guard !defaults.isEmpty else { return arguments }
        let explicit = Self.explicitConfigKeys(in: arguments[..<index])
        let added = defaults.filter { !explicit.contains($0.key.lowercased()) }.flatMap { ["-c", "\($0.key)=\($0.value)"] }
        return added + arguments
    }

    private static let optionsWithValue: Set<String> = [
        "-c", "-C", "--git-dir", "--work-tree", "--namespace", "--config-env", "--super-prefix", "--attr-source"
    ]

    package static func subcommandIndex(in arguments: [String]) -> Int? {
        var index = arguments.startIndex
        while index < arguments.endIndex {
            let argument = arguments[index]
            guard argument.hasPrefix("-") else { return index }
            index += optionsWithValue.contains(argument) ? 2 : 1
        }
        return nil
    }

    private static func explicitConfigKeys(in options: ArraySlice<String>) -> Set<String> {
        var keys = Set<String>()
        var index = options.startIndex
        while index < options.endIndex {
            let option = options[index]
            var assignment: Substring?
            if option == "-c" || option == "--config-env", index + 1 < options.endIndex {
                assignment = Substring(options[index + 1])
                index += 2
            } else {
                if option.hasPrefix("--config-env=") {
                    assignment = option.dropFirst("--config-env=".count)
                } else if option.hasPrefix("-c"), option.count > 2, !option.hasPrefix("--") {
                    assignment = option.dropFirst(2)
                }
                index += optionsWithValue.contains(option) ? 2 : 1
            }
            if let assignment, let key = assignment.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).first, !key.isEmpty {
                keys.insert(key.lowercased())
            }
        }
        return keys
    }
}
