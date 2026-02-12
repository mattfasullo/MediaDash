//
//  FilePickerService.swift
//  MediaDash
//
//  Service for presenting file and folder pickers.
//

import AppKit
import UniformTypeIdentifiers

enum FilePickerService {
    /// Presents a folder picker. Calls completion with the selected URL or nil if cancelled.
    static func chooseFolder(completion: @escaping (URL?) -> Void) {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true

        panel.begin { response in
            if response == .OK, let url = panel.urls.first {
                completion(url)
            } else {
                completion(nil)
            }
        }
    }

    /// Presents a file picker. Calls completion with selected URLs or empty array if cancelled.
    static func chooseFiles(
        allowedTypes: [UTType],
        allowsMultiple: Bool,
        completion: @escaping ([URL]) -> Void
    ) {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = allowsMultiple
        panel.allowedContentTypes = allowedTypes.isEmpty ? [.data] : allowedTypes

        panel.begin { response in
            if response == .OK {
                completion(panel.urls)
            } else {
                completion([])
            }
        }
    }
}
