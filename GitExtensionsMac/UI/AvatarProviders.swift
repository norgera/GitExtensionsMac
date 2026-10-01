import AppKit
import CryptoKit
import ImageIO
import GitCommands
import GitExtensionsCore

enum AvatarProvider: String, Codable, CaseIterable, Sendable { case `default` = "Default", custom = "Custom", none = "None" }
enum AvatarFallback: String, Codable, CaseIterable, Sendable {
    case authorInitials = "Author initials", monsterId = "MonsterId", wavatar = "Wavatar"
    case identicon = "Identicon", retro = "Retro", robohash = "Robohash"
    var gravatarName: String? { self == .authorInitials ? nil : rawValue.lowercased() }
}



struct AvatarPreferences: Codable, Equatable, Sendable {
    var provider: AvatarProvider = .none
    var fallback: AvatarFallback = .authorInitials
    var customTemplate = ""
    var cacheDays = 13
    var memoryCapacity = 200
    var showInCommitInfo = true
    var cachePath = ""
    var initialsPalette = "SlateGray,RoyalBlue,Purple,OrangeRed,Teal,OliveDrab"
    var luminanceThreshold = 0.5
    init() {}
    private enum CodingKeys: String, CodingKey {
        case provider, fallback, customTemplate, cacheDays, memoryCapacity, showInCommitInfo, cachePath, initialsPalette, luminanceThreshold
    }
    init(from decoder: Decoder) throws {
        let v = try decoder.container(keyedBy: CodingKeys.self)
        func value<T: Decodable>(_ key: CodingKeys, _ defaultValue: T) -> T { (try? v.decode(T.self, forKey: key)) ?? defaultValue }
        let oldProvider = value(.provider, "None")
        provider = oldProvider == "Gravatar" ? .default : AvatarProvider(rawValue: oldProvider) ?? .none
        fallback = AvatarFallback(rawValue: value(.fallback, "Author initials")) ?? .authorInitials
        if oldProvider == "AuthorInitials" { provider = .none; fallback = .authorInitials }
        customTemplate = value(.customTemplate, "")
        cacheDays = value(.cacheDays, 13); memoryCapacity = max(0, value(.memoryCapacity, 200))
        showInCommitInfo = value(.showInCommitInfo, true); cachePath = value(.cachePath, "")
        initialsPalette = value(.initialsPalette, initialsPalette)
        luminanceThreshold = value(.luminanceThreshold, 0.5)
    }
    var directory: URL {
        if !cachePath.isEmpty { return URL(fileURLWithPath: (cachePath as NSString).expandingTildeInPath, isDirectory: true) }
        return FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("GitExtensionsMac/avatars", isDirectory: true)
    }
    var performsIO: Bool { provider != .none || fallback != .authorInitials }
}

