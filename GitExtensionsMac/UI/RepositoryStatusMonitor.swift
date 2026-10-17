import Foundation
import CoreServices

struct RepositoryRefreshState {
    struct Ticket: Equatable {
        let epoch: UUID
        let sequence: UInt64
        let generation: UInt64
    }
    private var epoch = UUID()
    private var generation: UInt64 = 0
    private var incorporated: UInt64 = 0
    private var sequence: UInt64 = 0
    private(set) var active: Ticket?
    var isDirty: Bool { incorporated != generation }
    mutating func changed() { generation &+= 1 }
    mutating func begin() -> Ticket {
        sequence &+= 1
        let ticket = Ticket(epoch: epoch, sequence: sequence, generation: generation)
        active = ticket
        return ticket
    }
    @discardableResult mutating func finish(_ ticket: Ticket, succeeded: Bool) -> Bool {
        guard ticket == active else { return false }
        if succeeded { incorporated = ticket.generation }
        active = nil
        return true
    }
    mutating func reset() { self = Self() }
}

private final class StatusEventReceiver {
    weak var monitor: RepositoryStatusMonitor?
    init(_ monitor: RepositoryStatusMonitor) { self.monitor = monitor }
}

private final class RepositoryEventStream {
    private var stream: FSEventStreamRef?
    init(paths: [String], monitor: RepositoryStatusMonitor) {
        let receiver = Unmanaged.passRetained(StatusEventReceiver(monitor))
        var context = FSEventStreamContext(version: 0, info: receiver.toOpaque(), retain: nil, release: { pointer in
            if let pointer { Unmanaged<StatusEventReceiver>.fromOpaque(pointer).release() }
        }, copyDescription: nil)
        stream = FSEventStreamCreate(nil, { _, context, count, paths, flags, _ in
            guard let context else { return }
            let receiver = Unmanaged<StatusEventReceiver>.fromOpaque(context).takeUnretainedValue()
            let strings = paths.assumingMemoryBound(to: UnsafePointer<CChar>.self)
            MainActor.assumeIsolated {
                for index in 0..<count {
                    receiver.monitor?.receive(path: String(cString: strings[index]), flags: flags[index])
                }
            }
        }, &context, paths as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.05,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagWatchRoot))
        if let stream {
            FSEventStreamSetDispatchQueue(stream, .main)
            if !FSEventStreamStart(stream) { FSEventStreamInvalidate(stream) }
        } else { receiver.release() }
    }
    deinit {
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
    }
}

@MainActor
final class RepositoryStatusMonitor {
    struct Timing {
        var debounce: Duration = .seconds(1)
        var interactive: Duration = .milliseconds(200)
        var minimumInterval: Duration = .seconds(30)
        var poll: Duration = .seconds(300)
    }
    private(set) var state = RepositoryRefreshState()
    private(set) var repositoryID: String?
    private var paths: [String] = []
    private var requiresStreamRestart = false
    private var stream: RepositoryEventStream?
    private var scheduled: Task<Void, Never>?
    private var polling: Task<Void, Never>?
    private var due: ContinuousClock.Instant?
    private var earliest = ContinuousClock.now
    private var started = ContinuousClock.now
    private var errors = 0
    private var stoppedAfterErrors = false
    private var pendingInteractive = false
    let timing: Timing
    var onRefresh: (() -> Void)?
    var onStateChanged: (() -> Void)?
    var isPaused: () -> Bool = { false }
    var automaticRefreshSuspended: Bool { stoppedAfterErrors }
    var isRunning: Bool { stream != nil }

    init(timing: Timing = Timing()) { self.timing = timing }
    deinit { scheduled?.cancel(); polling?.cancel() }

    func configure(repositoryID: String, urls: [URL]) {
        if let previous = self.repositoryID, previous != repositoryID { stop() }
        self.repositoryID = repositoryID
        let paths = Array(Set(urls.map { $0.standardizedFileURL.resolvingSymlinksInPath().path })).sorted()
        guard paths != self.paths || stream == nil || requiresStreamRestart else { return }
        self.paths = paths
        requiresStreamRestart = false
        stream = nil
        stream = RepositoryEventStream(paths: paths, monitor: self)
        polling?.cancel()
        let interval = timing.poll
        polling = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: interval) } catch { return }
                self?.changed()
            }
        }
    }

    func stop() {
        scheduled?.cancel(); scheduled = nil
        polling?.cancel(); polling = nil
        requiresStreamRestart = false
        stream = nil; paths = []; repositoryID = nil; due = nil
        earliest = .now; errors = 0; stoppedAfterErrors = false
        pendingInteractive = false
        state.reset(); onStateChanged?()
    }

    func receive(path: String, flags: FSEventStreamEventFlags) {
        if flags & FSEventStreamEventFlags(kFSEventStreamEventFlagRootChanged) != 0 { requiresStreamRestart = true }
        if flags & FSEventStreamEventFlags(kFSEventStreamEventFlagRootChanged | kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagUserDropped | kFSEventStreamEventFlagKernelDropped) != 0 {
            changed(); return
        }
        if URL(fileURLWithPath: path).lastPathComponent == "index.lock" { return }
        if flags & FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsDir) != 0,
           paths.contains(path) || path.contains("/.git/modules/") { return }
        changed()
    }

    func changed(interactive: Bool = false) {
        state.changed(); onStateChanged?()
        if interactive { errors = 0; stoppedAfterErrors = false; pendingInteractive = true }
        if state.active != nil { return }
        guard !stoppedAfterErrors else { return }
        schedule(at: interactive ? .now.advanced(by: timing.interactive)
                 : max(.now.advanced(by: timing.debounce), earliest))
    }

    func beginRefresh() -> RepositoryRefreshState.Ticket {
        scheduled?.cancel(); scheduled = nil; due = nil
        started = .now
        pendingInteractive = false
        let ticket = state.begin()
        onStateChanged?()
        return ticket
    }

    func suspendAutomaticRefresh() {
        errors = 3; stoppedAfterErrors = true
        scheduled?.cancel(); scheduled = nil; due = nil
    }

    func resetErrors() { errors = 0; stoppedAfterErrors = false }

    func finishRefresh(_ ticket: RepositoryRefreshState.Ticket, succeeded: Bool) {
        guard state.finish(ticket, succeeded: succeeded) else { return }
        let elapsed = started.duration(to: .now)
        earliest = .now.advanced(by: max(timing.minimumInterval, elapsed * 2))
        errors = succeeded ? 0 : errors + 1
        stoppedAfterErrors = errors >= 3
        onStateChanged?()
        scheduled?.cancel(); scheduled = nil; due = nil
        if state.isDirty && !stoppedAfterErrors { schedule(at: pendingInteractive ? .now.advanced(by: timing.interactive) : earliest) }
    }

    private func schedule(at deadline: ContinuousClock.Instant) {
        if let due, due <= deadline { return }
        scheduled?.cancel(); due = deadline
        scheduled = Task { @MainActor [weak self] in
            do { try await ContinuousClock().sleep(until: deadline) } catch { return }
            guard let self, !Task.isCancelled else { return }
            self.scheduled = nil; self.due = nil
            if self.state.active != nil { return }
            if self.isPaused() {
                self.schedule(at: .now.advanced(by: self.timing.interactive))
                return
            }
            self.onRefresh?()
        }
    }
}
