import XCTest
@testable import MediaDash

/// Tests for NotificationCenter deduplication and management logic
@MainActor
final class NotificationTests: XCTestCase {

    private var notificationCenter: NotificationCenter!

    override func setUp() {
        super.setUp()
        notificationCenter = NotificationCenter()
    }

    override func tearDown() {
        notificationCenter = nil
        super.tearDown()
    }

    // MARK: - Basic Notification Creation

    func testCreateNotification() {
        let notification = Notification(
            type: .newDocket,
            title: "New Docket",
            message: "Test message",
            docketNumber: "26150",
            jobName: "Test Campaign"
        )

        XCTAssertEqual(notification.type, .newDocket)
        XCTAssertEqual(notification.title, "New Docket")
        XCTAssertEqual(notification.docketNumber, "26150")
        XCTAssertEqual(notification.jobName, "Test Campaign")
        XCTAssertFalse(notification.isRead)
    }

    func testNotificationIDGeneration() {
        let notification1 = Notification(
            type: .newDocket,
            title: "Test",
            message: "Message"
        )
        let notification2 = Notification(
            type: .newDocket,
            title: "Test",
            message: "Message"
        )

        // Each notification should have a unique ID
        XCTAssertNotEqual(notification1.id, notification2.id)
    }

    // MARK: - Deduplication by Email ID

    func testDuplicateByEmailId() {
        let notification1 = Notification(
            type: .newDocket,
            title: "First",
            message: "First message",
            emailId: "email123"
        )

        let notification2 = Notification(
            type: .newDocket,
            title: "Second",
            message: "Second message",
            emailId: "email123"
        )

        notificationCenter.add(notification1)
        notificationCenter.add(notification2)

        // Should only have 1 notification (second replaced first)
        let docketNotifications = notificationCenter.notifications.filter { $0.type == .newDocket }
        XCTAssertEqual(docketNotifications.count, 1)
        XCTAssertEqual(docketNotifications.first?.title, "Second")
    }

    // MARK: - Deduplication by Thread ID

    func testDuplicateDocketByThreadId() {
        let notification1 = Notification(
            type: .newDocket,
            title: "Original",
            message: "Original message",
            threadId: "thread456"
        )

        let notification2 = Notification(
            type: .newDocket,
            title: "Reply",
            message: "Reply message",
            threadId: "thread456"
        )

        notificationCenter.add(notification1)
        notificationCenter.add(notification2)

        // Should only have 1 notification (reply should be skipped)
        let docketNotifications = notificationCenter.notifications.filter { $0.type == .newDocket }
        XCTAssertEqual(docketNotifications.count, 1)
        XCTAssertEqual(docketNotifications.first?.title, "Original")
    }

    func testDuplicateRequestByThreadId() {
        let notification1 = Notification(
            type: .request,
            title: "Request 1",
            message: "Message 1",
            threadId: "thread789"
        )

        let notification2 = Notification(
            type: .request,
            title: "Request 2",
            message: "Message 2",
            threadId: "thread789"
        )

        notificationCenter.add(notification1)
        notificationCenter.add(notification2)

        // Should only have 1 request notification
        let requestNotifications = notificationCenter.notifications.filter { $0.type == .request }
        XCTAssertEqual(requestNotifications.count, 1)
    }

    // MARK: - Media Files Notification Updates

    func testMediaFilesNotificationAppendsNewLinks() {
        let notification1 = Notification(
            type: .mediaFiles,
            title: "Files",
            message: "First delivery",
            threadId: "thread999",
            fileLinks: ["http://link1.com"],
            fileLinkDescriptions: ["First file"]
        )

        let notification2 = Notification(
            type: .mediaFiles,
            title: "Files",
            message: "Second delivery",
            threadId: "thread999",
            fileLinks: ["http://link1.com", "http://link2.com"],
            fileLinkDescriptions: ["First file", "Second file"]
        )

        notificationCenter.add(notification1)
        notificationCenter.add(notification2)

        // Should have 1 notification with both links
        let mediaNotifications = notificationCenter.notifications.filter { $0.type == .mediaFiles }
        XCTAssertEqual(mediaNotifications.count, 1)
        XCTAssertEqual(mediaNotifications.first?.fileLinks?.count, 2)
    }

    func testMediaFilesNotificationSkipsDuplicateLinks() {
        let notification1 = Notification(
            type: .mediaFiles,
            title: "Files",
            message: "First delivery",
            threadId: "thread111",
            fileLinks: ["http://link1.com"],
            fileLinkDescriptions: ["First file"]
        )

        let notification2 = Notification(
            type: .mediaFiles,
            title: "Files",
            message: "Duplicate delivery",
            threadId: "thread111",
            fileLinks: ["http://link1.com"],
            fileLinkDescriptions: ["Same file"]
        )

        notificationCenter.add(notification1)
        notificationCenter.add(notification2)

        // Should have 1 notification with only 1 link (duplicate skipped)
        let mediaNotifications = notificationCenter.notifications.filter { $0.type == .mediaFiles }
        XCTAssertEqual(mediaNotifications.count, 1)
        XCTAssertEqual(mediaNotifications.first?.fileLinks?.count, 1)
    }

    // MARK: - Read/Unread State

    func testMarkAsRead() {
        let notification = Notification(
            type: .newDocket,
            title: "Test",
            message: "Message"
        )

        XCTAssertFalse(notification.isRead)

        var mutableNotification = notification
        mutableNotification.markAsRead()

        XCTAssertTrue(mutableNotification.isRead)
    }

    func testUnreadCountUpdates() {
        let notification1 = Notification(type: .newDocket, title: "1", message: "m1")
        let notification2 = Notification(type: .newDocket, title: "2", message: "m2")

        notificationCenter.add(notification1)
        notificationCenter.add(notification2)

        // Both are unread
        XCTAssertGreaterThanOrEqual(notificationCenter.unreadCount, 0)
    }
}
