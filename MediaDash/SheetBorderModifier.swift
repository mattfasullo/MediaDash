//
//  SheetBorderModifier.swift
//  MediaDash
//
//  Adds a faint border to SwiftUI sheets and fixes the macOS sheet resizing bug
//

import SwiftUI

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
/// 3. Allows the sheet to be resized larger without re-laying out on app activation
struct SheetSizeStabilizer: ViewModifier {
    @State private var capturedMinSize: CGSize?
    
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
                                            let size = geometry.size
                                            if size.width > 1, size.height > 1 {
                                                capturedMinSize = size
                                            }
                                        }
                                    }
                                }
                        }
                    )
            }
        }
    }
}

extension View {
    func sheetBorder() -> some View {
        modifier(SheetBorderModifier())
            .modifier(SheetSizeStabilizer())
    }

    /// Border only, no size stabilizer. Use for compact sheets where the stabilizer
    /// (which captures the sheet's default size) would prevent the sheet from sizing to fit.
    func compactSheetBorder() -> some View {
        modifier(SheetBorderModifier())
    }

    /// Apply just the size stabilizer without the border
    func sheetSizeStabilizer() -> some View {
        modifier(SheetSizeStabilizer())
    }
    
    /// Prevents sheet content from expanding to fill the sheet window.
    /// Apply to sheet views with fixed/compact content so the sheet sizes to fit.
    /// Use instead of or before .sheetBorder() for dialogs, option pickers, etc.
    func compactSheetContent() -> some View {
        fixedSize(horizontal: true, vertical: true)
    }
}
