import Foundation
import Testing

@testable import GitCommands
@testable import GitExtensionsCore
@testable import GitUI

extension UIIntegrationTests {
    @MainActor
    @Suite("Repository changed notifier")
    enum RepositoryChangedNotifierTests {

        @Test("Ordinary notification delivers once") private static func testOrdinaryNotificationDeliversOnce() {
            let notifier = RepositoryChangedNotifier {}
            var notificationCount = 0
            _ = notifier.subscribe { _, _ in notificationCount += 1 }

            notifier.notify()

            #expect(notificationCount == 1, "An ordinary notify must deliver exactly once")
        }

        @Test("Suppressed notifications coalesce into single unlock notification")
        private static func testSuppressedNotificationsCoalesceIntoSingleUnlockNotification() {
            let notifier = RepositoryChangedNotifier {}
            var notificationCount = 0
            _ = notifier.subscribe { _, _ in notificationCount += 1 }

            notifier.lock()
            notifier.notify()
            notifier.notify()
            #expect(notificationCount == 0, "Suppressed notifications must not be delivered while locked")
            #expect(notifier.isLocked, "Notifier must remain locked until unlock")

            notifier.unlock(requestNotify: true)
            #expect(notificationCount == 1, "Unlock must deliver one coalesced notification")
            #expect(!notifier.isLocked, "Notifier must be unlocked after matching unlock")
        }

        @Test("Nested locks coalesce into one notification") private static func testNestedLocksCoalesceIntoOneNotification() {
            let notifier = RepositoryChangedNotifier {}
            var notificationCount = 0
            _ = notifier.subscribe { _, _ in notificationCount += 1 }

            notifier.lock()
            notifier.notify()
            notifier.unlock(requestNotify: true)
            notifier.lock()
            notifier.notify()
            notifier.notify()

            #expect(notificationCount == 1, "Multiple notifications while locked must coalesce into one delivery")
        }

        @Test("Unsuccessful unlock does not notify") private static func testUnsuccessfulUnlockDoesNotNotify() {
            let notifier = RepositoryChangedNotifier {}
            var notificationCount = 0
            _ = notifier.subscribe { _, _ in notificationCount += 1 }

            notifier.lock()
            notifier.unlock(requestNotify: false)

            notifier.notify()

            #expect(notificationCount == 1, "The later explicit notify should deliver after an unsuccessful unlock")
        }

        @Test("Subscription cancellation stops notifications") private static func testSubscriptionCancellationStopsNotifications() {
            let notifier = RepositoryChangedNotifier {}
            var firstCount = 0
            var secondCount = 0
            let subscription = notifier.subscribe { _, _ in firstCount += 1 }
            _ = notifier.subscribe { _, _ in secondCount += 1 }

            notifier.notify()
            subscription.cancel()
            notifier.notify()

            #expect(firstCount == 1 && secondCount == 2, "Cancelled subscriptions must not receive later notifications")
        }
    }
}

typealias RepositoryChangedNotifierTests = UIIntegrationTests.RepositoryChangedNotifierTests
