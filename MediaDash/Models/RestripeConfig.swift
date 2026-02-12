//
//  RestripeConfig.swift
//  MediaDash
//
//  Configuration for restriping videos with audio files.
//

import Combine
import Foundation
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Assignment (picture + audio + output name)

/// One restripe job: picture + audio + chosen output basename.
struct RestripeAssignment: Identifiable {
    let id = UUID()
    var pictureURL: URL
    var audioURL: URL
    var outputBasename: String

    static func make(pictureURL: URL, audioURL: URL) -> RestripeAssignment {
        let base = audioURL.deletingPathExtension().lastPathComponent
        return RestripeAssignment(
            pictureURL: pictureURL,
            audioURL: audioURL,
            outputBasename: "\(base)_pic"
        )
    }
}

// MARK: - Drag payload for multi-select

struct AudioDropPayload: Transferable, Codable {
    let urls: [URL]

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: UTType.json)
    }
}

// MARK: - Config

/// Configuration for restriping videos with audio files.
final class RestripeConfig: ObservableObject {
    /// Video/picture files
    @Published var pictures: [URL] = []
    /// Audio files not yet linked to a picture
    @Published var unassignedAudio: [URL] = []
    /// Linked pairs: picture + audio + output name
    @Published var assignments: [RestripeAssignment] = []
    /// Where to write output files
    @Published var outputFolder: URL?
    /// Output container format
    @Published var outputFormat: OutputFormat = .mp4
    /// Audio gain in decibels (e.g. -6, 0, +6). 0 = no change.
    @Published var audioGainDB: Double = 0

    enum OutputFormat: String, CaseIterable {
        case mp4
        case mov

        var fileExtension: String {
            switch self {
            case .mp4: return "mp4"
            case .mov: return "mov"
            }
        }
    }

    /// Assignments grouped by picture URL
    func assignments(for pictureURL: URL) -> [RestripeAssignment] {
        assignments.filter { $0.pictureURL == pictureURL }
    }

    /// Total number of output files to create
    var totalOutputCount: Int { assignments.count }
}
