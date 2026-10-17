import AppKit
import Dispatch
import Foundation
import Testing

@testable import GitCommands
@testable import GitExtensionsCore
@testable import GitUI

@Suite(.tags(.unit))
struct UnitTests {}

@Suite(.gitConcurrency, .tags(.git))
struct GitIntegrationTests {}

@Suite(.serialized, .appEnvironment, .tags(.ui))
struct UIIntegrationTests {}

extension Testing.Tag {
    @Tag static var unit: Self
    @Tag static var git: Self
    @Tag static var ui: Self
}

actor IntegrationTestSlots {
    static let shared = IntegrationTestSlots()
    private var available = 2
    private var waiters: [(slots: Int, continuation: CheckedContinuation<Void, Never>)] = []

    func acquire(_ slots: Int) async {
        if waiters.isEmpty && available >= slots {
            available -= slots
        } else {
            await withCheckedContinuation { waiters.append((slots, $0)) }
        }
    }

    func release(_ slots: Int) {
        available += slots
        while let first = waiters.first, first.slots <= available {
            available -= first.slots
            waiters.removeFirst().continuation.resume()
        }
    }
}

struct GitConcurrencyTrait: SuiteTrait, TestTrait, TestScoping {
    var isRecursive: Bool { true }

    func provideScope(for test: Test, testCase: Test.Case?, performing function: @Sendable () async throws -> Void) async throws {
        guard !test.isSuite else {
            try await function()
            return
        }
        await IntegrationTestSlots.shared.acquire(1)
        do { try await function() } catch {
            await IntegrationTestSlots.shared.release(1)
            throw error
        }
        await IntegrationTestSlots.shared.release(1)
    }
}

struct AppEnvironmentTrait: SuiteTrait, TestTrait, TestScoping {
    var isRecursive: Bool { true }

    func provideScope(for test: Test, testCase: Test.Case?, performing function: @Sendable () async throws -> Void) async throws {
        guard !test.isSuite else {
            try await function()
            return
        }
        await IntegrationTestSlots.shared.acquire(2)
        await TestEnvironment.prepare()
        do { try await function() } catch {
            await TestEnvironment.finishCase()
            await IntegrationTestSlots.shared.release(2)
            throw error
        }
        await TestEnvironment.finishCase()
        await IntegrationTestSlots.shared.release(2)
    }
}

extension Trait where Self == AppEnvironmentTrait {
    static var appEnvironment: AppEnvironmentTrait { AppEnvironmentTrait() }
}

extension Trait where Self == GitConcurrencyTrait {
    static var gitConcurrency: GitConcurrencyTrait { GitConcurrencyTrait() }
}

private final class TestBundleMarker: NSObject {}

enum TestResources {
    static let root = Bundle(for: TestBundleMarker.self).resourceURL!
    static let fixtures = root.appendingPathComponent("Fixtures", isDirectory: true)
    static let themes = root.appendingPathComponent("Themes", isDirectory: true)
    static let images = root.appendingPathComponent("Resources", isDirectory: true)
}

@MainActor
enum TestEnvironment {
    private static var isPrepared = false
    private static let lifecycle = TestApplicationDelegate()
    private static var activity: NSObjectProtocol?

    static func prepare() {
        guard !isPrepared else { return }
        isPrepared = true
        activity = ProcessInfo.processInfo.beginActivity(options: .userInitiated, reason: "AppKit integration tests")
        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)
        application.delegate = lifecycle
        if ProcessInfo.processInfo.environment["GITEXTENSIONS_TEST_SHOW_WINDOWS"] != "1" {
            HiddenTestWindows.install()
        }
        AvatarService.shared.store = AvatarImageStore(transport: { request in
            (Data(), HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!)
        })
    }

    static func finishCase() {
        autoreleasepool {
            for window in NSApplication.shared.windows {
                if let sheet = window.attachedSheet { window.endSheet(sheet, returnCode: .cancel) }
                window.close()
            }
            CommandCache.shared.clear()
            CommandLog.shared.clear()
        }
    }
}

enum HiddenTestWindows {
    private static var installed = false

    static func install() {
        guard !installed else { return }
        installed = true
        let selector = #selector(NSWindow.order(_:relativeTo:))
        guard let method = class_getInstanceMethod(NSWindow.self, selector) else { return }
        typealias Order = @convention(c) (NSWindow, Selector, NSWindow.OrderingMode, Int) -> Void
        let original = unsafeBitCast(method_getImplementation(method), to: Order.self)
        let replacement: @convention(block) (NSWindow, NSWindow.OrderingMode, Int) -> Void = { window, mode, other in
            if mode != .out {
                window.alphaValue = 0
                window.ignoresMouseEvents = true
                window.hasShadow = false
            }
            original(window, selector, mode, other)
        }
        method_setImplementation(method, imp_implementationWithBlock(replacement))
    }
}

private final class TestApplicationDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply { .terminateCancel }
}

final class FixtureProcess: @unchecked Sendable {
    private let process = Process()
    private let completed = DispatchSemaphore(value: 0)

    init() {
        let completed = completed
        process.terminationHandler = { _ in completed.signal() }
    }

    var executableURL: URL? {
        get { process.executableURL }
        set { process.executableURL = newValue }
    }
    var arguments: [String]? {
        get { process.arguments }
        set { process.arguments = newValue }
    }
    var currentDirectoryURL: URL? {
        get { process.currentDirectoryURL }
        set { process.currentDirectoryURL = newValue }
    }
    var environment: [String: String]? {
        get { process.environment }
        set { process.environment = newValue }
    }
    var standardInput: Any? {
        get { process.standardInput }
        set { process.standardInput = newValue }
    }
    var standardOutput: Any? {
        get { process.standardOutput }
        set { process.standardOutput = newValue }
    }
    var standardError: Any? {
        get { process.standardError }
        set { process.standardError = newValue }
    }
    var terminationStatus: Int32 { process.terminationStatus }
    var isRunning: Bool { process.isRunning }

    func run() throws { try process.run() }
    func waitUntilExit() {
        completed.wait()
        completed.signal()
    }
}

struct TestFailure: Error, CustomStringConvertible {
    let description: String
}

func testObjectID(_ label: String) -> ObjectID {
    var words: [UInt32] = [2_166_136_261, 2_166_136_263, 2_166_136_269, 2_166_136_283, 2_166_136_301]
    for byte in label.utf8 {
        for index in words.indices {
            words[index] ^= UInt32(byte) &+ UInt32(index)
            words[index] &*= 16_777_619
        }
    }
    return try! ObjectID.parse(words.map { String(format: "%08x", $0) }.joined())
}

func testRevisionID(_ label: String) -> RevisionID { .object(testObjectID(label)) }

@MainActor
func waitUntil(
    _ message: @autoclosure () -> String, timeout: Duration = .seconds(10), sourceLocation: SourceLocation = #_sourceLocation, _ condition: () throws -> Bool
) async throws {
    let deadline = ContinuousClock.now + timeout
    while try !condition() {
        guard ContinuousClock.now < deadline else {
            Issue.record(Comment(rawValue: "timed out waiting for \(message())"), sourceLocation: sourceLocation)
            throw TestFailure(description: "timed out waiting for \(message())")
        }
        try await Task.sleep(for: .milliseconds(20))
    }
}
