import Foundation
import GitExtensionsCore

/// User-defined application links, persisted using upstream's RevisionLinkDefs
/// XML. These are presentation rules, not Git revision expressions or commands.
struct RevisionLinkDefinition: Equatable {
    struct Format: Equatable { var caption: String; var format: String }
    var name = "<new>"
    var enabled = true
    var searchPattern = ""
    var nestedSearchPattern = ""
    var remoteSearchPattern = ""
    var useRemotesPattern = "upstream|origin"
    var useOnlyFirstRemote = true
    var searchInParts: Set<String> = ["Message"]
    var remoteSearchInParts: Set<String> = ["URL"]
    var formats: [Format] = []

    static let settingKey = "RevisionLinkDefs"

    static func decode(_ xml: String?) throws -> [Self] {
        guard let xml, !xml.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        let document = try XMLDocument(xmlString: xml, options: .nodeLoadExternalEntitiesNever)
        guard document.dtd == nil, let root = document.rootElement(), root.name == "ArrayOfGitExtLinkDef" else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return root.elements(forName: "GitExtLinkDef").map { element in
            func value(_ key: String) -> String { element.elements(forName: key).first?.stringValue ?? "" }
            func members(_ key: String, _ child: String) -> Set<String> {
                Set(element.elements(forName: key).first?.elements(forName: child).compactMap(\.stringValue) ?? [])
            }
            var definition = Self()
            definition.name = value("Name")
            definition.enabled = value("Enabled").lowercased() == "true"
            definition.searchPattern = value("SearchPattern")
            definition.nestedSearchPattern = value("NestedSearchPattern")
            definition.remoteSearchPattern = value("RemoteSearchPattern")
            definition.useRemotesPattern = value("UseRemotesPattern")
            definition.useOnlyFirstRemote = value("UseOnlyFirstRemote").lowercased() == "true"
            definition.searchInParts = members("SearchInParts", "RevisionPart")
            definition.remoteSearchInParts = members("RemoteSearchInParts", "RemotePart")
            definition.formats = element.elements(forName: "LinkFormats").first?.elements(forName: "GitExtLinkFormat").map {
                Format(caption: $0.elements(forName: "Caption").first?.stringValue ?? "",
                       format: $0.elements(forName: "Format").first?.stringValue ?? "")
            } ?? []
            return definition
        }
    }

    static func encode(_ definitions: [Self]) -> String? {
        guard !definitions.isEmpty else { return nil }
        let root = XMLElement(name: "ArrayOfGitExtLinkDef")
        for definition in definitions.sorted(by: { $0.name < $1.name }) {
            let element = XMLElement(name: "GitExtLinkDef")
            for (key, value) in [("Name", definition.name), ("Enabled", String(definition.enabled)),
                                 ("SearchPattern", definition.searchPattern), ("NestedSearchPattern", definition.nestedSearchPattern),
                                 ("RemoteSearchPattern", definition.remoteSearchPattern), ("UseRemotesPattern", definition.useRemotesPattern),
                                 ("UseOnlyFirstRemote", String(definition.useOnlyFirstRemote))] {
                element.addChild(XMLElement(name: key, stringValue: value))
            }
            for (key, child, values) in [("SearchInParts", "RevisionPart", definition.searchInParts),
                                         ("RemoteSearchInParts", "RemotePart", definition.remoteSearchInParts)] {
                let list = XMLElement(name: key)
                for value in values.sorted() { list.addChild(XMLElement(name: child, stringValue: value)) }
                element.addChild(list)
            }
            let formats = XMLElement(name: "LinkFormats")
            for format in definition.formats where !format.caption.isEmpty || !format.format.isEmpty {
                let node = XMLElement(name: "GitExtLinkFormat")
                node.addChild(XMLElement(name: "Caption", stringValue: format.caption))
                node.addChild(XMLElement(name: "Format", stringValue: format.format))
                formats.addChild(node)
            }
            element.addChild(formats)
            root.addChild(element)
        }
        return XMLDocument(rootElement: root).xmlString(options: .nodePrettyPrint)
    }

    struct RemoteInput { let name: String; let url: String; let pushURL: String }
    struct Link: Equatable { let caption: String; let destination: String }

