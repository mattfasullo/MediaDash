import SwiftUI

// MARK: - Retro Window Component

enum RetroWindowType {
    case standard  // Blue title bar
    case media     // Orange title bar
    case input     // Yellow title bar
    case error     // Orange title bar
    case info      // Blue title bar
    case beige     // Beige title bar
}

struct RetroWindow<Content: View>: View {
    let title: String
    let windowType: RetroWindowType
    let content: Content
    let onClose: (() -> Void)?
    
    init(title: String, windowType: RetroWindowType = .standard, onClose: (() -> Void)? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.windowType = windowType
        self.onClose = onClose
        self.content = content()
    }
    
    private var titleBarColor: Color {
        switch windowType {
        case .standard, .info:
            return Color(red: 0.29, green: 0.565, blue: 0.886) // Blue #4A90E2
        case .media:
            return Color(red: 1.0, green: 0.549, blue: 0.259) // Orange #FF8C42
        case .input, .error:
            return Color(red: 1.0, green: 0.843, blue: 0.0) // Yellow #FFD700
        case .beige:
            return Color(red: 0.961, green: 0.961, blue: 0.863) // Beige #F5F5DC
        }
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // Title Bar
            HStack {
                Text(title)
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(.white)
                    .padding(.leading, 8)
                
                Spacer()
                
                // Window Controls
                HStack(spacing: 4) {
                    // Minimize
                    Button(action: {}) {
                        Text("_")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundColor(.white)
                            .frame(width: 16, height: 16)
                    }
                    .buttonStyle(.plain)
                    
                    // Maximize
                    Button(action: {}) {
                        Text("□")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(.white)
                            .frame(width: 16, height: 16)
                    }
                    .buttonStyle(.plain)
                    
                    // Close
                    if let onClose = onClose {
                        Button(action: onClose) {
                            Text("×")
                                .font(.system(size: 14, weight: .bold))
                                .foregroundColor(.white)
                                .frame(width: 16, height: 16)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.trailing, 8)
            }
            .frame(height: 30)
            .background(titleBarColor)
            
            // Content Area
            content
                .background(Color(red: 0.961, green: 0.961, blue: 0.863)) // Beige #F5F5DC
                .foregroundColor(.black) // Black text on beige background
                .padding(16)
        }
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.black, lineWidth: 3)
        )
        .cornerRadius(8)
        .shadow(color: Color.black.opacity(0.2), radius: 8, x: 0, y: 4)
    }
}

// MARK: - Retro Search Bar

struct RetroSearchBar: View {
    @Binding var text: String
    let placeholder: String
    let onSubmit: () -> Void
    let onTextChange: () -> Void
    
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundColor(.black)
                .font(.system(size: 16))
            
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 14, weight: .regular))
                .foregroundColor(.black)
                .accentColor(.black) // Cursor color
                .onSubmit(onSubmit)
                .onChange(of: text) { _, _ in
                    onTextChange()
                }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color(red: 1.0, green: 0.843, blue: 0.0)) // Yellow #FFD700
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color.black, lineWidth: 2)
        )
        .cornerRadius(6)
    }
}

// MARK: - Retro Text Field

struct RetroTextField: View {
    @Binding var text: String
    let placeholder: String
    let isSecure: Bool
    
    init(text: Binding<String>, placeholder: String, isSecure: Bool = false) {
        self._text = text
        self.placeholder = placeholder
        self.isSecure = isSecure
    }
    
    var body: some View {
        Group {
            if isSecure {
                SecureField(placeholder, text: $text)
            } else {
                TextField(placeholder, text: $text)
            }
        }
        .textFieldStyle(.plain)
        .font(.system(size: 14, weight: .regular))
        .foregroundColor(.black)
        .accentColor(.black) // Cursor color
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.white)
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .stroke(Color.black, lineWidth: 2)
        )
        .cornerRadius(4)
    }
}

// MARK: - Retro Button

struct RetroButton: View {
    let title: String
    let color: Color
    let action: () -> Void
    @State private var isHovered = false
    
    // Determine text color based on background color
    private var textColor: Color {
        // Beige background needs black text
        if color == Color(red: 0.961, green: 0.961, blue: 0.863) {
            return .black
        }
        // All other colored backgrounds use white text
        return .white
    }
    
    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(textColor)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .padding(.horizontal, 16)
                .background(isHovered ? color.opacity(0.9) : color)
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(Color.black, lineWidth: 2)
                )
                .cornerRadius(4)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovered = hovering
        }
    }
}

// MARK: - Retro Dialog

struct RetroDialog<Content: View>: View {
    let title: String
    let dialogType: RetroWindowType
    let content: Content
    let buttons: [RetroDialogButton]
    
    init(title: String, dialogType: RetroWindowType = .info, @ViewBuilder content: () -> Content, buttons: [RetroDialogButton] = []) {
        self.title = title
        self.dialogType = dialogType
        self.content = content()
        self.buttons = buttons
    }
    
    var body: some View {
        RetroWindow(title: title, windowType: dialogType) {
            VStack(spacing: 20) {
                content
                
                if !buttons.isEmpty {
                    HStack {
                        Spacer()
                        ForEach(Array(buttons.enumerated()), id: \.offset) { index, button in
                            RetroButton(title: button.title, color: button.color) {
                                button.action()
                            }
                        }
                    }
                }
            }
        }
    }
}

struct RetroDialogButton {
    let title: String
    let color: Color
    let action: () -> Void
    
    static func ok(color: Color = Color(red: 0.29, green: 0.565, blue: 0.886), action: @escaping () -> Void) -> RetroDialogButton {
        RetroDialogButton(title: "OK", color: color, action: action)
    }
    
    static func cancel(action: @escaping () -> Void) -> RetroDialogButton {
        RetroDialogButton(title: "Cancel", color: Color(red: 0.961, green: 0.961, blue: 0.863), action: action)
    }
}

// MARK: - Retro Container (for main app background)

struct RetroContainer<Content: View>: View {
    let content: Content
    
    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }
    
    var body: some View {
        content
            .background(Color(red: 0.173, green: 0.173, blue: 0.173)) // Dark gray #2C2C2C
    }
}

