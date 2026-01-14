//
//  SheetBorderModifier.swift
//  MediaDash
//
//  Adds a faint border to SwiftUI sheets
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

extension View {
    func sheetBorder() -> some View {
        modifier(SheetBorderModifier())
    }
}

