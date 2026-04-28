import Foundation
import AppKit
import Combine
import UserNotifications

// NOTE: Cloudflare Worker + APNs relay integration is commented out in GatekeeperView and AppDelegate.
// This file remains for when you turn the relay back on.

/// Manages APNs registration and incoming push notifications for the Airtable
/// new-docket push flow. The Cloudflare Worker sends an APNs push whenever
/// Airtable creates a new record; this manager receives it and injects it into
/// the app's `NotificationCenter` exactly like the polling path would.
@MainActor
class PushNotificationManager: NSObject, ObservableObject, UNUserNotificationCenterDelegate {

    static let shared = PushNotificationManager()

    /// Set by GatekeeperView after initialisation.
    weak var appNotificationCenter: NotificationCenter?
    weak var settingsManager: SettingsManager?

    @Published var isRegistered = false
    @Published var registrationError: String?

    private let deviceTokenKey = "apns_device_token"

    // MARK: - Registration

    /// Request notification permission and register with APNs.
    /// Called when `newDocketDetectionMode == .airtable` and a Worker URL is configured.
    func requestPermissionAndRegister() {
        UNUserNotificationCenter.current().delegate = self
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { [weak self] granted, error in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let error {
                    self.registrationError = "Notification permission error: \(error.localizedDescription)"
                    return
                }
                guard granted else {
                    self.registrationError = "Notification permission denied"
                    return
                }
                NSApplication.shared.registerForRemoteNotifications()
            }
        }
    }

    /// Called by `AppDelegate` when APNs returns a device token.
    func handleDeviceToken(_ tokenData: Data) {
        let token = tokenData.map { String(format: "%02x", $0) }.joined()
        UserDefaults.standard.set(token, forKey: deviceTokenKey)
        isRegistered = true
        registrationError = nil
        #if DEBUG
        print("PushNotificationManager: ✅ Device token: \(token)")
        #endif
        Task { await uploadTokenToWorker(token) }
    }

    /// Called by `AppDelegate` when APNs registration fails.
    func handleRegistrationFailure(_ error: Error) {
        registrationError = "APNs registration failed: \(error.localizedDescription)"
        isRegistered = false
        print("PushNotificationManager: ❌ \(registrationError ?? "")")
    }

    // MARK: - Token upload

    private func uploadTokenToWorker(_ token: String) async {
        guard let settings = settingsManager?.currentSettings,
              let workerURL = settings.airtableWorkerURL, !workerURL.isEmpty,
              let secret = settings.airtableWorkerSecret, !secret.isEmpty else {
            #if DEBUG
            print("PushNotificationManager: Worker URL/secret not configured — skipping token upload")
            #endif
            return
        }

        guard let url = URL(string: "\(workerURL.trimmingCharacters(in: .init(charactersIn: "/")))/register") else { return }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(secret, forHTTPHeaderField: "X-MediaDash-Secret")

        #if DEBUG
        let isProduction = false
        #else
        let isProduction = true
        #endif

        let body: [String: Any] = ["deviceToken": token, "isProduction": isProduction]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, http.statusCode == 200 {
                #if DEBUG
                print("PushNotificationManager: ✅ Token registered with Worker")
                #endif
            } else {
                print("PushNotificationManager: ⚠️ Token upload got unexpected response")
            }
        } catch {
            print("PushNotificationManager: ⚠️ Token upload failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Incoming push handling

    /// Called by `AppDelegate` when a push arrives while the app is in the foreground.
    func handleIncomingPush(_ userInfo: [AnyHashable: Any]) {
        handleIncomingPush(
            docketNumber: userInfo["docketNumber"] as? String,
            jobName: userInfo["jobName"] as? String,
            recordId: userInfo["recordId"] as? String
        )
    }

    /// Sendable-friendly variant called from `nonisolated` delegate paths after
    /// the relevant fields have been extracted from the (non-Sendable) userInfo dict.
    func handleIncomingPush(docketNumber: String?, jobName: String?, recordId: String?) {
        guard let docketNumber, !docketNumber.isEmpty else { return }
        createDocketNotification(
            docketNumber: docketNumber,
            jobName: jobName ?? "",
            recordId: recordId
        )
    }

    // MARK: - UNUserNotificationCenterDelegate

    /// Foreground notification — suppress the system banner (we handle it in-app).
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler handler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        let userInfo = notification.request.content.userInfo
        let docketNumber = userInfo["docketNumber"] as? String
        let jobName      = userInfo["jobName"]      as? String
        let recordId     = userInfo["recordId"]     as? String
        Task { @MainActor in
            self.handleIncomingPush(docketNumber: docketNumber, jobName: jobName, recordId: recordId)
        }
        // Suppress the system banner — we show our own in-app notification.
        handler([])
    }

    /// User tapped on a background notification banner — bring app to front and create in-app entry.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler handler: @escaping () -> Void
    ) {
        let userInfo = response.notification.request.content.userInfo
        let docketNumber = userInfo["docketNumber"] as? String
        let jobName      = userInfo["jobName"]      as? String
        let recordId     = userInfo["recordId"]     as? String
        Task { @MainActor in
            self.handleIncomingPush(docketNumber: docketNumber, jobName: jobName, recordId: recordId)
            NSApplication.shared.activate(ignoringOtherApps: true)
        }
        handler()
    }

    // MARK: - Notification creation

    private func createDocketNotification(docketNumber: String, jobName: String, recordId: String?) {
        guard let nc = appNotificationCenter else { return }

        // Skip if we already have this docket in the notification list
        let alreadyExists = nc.notifications.contains {
            $0.type == .newDocket && $0.docketNumber == docketNumber
        }
        guard !alreadyExists else { return }

        let message = jobName.isEmpty
            ? "Docket \(docketNumber)"
            : "Docket \(docketNumber): \(jobName)"

        let notification = Notification(
            type: .newDocket,
            title: "New Docket Detected",
            message: message,
            docketNumber: docketNumber,
            jobName: jobName.isEmpty ? nil : jobName
        )

        nc.add(notification)

        NotificationService.shared.showNewDocketNotification(
            docketNumber: docketNumber,
            jobName: jobName
        )

        // Mark the Airtable record ID as seen so the polling fallback doesn't double-fire
        if let recordId, !recordId.isEmpty {
            markAirtableRecordSeen(recordId)
        }

        #if DEBUG
        print("PushNotificationManager: ✅ Created push-sourced notification for \(docketNumber) — \(jobName)")
        #endif
    }

    /// Persist the Airtable record ID so `AirtableDocketScanningService` skips it on next poll.
    private func markAirtableRecordSeen(_ recordId: String) {
        let key = "airtable_seen_docket_record_ids"
        var ids: Set<String> = []
        if let data = UserDefaults.standard.data(forKey: key),
           let decoded = try? JSONDecoder().decode(Set<String>.self, from: data) {
            ids = decoded
        }
        ids.insert(recordId)
        if let data = try? JSONEncoder().encode(ids) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}
