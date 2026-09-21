import Foundation
import GitCommands

enum DistributedSettingsScope: String, CaseIterable {
    case effective, local, distributed, global
}

@MainActor
struct DistributedSettings {
    static let remoteBranches = "Detailed.GetRemoteBranchesDirectlyFromRemote"
    static let mergeLog = "Detailed.AddMergeLogMessages"
    static let mergeLogCount = "Detailed.MergeLogMessagesCount"
    let localURL: URL
    let distributedURL: URL

    static func normalizedMergeLogCount(_ value: String) -> String? {
        Int32(value.trimmingCharacters(in: .whitespacesAndNewlines)).map(String.init)
    }

    static func loadLocations(from source: any RepositorySettingsDataSource) async throws -> Self {
        let directories = try await source.settingsDirectories()
        return Self(localURL: directories.commonGit.appendingPathComponent("GitExtensions.settings"),
                    distributedURL: directories.working.appendingPathComponent("GitExtensions.settings"))
    }

    static func read(_ url: URL) throws -> [String: String] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        let document = try XMLDocument(contentsOf: url, options: [.nodeLoadExternalEntitiesNever])
        guard document.dtd == nil, let root = document.rootElement(), root.name == "dictionary" else {
            throw CocoaError(.fileReadCorruptFile)
        }
        var result: [String: String] = [:]
        for item in root.elements(forName: "item") {
            guard let key = item.elements(forName: "key").first?.elements(forName: "string").first?.stringValue,
                  let value = item.elements(forName: "value").first?.elements(forName: "string").first?.stringValue else {
                throw CocoaError(.fileReadCorruptFile)
            }
            result[key] = value
        }
        return result
    }

    @discardableResult
    static func write(_ edits: [String: String?], to url: URL) throws -> Bool {
        var values = try read(url)
        let previous = values
        for (key, value) in edits { values[key] = value }
        guard values != previous else { return false }
        let root = XMLElement(name: "dictionary")
        for key in values.keys.sorted() {
            let item = XMLElement(name: "item")
            for (name, value) in [("key", key), ("value", values[key]!)] {
                let holder = XMLElement(name: name)
                holder.addChild(XMLElement(name: "string", stringValue: value))
                item.addChild(holder)
            }
            root.addChild(item)
        }
        let document = XMLDocument(rootElement: root)
        document.characterEncoding = "utf-8"
        try document.xmlData(options: [.nodePrettyPrint]).write(to: url, options: .atomic)
        return true
    }

    func values(_ scope: DistributedSettingsScope, global: [String: String]) throws -> [String: String] {
        switch scope {
        case .global: return global
        case .local: return try Self.read(localURL)
        case .distributed: return try Self.read(distributedURL)
        case .effective:
            return try global.merging(Self.read(distributedURL), uniquingKeysWith: { _, new in new })
                .merging(Self.read(localURL), uniquingKeysWith: { _, new in new })
        }
    }

    static func globalValues(_ store: AppSettingsStore) -> [String: String] {
        [remoteBranches: String(store.pushPreferences.loadRemoteBranchesDirectly),
         mergeLog: String(store.mergePreferences.addLogMessages),
         mergeLogCount: String(store.mergePreferences.logMessagesCount)]
    }

    func mergePreferences(_ store: AppSettingsStore) throws -> MergePreferences {
        let values = try values(.effective, global: Self.globalValues(store))
        var preferences = store.mergePreferences
        preferences.addLogMessages = values[Self.mergeLog]?.lowercased() == "true"
        preferences.logMessagesCount = Int(values[Self.mergeLogCount] ?? "") ?? 20
        return preferences
    }

    func saveMergeLog(_ preferences: MergePreferences, store: AppSettingsStore) throws {
        let local = try Self.read(localURL)
        let distributed = try Self.read(distributedURL)
        let effective = try values(.effective, global: Self.globalValues(store))
        var edits: [String: String?] = [:]
        var global = store.mergePreferences
        for (key, value) in [(Self.mergeLog, String(preferences.addLogMessages)), (Self.mergeLogCount, String(preferences.logMessagesCount))] {
            guard value.lowercased() != effective[key]?.lowercased() else { continue }
            if local[key] != nil || distributed[key] != nil { edits[key] = value }
            else if key == Self.mergeLog { global.addLogMessages = preferences.addLogMessages }
            else { global.logMessagesCount = preferences.logMessagesCount }
        }
        if !edits.isEmpty { try Self.write(edits, to: localURL) }
        if global != store.mergePreferences { store.saveMergePreferences(global) }
    }
}
