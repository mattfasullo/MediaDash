import SwiftUI

/// Popup notification that appears briefly when app is open
struct NotificationPopupView: View {
    let notification: Notification
    @Binding var isVisible: Bool
    
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: iconForType(notification.type))
                .font(.system(size: 20))
                .foregroundColor(.white)
            
            VStack(alignment: .leading, spacing: 4) {
                Text(notification.title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.white)
                
                Text(notification.message)
                    .font(.system(size: 12))
                    .foregroundColor(.white.opacity(0.9))
                    .lineLimit(2)
            }
            
            Spacer()
        }
        .padding(16)
        .frame(width: 350)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.blue)
                .shadow(color: .black.opacity(0.2), radius: 10, x: 0, y: 5)
        )
        .transition(.move(edge: .top).combined(with: .opacity))
        .onAppear {
            // Auto-dismiss after 4 seconds
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
                withAnimation {
                    isVisible = false
                }
            }
        }
    }
    
    private func iconForType(_ type: NotificationType) -> String {
        switch type {
        case .newDocket:
            return "folder.badge.plus"
        case .mediaFiles:
            return "link.circle.fill"
        case .error:
            return "exclamationmark.triangle.fill"
        case .info:
            return "info.circle.fill"
        }
    }
}

