//
//  SheetBorderModifier.swift
//  MediaDash
//
//  Adds a faint border to SwiftUI sheets and fixes the macOS sheet resizing bug
//

import SwiftUI
import Combine

struct SheetBorderModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .overlay(
                Rectangle()
                    .stroke(Color(nsColor: .separatorColor).opacity(0.3), lineWidth: 0.5)
            )
    }
}

/// Fixes the macOS SwiftUI bug where sheets shrink when cmd+tabbing in/out of the app.
/// Uses minimum size (not fixed size) so sheets remain resizable and draggable:
/// 1. Captures the initial size when the sheet first appears as the minimum
/// 2. Applies minWidth/minHeight so the sheet cannot shrink below that
/// 3. Allows the sheet to be resized larger; monitoring app activation for re-layout
struct SheetSizeStabilizer: ViewModifier {
    @State private var capturedMinSize: CGSize?
    @State private var refreshToken = UUID()
    
    func body(content: Content) -> some View {
        Group {
            if let minSize = capturedMinSize {
                content
                    .frame(minWidth: minSize.width, minHeight: minSize.height)
            } else {
                content
                    .background(
                        GeometryReader { geometry in
                            Color.clear
                                .onAppear {
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                                        if capturedMinSize == nil {
                                            capturedMinSize = geometry.size
                                        }
                                    }
                                }
                        }
                    )
            }
        }
        .id(refreshToken)
        .onReceive(Foundation.NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            if capturedMinSize != nil {
                refreshToken = UUID()
            }
        }
    }
}

extension View {
    func sheetBorder() -> some View {
        modifier(SheetBorderModifier())
            .modifier(SheetSizeStabilizer())
    }
    
    /// Apply just the size stabilizer without the border
    func sheetSizeStabilizer() -> some View {
        modifier(SheetSizeStabilizer())
    }
}

