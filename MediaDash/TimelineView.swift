import SwiftUI
import AppKit

// MARK: - Timeline View

struct TimelineView: View {
    let clips: [TimelineClip]
    @Binding var hoveredClip: TimelineClip?
    @Binding var hoveredClipTrackIndex: Int?
    @Binding var hoveredClipXPosition: CGFloat?
    
    // Calculate timeline duration
    private var timelineDuration: Double {
        clips.map { $0.endTime }.max() ?? 10.0
    }
    
    // Group clips by track
    private var tracks: [[TimelineClip]] {
        let maxTrack = clips.map { $0.trackIndex }.max() ?? 0
        var trackClips: [[TimelineClip]] = Array(repeating: [], count: maxTrack + 1)
        for clip in clips {
            trackClips[clip.trackIndex].append(clip)
        }
        // Sort clips in each track by timeline position
        // Also filter out clips with zero or invalid durations
        return trackClips.map { track in
            track.sorted { $0.startTime < $1.startTime }
                .filter { $0.endTime > $0.startTime } // Only show clips with valid duration
        }
    }
    
    var body: some View {
        ZStack(alignment: .topLeading) {
            timelineContentView
            tooltipOverlay
        }
    }
    
    private var timelineContentView: some View {
        VStack(spacing: 0) {
            // Timecode ruler
            TimelineRulerView(duration: timelineDuration)
                .frame(height: 16)
                .padding(.horizontal, 3) // Prevent timecode cutoff
            
            // Tracks
            VStack(spacing: 0) {
                ForEach(Array(tracks.enumerated()), id: \.offset) { trackIndex, trackClips in
                    TrackView(
                        trackIndex: trackIndex,
                        clips: trackClips,
                        timelineDuration: timelineDuration,
                        hoveredClip: $hoveredClip,
                        hoveredClipTrackIndex: $hoveredClipTrackIndex,
                        hoveredClipXPosition: $hoveredClipXPosition
                    )
                    .frame(height: 18)
                }
            }
            .padding(.horizontal, 3) // Prevent clip cutoff
            .padding(.bottom, 3) // Prevent bottom clip cutoff
        }
        .padding(3) // Internal padding to prevent border clipping
        .background(Color(nsColor: .controlBackgroundColor))
        .clipped() // Ensure all content stays within bounds
    }
    
    @ViewBuilder
    private var tooltipOverlay: some View {
        if let clip = hoveredClip,
           let trackIndex = hoveredClipTrackIndex {
            tooltipView(clip: clip, trackIndex: trackIndex)
        }
    }
    
    private func tooltipView(clip: TimelineClip, trackIndex: Int) -> some View {
        GeometryReader { geometry in
            let tooltipPosition = calculateTooltipPosition(
                clip: clip,
                trackIndex: trackIndex,
                geometry: geometry
            )
            
            ClipInfoTooltip(clip: clip)
                .position(x: tooltipPosition.x, y: tooltipPosition.y)
        }
        .allowsHitTesting(false)
        .transition(.opacity.combined(with: .scale(scale: 0.95)))
    }
    
