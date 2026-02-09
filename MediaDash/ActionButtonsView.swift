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
    let cacheManager: AsanaCacheManager
    /// Opens Prep window (sessions list for today + 5 business days).
    var onOpenPrep: () -> Void = {}
    /// Opens full 2-week Asana calendar view.
    var onOpenFullCalendar: () -> Void = {}
    /// Right-click "File + Prep": file first, then open prep for a matching calendar session.
    var onFileThenPrep: (() -> Void)? = nil
    
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
                .contextMenu {
                    if let onFileThenPrep = onFileThenPrep {
                        Button("File + Prep") {
                            onFileThenPrep()
                        }
                        .help("File to Work Picture, then open Prep for a matching calendar session (same docket)")
                    }
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
                    subtitle: "Sessions",
                    shortcut: "⌘2",
                    color: currentTheme.buttonColors.prep,
                    isPrimary: false,
                    isFocused: focusedButton.wrappedValue == .prep,
                    showShortcut: isCommandKeyHeld,
                    theme: currentTheme,
                    iconName: "list.clipboard"
                ) {
                    onOpenPrep()
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
                        "Open sessions (today + 5 business days) to prep from calendar" :
                        "Ready."
                }
                .keyboardShortcut("2", modifiers: .command)
            }

            // Row 2: Calendar (2-week view) and Convert
            HStack(spacing: 8) {
                ActionButtonWithShortcut(
                    title: "Calendar",
                    subtitle: "2 weeks",
                    shortcut: "⌘3",
                    color: currentTheme.buttonColors.prep,
                    isPrimary: false,
                    isFocused: focusedButton.wrappedValue == .calendar,
                    showShortcut: isCommandKeyHeld,
                    theme: currentTheme,
                    iconName: "calendar"
                ) {
                    onOpenFullCalendar()
                }
                .focused(focusedButton, equals: .calendar)
                .focusEffectDisabled()
                .onHover { hovering in
                    if hovering {
                        focusedButton.wrappedValue = nil
                        mainViewFocused.wrappedValue = true
                        isKeyboardMode = false
                    }
                    hoverInfo = hovering ?
                        "Open Asana calendar (next 2 weeks)" :
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

