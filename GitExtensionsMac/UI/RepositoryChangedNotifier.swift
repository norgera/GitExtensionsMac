import GitExtensionsCore
import GitCommands
import Foundation

@MainActor
final class RepositoryChangedNotifier {
    private var lockCount = 0
    private var isNotifyRequested = false
    private var subscribers: [UUID: @MainActor (RepositoryChangedNotifier, RepositoryChangedReason) -> Void] = [:]
    private let notifyAction: @MainActor () -> Void

    init(notify: @escaping @MainActor () -> Void) {
        self.notifyAction = notify
    }

    func notify() {
        isNotifyRequested = true
        deliverNotificationIfUnlocked()
    }

    @discardableResult
    func subscribe(
        _ handler: @escaping @MainActor (RepositoryChangedNotifier, RepositoryChangedReason) -> Void
    ) -> RepositoryChangedSubscription {
        let identifier = UUID()
        subscribers[identifier] = handler
        return RepositoryChangedSubscription(notifier: self, identifier: identifier)
    }

    func unsubscribe(_ subscription: RepositoryChangedSubscription) {
        subscribers.removeValue(forKey: subscription.identifier)
    }

    private func internalNotify() {
        for subscriber in subscribers.values {
            subscriber(self, .repositoryChanged)
        }
    }

    func lock() { lockCount += 1 }

    func unlock(requestNotify: Bool) {
        precondition(lockCount > 0, "RepositoryChangedNotifier.unlock has no matching lock")
        lockCount -= 1
        deliverNotificationIfUnlocked()
    }

    var isLocked: Bool { lockCount != 0 }

    private func deliverNotificationIfUnlocked() {
        guard lockCount == 0, isNotifyRequested else { return }
        isNotifyRequested = false
        internalNotify()
        notifyAction()
    }
}

enum RepositoryChangedReason {
    case repositoryChanged
}

struct RepositoryChangedSubscription {
    fileprivate let notifier: RepositoryChangedNotifier
    fileprivate let identifier: UUID

    func cancel() {
        MainActor.assumeIsolated {
        notifier.unsubscribe(self)
        }
    }
}
