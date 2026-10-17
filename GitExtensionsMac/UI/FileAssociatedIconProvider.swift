import AppKit
import UniformTypeIdentifiers

@MainActor
final class FileAssociatedIconProvider {
    enum Key: Hashable {
        case folder
        case fileExtension(String)
        case generic
    }

    static let shared = FileAssociatedIconProvider()
    private var cache: [Key: NSImage] = [:]
    var cacheCount: Int { cache.count }

    static func key(path: String, isDirectory: Bool = false) -> Key {
        if isDirectory || path.hasSuffix("/") { return .folder }
        let ext = (path as NSString).pathExtension.lowercased()
        return ext.isEmpty ? .generic : .fileExtension(ext)
    }

    func icon(path: String, isDirectory: Bool = false) -> NSImage {
        let key = Self.key(path: path, isDirectory: isDirectory)
        if let image = cache[key] { return image }
        let type: UTType
        switch key {
        case .folder: type = .folder
        case .generic: type = .data
        case .fileExtension(let ext): type = UTType(filenameExtension: ext) ?? .data
        }
        let image = NSWorkspace.shared.icon(for: type)
        cache[key] = image
        return image
    }
}
