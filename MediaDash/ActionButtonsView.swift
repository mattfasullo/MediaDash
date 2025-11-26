import SwiftUI

struct ActionButtonsView: View {
    @EnvironmentObject var settingsManager: SettingsManager
    var focusedButton: FocusState<ActionButtonFocus?>.Binding
    var mainViewFocused: FocusState<Bool>.Binding
    @Binding var isKeyboardMode: Bool
    @Binding var isCommandKeyHeld: Bool
    @Binding var hoverInfo: String
    @Binding var showVideoConverterSheet: Bool
    
    let wpDate: Date
    let prepDate: Date
    let dateFormatter: DateFormatter
    let attempt: (JobType) -> Void
    
    private var currentTheme: AppTheme {
        settingsManager.currentSettings.appTheme
    }
    
    var body: some View {
        VStack(spacing: 8) {
            // Row 1: File and Prep
            HStack(spacing: 8) {
                ActionButtonWithShortcut(
                    title: "File",
                    subtitle: "Work Picture",
                    shortcut: "⌘1",
                    color: currentTheme.buttonColors.file,
                    isPrimary: false,
                    isFocused: focusedButton.wrappedValue == .file,
                    showShortcut: isCommandKeyHeld,
                    theme: currentTheme,
                    iconName: "folder"
                ) {
                    attempt(.workPicture)
                }
                .focused(focusedButton, equals: .file)
                .focusEffectDisabled()
                .onHover { hovering in
                    if hovering {
                        focusedButton.wrappedValue = nil
                        mainViewFocused.wrappedValue = true
                        isKeyboardMode = false
                    }
                    hoverInfo = hovering ?
                        "Files to Work Picture (\(dateFormatter.string(from: wpDate)))" :
                        "Ready."
                }
                .keyboardShortcut("1", modifiers: .command)

                ActionButtonWithShortcut(
                    title: "Prep",
                    subtitle: "Session Prep",
                    shortcut: "⌘2",
                    color: currentTheme.buttonColors.prep,
                    isPrimary: false,
                    isFocused: focusedButton.wrappedValue == .prep,
                    showShortcut: isCommandKeyHeld,
                    theme: currentTheme,
                    iconName: "list.clipboard"
                ) {
                    attempt(.prep)
                }
                .focused(focusedButton, equals: .prep)
                .focusEffectDisabled()
                .onHover { hovering in
                    if hovering {
                        focusedButton.wrappedValue = nil
                        mainViewFocused.wrappedValue = true
                        isKeyboardMode = false
                    }
                    hoverInfo = hovering ?
                        "Files to Session Prep (\(dateFormatter.string(from: prepDate)))" :
                        "Ready."
                }
                .keyboardShortcut("2", modifiers: .command)
            }

            // Row 2: Both and Convert
            HStack(spacing: 8) {
                ActionButtonWithShortcut(
                    title: "File + Prep",
                    subtitle: "Both",
                    shortcut: "⌘3",
                    color: currentTheme.buttonColors.both,
                    isPrimary: false,
                    isFocused: focusedButton.wrappedValue == .both,
                    showShortcut: isCommandKeyHeld,
                    theme: currentTheme,
                    iconName: "doc.on.doc"
                ) {
                    attempt(.both)
                }
                .focused(focusedButton, equals: .both)
                .focusEffectDisabled()
                .onHover { hovering in
                    if hovering {
                        focusedButton.wrappedValue = nil
                        mainViewFocused.wrappedValue = true
                        isKeyboardMode = false
                    }
                    hoverInfo = hovering ?
                        "Processes both Work Picture and Prep" :
                        "Ready."
                }
                .keyboardShortcut("3", modifiers: .command)

                ActionButtonWithShortcut(
                    title: "Convert Video",
                    subtitle: "ProRes Proxy",
                    shortcut: "⌘4",
                    color: Color(red: 0.50, green: 0.25, blue: 0.25),  // Subtle dark red
                    isPrimary: false,
                    isFocused: focusedButton.wrappedValue == .convert,
                    showShortcut: isCommandKeyHeld,
                    theme: currentTheme,
                    iconName: "film"
                ) {
                    showVideoConverterSheet = true
                }
                .focused(focusedButton, equals: .convert)
                .focusEffectDisabled()
                .onHover { hovering in
                    if hovering {
                        focusedButton.wrappedValue = nil
                        mainViewFocused.wrappedValue = true
                        isKeyboardMode = false
                    }
                    hoverInfo = hovering ?
                        "Convert videos" :
                        "Ready."
                }
                .keyboardShortcut("4", modifiers: .command)
            }
        }
    }
}

