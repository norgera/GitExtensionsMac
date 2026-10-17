import Foundation
import GitExtensionsCore

package struct FileStatusPathNode: Sendable {
    package let title: String
    package let path: String
    package let file: ChangedFile?
    package let children: [FileStatusPathNode]
}

package enum FileStatusPaths {
    package static func compare(_ left: String, _ right: String) -> ComparisonResult {
        left.compare(right, options: [], locale: Locale(identifier: ""))
    }

    package static func directory(_ name: String) -> String {
        let value = name.hasSuffix("/") ? String(name.dropLast()) : name
        guard let slash = value.lastIndex(of: "/") else { return "" }
        return String(value[..<slash])
    }

    package static func precedes(_ left: String, _ right: String) -> Bool {
        let a = directory(left), b = directory(right)
        if a.isEmpty != b.isEmpty { return !a.isEmpty }
        if a != b {
            if b.hasPrefix(a + "/") { return false }
            if a.hasPrefix(b + "/") { return true }
            let ac = a.split(separator: "/"), bc = b.split(separator: "/")
            for (x, y) in zip(ac, bc) {
                let result = compare(String(x), String(y))
                if result != .orderedSame { return result == .orderedAscending }
            }
            if ac.count != bc.count { return ac.count < bc.count }
        }
        return compare(left, right) == .orderedAscending
    }

    package static func commonPath(_ a: String, _ b: String) -> String {
        zip(a.split(separator: "/"), b.split(separator: "/")).prefix { $0 == $1 }.map { String($0.0) }.joined(separator: "/")
    }

    private final class Node {
        let path: String
        let file: ChangedFile?
        weak var parent: Node?
        var children: [Node] = []
        init(_ path: String, file: ChangedFile? = nil) { self.path = path; self.file = file }
        func add(_ child: Node) { children.append(child); child.parent = self }
    }

    package static func build(_ files: [ChangedFile], flat: Bool, dense: Bool) -> [FileStatusPathNode] {
        let root = Node("")
        var previous = root
        for file in files.sorted(by: { precedes($0.path, $1.path) }) {
            let path = directory(file.path)
            if flat { root.add(Node(file.path, file: file)); continue }
            if previous.path != path {
                let common = commonPath(previous.path, path)
                var ancestor = previous
                if common.isEmpty { ancestor = root }
                else {
                    while let parent = ancestor.parent, parent.path == common || parent.path.hasPrefix(common + "/") { ancestor = parent }
                    if ancestor.path != common, let parent = ancestor.parent,
                       let index = parent.children.firstIndex(where: { $0 === ancestor }) {
                        let split = Node(common)
                        split.add(ancestor)
                        split.parent = parent
                        parent.children[index] = split
                        ancestor = split
                    }
                }
                if common == path { previous = ancestor }
                else { let next = Node(path); ancestor.add(next); previous = next }
            }
            previous.add(Node(file.path, file: file))
        }
        func materialize(_ node: Node, parent: String) -> FileStatusPathNode {
            let merged = dense && node.file == nil && node.children.count == 1 && node.children[0].file != nil
            let content = merged ? node.children[0] : node
            let title = !flat && !parent.isEmpty && content.path.hasPrefix(parent + "/")
                ? String(content.path.dropFirst(parent.count + 1)) : content.path
            return FileStatusPathNode(title: title, path: content.path, file: content.file,
                                      children: merged ? [] : node.children.map { materialize($0, parent: node.path) })
        }
        return root.children.map { materialize($0, parent: "") }
    }
}

package enum FileViewerCopy {
    package enum Command { case selection, patch, oldVersion, newVersion }

    package static func payload(_ command: Command, text: String, selection: NSRange? = nil,
                                isDiff: Bool = true, fullPrefixes: [String] = ["-", "+", " "],
                                normalizeLineEndings: Bool = false) -> String? {
        let source = text as NSString
        let selected = selection.flatMap { range -> NSRange? in
            guard range.location >= 0, range.length > 0, range.location <= source.length,
                  range.length <= source.length - range.location else { return nil }
            return range
        }
        if command == .selection && selected == nil { return nil }
        var result = selected.map { source.substring(with: $0) } ?? text
        if command == .patch { return result.isEmpty ? nil : result }
        let position = selected?.location ?? 0
        let hunk = source.range(of: "\n@@").location
        let strip = isDiff && (hunk == NSNotFound || hunk <= position)
        if isDiff && position > 0 && source.character(at: position - 1) != 10 && (strip || command != .selection) {
            result = " " + result
        }
        if isDiff {
            let excluded = command == .oldVersion ? "+" : "-"
            var lines = result.components(separatedBy: "\n")
            if command != .selection {
                lines = lines.filter { !$0.hasPrefix(excluded) || $0.hasPrefix(String(repeating: excluded, count: 3)) }
            }
            if strip {
                lines = lines.map { line in
                    let prefixes = command == .selection ? fullPrefixes : ["-", "+", " "]
                    guard let prefix = prefixes.first(where: { line.hasPrefix($0) }) else { return line }
                    return String(line.dropFirst(prefix.count))
                }
            }
            result = lines.joined(separator: "\n")
        }
        if normalizeLineEndings && !result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if result.contains("\r\n") { result = result.replacingOccurrences(of: "\r\n", with: "\n") }
            else if result.contains("\r") { result = result.replacingOccurrences(of: "\r", with: "\n") }
        }
        return result
    }

    package static func selectedRange(lines: [DiffLine], rows: IndexSet, patch: Bool = true) -> NSRange? {
        guard let first = rows.first, let last = rows.last, lines.indices.contains(first), lines.indices.contains(last) else { return nil }
        let start = lines[..<first].reduce(0) { $0 + (patch ? $1.patchText : $1.text).utf16.count + 1 }
        let length = lines[first...last].reduce(0) { $0 + (patch ? $1.patchText : $1.text).utf16.count + 1 } - (last == lines.count - 1 ? 1 : 0)
        return NSRange(location: start, length: length)
    }

    package static func selectedRanges(lines: [DiffLine], rows: IndexSet, patch: Bool = true) -> [NSRange] {
        rows.rangeView.compactMap { selectedRange(lines: lines, rows: IndexSet(integersIn: $0), patch: patch) }
    }
}