    func links(commitID: ObjectID, message: String, localRefs: [String], remoteRefs: [String], remotes: [RemoteInput]) -> [Link] {
        guard enabled, !searchPattern.isEmpty, let search = try? NSRegularExpression(pattern: searchPattern) else { return [] }
        func matches(_ regex: NSRegularExpression, _ value: String) -> [(String, [String])] {
            regex.matches(in: value, range: NSRange(value.startIndex..., in: value)).map { match in
                let text = value as NSString
                let groups = (match.numberOfRanges > 1 ? 1 : 0)..<match.numberOfRanges
                return (text.substring(with: match.range), groups.map {
                    let range = match.range(at: $0)
                    return range.location == NSNotFound ? "" : text.substring(with: range)
                })
            }
        }
        var remoteGroups: [[String]] = [[]]
        if !remoteSearchPattern.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           let regex = try? NSRegularExpression(pattern: remoteSearchPattern) {
            var selected = remotes
            if !useRemotesPattern.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               let names = try? NSRegularExpression(pattern: useRemotesPattern) {
                selected = selected.filter { !matches(names, $0.name).isEmpty }.sorted {
                    (useRemotesPattern as NSString).range(of: $0.name, options: .caseInsensitive).location
                        < (useRemotesPattern as NSString).range(of: $1.name, options: .caseInsensitive).location
                }
                if useOnlyFirstRemote { selected = Array(selected.prefix(1)) }
            }
            var seen: Set<String> = []
            remoteGroups = selected.flatMap { remote -> [[String]] in
                var urls: [String] = []
                if remoteSearchInParts.contains("URL") { urls.append(remote.url) }
                if remoteSearchInParts.contains("PushURL") { urls.append(remote.pushURL) }
                return urls.filter { !$0.isEmpty && seen.insert($0).inserted }.flatMap { matches(regex, $0).map(\.1) }
            }
        }
        var parts: [String] = []
        if searchInParts.contains("LocalBranches") { parts += localRefs }
        if searchInParts.contains("RemoteBranches") { parts += remoteRefs }
        if searchInParts.contains("Message") { parts.append(message) }
        let revisionGroups = parts.flatMap { part -> [[String]] in
            matches(search, part).flatMap { text, groups -> [[String]] in
                if nestedSearchPattern.isEmpty { return [groups] }
                guard let nested = try? NSRegularExpression(pattern: nestedSearchPattern) else { return [] }
                return matches(nested, text).map(\.1)
            }
        }
        return remoteGroups.flatMap { remote in revisionGroups.flatMap { revision in
            formats.compactMap { format in
                guard let caption = Self.format(format.caption, groups: remote + revision),
                      let destination = Self.format(format.format.replacingOccurrences(of: "%COMMIT_HASH%", with: commitID.string), groups: remote + revision) else { return nil }
                return Link(caption: caption, destination: destination)
            }
        } }
    }

    /// Indexed string.Format substitutions (including escaped braces). Invalid
    /// formats do not produce an actionable URL.
    static func format(_ template: String, groups: [String]) -> String? {
        var result = ""
        var remaining = template[...]
        while let first = remaining.first {
            remaining = remaining.dropFirst()
            if first == "{" {
                if remaining.first == "{" { result.append("{"); remaining = remaining.dropFirst(); continue }
                guard let end = remaining.firstIndex(of: "}") else { return nil }
                // ExternalLinkFormat formats string captures with String.Format.
                // Strings ignore a format specifier, but alignment still applies.
                let item = remaining[..<end]
                guard !item.contains("{") else { return nil }
                let address = item.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)[0]
                let fields = address.split(separator: ",", maxSplits: 1, omittingEmptySubsequences: false)
                let indexText = fields[0].trimmingCharacters(in: .whitespaces)
                guard !indexText.isEmpty, indexText.allSatisfy({ $0.isASCII && $0.isNumber }),
                      let index = Int(indexText), groups.indices.contains(index) else { return nil }
                var value = groups[index]
                if fields.count == 2 {
                    guard let alignment = Int(fields[1].trimmingCharacters(in: .whitespaces)),
                          (-1_000_000...1_000_000).contains(alignment) else { return nil }
                    let padding = String(repeating: " ", count: max(0, abs(alignment) - value.utf16.count))
                    value = alignment < 0 ? value + padding : padding + value
                }
                result += value
                remaining = remaining[remaining.index(after: end)...]
            } else if first == "}" {
                guard remaining.first == "}" else { return nil }
                result.append("}"); remaining = remaining.dropFirst()
            } else { result.append(first) }
        }
        return result
    }
}
