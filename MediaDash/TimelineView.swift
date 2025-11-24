import SwiftUI

// MARK: - Timeline View

struct TimelineView: View {
    let clips: [PlaybackClip]
    @ObservedObject var playbackManager: OMFPlaybackManager
    @State private var zoomLevel: CGFloat = 1.0
    @State private var scrollPosition: CGFloat = 0.0
    
    // Calculate timeline duration
    private var timelineDuration: Double {
        clips.map { $0.timelineEnd }.max() ?? 10.0
    }
    
    // Group clips by track
    private var tracks: [[PlaybackClip]] {
        let maxTrack = clips.map { $0.trackIndex }.max() ?? 0
        var trackClips: [[PlaybackClip]] = Array(repeating: [], count: maxTrack + 1)
        for clip in clips {
            trackClips[clip.trackIndex].append(clip)
        }
        // Sort clips in each track by timeline position
        // Also filter out clips with zero or invalid durations
        return trackClips.map { track in
            track.sorted { $0.timelineStart < $1.timelineStart }
                .filter { $0.timelineEnd > $0.timelineStart } // Only show clips with valid duration
        }
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // Timecode ruler
            TimelineRulerView(duration: timelineDuration, zoomLevel: zoomLevel)
                .frame(height: 30)
            
            // Tracks
            ScrollView(.vertical, showsIndicators: true) {
                VStack(spacing: 2) {
                    ForEach(Array(tracks.enumerated()), id: \.offset) { trackIndex, trackClips in
                        TrackView(
                            trackIndex: trackIndex,
                            clips: trackClips,
                            timelineDuration: timelineDuration,
                            zoomLevel: zoomLevel
                        )
                        .frame(height: 50)
                    }
                }
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }
}

struct TimelineRulerView: View {
    let duration: Double
    let zoomLevel: CGFloat
    
    var body: some View {
        GeometryReader { geometry in
            let pixelsPerSecond = (geometry.size.width / CGFloat(duration)) * zoomLevel
            let majorInterval = max(1.0, duration / 10.0) // Show ~10 major ticks
            
            ZStack(alignment: .leading) {
                // Background
                Rectangle()
                    .fill(Color(nsColor: .controlBackgroundColor))
                
                // Timecode marks
                ForEach(0..<Int(duration / majorInterval) + 1, id: \.self) { i in
                    let time = Double(i) * majorInterval
                    VStack(spacing: 0) {
                        Rectangle()
                            .fill(Color.primary)
                            .frame(width: 1, height: 10)
                        Text(formatTimecode(time))
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundColor(.secondary)
                    }
                    .offset(x: CGFloat(time) * pixelsPerSecond)
                }
            }
        }
    }
    
    private func formatTimecode(_ seconds: Double) -> String {
        let minutes = Int(seconds) / 60
        let secs = Int(seconds) % 60
        let frames = Int((seconds.truncatingRemainder(dividingBy: 1.0)) * 30) // 30 fps
        return String(format: "%02d:%02d:%02d", minutes, secs, frames)
    }
}

struct TrackView: View {
    let trackIndex: Int
    let clips: [PlaybackClip]
    let timelineDuration: Double
    let zoomLevel: CGFloat
    
    var body: some View {
        GeometryReader { geometry in
            let pixelsPerSecond = (geometry.size.width / CGFloat(timelineDuration)) * zoomLevel
            
            ZStack(alignment: .leading) {
                // Track background
                Rectangle()
                    .fill(trackIndex % 2 == 0 ? 
                          Color(nsColor: .controlBackgroundColor) : 
                          Color(nsColor: .controlBackgroundColor).opacity(0.5))
                
                // Track label
                HStack {
                    Text("Track \(trackIndex + 1)")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                        .frame(width: 60)
                    
                    // Clips on this track
                    ZStack(alignment: .leading) {
                        ForEach(clips, id: \.id) { clip in
                            ClipBlockView(clip: clip, pixelsPerSecond: pixelsPerSecond)
                                .offset(x: CGFloat(clip.timelineStart) * pixelsPerSecond)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }
}

struct ClipBlockView: View {
    let clip: PlaybackClip
    let pixelsPerSecond: CGFloat
    
    var body: some View {
        let duration = clip.timelineEnd - clip.timelineStart
        let width = max(20, CGFloat(duration) * pixelsPerSecond)
        
        // Only render if clip has valid duration
        if duration > 0 {
            RoundedRectangle(cornerRadius: 4)
                .fill(Color.blue.opacity(0.7))
                .frame(width: width, height: 40)
                .overlay(
                    Text(clip.name)
                        .font(.system(size: 9))
                        .foregroundColor(.white)
                        .lineLimit(1)
                        .padding(.horizontal, 4)
                )
        } else {
            // Show a small marker for clips with no duration
            Circle()
                .fill(Color.blue.opacity(0.7))
                .frame(width: 8, height: 8)
        }
    }
}

