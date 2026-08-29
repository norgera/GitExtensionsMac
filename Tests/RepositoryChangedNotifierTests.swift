@testable import GitExtensionsCore
@testable import GitCommands
@testable import GitUI
import Foundation

@MainActor
enum RepositoryChangedNotifierTests {
    static func run() {
        testOrdinaryNotificationDeliversOnce()
        testSuppressedNotificationsCoalesceIntoSingleUnlockNotification()
        testNestedLocksCoalesceIntoOneNotification()
        testUnsuccessfulUnlockDoesNotNotify()
        testSubscriptionCancellationStopsNotifications()
    }

    private static func testOrdinaryNotificationDeliversOnce() {
        let notifier = RepositoryChangedNotifier {}
        var notificationCount = 0
        _ = notifier.subscribe { _, _ in notificationCount += 1 }

        notifier.notify()

        precondition(notificationCount == 1, "An ordinary notify must deliver exactly once")
    }

    private static func testSuppressedNotificationsCoalesceIntoSingleUnlockNotification() {
        let notifier = RepositoryChangedNotifier {}
        var notificationCount = 0
        _ = notifier.subscribe { _, _ in notificationCount += 1 }

        notifier.lock()
        notifier.notify()
        notifier.notify()
        precondition(notificationCount == 0, "Suppressed notifications must not be delivered while locked")
        precondition(notifier.isLocked, "Notifier must remain locked until unlock")

        notifier.unlock(requestNotify: true)
        precondition(notificationCount == 1, "Unlock must deliver one coalesced notification")
        precondition(!notifier.isLocked, "Notifier must be unlocked after matching unlock")
    }

    private static func testNestedLocksCoalesceIntoOneNotification() {
        let notifier = RepositoryChangedNotifier {}
        var notificationCount = 0
        _ = notifier.subscribe { _, _ in notificationCount += 1 }

        notifier.lock()
        notifier.notify()
        notifier.unlock(requestNotify: true)
        notifier.lock()
        notifier.notify()
        notifier.notify()

        precondition(notificationCount == 1, "Multiple notifications while locked must coalesce into one delivery")
    }

    private static func testUnsuccessfulUnlockDoesNotNotify() {
        let notifier = RepositoryChangedNotifier {}
        var notificationCount = 0
        _ = notifier.subscribe { _, _ in notificationCount += 1 }

        notifier.lock()
        notifier.unlock(requestNotify: false)

        notifier.notify()

        precondition(notificationCount == 1, "The later explicit notify should deliver after an unsuccessful unlock")
    }

    private static func testSubscriptionCancellationStopsNotifications() {
        let notifier = RepositoryChangedNotifier {}
        var firstCount = 0
        var secondCount = 0
        let subscription = notifier.subscribe { _, _ in firstCount += 1 }
        _ = notifier.subscribe { _, _ in secondCount += 1 }

        notifier.notify()
        subscription.cancel()
        notifier.notify()

        precondition(firstCount == 1 && secondCount == 2, "Cancelled subscriptions must not receive later notifications")
    }
}
