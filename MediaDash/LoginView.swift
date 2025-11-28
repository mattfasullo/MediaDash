import SwiftUI

struct LoginView: View {
    @ObservedObject var sessionManager: SessionManager
    @Environment(\.colorScheme) var colorScheme

    @State private var username = ""
    @State private var showCreateNew = false
    @State private var showError = false
    @State private var errorMessage = ""
    @State private var isLoggingIn = false
    
    private var existingProfiles: [WorkspaceProfile] {
        sessionManager.getAllUserProfiles()
    }
    
    private var logoImage: some View {
        let baseLogo = Image("HeaderLogo")
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(height: 120)
        
        if colorScheme == .light {
            return AnyView(baseLogo.colorInvert())
        } else {
            return AnyView(baseLogo)
        }
    }

    var body: some View {
        ZStack {
            // Clean background
            Color(nsColor: .windowBackgroundColor)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer()

                // Logo Section
                logoImage
                    .shadow(radius: 10)
                    .padding(.bottom, 50)

                // Login Card
                VStack(spacing: 0) {
                    // Content Area
                    VStack(spacing: 24) {
                        profilePickerContent
                    }
                    .padding(32)
                    .frame(width: 500)
                    .frame(minHeight: 300, maxHeight: 500)
                }
                .background(Color(nsColor: .windowBackgroundColor))
                .cornerRadius(12)
                .shadow(color: Color.black.opacity(0.3), radius: 20, x: 0, y: 10)

                Spacer()
            }
            .padding()
        }
        .alert("Error", isPresented: $showError) {
            Button("OK") { showError = false }
        } message: {
            Text(errorMessage)
        }
    }

    // MARK: - Profile Picker Content

    private var profilePickerContent: some View {
        VStack(spacing: 20) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Select Your Profile")
                    .font(.headline)
                    .foregroundColor(.primary)

                Text("Your settings will sync across all computers")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if !showCreateNew && !existingProfiles.isEmpty {
                // Show existing profiles
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(existingProfiles) { profile in
                            ProfileButton(
                                profile: profile,
                                isLoggingIn: isLoggingIn
                            ) {
                                selectProfile(profile)
                            }
                        }
                    }
                }
                .frame(maxHeight: 200)
            }

            if showCreateNew || existingProfiles.isEmpty {
                // Show create new profile form
                VStack(alignment: .leading, spacing: 4) {
                    Text("Username or Email")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    TextField("Enter your username or email", text: $username)
                        .textFieldStyle(.roundedBorder)
                        .textContentType(.username)
                        .disabled(isLoggingIn)
                        .onSubmit {
                            attemptUserLogin()
                        }
                }
            }

            Spacer()

            // Action Buttons
            HStack(spacing: 12) {
                if !showCreateNew && !existingProfiles.isEmpty {
                    Button(action: {
                        showCreateNew = true
                        username = ""
                    }) {
                        HStack {
                            Image(systemName: "plus.circle")
                            Text("New Profile")
                        }
                        .font(.subheadline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                    }
                    .buttonStyle(.bordered)
                    .disabled(isLoggingIn)
                }

                if showCreateNew || existingProfiles.isEmpty {
                    Button(action: attemptUserLogin) {
                        HStack {
                            if isLoggingIn {
                                ProgressView()
                                    .scaleEffect(0.8)
                                    .frame(width: 16, height: 16)
                            } else {
                                Image(systemName: "arrow.right.circle.fill")
                            }
                            Text(isLoggingIn ? "Signing In..." : "Sign In")
                        }
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(username.isEmpty || isLoggingIn)
                }
            }
        }
    }

    // MARK: - Actions

    private func selectProfile(_ profile: WorkspaceProfile) {
        guard let username = profile.username else { return }
        
        isLoggingIn = true
        
        Task {
            // Use loginWithUsername to ensure settings are synced from shared storage
            await sessionManager.loginWithUsername(username)
            
            await MainActor.run {
                isLoggingIn = false
                
                // Check if login was successful
                if case .loggedIn = sessionManager.authenticationState {
                    // Successfully logged in
                } else {
                    errorMessage = "Failed to load settings. Please check your shared storage connection."
                    showError = true
                }
            }
        }
    }

    private func attemptUserLogin() {
        guard !username.isEmpty else { return }
        
        isLoggingIn = true
        
        Task {
            await sessionManager.loginWithUsername(username)
            
            await MainActor.run {
                isLoggingIn = false
                
                // Check if login was successful
                if case .loggedIn = sessionManager.authenticationState {
                    // Successfully logged in
                } else {
                    errorMessage = "Failed to load settings. Please check your shared storage connection."
                    showError = true
                }
            }
        }
    }
}

// MARK: - Profile Button

struct ProfileButton: View {
    let profile: WorkspaceProfile
    let isLoggingIn: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: "person.circle.fill")
                    .font(.title2)
                    .foregroundColor(.blue)
                
                VStack(alignment: .leading, spacing: 2) {
                    Text(profile.name)
                        .font(.headline)
                        .foregroundColor(.primary)
                    if let username = profile.username {
                        Text(username)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                
                Spacer()
                
                if isLoggingIn {
                    ProgressView()
                        .scaleEffect(0.8)
                } else {
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(Color(nsColor: .controlBackgroundColor))
            .cornerRadius(8)
        }
        .buttonStyle(.plain)
        .disabled(isLoggingIn)
    }
}

// MARK: - Preview

#Preview {
    LoginView(sessionManager: SessionManager())
        .frame(width: 800, height: 600)
}