enum AvatarURLs {
    static func encode(_ text: String) -> String {

        text.addingPercentEncoding(withAllowedCharacters: CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.!*()"))!
            .replacingOccurrences(of: "%20", with: "+")
    }
    static func hash(_ email: String, algorithm: String = "md5") -> String {
        let data = Data(email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().utf8)
        let bytes: [UInt8]
        switch algorithm { case "sha1": bytes = Array(Insecure.SHA1.hash(data: data))
        case "sha256": bytes = Array(SHA256.hash(data: data))
        default: bytes = Array(Insecure.MD5.hash(data: data)) }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
    static func gravatar(email: String, size: Int, fallback: AvatarFallback, force: Bool = false) -> URL {
        URL(string: "https://www.gravatar.com/avatar/\(hash(email))?r=g&d=\(fallback.gravatarName ?? "404")\(force ? "&f=y" : "")&s=\(size)")!
    }
    static func githubUsername(_ email: String) -> String? {
        guard let range = email.range(of: #"^(\d+\+)?([^@]+)@users\.noreply\.github\.com$"#, options: [.regularExpression, .caseInsensitive]) else { return nil }
        let local = String(email[range].split(separator: "@")[0])
        if let plus = local.firstIndex(of: "+"), local[..<plus].allSatisfy(\.isNumber) { return String(local[local.index(after: plus)...]) }
        return local
    }
    static func github(email: String, size: Int) -> URL {
        if let user = githubUsername(email) { return URL(string: "https://avatars.githubusercontent.com/\(encode(user))?s=\(size)")! }
        return URL(string: "https://avatars.githubusercontent.com/u/e?email=\(encode(email))&s=\(size)")!
    }


    static func template(_ template: String, email: String, name: String?, size: Int) -> String {
        var result = "", remainder = template[...]
        while let open = remainder.firstIndex(of: "{") {
            result += remainder[..<open]
            guard let close = remainder[remainder.index(after: open)...].firstIndex(of: "}") else { return result }
            let key = remainder[remainder.index(after: open)..<close].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            switch key {
            case "email": result += encode(email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
            case "name": result += encode(name ?? "")
            case "imagesize": result += String(size)
            case "md5", "sha1", "sha256": result += hash(email, algorithm: key)
            default: break
            }
            remainder = remainder[remainder.index(after: close)...]
        }
        return result + remainder
    }
    static func pixelWidth(_ data: Data) -> Int? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let info = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else { return nil }
        return info[kCGImagePropertyPixelWidth] as? Int
    }
}



actor AvatarImageStore {
    private struct Key: Hashable { let email: String; let size: Int }
    private var settings: AvatarPreferences?
    private var generation = 0
    private var memory: [Key: Data] = [:]
    private var mru: [Key] = []
    private var pending: [Key: Task<Data?, Never>] = [:]
    private var downloads: [URL: (Date, Task<Data?, Never>)] = [:]
    private var activeDownloads = 0
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private let transport: HostTransport
    private let now: @Sendable () -> Date
    init(transport: @escaping HostTransport = { try await HostHTTP.send($0) }, now: @escaping @Sendable () -> Date = { Date() }) {
        self.transport = transport; self.now = now
    }
    func configure(_ new: AvatarPreferences, clear: Bool = false) {
        let changed = settings.map { $0.provider != new.provider || $0.fallback != new.fallback || $0.customTemplate != new.customTemplate || $0.cachePath != new.cachePath } ?? false
        if changed || clear {
            generation += 1
            pending.values.forEach { $0.cancel() }; downloads.values.forEach { $0.1.cancel() }
            pending.removeAll(); downloads.removeAll(); memory.removeAll(); mru.removeAll()
            clearDisk(new.directory)
            if let old = settings, old.directory != new.directory { clearDisk(old.directory) }
        }
        settings = new
        while mru.count > new.memoryCapacity { memory[mru.removeFirst()] = nil }
    }
    private func clearDisk(_ directory: URL) {

        for file in (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
            where file.lastPathComponent.range(of: #"^[a-f0-9]{64}\.[0-9]+px\.avatar$"#, options: .regularExpression) != nil {
            try? FileManager.default.removeItem(at: file)
        }
    }
    func image(email: String, name: String?, size requested: Int, preferences: AvatarPreferences) async -> Data? {
        guard !Task.isCancelled else { return nil }
        configure(preferences)
        guard !email.isEmpty, preferences.performsIO else { return nil }
        let size = requested < 1 ? 64 : min(512, requested)
        let key = Key(email: email, size: size)
        if let cached = memory[key] { touch(key); return cached }
        if let task = pending[key] { return await task.value }
        let revision = generation
        let task = Task { await self.load(email: email, name: name, size: size, preferences: preferences) }
        pending[key] = task
        let image = await task.value
        guard generation == revision else { return nil }
        pending[key] = nil
        if let image, preferences.memoryCapacity > 0 {
            memory[key] = image; touch(key)
            while mru.count > preferences.memoryCapacity { memory[mru.removeFirst()] = nil }
        }
        return image
    }
    private func touch(_ key: Key) { mru.removeAll { $0 == key }; mru.append(key) }
    private func load(email: String, name: String?, size: Int, preferences: AvatarPreferences) async -> Data? {

        let file = preferences.directory.appendingPathComponent("\(AvatarURLs.hash(email, algorithm: "sha256")).\(size)px.avatar")
        if let values = try? file.resourceValues(forKeys: [.contentModificationDateKey]), let modified = values.contentModificationDate {
            let fresh = preferences.provider == .none || now().timeIntervalSince(modified) < Double(preferences.cacheDays < 1 ? 30 : preferences.cacheDays) * 86400
            if fresh, let data = try? Data(contentsOf: file), AvatarURLs.pixelWidth(data) != nil { return data }
            if !fresh { try? FileManager.default.removeItem(at: file) }
        }
        let image = await resolve(email: email, name: name, size: size, preferences: preferences)
        guard !Task.isCancelled else { return nil }
        if let image {
            try? FileManager.default.createDirectory(at: preferences.directory, withIntermediateDirectories: true)
            try? image.write(to: file, options: .atomic)
        }
        return image
    }
    private func resolve(email: String, name: String?, size: Int, preferences: AvatarPreferences) async -> Data? {
        if preferences.provider == .default {
            if let image = await defaultProvider(email: email, size: size, fallback: preferences.fallback) { return image }
        } else if preferences.provider == .custom {
            for part in preferences.customTemplate.split(separator: ";") {
                guard !Task.isCancelled else { return nil }
                let template = part.trimmingCharacters(in: .whitespacesAndNewlines)
                if template.lowercased() == "<default>" {
                    if let image = await defaultProvider(email: email, size: size, fallback: .authorInitials) { return image }

                    return nil
                }
                if template.lowercased() == "<none>" { return nil }
                if template.hasPrefix("<") && template.hasSuffix(">") { continue }
                if let url = URL(string: AvatarURLs.template(template, email: email, name: name, size: size)),
                   let image = await download(url) { return image }
            }
        }
        guard !Task.isCancelled, preferences.fallback != .authorInitials else { return nil }
        return await download(AvatarURLs.gravatar(email: email, size: size, fallback: preferences.fallback, force: true))
    }
    private func defaultProvider(email: String, size: Int, fallback: AvatarFallback) async -> Data? {
        var url: URL? = AvatarURLs.github(email: email, size: size)
        if let user = AvatarURLs.githubUsername(email), user.contains("[") {


            url = try? await RepositoryHostClient.publicUserAvatar(user, size: size, transport: transport)
        }
        if let url, let image = await download(url), size == 420 || AvatarURLs.pixelWidth(image) != 420 { return image }
        guard !Task.isCancelled else { return nil }
        return await download(AvatarURLs.gravatar(email: email, size: size, fallback: fallback))
    }
    private func acquire() async {
        if activeDownloads < 10 { activeDownloads += 1; return }
        await withCheckedContinuation { waiting.append($0) }
    }
    private func release() {
        if waiting.isEmpty { activeDownloads -= 1 } else { waiting.removeFirst().resume() }
    }
    private func download(_ url: URL) async -> Data? {
        guard !Task.isCancelled, ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return nil }
        downloads = downloads.filter { now().timeIntervalSince($0.value.0) <= 30 }
        if let entry = downloads[url] { return await entry.1.value }
        let task = Task { () -> Data? in
            await self.acquire()
            defer { self.release() }
            guard !Task.isCancelled else { return nil }
            do {
                let request = URLRequest(url: url, timeoutInterval: 30)
                let (data, response) = try await self.transport(request)
                guard !Task.isCancelled, (200..<300).contains(response.statusCode), AvatarURLs.pixelWidth(data) != nil else { return nil }
                return data
            } catch { return nil }
        }
        downloads[url] = (now(), task)
        return await task.value
    }
}

extension Notification.Name { static let avatarCacheDidChange = Notification.Name("GitExtensionsMac.avatarCacheDidChange") }

@MainActor
final class AvatarService {
    static let shared = AvatarService()
    var store = AvatarImageStore()
    func image(email: String, name: String?, size: Int) async -> NSImage? {
        guard !Task.isCancelled else { return nil }
        let preferences = AppSettingsStore.shared.avatarPreferences
        let data = await store.image(email: email, name: name, size: size, preferences: preferences)
        guard !Task.isCancelled else { return nil }
        if let data, let image = NSImage(data: data) { return image }
        let usesLocalFallback = preferences.fallback == .authorInitials ||
            (preferences.provider == .custom && preferences.customTemplate.split(separator: ";").contains {
                ["<none>", "<default>"].contains($0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
            })
        return usesLocalFallback ? nil : AppKitFactory.resourceImage("User80", accessibilityDescription: "Unknown author")
    }
    func configure(_ preferences: AvatarPreferences, clear: Bool = false) async {
        await store.configure(preferences, clear: clear)
        NotificationCenter.default.post(name: .avatarCacheDidChange, object: nil)
    }
    func clearCache() { Task { await configure(AppSettingsStore.shared.avatarPreferences, clear: true) } }
}



@MainActor
final class AuthorAvatarView: NSView, NSMenuDelegate {
    private var presentation = AuthorAvatarPresentation(initials: "?", paletteIndex: 0)
    private var image: NSImage?
    private var name: String?, email: String?
    private var task: Task<Void, Never>?
    private var generation = 0
    private var loadedSize = 0
    private var observer: NSObjectProtocol?
    private var fontObserver: NSObjectProtocol?
    var commitInfoMode = false
    var cornerRadius: CGFloat = 0
    var hasProviderImage: Bool { image != nil }
    var providerImageSize: NSSize? { image?.size }
    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        observer = NotificationCenter.default.addObserver(forName: .avatarCacheDidChange, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.reload() }
        }
        fontObserver = NotificationCenter.default.addObserver(forName: .appPreferencesDidChange, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.needsDisplay = true }
        }
    }
    required init?(coder: NSCoder) { nil }
    deinit {
        task?.cancel()
        if let observer { NotificationCenter.default.removeObserver(observer) }
        if let fontObserver { NotificationCenter.default.removeObserver(fontObserver) }
    }
    func apply(name: String?, email: String?) {
        guard self.name != name || self.email != email || loadedSize == 0 else { return }
        self.name = name; self.email = email
        presentation = AuthorAvatarPresentation.make(name: name, email: email,
            paletteCount: AppSettingsStore.shared.avatarPreferences.initialsPalette.split(separator: ",").count)
        setAccessibilityLabel("Author avatar for \(name?.isEmpty == false ? name! : email ?? "unknown author")")
        reload()
    }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); reload() }
    override func layout() {
        super.layout()
        if requestedSize != loadedSize { reload() }
    }
    private var requestedSize: Int { max(0, min(512, Int(max(bounds.width, bounds.height).rounded()))) }
    private func reload() {
        presentation = AuthorAvatarPresentation.make(name: name, email: email,
            paletteCount: AppSettingsStore.shared.avatarPreferences.initialsPalette.split(separator: ",").count)
        generation += 1; task?.cancel(); image = nil; needsDisplay = true
        if email?.isEmpty != false || (commitInfoMode && !AppSettingsStore.shared.avatarPreferences.showInCommitInfo) {
            image = AppKitFactory.resourceImage("User80", accessibilityDescription: "Unknown author")
        }
        loadedSize = requestedSize
        guard loadedSize > 0, !isHidden, !isHiddenOrHasHiddenAncestor, window != nil, let email, !email.isEmpty,
              !commitInfoMode || AppSettingsStore.shared.avatarPreferences.showInCommitInfo else { return }
        let revision = generation, name = name, size = loadedSize
        task = Task { @MainActor [weak self] in
            let image = await AvatarService.shared.image(email: email, name: name, size: size)
            guard !Task.isCancelled, let self, generation == revision else { return }
            self.image = image; needsDisplay = true
        }
    }
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        if cornerRadius > 0 { NSBezierPath(roundedRect: bounds, xRadius: cornerRadius, yRadius: cornerRadius).addClip() }
        if let image { image.draw(in: bounds); return }
        let preferences = AppSettingsStore.shared.avatarPreferences
        let colors = preferences.initialsPalette.split(separator: ",").map { Self.color(String($0)) }
        let color = colors.isEmpty ? NSColor.black : colors[presentation.paletteIndex % colors.count]
        color.setFill(); bounds.fill()
        let rgb = color.usingColorSpace(.sRGB) ?? .black
        let luminance = 0.2126 * rgb.redComponent + 0.7152 * rgb.greenComponent + 0.0722 * rgb.blueComponent
        let attributes: [NSAttributedString.Key: Any] = [
            .font: AppSettingsStore.shared.applicationFont(size: min(32, bounds.height * 0.45)),
            .foregroundColor: luminance > preferences.luminanceThreshold ? NSColor.black : NSColor.white
        ]
        let size = presentation.initials.size(withAttributes: attributes)
        presentation.initials.draw(at: NSPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2), withAttributes: attributes)
    }
    private static func color(_ name: String) -> NSColor {
        let text = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let hex = text.hasPrefix("#") ? String(text.dropFirst()) : text
        let parsed = text.hasPrefix("#") && hex.count == 8 ? UInt64(hex, radix: 16) : ApplicationThemeReader.parseColor(text).map(UInt64.init)
        if let value = parsed {
            return NSColor(srgbRed: Double((value >> 16) & 255) / 255, green: Double((value >> 8) & 255) / 255,
                           blue: Double(value & 255) / 255, alpha: hex.count == 8 ? Double((value >> 24) & 255) / 255 : 1)
        }
        return .black
    }
    override func menu(for event: NSEvent) -> NSMenu? {
        guard commitInfoMode else { return super.menu(for: event) }
        let menu = NSMenu(); menu.autoenablesItems = false
        let clear = menu.addItem(withTitle: "Clear image cache", action: #selector(clearCache), keyEquivalent: ""); clear.target = self
        let preferences = AppSettingsStore.shared.avatarPreferences
        for (title, values, selected) in [("Avatar provider", AvatarProvider.allCases.map(\.rawValue), preferences.provider.rawValue),
                                        ("Fallback generated avatar style", AvatarFallback.allCases.map(\.rawValue), preferences.fallback.rawValue)] {
            let parent = menu.addItem(withTitle: title, action: nil, keyEquivalent: "")
            let sub = NSMenu(); sub.autoenablesItems = false; parent.submenu = sub
            for value in values {
                let item = sub.addItem(withTitle: value, action: #selector(changeProvider(_:)), keyEquivalent: "")
                item.target = self; item.representedObject = [title, value]; item.state = value == selected ? .on : .off
            }
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: "Register at gravatar.com", action: #selector(registerGravatar), keyEquivalent: "").target = self
        return menu
    }
    @objc private func clearCache() { AvatarService.shared.clearCache() }
    @objc private func registerGravatar() { NSWorkspace.shared.open(URL(string: "https://www.gravatar.com")!) }
    @objc private func changeProvider(_ sender: NSMenuItem) {
        guard let values = sender.representedObject as? [String], values.count == 2 else { return }
        var preferences = AppSettingsStore.shared.avatarPreferences
        if values[0] == "Avatar provider" { preferences.provider = AvatarProvider(rawValue: values[1]) ?? .none }
        else { preferences.fallback = AvatarFallback(rawValue: values[1]) ?? .authorInitials }
        AppSettingsStore.shared.saveAvatarPreferences(preferences)
    }
}