    private func calculateTooltipPosition(clip: TimelineClip, trackIndex: Int, geometry: GeometryProxy) -> (x: CGFloat, y: CGFloat) {
        let pixelsPerSecond = geometry.size.width / timelineDuration
        let clipStartX = CGFloat(clip.startTime) * pixelsPerSecond
        let clipWidth = CGFloat(clip.endTime - clip.startTime) * pixelsPerSecond
        let clipEndX = clipStartX + clipWidth
        
        // Tooltip dimensions (approximate)
        let tooltipWidth: CGFloat = 250
        let tooltipHeight: CGFloat = 120
        let tooltipHalfWidth = tooltipWidth / 2
        let tooltipHalfHeight = tooltipHeight / 2
        
        let padding = CGFloat(3)
        let trackLabelWidth = CGFloat(20)
        let rulerHeight = CGFloat(16)
        let trackHeight = CGFloat(18)
        let clipCenter = CGFloat(7)
        let trackOffset = CGFloat(trackIndex) * trackHeight
        
        // Clip position in timeline coordinates
        let clipStartInTimeline = padding + trackLabelWidth + padding + clipStartX
        let clipEndInTimeline = padding + trackLabelWidth + padding + clipEndX
        let clipCenterInTimeline = padding + trackLabelWidth + padding + clipStartX + clipWidth / 2
        
        // Clip Y position (center of clip)
        let clipY = rulerHeight + padding + trackOffset + clipCenter
        
        // Try to position to the right of the clip first
        let rightX = clipEndInTimeline + 10
        let canFitRight = rightX + tooltipHalfWidth <= geometry.size.width
        
        // Try to position to the left of the clip if right doesn't fit
        let leftX = clipStartInTimeline - 10 - tooltipWidth
        let canFitLeft = leftX >= tooltipHalfWidth
        
        // Determine X position
        let tooltipX: CGFloat
        if canFitRight {
            // Position to the right
            tooltipX = min(rightX + tooltipHalfWidth, geometry.size.width - tooltipHalfWidth)
        } else if canFitLeft {
            // Position to the left
            tooltipX = max(leftX + tooltipHalfWidth, tooltipHalfWidth)
        } else {
            // Center on clip if neither side works
            tooltipX = min(max(clipCenterInTimeline, tooltipHalfWidth), geometry.size.width - tooltipHalfWidth)
        }
        
        // Y position: align with clip center, but adjust if needed
        let minY = tooltipHalfHeight
        let maxY = geometry.size.height - tooltipHalfHeight
        let tooltipY = min(max(clipY, minY), maxY)
        
        return (x: tooltipX, y: tooltipY)
    }
}

struct TimelineRulerView: View {
    let duration: Double
    
