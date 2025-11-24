import SwiftUI

// MARK: - Timeline View

struct TimelineView: View {
    let clips: [TimelineClip]
    let totalDuration: Double
    @State private var zoomLevel: CGFloat = 1.0
    
    // Group clips by track
    private var tracks: [[TimelineClip]] {
        guard !clips.isEmpty else { return [] }
        let maxTrack = clips.map { $0.trackIndex }.max() ?? 0
        var trackClips: [[TimelineClip]] = Array(repeating: [], count: maxTrack + 1)
        for clip in clips {
            trackClips[clip.trackIndex].append(clip)
        }
        // Sort clips in each track by timeline position
        return trackClips.map { track in
            track.sorted { $0.startTime < $1.startTime }
                .filter { $0.endTime > $0.startTime } // Only show clips with valid duration
        }
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // Timecode ruler
            TimelineRulerView(duration: totalDuration, zoomLevel: zoomLevel)
                .frame(height: 30)
            
            // Tracks
            ScrollView([.vertical, .horizontal], showsIndicators: true) {
                VStack(spacing: 2) {
                    ForEach(Array(tracks.enumerated()), id: \.offset) { trackIndex, trackClips in
                        TrackView(
                            trackIndex: trackIndex,
                            clips: trackClips,
                            timelineDuration: totalDuration,
                            zoomLevel: zoomLevel
                        )
                        .frame(height: 50)
                    }
                }
                .frame(minWidth: max(800, CGFloat(totalDuration) * 10 * zoomLevel))
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
            let pixelsPerSecond = (geometry.size.width / max(CGFloat(duration), 1.0)) * zoomLevel
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
    let clips: [TimelineClip]
    let timelineDuration: Double
    let zoomLevel: CGFloat
    
    var body: some View {
        GeometryReader { geometry in
            let pixelsPerSecond = (geometry.size.width / max(CGFloat(timelineDuration), 1.0)) * zoomLevel
            
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
                        ForEach(clips) { clip in
                            ClipBlockView(clip: clip, pixelsPerSecond: pixelsPerSecond)
                                .offset(x: CGFloat(clip.startTime) * pixelsPerSecond)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }
}

struct ClipBlockView: View {
    let clip: TimelineClip
    let pixelsPerSecond: CGFloat
    @State private var isHovered = false
    
    var body: some View {
        let duration = clip.endTime - clip.startTime
        let width = max(20, CGFloat(duration) * pixelsPerSecond)
        
        // Only render if clip has valid duration
        if duration > 0 {
            RoundedRectangle(cornerRadius: 4)
                .fill(clip.nameMatches ? Color.green.opacity(0.7) : Color.red.opacity(0.7))
                .frame(width: width, height: 40)
                .overlay(
                    Text(clip.name)
                        .font(.system(size: 9))
                        .foregroundColor(.white)
                        .lineLimit(1)
                        .padding(.horizontal, 4)
                )
                .overlay(
                    // Tooltip on hover
                    Group {
                        if isHovered {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(clip.name)
                                    .font(.system(size: 11, weight: .semibold))
                                if let expected = clip.expectedFilename, !clip.nameMatches {
                                    Text("Expected: \(expected)")
                                        .font(.system(size: 10))
                                        .foregroundColor(.red)
                                }
                                Text("Track \(clip.trackIndex + 1)")
                                    .font(.system(size: 9))
                                    .foregroundColor(.secondary)
                                Text("\(String(format: "%.2f", clip.startTime))s - \(String(format: "%.2f", clip.endTime))s")
                                    .font(.system(size: 9))
                                    .foregroundColor(.secondary)
                            }
                            .padding(8)
                            .background(Color.black.opacity(0.9))
                            .foregroundColor(.white)
                            .cornerRadius(6)
                            .shadow(radius: 4)
                            .offset(y: -50)
                        }
                    }
                    .opacity(isHovered ? 1 : 0)
                )
                .onHover { hovering in
                    isHovered = hovering
                }
        } else {
            // Show a small marker for clips with no duration
            Circle()
                .fill(clip.nameMatches ? Color.green.opacity(0.7) : Color.red.opacity(0.7))
                .frame(width: 8, height: 8)
        }
    }
}
