import Darwin
import Foundation

package struct GitCredentialPrompt: Sendable, Equatable {
    package let text: String
    package let isSecret: Bool

    package init(text: String) {
        self.text = text
        let lower = text.lowercased()
        isSecret = !(lower.hasPrefix("username") || lower.contains("(yes/no"))
    }
}

package final class GitInteractiveSession: @unchecked Sendable {
    package typealias PromptHandler = @Sendable (GitCredentialPrompt) async -> String?

    package static let current = TaskLocal<GitInteractiveSession?>(wrappedValue: nil)

    private let lock = NSLock()
    private let promptHandler: PromptHandler
    private var inputs: [(id: UUID, descriptor: Int32)] = []
    private var bridge: GitAskPassBridge?
    private var bridgeFailed = false
    private var isClosed = false

    package init(prompt: @escaping PromptHandler) {
        promptHandler = prompt
    }

    deinit { close() }

    package func bind<T>(_ operation: () async throws -> T) async rethrows -> T {
        try await Self.current.withValue(self) { try await operation() }
    }

    package var hasActiveInput: Bool {
        lock.lock(); defer { lock.unlock() }
        return !inputs.isEmpty
    }

    package var askPassURL: URL? {
        lock.lock(); defer { lock.unlock() }
        return bridge?.scriptURL
    }

    package func environment(inherited: [String: String]) -> [String: String] {
        lock.lock()
        defer { lock.unlock() }
        guard !isClosed else { return [:] }
        if bridge == nil, !bridgeFailed {
            bridge = GitAskPassBridge(handler: promptHandler)
            bridgeFailed = bridge == nil
        }
        var environment = ["SSH_ASKPASS_REQUIRE": "force"]
        if let existing = inherited["SSH_ASKPASS"], !existing.isEmpty {
            environment["SSH_ASKPASS"] = existing
        } else if let bridge {
            environment["SSH_ASKPASS"] = bridge.scriptURL.path
        } else {
            return [:]
        }
        return environment
    }

    func attachInput(_ descriptor: Int32) -> UUID {
        _ = fcntl(descriptor, F_SETNOSIGPIPE, 1)
        _ = fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL) | O_NONBLOCK)
        let id = UUID()
        lock.lock()
        inputs.append((id, descriptor))
        lock.unlock()
        return id
    }

    func detachInput(_ id: UUID) {
        lock.lock()
        inputs.removeAll { $0.id == id }
        lock.unlock()
    }

    @discardableResult
    package func send(_ text: String) -> Bool {
        let bytes = Array((text + "\n").utf8)
        lock.lock()
        defer { lock.unlock() }
        guard let descriptor = inputs.last?.descriptor else { return false }
        var offset = 0
        while offset < bytes.count {
            let written = bytes[offset...].withUnsafeBytes { Darwin.write(descriptor, $0.baseAddress, $0.count) }
            if written < 0 {
                if errno == EINTR { continue }
                return false
            }
            offset += written
        }
        return true
    }

    package func close() {
        lock.lock()
        isClosed = true
        let closing = bridge
        bridge = nil
        lock.unlock()
        closing?.close()
    }
}

final class GitAskPassBridge: @unchecked Sendable {
    let directory: URL
    let scriptURL: URL
    private let requestDescriptor: Int32
    private let source: DispatchSourceRead
    private let handler: GitInteractiveSession.PromptHandler
    private let lock = NSLock()
    private var buffer = Data()
    private var closed = false

    static let script = """
    #!/bin/sh
    d=$(dirname "$0")
    [ -p "$d/request" ] || exit 1
    umask 077
    r="$d/r.$$"
    p="$d/p.$$"
    trap 'rm -f "$r" "$p"' EXIT
    trap 'exit 1' HUP INT TERM
    mkfifo "$r" || exit 1
    exec 3<>"$r"
    printf '%s' "$1" > "$p" || exit 1
    printf '%s\\n' "$$" > "$d/request" || exit 1
    IFS= read -r line <&3 || exit 1
    case "$line" in
    1*) printf '%s\\n' "${line#1}" ;;
    *) exit 1 ;;
    esac

    """

    init?(handler: @escaping GitInteractiveSession.PromptHandler) {
        self.handler = handler
        var template = Array(FileManager.default.temporaryDirectory.appendingPathComponent("GitExtensionsMac-askpass.XXXXXX").path.utf8CString)
        guard let created = template.withUnsafeMutableBufferPointer({ mkdtemp($0.baseAddress) }) else { return nil }
        let directory = URL(fileURLWithPath: String(cString: created), isDirectory: true)
        _ = chmod(directory.path, 0o700)
        let scriptURL = directory.appendingPathComponent("askpass.sh")
        let request = directory.appendingPathComponent("request")
        guard FileManager.default.createFile(atPath: scriptURL.path, contents: Data(Self.script.utf8), attributes: [.posixPermissions: 0o700]),
              mkfifo(request.path, 0o600) == 0 else {
            try? FileManager.default.removeItem(at: directory)
            return nil
        }
        let descriptor = open(request.path, O_RDWR | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else {
            try? FileManager.default.removeItem(at: directory)
            return nil
        }
        self.directory = directory
        self.scriptURL = scriptURL
        requestDescriptor = descriptor
        source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: DispatchQueue(label: "com.gitextensions.mac.askpass"))
        source.setEventHandler { [weak self] in self?.readRequests() }
        source.setCancelHandler { Darwin.close(descriptor) }
        source.resume()
    }

    private func readRequests() {
        var chunk = [UInt8](repeating: 0, count: 512)
        let count = chunk.withUnsafeMutableBytes { Darwin.read(requestDescriptor, $0.baseAddress, $0.count) }
        guard count > 0 else { return }
        lock.lock()
        buffer.append(contentsOf: chunk[0..<count])
        var identifiers: [String] = []
        while let newline = buffer.firstIndex(of: 0x0A) {
            identifiers.append(String(decoding: buffer[buffer.startIndex..<newline], as: UTF8.self))
            buffer.removeSubrange(buffer.startIndex...newline)
        }
        lock.unlock()
        for identifier in identifiers where !identifier.isEmpty && identifier.allSatisfy(\.isASCII) && identifier.allSatisfy(\.isNumber) {
            answer(identifier)
        }
    }

    private func answer(_ identifier: String) {
        let promptURL = directory.appendingPathComponent("p.\(identifier)")
        let responsePath = directory.appendingPathComponent("r.\(identifier)").path
        let prompt = (try? String(contentsOf: promptURL, encoding: .utf8)) ?? ""
        let handler = handler
        Task.detached { [weak self] in
            let value = await handler(GitCredentialPrompt(text: prompt))
            guard let self, !self.isClosed else { return }
            let line = value.map { "1" + $0.prefix { $0 != "\n" && $0 != "\r" } + "\n" } ?? "0\n"
            let descriptor = open(responsePath, O_WRONLY | O_NONBLOCK | O_CLOEXEC)
            guard descriptor >= 0 else { return }
            _ = fcntl(descriptor, F_SETNOSIGPIPE, 1)
            let bytes = Array(line.utf8)
            _ = bytes.withUnsafeBytes { Darwin.write(descriptor, $0.baseAddress, $0.count) }
            Darwin.close(descriptor)
        }
    }

    private var isClosed: Bool {
        lock.lock(); defer { lock.unlock() }
        return closed
    }

    func close() {
        lock.lock()
        guard !closed else { lock.unlock(); return }
        closed = true
        lock.unlock()
        source.cancel()
        try? FileManager.default.removeItem(at: directory)
    }
}
