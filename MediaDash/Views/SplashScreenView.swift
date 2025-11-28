//
//  SplashScreenView.swift
//  MediaDash
//
//  Created on 2025-11-27.
//

import SwiftUI

struct SplashScreenView: View {
    @Environment(\.colorScheme) var colorScheme
    @State private var isAnimating = false
    let progress: Double
    let statusMessage: String
    
    init(progress: Double = 0.0, statusMessage: String = "Loading...") {
        self.progress = progress
        self.statusMessage = statusMessage
    }
    
    private var logoImage: some View {
        let baseLogo = Image("HeaderLogo")
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(height: 60)
        
        if colorScheme == .light {
            return AnyView(baseLogo.colorInvert())
        } else {
            return AnyView(baseLogo)
        }
    }
    
    var body: some View {
        ZStack {
            // Background
            Color(NSColor.windowBackgroundColor)
                .ignoresSafeArea()
            
            VStack(spacing: 20) {
                // Logo
                logoImage
                    .opacity(isAnimating ? 1.0 : 0.8)
                    .scaleEffect(isAnimating ? 1.0 : 0.95)
                
                // Progress bar
                VStack(spacing: 8) {
                    // Status message
                    Text(statusMessage)
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                        .frame(height: 16)
                    
                    // Progress bar
                    GeometryReader { geometry in
                        ZStack(alignment: .leading) {
                            // Background
                            RoundedRectangle(cornerRadius: 4)
                                .fill(Color(NSColor.controlBackgroundColor))
                                .frame(height: 6)
                            
                            // Progress fill
                            RoundedRectangle(cornerRadius: 4)
                                .fill(Color.accentColor)
                                .frame(width: geometry.size.width * max(0.05, min(1.0, progress)), height: 6)
                                .animation(.spring(response: 0.3, dampingFraction: 0.8), value: progress)
                        }
                    }
                    .frame(height: 6)
                    .frame(width: 200)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .drawingGroup() // Optimize rendering by compositing to a single layer
        .onAppear {
            withAnimation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true)) {
                isAnimating = true
            }
        }
    }
}

#Preview {
    SplashScreenView(progress: 0.6, statusMessage: "Scanning dockets...")
}

