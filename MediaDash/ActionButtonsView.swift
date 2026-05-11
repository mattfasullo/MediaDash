import SwiftUI

struct ActionButtonsView: View {
    @EnvironmentObject var settingsManager: SettingsManager
    @EnvironmentObject var sessionManager: SessionManager
    @EnvironmentObject var manager: MediaManager
    @ObservedObject private var keyboardFocus = MainWindowKeyboardFocus.shared
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
    /// Opens full 2-week Asana calendar view.
    var onOpenFullCalendar: () -> Void = {}
    /// Right-click "File + Prep": file first, then open prep for a matching calendar session.
    var onFileThenPrep: (() -> Void)? = nil
    @Binding var showVideoSheet: Bool

    private var currentTheme: AppTheme {
        settingsManager.currentSettings.appTheme
    }
    
    /// Washed-out forest green color for calendar button, matching the muted style of other buttons
    private var calendarButtonColor: Color {
        switch currentTheme {
        case .modern:
            return Color(red: 0.30, green: 0.45, blue: 0.30)  // Washed-out forest green
        case .retroDesktop:
            return Color(red: 0.25, green: 0.55, blue: 0.35)  // Slightly brighter forest green for retro
        case .windows98:
            return Win98Colors.buttonCalendar  // #406040 forest green
        }
    }
    
    var body: some View {
        VStack(spacing: 8) {
            // Row 1: File and Simian
            HStack(spacing: 8) {
                ActionButtonWithShortcut(
                    title: "File",
                    subtitle: "Work Picture",
                    shortcut: "⌘1",
                    color: currentTheme.buttonColors.file,
                    isPrimary: false,
                    isFocused: keyboardFocus.focusedButton == .file,
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
                    title: "Simian",
                    subtitle: "Upload",
                    shortcut: "⌘2",
                    color: currentTheme.buttonColors.simian,
                    isPrimary: false,
                    isFocused: keyboardFocus.focusedButton == .simian,
                    showShortcut: isCommandKeyHeld,
                    theme: currentTheme,
                    iconName: "arrow.up.circle"
                ) {
                    SimianPostWindowManager.shared.show(settingsManager: settingsManager, sessionManager: sessionManager, manager: manager)
                }
                .focused(focusedButton, equals: .simian)
                .focusEffectDisabled()
                .onHover { hovering in
                    if hovering {
                        focusedButton.wrappedValue = nil
                        mainViewFocused.wrappedValue = true
                        isKeyboardMode = false
                    }
                    hoverInfo = hovering ?
                        "Open Simian posting (search projects, upload files)" :
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
                    color: calendarButtonColor,
                    isPrimary: false,
                    isFocused: keyboardFocus.focusedButton == .calendar,
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
                    title: "Tools",
                    subtitle: "",
                    shortcut: "⌘4",
                    color: Color(red: 0.50, green: 0.25, blue: 0.25),  // Subtle dark red
                    isPrimary: false,
                    isFocused: keyboardFocus.focusedButton == .convert,
                    showShortcut: isCommandKeyHeld,
                    theme: currentTheme,
                    iconName: "wrench.and.screwdriver"
                ) {
                    showVideoSheet = true
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
                        "Tools: conversion, restriping, LUFS normalizer…" :
                        "Ready."
                }
                .keyboardShortcut("4", modifiers: .command)
                .popover(isPresented: $showVideoSheet, arrowEdge: .leading) {
                    VideoView(
                        isPresented: $showVideoSheet,
                        onOpenVideoConverter: {
                            showVideoSheet = false
                            showVideoConverterSheet = true
                        },
                        onOpenRestripe: {
                            showVideoSheet = false
                            RestripeWindowManager.shared.show()
                        },
                        onOpenNormalizer: {
                            showVideoSheet = false
                            NormalizerWindowManager.shared.show()
                        }
                    )
                    .compactSheetBorder()
                    .frame(width: 380, height: 270)
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