package enum SubmoduleDiffPresentation {
    package static func relativeDate(now: Date, date: Date) -> String {
        let seconds = Int(now.timeIntervalSince1970) - Int(date.timeIntervalSince1970)
        let delta = abs(seconds), days = seconds / 86_400, minutes = (seconds / 60) % 60
        func ago(_ count: Int, _ unit: String) -> String { "\(count) \(unit)\(abs(count) == 1 ? "" : "s") ago" }
        if delta < 60 { return ago(seconds % 60, "second") }
        if delta < 2700 { return ago(minutes, "minute") }
        if delta < 86_400 { return ago(delta < 3600 ? (minutes > 0 ? 1 : -1) : (seconds / 3600) % 24, "hour") }
        if delta < 7 * 86_400 { return ago(days, "day") }
        if delta < 30 * 86_400 { return ago(Int((Double(days) / 7).rounded(.toNearestOrEven)), "week") }
        if delta < 365 * 86_400 { return ago(Int((Double(days) / 30).rounded(.toNearestOrEven)), "month") }
        return ago(Int((Double(days) / 365).rounded(.toNearestOrEven)), "year")
    }

    package static func text(_ summary: SubmoduleDiffSummary, limitOutput: Bool = false, now: Date = Date()) -> String {
        if let failure = summary.failure { return failure }
        var text = "Submodule \(summary.path)\n"
        func info(_ value: SubmoduleDiffSummary.CommitInfo?) -> String {
            guard let value else { return "" }
            let full = DateFormatter()
            full.dateStyle = .short; full.timeStyle = .medium
            let body = value.body.trimmingCharacters(in: .newlines).components(separatedBy: CharacterSet.newlines)
                .map { "\t\t" + $0 + "\n" }.joined()
            return "\t\t\t\(relativeDate(now: now, date: value.date)) (\(full.string(from: value.date)))\n" + body
        }
        if let from = summary.from, summary.from != summary.to {
            text += "\nFrom:\t\(from.string)\n" + info(summary.fromInfo)
        }
        if let to = summary.to {
            text += "\n" + (summary.from == summary.to ? "Commit:\t" : "To:  \t")
                + to.string + (summary.isDirty ? " (dirty)" : "") + "\n" + info(summary.toInfo)
        }
        text += "\nType: " + summary.change.rawValue + (summary.change == .removed ? "\n" : "") + (summary.isDirty ? " Dirty" : "") + "\n"
        if let added = summary.added, let removed = summary.removed, added != 0 || removed != 0 {
            text += "\nCommits: \(added) added, \(removed) removed\n"
        }
        func limited(_ value: String, noun: String) -> String {
            guard limitOutput else { return value }
            let lines = value.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n")
            return lines.count > 5 ? lines.prefix(5).joined(separator: "\n") + "\n \(lines.count - 5) more \(noun)" : value
        }
        if !summary.status.isEmpty {
            text += "\nStatus:\n" + limited(summary.status, noun: "changes")
                .replacingOccurrences(of: "(?m)^(\\s*\\S+)\\s+", with: "$1\t", options: .regularExpression)
        }
        if !summary.differences.isEmpty { text += "\nDifferences:\n" + limited(summary.differences, noun: "differences") }
        return text
    }
}

package enum FileStatusCopyPathKind: String, CaseIterable, Sendable {
    case relativePOSIX, relativeNative, fullNative

    package var title: String {
        switch self {
        case .relativePOSIX: "Copy relative path(s) - POSIX"
        case .relativeNative: "Copy relative path(s) - native"
        case .fullNative: "Copy full path(s) - native"
        }
    }

    package static func payload(files: [ChangedFile], folder: String? = nil, repositoryURL: URL?, kind: Self) -> String {
        var seen = Set<Data>()
        return (folder.map { [$0] } ?? files.map(\.path)).filter { seen.insert(Data($0.utf8)).inserted }.map { path in
            if kind == .fullNative, let repositoryURL {
                return path.hasPrefix("/") ? path : repositoryURL.appendingPathComponent(path).path
            }
            return path.isEmpty ? "." : path
        }.joined(separator: "\n")
    }
}
