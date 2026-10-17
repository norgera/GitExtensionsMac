import Foundation
import AppKit
import GitExtensionsCore
import GitCommands

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

    static func format(_ template: String, groups: [String]) -> String? {
        var result = ""
        var remaining = template[...]
        while let first = remaining.first {
            remaining = remaining.dropFirst()
            if first == "{" {
                if remaining.first == "{" { result.append("{"); remaining = remaining.dropFirst(); continue }
                guard let end = remaining.firstIndex(of: "}") else { return nil }
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

enum RevisionLinkTemplates: String, CaseIterable {
    case gitHub = "GitHub", azureDevOps = "Azure DevOps"
    var actionTitle: String { "Add \(rawValue) templates" }
    var imageName: String { self == .gitHub ? "GitHub" : "VisualStudioTeamServices" }
    func identity(_ url: String) -> (String, String)? {
        let patterns: [String]
        switch self {
        case .gitHub:
            patterns = [#"^https?://(?:[^@:]*?)?(?::[^/@:]*?)?@?(?<hosting>([^./]+\.)+[^./]+)/(?<owner>[^/]+)/(?<repo>[\w_\.\-]+)(?:.git)?$"#,
                        #"^(ssh://)?git(?:@|://)(?<hosting>([^.]+\.)+[^.]+)[:/](?<owner>[^/]+)/(?<repo>[\w_\.\-]+)(?:.git)?"#]
        case .azureDevOps:
            patterns = [#"^https://[^@]*@dev\.azure\.com/(?<owner>[^/]*)/(?<project>[^/]*)/_git/(?<repo>.*)$"#,
                        #"^git@ssh\.dev\.azure\.com:v\d/(?<owner>[^/]*)/(?<project>[^/]*)/(?<repo>.*)$"#,
                        #"^https://(?<owner>[^.]*)\.visualstudio\.com(?:/DefaultCollection)?/(?<project>[^/]*)/_git/(?<repo>.*)$"#,
                        #"^[^@]*@vs-ssh\.visualstudio\.com:v\d/(?<owner>[^/]*)/(?<project>[^/]*)/(?<repo>.*)$"#]
        }
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern), let match = regex.firstMatch(in: url, range: NSRange(location: 0, length: url.utf16.count)) else { continue }
            let string = url as NSString
            func group(_ name: String) -> String { string.substring(with: match.range(withName: name)) }
            if self == .gitHub, group("hosting") != "github.com" { return nil }
            return (group("owner"), self == .gitHub ? group("repo").replacingOccurrences(of: ".git", with: "") : group("repo"))
        }
        return nil
    }
    func definitions(remotes: [RepositoryRemoteConfiguration]) -> [RevisionLinkDefinition] {
        let applicable = remotes.filter { identity($0.fetchURL) != nil }
        let preferred = ["upstream", "fork", "origin"].compactMap { name in applicable.first { $0.name == name } }.first ?? applicable.first
        return definitions(url: preferred?.fetchURL)
    }
    func definitions(url: String?) -> [RevisionLinkDefinition] {
        let names = url.flatMap(identity) ?? (self == .gitHub ? "ORGANIZATION_NAME" : "ACCOUNT_NAME", "REPO_NAME")
        let base = self == .gitHub ? "https://github.com/\(names.0)/\(names.1)" : "https://dev.azure.com/\(names.0)"
        func definition(_ title: String, _ pattern: String, _ nested: String, _ parts: Set<String>, _ formats: [RevisionLinkDefinition.Format]) -> RevisionLinkDefinition {
            var value = RevisionLinkDefinition()
            value.name = rawValue + " - " + title; value.searchPattern = pattern; value.nestedSearchPattern = nested
            value.searchInParts = parts; value.remoteSearchInParts = []; value.useRemotesPattern = ""; value.useOnlyFirstRemote = false; value.formats = formats
            return value
        }
        let commit = self == .gitHub ? base + "/commit/%COMMIT_HASH%" : base + "/_git/\(names.1)/commit/%COMMIT_HASH%"
        let project = self == .gitHub ? base : base + "/\(names.1)"
        let code = definition("Code", ".*", "", ["Message"], [.init(caption: "View commit in \(rawValue)", format: commit), .init(caption: "View project in \(rawValue)", format: project)])
        if self == .azureDevOps {
            return [code, definition("Issues", #"#(\d+)"#, "", ["Message"], [.init(caption: "#{0}", format: base + "/\(names.1)/_workitems/edit/{0}")])]
        }
        return [code,
            definition("Issues", #"(?i)(?<!pull request |pr[ _]?)(#|(((feat(ure)?)|fix)[/_-]))\d+"#, #"\d+"#, ["Message", "LocalBranches"], [.init(caption: "#{0}", format: base + "/issues/{0}")]),
            definition("Pull Requests", #"(?i)(pull request |pr[ _]?)#?\d+"#, #"\d+"#, ["Message", "LocalBranches", "RemoteBranches"], [.init(caption: "PR #{0}", format: base + "/pull/{0}")])]
    }
    static func insert(_ templates: [RevisionLinkDefinition], into scopes: inout [DistributedSettingsScope: [RevisionLinkDefinition]], startingAt scope: DistributedSettingsScope) -> Set<DistributedSettingsScope> {
        let levels: [DistributedSettingsScope]
        switch scope {
        case .local: levels = [.local, .distributed, .global]
        case .distributed: levels = [.distributed, .global]
        case .global: levels = [.global]
        case .effective: return []
        }
        var changed = Set<DistributedSettingsScope>()
        func add(_ definition: RevisionLinkDefinition, level: Int) {
            let current = levels[level]
            if level + 1 < levels.count, scopes[levels[level + 1]]?.contains(where: { $0.name == definition.name }) != true {
                add(definition, level: level + 1)
            } else if scopes[current]?.contains(where: { $0.name == definition.name }) != true {
                scopes[current, default: []].append(definition)
                changed.insert(current)
            }
        }
        for definition in templates { add(definition, level: 0) }
        return changed
    }

    static func insert(_ templates: [RevisionLinkDefinition], into definitions: inout [RevisionLinkDefinition]) {
        for value in templates where !definitions.contains(where: { $0.name == value.name }) { definitions.append(value) }
    }
}

@MainActor
final class RevisionLinksSettingsEditor: NSView, NSTableViewDataSource, NSTableViewDelegate, NSSplitViewDelegate {
    static var helpURL: URL { URL(string: ApplicationShellLinks.documentationURL.absoluteString + "settings.html#revision-links")! }
    private(set) var definitions: [RevisionLinkDefinition]
    private(set) var selectedIndex: Int
    let categories = NSTableView()
    let links = RevisionLinksFormatsTable()
    let split = NSSplitView()
    let addButton = NSButton(title: "Add", target: nil, action: nil)
    let templates = NSPopUpButton(frame: .zero, pullsDown: true)
    let removeButton = NSButton(title: "Remove", target: nil, action: nil)
    let help = NSButton(title: "Help", target: nil, action: nil)
    var onSelection: ((Int) -> Void)?
    var onChange: ((Int, RevisionLinkDefinition) -> Void)?
    var onAdd: (() -> Void)?
    var onRemove: ((Int) -> Void)?
    private let editable: Bool
    private let detail = NSStackView()
    private var positioned = false

    init(definitions: [RevisionLinkDefinition], selected: Int, editable: Bool, menu: NSMenu) {
        self.definitions = definitions
        selectedIndex = definitions.isEmpty || selected < 0 ? -1 : min(selected, definitions.count - 1)
        self.editable = editable
        super.init(frame: .zero)
        setAccessibilityIdentifier("RevisionLinks.Editor")
        split.isVertical = true
        split.dividerStyle = .thin
        split.delegate = self
        split.setAccessibilityIdentifier("RevisionLinks.Split")
        split.translatesAutoresizingMaskIntoConstraints = false
        addSubview(split)
        NSLayoutConstraint.activate([
            split.leadingAnchor.constraint(equalTo: leadingAnchor), split.trailingAnchor.constraint(equalTo: trailingAnchor),
            split.topAnchor.constraint(equalTo: topAnchor), split.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
        let left = NSView()
        let caption = NSTextField(labelWithString: "Categories")
        let column = NSTableColumn(identifier: .init("Categories"))
        categories.addTableColumn(column)
        categories.headerView = nil
        categories.rowHeight = AppSettingsStore.shared.applicationRowHeight(minimum: 20)
        categories.allowsEmptySelection = true
        categories.delegate = self
        categories.dataSource = self
        categories.setAccessibilityIdentifier("RevisionLinks.Categories")
        let scroll = NSScrollView()
        scroll.documentView = categories
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        addButton.target = self
        addButton.action = #selector(addCategory)
        addButton.isEnabled = editable
        addButton.image = NSImage(systemSymbolName: "plus", accessibilityDescription: "Add")?.withSymbolConfiguration(.init(paletteColors: [.systemGreen]))
        addButton.imagePosition = .imageLeading
        addButton.setAccessibilityIdentifier("RevisionLinks.Add")
        templates.menu = menu
        templates.isEnabled = editable
        templates.widthAnchor.constraint(equalToConstant: 22).isActive = true
        templates.setAccessibilityIdentifier("RevisionLinks.AddTemplates")
        templates.toolTip = "Add templates"
        let add = NSStackView(views: [addButton, templates])
        add.spacing = 0
        let separator = NSBox()
        separator.boxType = .separator
        separator.widthAnchor.constraint(equalToConstant: 1).isActive = true
        separator.heightAnchor.constraint(equalToConstant: 20).isActive = true
        removeButton.target = self
        removeButton.action = #selector(removeCategory)
        removeButton.image = NSImage(systemSymbolName: "minus", accessibilityDescription: "Remove")?.withSymbolConfiguration(.init(paletteColors: [.systemRed]))
        removeButton.imagePosition = .imageLeading
        removeButton.setAccessibilityIdentifier("RevisionLinks.Remove")
        let toolbar = NSStackView(views: [add, separator, removeButton])
        toolbar.spacing = 4
        for child in [caption, scroll, toolbar] {
            child.translatesAutoresizingMaskIntoConstraints = false
            left.addSubview(child)
        }
        NSLayoutConstraint.activate([
            caption.leadingAnchor.constraint(equalTo: left.leadingAnchor), caption.topAnchor.constraint(equalTo: left.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: left.leadingAnchor), scroll.trailingAnchor.constraint(equalTo: left.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: caption.bottomAnchor, constant: 4), scroll.bottomAnchor.constraint(equalTo: toolbar.topAnchor, constant: -4),
            toolbar.leadingAnchor.constraint(equalTo: left.leadingAnchor), toolbar.bottomAnchor.constraint(equalTo: left.bottomAnchor),
            left.widthAnchor.constraint(greaterThanOrEqualToConstant: 180)
        ])
        detail.orientation = .vertical
        detail.alignment = .leading
        detail.spacing = 6
        detail.edgeInsets = NSEdgeInsets(top: 0, left: 8, bottom: 0, right: 0)
        split.addArrangedSubview(left)
        split.addArrangedSubview(detail)
        detail.widthAnchor.constraint(greaterThanOrEqualToConstant: 350).isActive = true
        split.setHoldingPriority(.defaultHigh, forSubviewAt: 0)
        categories.selectRowIndexes(selectedIndex < 0 ? [] : IndexSet(integer: selectedIndex), byExtendingSelection: false)
        showDefinition()
    }

    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        if !positioned, split.bounds.width > 550 {
            positioned = true
            split.setPosition(192, ofDividerAt: 0)
            if selectedIndex >= 0 { categories.scrollRowToVisible(selectedIndex) }
        }
    }

    func splitView(_ splitView: NSSplitView, canCollapseSubview subview: NSView) -> Bool { false }
    func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposedMinimumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat { 180 }
    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposedMaximumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat { max(180, splitView.bounds.width - 350) }
    func splitView(_ splitView: NSSplitView, shouldAdjustSizeOfSubview view: NSView) -> Bool { view === detail }

    private func change(_ transform: (inout RevisionLinkDefinition) -> Void) {
        guard editable, definitions.indices.contains(selectedIndex) else { return }
        transform(&definitions[selectedIndex])
        onChange?(selectedIndex, definitions[selectedIndex])
    }

    private func showDefinition() {
        detail.arrangedSubviews.forEach { detail.removeArrangedSubview($0); $0.removeFromSuperview() }
        let definition = definitions.indices.contains(selectedIndex) ? definitions[selectedIndex] : nil
        let enabled = editable && definition != nil
        removeButton.isEnabled = enabled
        func field(_ text: String, id: String, change: @escaping (String) -> Void) -> RevisionLinkSettingsTextField {
            let control = RevisionLinkSettingsTextField(string: text)
            control.delegate = control
            control.onChange = change
            control.isEnabled = enabled
            control.font = AppSettingsStore.shared.applicationFont(size: 13)
            control.isBezeled = true
            control.heightAnchor.constraint(greaterThanOrEqualToConstant: max(24, control.intrinsicContentSize.height)).isActive = true
            control.setContentCompressionResistancePriority(.required, for: .vertical)
            control.setAccessibilityIdentifier(id)
            control.setContentHuggingPriority(.defaultLow, for: .horizontal)
            return control
        }
        func toggle(_ title: String, value: Bool, change: @escaping (Bool) -> Void) -> RevisionLinkSettingsToggle {
            let control = RevisionLinkSettingsToggle(checkboxWithTitle: title, target: nil, action: nil)
            control.target = control
            control.action = #selector(RevisionLinkSettingsToggle.invoke)
            control.onChange = change
            control.state = value ? .on : .off
            control.isEnabled = enabled
            return control
        }
        func group(_ title: String, rows: [[NSView]]) -> NSBox {
            let grid = NSGridView(views: rows)
            grid.columnSpacing = 6
            grid.rowSpacing = 5
            grid.column(at: 0).xPlacement = .leading
            grid.column(at: 0).width = ceil(rows.compactMap { $0.first?.intrinsicContentSize.width }.max() ?? 0)
            grid.column(at: 1).xPlacement = .fill
            grid.rowAlignment = .none
            for index in rows.indices {
                grid.row(at: index).height = max(24, rows[index].map { $0.fittingSize.height }.max() ?? 0)
                for flow in rows[index].compactMap({ $0 as? RevisionLinksOptionsFlow }) {
                    flow.onHeightChanged = { [weak grid] height in
                        guard let grid else { return }
                        grid.row(at: index).height = max(24, height)
                        grid.invalidateIntrinsicContentSize()
                        grid.superview?.needsLayout = true
                    }
                }
                grid.row(at: index).yPlacement = .center
            }
            grid.setContentHuggingPriority(.required, for: .vertical)
            let box = AppKitFactory.titledBox(title, grid)
            box.setContentHuggingPriority(.required, for: .vertical)
            return box
        }
        let name = field(definition?.name ?? "", id: "RevisionLinks.Name") { [weak self] value in
            guard let self else { return }
            self.change { $0.name = value }
            if self.selectedIndex >= 0 { self.categories.reloadData(forRowIndexes: IndexSet(integer: self.selectedIndex), columnIndexes: IndexSet(integer: 0)) }
        }
        let active = toggle("Enabled", value: definition?.enabled ?? false) { [weak self] value in self?.change { $0.enabled = value } }
        help.target = self
        help.action = #selector(openHelp)
        help.isEnabled = definition != nil
        help.toolTip = "Read more about this feature at " + Self.helpURL.absoluteString
        help.image = AppKitFactory.resourceImage("GotoManual")
        help.imagePosition = .imageLeading
        help.setAccessibilityIdentifier("RevisionLinks.Help")
        let nameRow = NSStackView(views: [NSTextField(labelWithString: "Name:"), name, active, help])
        nameRow.spacing = 6
        detail.addArrangedSubview(nameRow)
        let search = field(definition?.searchPattern ?? "", id: "RevisionLinks.SearchPattern") { [weak self] value in self?.change { $0.searchPattern = value.trimmingCharacters(in: .whitespacesAndNewlines) } }
        let nested = field(definition?.nestedSearchPattern ?? "", id: "RevisionLinks.NestedPattern") { [weak self] value in self?.change { $0.nestedSearchPattern = value.trimmingCharacters(in: .whitespacesAndNewlines) } }
        var revisionControls: [NSView] = []
        for (part, title) in [("Message", "Message"), ("LocalBranches", "Local branch name"), ("RemoteBranches", "Remote branch name")] {
            revisionControls.append(toggle(title, value: definition?.searchInParts.contains(part) ?? false) { [weak self] value in
                self?.change { if value { $0.searchInParts.insert(part) } else { $0.searchInParts.remove(part) } }
            })
        }
        let revisionParts = RevisionLinksOptionsFlow(revisionControls)
        let revisionBox = group("Revision data", rows: [
            [NSTextField(labelWithString: "Search in"), revisionParts],
            [NSTextField(labelWithString: "Search pattern"), search],
            [NSTextField(labelWithString: "Nested pattern"), nested]
        ])
        let useRemotes = field(definition?.useRemotesPattern ?? "", id: "RevisionLinks.UseRemotes") { [weak self] value in self?.change { $0.useRemotesPattern = value.trimmingCharacters(in: .whitespacesAndNewlines) } }
        let onlyFirst = toggle("Only use the first match", value: definition?.useOnlyFirstRemote ?? false) { [weak self] value in self?.change { $0.useOnlyFirstRemote = value } }
        let useRow = RevisionLinksOptionsFlow([useRemotes, onlyFirst], fixedWidths: [0: 218])
        let remoteSearch = field(definition?.remoteSearchPattern ?? "", id: "RevisionLinks.RemotePattern") { [weak self] value in self?.change { $0.remoteSearchPattern = value.trimmingCharacters(in: .whitespacesAndNewlines) } }
        var remoteControls: [NSView] = []
        for part in ["URL", "PushURL"] {
            remoteControls.append(toggle(part, value: definition?.remoteSearchInParts.contains(part) ?? false) { [weak self] value in
                self?.change { if value { $0.remoteSearchInParts.insert(part) } else { $0.remoteSearchInParts.remove(part) } }
            })
        }
        let remoteParts = RevisionLinksOptionsFlow(remoteControls)
        detail.addArrangedSubview(group("Remote data", rows: [
            [NSTextField(labelWithString: "Use remotes"), useRow],
            [NSTextField(labelWithString: "Search in"), remoteParts],
            [NSTextField(labelWithString: "Search pattern"), remoteSearch]
        ]))
        detail.addArrangedSubview(revisionBox)
        if links.tableColumns.isEmpty {
            let caption = NSTableColumn(identifier: .init("Caption"))
            caption.title = "Caption"
            caption.width = 150
            caption.resizingMask = .userResizingMask
            let uri = NSTableColumn(identifier: .init("URI"))
            uri.title = "URI"
            uri.resizingMask = [.autoresizingMask, .userResizingMask]
            links.addTableColumn(caption)
            links.addTableColumn(uri)
            links.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
            links.delegate = self
            links.dataSource = self
            links.rowHeight = AppSettingsStore.shared.applicationRowHeight(minimum: 22)
            links.allowsMultipleSelection = false
            links.setAccessibilityIdentifier("RevisionLinks.Formats")
            links.onDelete = { [weak self] in self?.removeFormat() }
        }
        links.isEnabled = enabled
        links.reloadData()
        let scroll = NSScrollView()
        scroll.documentView = links
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.borderType = .bezelBorder
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 100).isActive = true
        scroll.setContentHuggingPriority(.defaultLow, for: .vertical)
        detail.addArrangedSubview(NSTextField(labelWithString: "Links"))
        detail.addArrangedSubview(scroll)
        for child in detail.arrangedSubviews { child.widthAnchor.constraint(equalTo: detail.widthAnchor, constant: -8).isActive = true }
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        if tableView === categories { return definitions.count }
        guard definitions.indices.contains(selectedIndex) else { return 0 }
        return definitions[selectedIndex].formats.count + (editable ? 1 : 0)
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        if tableView === categories { return NSTextField(labelWithString: definitions[row].name) }
        let formats = definitions[selectedIndex].formats
        let caption = tableColumn?.identifier.rawValue == "Caption"
        let value = row < formats.count ? (caption ? formats[row].caption : formats[row].format) : ""
        let control = RevisionLinkSettingsTextField(string: value)
        control.isBordered = false
        control.drawsBackground = false
        control.isEditable = editable
        control.isEnabled = editable
        control.delegate = control
        control.setAccessibilityIdentifier("RevisionLinks.Format.\(row).\(caption ? "Caption" : "URI")")
        control.onChange = { [weak self] text in
            guard let self else { return }
            self.change {
                if row == $0.formats.count { $0.formats.append(.init(caption: "", format: "")) }
                guard $0.formats.indices.contains(row) else { return }
                if caption { $0.formats[row].caption = text } else { $0.formats[row].format = text }
            }
            self.links.noteNumberOfRowsChanged()
        }
        return control
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard notification.object as? NSTableView === categories else { return }
        window?.makeFirstResponder(nil)
        selectedIndex = categories.selectedRow
        showDefinition()
        onSelection?(selectedIndex)
    }

    private func removeFormat() {
        let row = links.selectedRow
        guard definitions.indices.contains(selectedIndex), definitions[selectedIndex].formats.indices.contains(row) else { return }
        window?.makeFirstResponder(nil)
        change { $0.formats.remove(at: row) }
        links.reloadData()
    }

    @objc private func addCategory() { window?.makeFirstResponder(nil); onAdd?() }
    @objc private func removeCategory() { window?.makeFirstResponder(nil); if selectedIndex >= 0 { onRemove?(selectedIndex) } }
    @objc private func openHelp() { NSWorkspace.shared.open(Self.helpURL) }
}

@MainActor
final class RevisionLinksFormatsTable: NSTableView {
    var onDelete: (() -> Void)?
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 51 || event.keyCode == 117 { onDelete?() }
        else { super.keyDown(with: event) }
    }
}

@MainActor
private final class RevisionLinkSettingsTextField: NSTextField, NSTextFieldDelegate {
    var onChange: ((String) -> Void)?
    func controlTextDidChange(_ notification: Notification) { onChange?(stringValue) }
    func controlTextDidEndEditing(_ notification: Notification) { onChange?(stringValue) }
}

@MainActor
private final class RevisionLinkSettingsToggle: NSButton {
    var onChange: ((Bool) -> Void)?
    @objc func invoke() { onChange?(state == .on) }
}

@MainActor
private final class RevisionLinksOptionsFlow: NSView {
    private let controls: [NSView]
    private let fixedWidths: [Int: CGFloat]
    private var measuredHeight: CGFloat = 24
    var onHeightChanged: ((CGFloat) -> Void)?
    override var isFlipped: Bool { true }

    init(_ controls: [NSView], fixedWidths: [Int: CGFloat] = [:]) {
        self.controls = controls
        self.fixedWidths = fixedWidths
        super.init(frame: .zero)
        controls.forEach { addSubview($0) }
    }

    required init?(coder: NSCoder) { nil }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: measuredHeight) }

    override func layout() {
        super.layout()
        guard bounds.width > 0 else { return }
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        for (index, control) in controls.enumerated() {
            let fit = control.fittingSize
            let width = min(bounds.width, max(1, fixedWidths[index] ?? fit.width))
            let height = max(24, fit.height)
            if x > 0 && x + width > bounds.width {
                x = 0
                y += rowHeight + 4
                rowHeight = 0
            }
            control.frame = NSRect(x: x, y: y, width: width, height: height)
            x += width + 6
            rowHeight = max(rowHeight, height)
        }
        let height = y + rowHeight
        if abs(measuredHeight - height) > 0.5 {
            measuredHeight = height
            invalidateIntrinsicContentSize()
            onHeightChanged?(height)
            superview?.needsLayout = true
        }
    }
}
