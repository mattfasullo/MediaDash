import SwiftUI

// MARK: - Notification Tab Button

struct NotificationTabButton: View {
    @ObservedObject var notificationCenter: NotificationCenter
    @Binding var showNotificationCenter: Bool
    @State private var isHovered = false

    var body: some View {
        Button(action: {
            showNotificationCenter.toggle()
        }) {
            HStack(spacing: 6) {
                Spacer()

                Image(systemName: "bell")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)

                Text("New Dockets")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.primary)

                if notificationCenter.unreadCount > 0 {
                    Text("\(notificationCenter.unreadCount)")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 2)
                        .background(Color.red)
                        .clipShape(Capsule())
                }

                Spacer()
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .padding(.horizontal, 10)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.accentColor.opacity(0.1))
            )
        }
        .buttonStyle(.plain)
        .help("New Dockets (\(notificationCenter.unreadCount))")
        .onHover { hovering in
            isHovered = hovering
        }
        .scaleEffect(isHovered ? 1.02 : 1.0)
        .animation(.easeInOut(duration: 0.15), value: isHovered)
    }
}

// MARK: - Email Refresh Button

struct EmailRefreshButton: View {
    @EnvironmentObject var emailScanningService: EmailScanningService
    var notificationCenter: NotificationCenter? = nil
    var grabbedIndicatorService: GrabbedIndicatorService? = nil
    @State private var isHovered = false
    @State private var isRefreshing = false
    @State private var statusMessage: String?
    @State private var statusTimer: Timer?

    var body: some View {
        HStack(spacing: 4) {
            Button(action: {
                guard !isRefreshing else { return }
                isRefreshing = true
                statusMessage = nil

                Task { @MainActor in
                    let service = emailScanningService

                    let beforeCount = notificationCenter?.notifications.filter { $0.status == .pending }.count ?? 0

                    await service.scanUnreadEmails(forceRescan: true)

                    if let grabbedService = grabbedIndicatorService {
                        print("EmailRefreshButton: Triggering grabbed reply check after scan...")
                        await grabbedService.checkForGrabbedReplies()
                    }

                    let afterCount = notificationCenter?.notifications.filter { $0.status == .pending }.count ?? 0
                    let newCount = afterCount - beforeCount

                    await MainActor.run {
                        isRefreshing = false

                        if newCount > 0 {
                            statusMessage = "✅ Found \(newCount) new notification\(newCount == 1 ? "" : "s")"
                        } else {
                            statusMessage = "✓ Up to date"
                        }

                        statusTimer?.invalidate()
                        statusTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: false) { _ in
                            statusMessage = nil
                        }
                    }
                }
            }) {
                ZStack {
                    Circle()
                        .fill(isHovered ? Color.accentColor.opacity(0.15) : Color.accentColor.opacity(0.1))
                        .frame(width: 24, height: 24)

                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.secondary)
                        .rotationEffect(.degrees(isRefreshing ? 360 : 0))
                        .animation(isRefreshing ? .linear(duration: 1).repeatForever(autoreverses: false) : .default, value: isRefreshing)
                }
            }
            .buttonStyle(.plain)
            .help(statusMessage ?? "Refresh emails")
            .disabled(isRefreshing || emailScanningService.isScanning)
            .onHover { hovering in
                isHovered = hovering
            }

            if let status = statusMessage {
                Text(status)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .transition(.opacity.combined(with: .move(edge: .leading)))
                    .animation(.easeInOut, value: statusMessage)
            }
        }
        .onDisappear {
            statusTimer?.invalidate()
        }
    }
}