    var body: some View {
        GeometryReader { geometry in
            let pixelsPerSecond = geometry.size.width / CGFloat(duration)
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
                            .frame(width: 1, height: 6)
                        Text(formatTimecode(time))
                            .font(.system(size: 7, design: .monospaced))
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
    @Binding var hoveredClip: TimelineClip?
    @Binding var hoveredClipTrackIndex: Int?
    @Binding var hoveredClipXPosition: CGFloat?
    
    var body: some View {
        GeometryReader { geometry in
            let pixelsPerSecond = geometry.size.width / CGFloat(timelineDuration)
            
            ZStack(alignment: .leading) {
                // Track background
                Rectangle()
                    .fill(trackIndex % 2 == 0 ? 
                          Color(nsColor: .controlBackgroundColor) : 
                          Color(nsColor: .controlBackgroundColor).opacity(0.5))
                
                // Track label (minimized for minimap view)
                HStack {
                    Text("\(trackIndex + 1)")
                        .font(.system(size: 7))
                        .foregroundColor(.secondary.opacity(0.6))
                        .frame(width: 20)
                    
                    // Clips on this track
                    ZStack(alignment: .leading) {
                        ForEach(clips, id: \.id) { clip in
                            ClipBlockView(
                                clip: clip,
                                pixelsPerSecond: pixelsPerSecond,
                                hoveredClip: $hoveredClip,
                                hoveredClipTrackIndex: $hoveredClipTrackIndex,
                                hoveredClipXPosition: $hoveredClipXPosition,
                                trackIndex: trackIndex
                            )
                            .offset(x: CGFloat(clip.startTime) * pixelsPerSecond)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .clipped() // Prevent clips from extending beyond track bounds
                }
            }
        }
    }
}

struct ClipBlockView: View {
    let clip: TimelineClip
    let pixelsPerSecond: CGFloat
    @Binding var hoveredClip: TimelineClip?
    @Binding var hoveredClipTrackIndex: Int?
    @Binding var hoveredClipXPosition: CGFloat?
    let trackIndex: Int
    @State private var isHovered = false
    
    var body: some View {
        let duration = clip.endTime - clip.startTime
        let width = max(20, CGFloat(duration) * pixelsPerSecond)
        let clipCenterX = CGFloat(clip.startTime) * pixelsPerSecond + width / 2
        
        // Color based on name matching: green if matches, red if doesn't
        let baseColor = clip.nameMatches ? Color.green.opacity(0.7) : Color.red.opacity(0.7)
        let clipColor = isHovered ? baseColor.opacity(0.9) : baseColor
        
        // Only render if clip has valid duration
        if duration > 0 {
            RoundedRectangle(cornerRadius: 2)
                .fill(clipColor)
                .frame(width: width, height: 14)
                .overlay(
                    // Only show text if clip is wide enough
                    Group {
                        if width > 40 {
                    Text(clip.name)
                                .font(.system(size: 6))
                                .foregroundColor(.white.opacity(0.9))
                        .lineLimit(1)
                                .padding(.horizontal, 2)
                        }
                    }
                )
                .overlay(
                    // Highlight border on hover
                    RoundedRectangle(cornerRadius: 2)
                        .stroke(isHovered ? Color.white.opacity(0.7) : Color.clear, lineWidth: 1)
                )
                .shadow(color: isHovered ? baseColor.opacity(0.4) : Color.clear, radius: isHovered ? 3 : 0)
                .scaleEffect(isHovered ? 1.08 : 1.0)
                .contentShape(Rectangle())
                .onTapGesture {
                    // Show tooltip on click
                    hoveredClipXPosition = clipCenterX
                    hoveredClipTrackIndex = trackIndex
                    withAnimation(.spring(response: 0.2, dampingFraction: 0.7)) {
                        hoveredClip = clip
                    }
                }
                .onHover { hovering in
                    isHovered = hovering
                    if hovering {
                        NSCursor.pointingHand.push()
                        hoveredClipXPosition = clipCenterX
                        hoveredClipTrackIndex = trackIndex
                        withAnimation(.spring(response: 0.2, dampingFraction: 0.7)) {
                            hoveredClip = clip
                        }
                    } else {
                        NSCursor.pop()
                        // Hide when mouse leaves
                        withAnimation(.spring(response: 0.15, dampingFraction: 0.8)) {
                            hoveredClip = nil
                            hoveredClipTrackIndex = nil
                            hoveredClipXPosition = nil
                        }
                    }
                }
        } else {
            // Show a small marker for clips with no duration
            Circle()
                .fill(clipColor)
                .frame(width: isHovered ? 10 : 8, height: isHovered ? 10 : 8)
                .overlay(
                    Circle()
                        .stroke(isHovered ? Color.white.opacity(0.6) : Color.clear, lineWidth: 1.5)
                )
                .shadow(color: isHovered ? baseColor.opacity(0.5) : Color.clear, radius: isHovered ? 3 : 0)
                .contentShape(Rectangle())
                .onTapGesture {
                    hoveredClipXPosition = CGFloat(clip.startTime) * pixelsPerSecond
                    hoveredClipTrackIndex = trackIndex
                    withAnimation(.spring(response: 0.2, dampingFraction: 0.7)) {
                        hoveredClip = clip
                    }
                }
                .onHover { hovering in
                    isHovered = hovering
                    if hovering {
                        NSCursor.pointingHand.push()
                        hoveredClipXPosition = CGFloat(clip.startTime) * pixelsPerSecond
                        hoveredClipTrackIndex = trackIndex
                        withAnimation(.spring(response: 0.2, dampingFraction: 0.7)) {
                            hoveredClip = clip
                        }
                    } else {
                        NSCursor.pop()
                        withAnimation(.spring(response: 0.15, dampingFraction: 0.8)) {
                            hoveredClip = nil
                            hoveredClipTrackIndex = nil
                            hoveredClipXPosition = nil
                        }
                    }
                }
        }
    }
}

struct ClipInfoTooltip: View {
    let clip: TimelineClip
    
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Clip name
            Text(clip.name)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.primary)
            
            Divider()
            
            // File name (if available)
            if let filename = clip.expectedFilename {
                VStack(alignment: .leading, spacing: 4) {
                    Text("File:")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                    Text(filename)
                        .font(.system(size: 11))
                        .foregroundColor(.primary)
                }
            } else {
                Text("Embedded clip")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }
            
            // Status
            HStack(spacing: 4) {
                Image(systemName: clip.nameMatches ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .font(.system(size: 10))
                    .foregroundColor(clip.nameMatches ? .green : .red)
                Text(clip.nameMatches ? "Name matches file" : "Name does not match file")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(nsColor: .windowBackgroundColor))
                .shadow(color: .black.opacity(0.25), radius: 10, x: 0, y: 4)
        )
        .frame(maxWidth: 250)
    }
}

