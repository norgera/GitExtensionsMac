@testable import GitExtensionsCore
@testable import GitCommands
@testable import GitUI
import AppKit

private final class AvatarFixtureClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value = Date()
    func now() -> Date { lock.lock(); defer { lock.unlock() }; return value }
    func advance(_ seconds: TimeInterval) { lock.lock(); defer { lock.unlock() }; value.addTimeInterval(seconds) }
}

private actor AvatarFixtureTransport {
    var requests: [URLRequest] = []
    var responses: [String: (Int, Data)] = [:]
    var delay: Duration = .zero
    var active = 0, maximumActive = 0
    func set(_ contains: String, status: Int = 200, data: Data) { responses[contains] = (status, data) }
    func setDelay(_ value: Duration) { delay = value }
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request); active += 1; maximumActive = max(maximumActive, active)
        defer { active -= 1 }
        if delay != .zero { try await Task.sleep(for: delay) }
        let response = responses.first { request.url!.absoluteString.contains($0.key) }?.value ?? (404, Data())
        return (response.1, HTTPURLResponse(url: request.url!, statusCode: response.0, httpVersion: nil, headerFields: nil)!)
    }
    func urls() -> [String] { requests.map { $0.url!.absoluteString } }
}

@MainActor
enum AvatarProviderTests {
    static func png(_ width: Int) -> Data {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: width, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        for x in 0..<width { for y in 0..<width {
            let pixel = rep.bitmapData!.advanced(by: y * rep.bytesPerRow + x * 4)
            pixel[0] = 26; pixel[1] = 102; pixel[2] = 230; pixel[3] = 255
        } }
        return rep.representation(using: .png, properties: [:])!
    }
    static func run() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("AvatarTests-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var prefs = AvatarPreferences(); prefs.cachePath = root.path
        precondition(prefs.provider == .none && prefs.cacheDays == 13 && prefs.memoryCapacity == 200 && prefs.showInCommitInfo)
        precondition(AvatarURLs.hash(" MyEmailAddress@example.com ") == "0bc83cb571cd1c50ba6f3e8a78ef1346")
        precondition(AvatarURLs.hash("a", algorithm: "sha1") == "86f7e437faa5a7fce15d1ddcb9eaeaea377667b8")
        precondition(AvatarURLs.hash("a", algorithm: "sha256") == "ca978112ca1bbdcafac231b39a23dc4da786eff8147c4e72b9807785afee48bb")
        precondition(AvatarURLs.template("x/{ EMAIL }/{name}/{imagesize}/{unknown}/done", email: " A+B@C.com ", name: "A B", size: 80) == "x/a%2Bb%40c.com/A+B/80//done")
        precondition(AvatarURLs.template("x/{md5}/tail{broken", email: "a", name: nil, size: 20) == "x/0cc175b9c0f1b6a831c399e269772661/tail")
        precondition(AvatarURLs.githubUsername("123+Bot[bot]@USERS.NOREPLY.GITHUB.COM") == "Bot[bot]")
        precondition(AvatarURLs.github(email: "123+fixture@users.noreply.github.com", size: 80).absoluteString == "https://avatars.githubusercontent.com/fixture?s=80")
        precondition(AvatarURLs.github(email: "author@example.test", size: 16).absoluteString.contains("email=author%40example.test&s=16"))
        for fallback in AvatarFallback.allCases {
            let url = AvatarURLs.gravatar(email: "a", size: 80, fallback: fallback, force: true).absoluteString
            precondition(url.contains("r=g&d=\(fallback.gravatarName ?? "404")&f=y&s=80"))
        }
        for (name, email, expected) in [("albert einstein (k)", "a", "AE"), ("EINSTEIN, Albert middlename (winner)", "a", "EM"),
            ("AEinstein", "", "AE"), ("albert", "", "Al"), ("", "albert_z_einstein@example.test", "AE"), ("'µ *", "", "'*"), ("", "", "?")] {
            precondition(AuthorAvatarPresentation.make(name: name, email: email).initials == expected)
        }
        let fixture = AvatarFixtureTransport(), bitmap = png(32)
        let store = AvatarImageStore(transport: { try await fixture.send($0) })
        let local = await store.image(email: "local@example.test", name: "Local", size: 80, preferences: prefs)
        precondition(local == nil)
        let localRequests = await fixture.urls(); precondition(localRequests.isEmpty)
        prefs.provider = .default
        let cancelledPreferences = prefs
        let cancelled = Task { @MainActor in
            await store.image(email: "cancelled@example.test", name: nil, size: 80, preferences: cancelledPreferences)
        }
        cancelled.cancel()
        let cancelledImage = await cancelled.value
        let cancelledRequests = await fixture.urls()
        precondition(cancelledImage == nil && cancelledRequests.isEmpty, "cancelled queued lookups never start network requests")
        await fixture.set("www.gravatar.com", data: bitmap)
        let fallbackImage = await store.image(email: "regular@example.test", name: "Regular", size: 80, preferences: prefs)
        precondition(fallbackImage == bitmap)
        var urls = await fixture.urls()
        precondition(urls.count == 2 && urls[0].contains("githubusercontent.com") && urls[1].contains("www.gravatar.com"))
        _ = await store.image(email: "regular@example.test", name: "Changed name", size: 80, preferences: prefs)
        urls = await fixture.urls(); precondition(urls.count == 2, "memory hit")
        let secondStore = AvatarImageStore(transport: { try await fixture.send($0) })
        _ = await secondStore.image(email: "regular@example.test", name: nil, size: 80, preferences: prefs)
        urls = await fixture.urls(); precondition(urls.count == 2, "disk survives new service")
        let expired = AvatarImageStore(transport: { try await fixture.send($0) }, now: { Date().addingTimeInterval(14 * 86400) })
        _ = await expired.image(email: "regular@example.test", name: nil, size: 80, preferences: prefs)
        urls = await fixture.urls(); precondition(urls.count == 4, "expired disk refetches")
        let concurrent = AvatarFixtureTransport()
        await concurrent.set("githubusercontent.com", data: bitmap); await concurrent.setDelay(.milliseconds(30))
        let coalescing = AvatarImageStore(transport: { try await concurrent.send($0) })
        prefs.cachePath = root.appendingPathComponent("concurrent").path
        let concurrentPrefs = prefs
        await withTaskGroup(of: Data?.self) { group in
            for _ in 0..<20 { group.addTask { await coalescing.image(email: "shared@example.test", name: nil, size: 80, preferences: concurrentPrefs) } }
            for await image in group { precondition(image == bitmap) }
        }
        urls = await concurrent.urls(); precondition(urls.count == 1, "one in-flight request")
        await withTaskGroup(of: Data?.self) { group in
            for n in 0..<16 { group.addTask { await coalescing.image(email: "\(n)@example.test", name: nil, size: 80, preferences: concurrentPrefs) } }
            for await image in group { precondition(image == bitmap) }
        }
        let maxDownloads = await concurrent.maximumActive; precondition(maxDownloads <= 10)
        let bot = AvatarFixtureTransport()
        await bot.set("api.github.com/users", data: Data(#"{"avatar_url":"https://avatars.githubusercontent.com/bot?id=1"}"#.utf8))
        await bot.set("githubusercontent.com/bot", data: bitmap)
        let botStore = AvatarImageStore(transport: { try await bot.send($0) })
        let botImage = await botStore.image(email: "123+action[bot]@users.noreply.github.com", name: nil, size: 80, preferences: prefs)
        precondition(botImage == bitmap)
        let botRequests = await bot.requests
        precondition(botRequests.count == 2 && botRequests[0].value(forHTTPHeaderField: "Authorization") == nil)
        precondition(botRequests[1].url!.absoluteString.hasSuffix("id=1&s=80"))
        let identicon = AvatarFixtureTransport()
        await identicon.set("githubusercontent.com", data: png(420)); await identicon.set("gravatar.com", data: bitmap)
        let identiconStore = AvatarImageStore(transport: { try await identicon.send($0) })
        prefs.cachePath = root.appendingPathComponent("identicon").path
        let withoutIdenticon = await identiconStore.image(email: "x@test", name: nil, size: 80, preferences: prefs)
        precondition(withoutIdenticon == bitmap)
        urls = await identicon.urls(); precondition(urls.count == 2, "GitHub identicon defers to configured fallback")
        let custom = AvatarFixtureTransport()
        await custom.set("second.test", data: bitmap)
        let customStore = AvatarImageStore(transport: { try await custom.send($0) })
        prefs.provider = .custom; prefs.customTemplate = "https://first.test/{md5};https://second.test/{email}?size={imagesize}"; prefs.memoryCapacity = 1
        prefs.cachePath = root.appendingPathComponent("custom").path
        let customImage = await customStore.image(email: "a@test", name: nil, size: 16, preferences: prefs)
        precondition(customImage == bitmap)
        urls = await custom.urls(); precondition(urls.count == 2 && urls[1].contains("a%40test?size=16"))
        _ = await customStore.image(email: "b@test", name: nil, size: 16, preferences: prefs)
        _ = await customStore.image(email: "a@test", name: nil, size: 16, preferences: prefs)
        urls = await custom.urls(); precondition(urls.count == 4, "MRU eviction still hits disk")
        let unrelated = URL(fileURLWithPath: prefs.cachePath).appendingPathComponent("keep.txt")
        try Data("keep".utf8).write(to: unrelated)
        await customStore.configure(prefs, clear: true)
        precondition(FileManager.default.fileExists(atPath: unrelated.path))
        _ = await customStore.image(email: "a@test", name: nil, size: 16, preferences: prefs)
        urls = await custom.urls(); precondition(urls.count == 6, "clear removes all avatar cache layers")
        let misses = AvatarFixtureTransport(), clock = AvatarFixtureClock()
        let missing = AvatarImageStore(transport: { try await misses.send($0) }, now: { clock.now() })
        prefs.cachePath = root.appendingPathComponent("missing").path
        _ = await missing.image(email: "a@test", name: nil, size: 16, preferences: prefs)
        _ = await missing.image(email: "a@test", name: nil, size: 16, preferences: prefs)
        urls = await misses.urls(); precondition(urls.count == 2, "30s negative URL cache avoids repeat misses")
        clock.advance(31)
        _ = await missing.image(email: "a@test", name: nil, size: 16, preferences: prefs)
        urls = await misses.urls(); precondition(urls.count == 4, "negative URL entries expire after 30s")
        prefs.customTemplate = "<None>;https://second.test/{email}"
        _ = await missing.image(email: "b@test", name: nil, size: 0, preferences: prefs)
        urls = await misses.urls(); precondition(urls.count == 4, "local template provider stops before network")
        prefs.provider = .none; prefs.fallback = .retro
        _ = await missing.image(email: "b@test", name: nil, size: 900, preferences: prefs)
        urls = await misses.urls(); precondition(urls.last!.contains("d=retro&f=y&s=512"))
        let staleFixture = AvatarFixtureTransport()
        await staleFixture.set("second.test", data: bitmap); await staleFixture.setDelay(.milliseconds(50))
        let staleStore = AvatarImageStore(transport: { try await staleFixture.send($0) })
        prefs.provider = .custom; prefs.fallback = .authorInitials; prefs.customTemplate = "https://second.test/{email}"
        prefs.cachePath = root.appendingPathComponent("stale").path
        let stalePrefs = prefs
        let stale = Task { await staleStore.image(email: "old@test", name: nil, size: 16, preferences: stalePrefs) }
        try await Task.sleep(for: .milliseconds(10)); await staleStore.configure(prefs, clear: true)
        let staleResult = await stale.value
        precondition(staleResult == nil, "old requests cannot populate cleared cache")
        try await hosted(prefs: prefs, root: root)
        print("AvatarProviderTests: passed")
    }
    private static func hosted(prefs: AvatarPreferences, root: URL) async throws {
        let suite = "AvatarTests.\(UUID())", defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettingsStore(defaults: defaults)
        settings.saveAvatarPreferences(prefs)
        precondition(AppSettingsStore(defaults: defaults).avatarPreferences == prefs)
        defaults.set(Data(#"{"provider":"AuthorInitials","fallback":"Retro"}"#.utf8), forKey: "GitExtensionsMac.avatarPreferences.v1")
        precondition(settings.avatarPreferences.provider == .none && settings.avatarPreferences.fallback == .authorInitials)
        let old = AppSettingsStore.shared.avatarPreferences, oldStore = AvatarService.shared.store
        var uiPrefs = prefs; uiPrefs.customTemplate = "https://avatar.test/{email}"; uiPrefs.cachePath = root.appendingPathComponent("ui").path
        let fixture = AvatarFixtureTransport()
        await fixture.set("a%40test", data: png(8)); await fixture.set("b%40test", data: png(16)); await fixture.setDelay(.milliseconds(30))
        AvatarService.shared.store = AvatarImageStore(transport: { try await fixture.send($0) })
        AppSettingsStore.shared.saveAvatarPreferences(uiPrefs)
        defer { AvatarService.shared.store = oldStore; AppSettingsStore.shared.saveAvatarPreferences(old) }
        let view = AuthorAvatarView(frame: .init(x: 0, y: 0, width: 80, height: 80)); view.commitInfoMode = true
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 100, height: 100), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView?.addSubview(view); window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        view.apply(name: "A", email: "a@test"); view.apply(name: "B", email: "b@test")
        try await Task.sleep(for: .milliseconds(120))
        precondition(view.hasProviderImage, "shared view receives async provider image")
        precondition(view.providerImageSize?.width == 16, "a stale author response cannot replace the latest author")
        let event = NSEvent.mouseEvent(with: .rightMouseDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        let menu = view.menu(for: event)!
        precondition(menu.items.map(\.title) == ["Clear image cache", "Avatar provider", "Fallback generated avatar style", "", "Register at gravatar.com"])
        precondition(menu.items[1].submenu!.items.first { $0.title == "Custom" }?.state == .on)
        uiPrefs.provider = .none; AppSettingsStore.shared.saveAvatarPreferences(uiPrefs)
        try await Task.sleep(for: .milliseconds(80)); precondition(!view.hasProviderImage, "live changes restore initials")
    }
}
