import SwiftUI

/// Notification badge that appears in the sidebar
struct NotificationBadgeView: View {
    @ObservedObject var notificationCenter: NotificationCenter
    @Binding var isExpanded: Bool
    
    var body: some View {
        Button(action: {
            isExpanded.toggle()
        }) {
            ZStack(alignment: .topTrailing) {
                Image(systemName: "bell")
                    .font(.system(size: 16))
                    .foregroundColor(.primary)
                
                if notificationCenter.unreadCount > 0 {
                    Text("\(notificationCenter.unreadCount)")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(.white)
                        .padding(4)
                        .background(Color.red)
                        .clipShape(Circle())
                        .offset(x: 8, y: -8)
                }
            }
        }
        .buttonStyle(.plain)
        .help("Notifications (\(notificationCenter.unreadCount))")
    }
}

