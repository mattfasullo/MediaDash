import SwiftUI

struct LoginView: View {
    @ObservedObject var sessionManager: SessionManager
    @Environment(\.colorScheme) var colorScheme

    @State private var username = ""
    @State private var showCreateNew = false
    @State private var showError = false
    @State private var errorMessage = ""
    @State private var isLoggingIn = false
    @State private var serverUsers: [String] = []
    @State private var isLoadingServerUsers = false
    @State private var profileToDelete: WorkspaceProfile?
    @State private var showDeleteConfirmation = false
    @State private var deleteConfirmationText = ""
    @State private var newUserRole: UserRole = .mediaTeamMember
    @State private var showGuestRoleSheet = false
    
    private var existingProfiles: [WorkspaceProfile] {
        sessionManager.getAllUserProfiles()
    }
    
    private var isServerConnected: Bool {
        sessionManager.isServerConnected()
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
                    .frame(minHeight: 300, maxHeight: 600)
                }
                .background(Color(nsColor: .windowBackgroundColor))
                .cornerRadius(12)
                .shadow(color: Color.black.opacity(0.3), radius: 20, x: 0, y: 10)

                Spacer()
            }
            .padding()
        }
        .onAppear {
            loadServerUsers()
        }
        .alert("Error", isPresented: $showError) {
            Button("OK") { showError = false }
        } message: {
            Text(errorMessage)
        }
        .sheet(isPresented: $showGuestRoleSheet) {
            GuestRoleSheet(
                onSelect: { role in
                    sessionManager.createLocalWorkspace(name: "Guest", userRole: role)
                    showGuestRoleSheet = false
                },
                onCancel: {
                    showGuestRoleSheet = false
                }
            )
        }
        .alert("Delete User", isPresented: $showDeleteConfirmation) {
            TextField("Type 'delete' to confirm", text: $deleteConfirmationText)
            Button("Cancel", role: .cancel) {
                profileToDelete = nil
                deleteConfirmationText = ""
            }
            Button("Delete", role: .destructive) {
                if let profile = profileToDelete {
                    deleteProfile(profile)
                }
                profileToDelete = nil
                deleteConfirmationText = ""
            }
            .disabled(deleteConfirmationText.lowercased() != "delete")
        } message: {
            if let profile = profileToDelete {
                let message: String
                if profile.isLocal {
                    message = "Are you sure you want to delete '\(profile.name)'? This will remove the profile from this computer. Type 'delete' to confirm."
                } else {
                    message = "Are you sure you want to delete '\(profile.name)'? This will remove the profile from both this computer and the server. Type 'delete' to confirm."
                }
                return Text(message)
            }
            return Text("")
        }
    }

    // MARK: - Profile Picker Content

    private var profilePickerContent: some View {
        VStack(spacing: 20) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Select Your Profile")
                    .font(.headline)
                    .foregroundColor(.primary)

                if isServerConnected {
                    Text("Connected to server • Your settings will sync across all computers")
                        .font(.caption)
                        .foregroundColor(.secondary)
                } else {
                    Text("Server not connected • Using guest account")
                        .font(.caption)
                        .foregroundColor(.orange)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if !showCreateNew {
                ScrollView {
                    VStack(spacing: 8) {
                        if isLoadingServerUsers {
                            HStack {
                                ProgressView()
                                    .scaleEffect(0.8)
                                Text("Loading users from server...")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            .padding(.vertical, 8)
                        } else {
                            // Get all unique users (combine server users and local profiles, deduplicate)
                            let allUsers = getAllUniqueUsers()
                            
                            if allUsers.isEmpty && !isServerConnected {
                                // No users and server not connected - show guest option
                                GuestAccountButton(isLoggingIn: isLoggingIn) {
                                    showGuestRoleSheet = true
                                }
                            } else {
                                // Show all users (server users first, then local-only profiles)
                                ForEach(allUsers, id: \.username) { userInfo in
                                    if userInfo.isOnServer {
                                        ServerUserButton(
                                            username: userInfo.username,
                                            isLoggingIn: isLoggingIn,
                                            onSelect: {
                                                selectServerUser(userInfo.username)
                                            },
                                            onDelete: {
                                                // For server users, we can delete even without a local profile
                                                if let profile = userInfo.profile {
                                                    profileToDelete = profile
                                                } else {
                                                    // Create a temporary profile for deletion confirmation
                                                    let tempProfile = WorkspaceProfile.user(username: userInfo.username, settings: AppSettings.default)
                                                    profileToDelete = tempProfile
                                                }
                                                showDeleteConfirmation = true
                                            }
                                        )
                                    } else if let profile = userInfo.profile {
                                        ProfileButton(
                                            profile: profile,
                                            isLoggingIn: isLoggingIn,
                                            onDelete: {
                                                profileToDelete = profile
                                                showDeleteConfirmation = true
                                            }
                                        ) {
                                            selectProfile(profile)
                                        }
                                    }
                                }
                                
                                // Show guest account option if server not connected
                                if !isServerConnected {
                                    Divider()
                                        .padding(.vertical, 4)
                                    
                                    GuestAccountButton(isLoggingIn: isLoggingIn) {
                                        showGuestRoleSheet = true
                                    }
                                }
                            }
                        }
                    }
                }
                .frame(maxHeight: 350)
            }

            if showCreateNew {
                // Show create new profile form
                VStack(alignment: .leading, spacing: 16) {
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
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Account type")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Picker("Account type", selection: $newUserRole) {
                            Text("Media Team Member").tag(UserRole.mediaTeamMember)
                            Text("Producer").tag(UserRole.producer)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                    }
                }
            }

            Spacer()

            // Action Buttons
            HStack(spacing: 12) {
                if !showCreateNew {
                    Button(action: {
                        showCreateNew = true
                        username = ""
                    }) {
                        HStack {
                            Image(systemName: "plus.circle")
                            Text("New User")
                        }
                        .font(.subheadline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                    }
                    .buttonStyle(.bordered)
                    .disabled(isLoggingIn)
                }

                if showCreateNew {
                    Button(action: {
                        showCreateNew = false
                        username = ""
                    }) {
                        Text("Cancel")
                            .font(.subheadline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                    }
                    .buttonStyle(.bordered)
                    .disabled(isLoggingIn)
                    
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

    // MARK: - User List Management
    
    private struct UserInfo {
        let username: String
        let isOnServer: Bool
        let profile: WorkspaceProfile?
    }
    
    private func getAllUniqueUsers() -> [UserInfo] {
        var userMap: [String: UserInfo] = [:]
        
        // Add server users
        for serverUser in serverUsers {
            let lowercased = serverUser.lowercased()
            if userMap[lowercased] == nil {
                // Check if we have a local profile for this user
                let profile = existingProfiles.first { $0.username?.lowercased() == lowercased }
                userMap[lowercased] = UserInfo(
                    username: serverUser,
                    isOnServer: true,
                    profile: profile
                )
            }
        }
        
        // Add local profiles that aren't on server
        for profile in existingProfiles {
            if let username = profile.username {
                let lowercased = username.lowercased()
                if userMap[lowercased] == nil {
                    userMap[lowercased] = UserInfo(
                        username: username,
                        isOnServer: false,
                        profile: profile
                    )
                }
            }
        }
        
        // Sort: server users first, then by username
        return userMap.values.sorted { user1, user2 in
            if user1.isOnServer && !user2.isOnServer {
                return true
            }
            if !user1.isOnServer && user2.isOnServer {
                return false
            }
            return user1.username.lowercased() < user2.username.lowercased()
        }
    }
    
    // MARK: - Actions
    
    private func loadServerUsers() {
        guard isServerConnected else {
            serverUsers = []
            return
        }
        
        isLoadingServerUsers = true
        Task {
            let users = await sessionManager.getServerUsers()
            await MainActor.run {
                serverUsers = users
                isLoadingServerUsers = false
            }
        }
    }
    
    private func selectServerUser(_ username: String) {
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
            await sessionManager.loginWithUsername(username, initialUserRole: newUserRole)
            
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
    
    private func deleteProfile(_ profile: WorkspaceProfile) {
        Task {
            _ = await sessionManager.deleteProfile(profile)
            await MainActor.run {
                // Reload server users if connected
                if isServerConnected {
                    loadServerUsers()
                }
            }
        }
    }
    
    private func deleteServerUser(username: String) {
        Task {
            await sessionManager.deleteServerUser(username: username)
            await MainActor.run {
                // Reload server users if connected
                if isServerConnected {
                    loadServerUsers()
                }
            }
        }
    }
}

// MARK: - Server User Button

struct ServerUserButton: View {
    let username: String
    let isLoggingIn: Bool
    let onSelect: () -> Void
    let onDelete: () -> Void
    @State private var isHovered = false
    
    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 12) {
                Image(systemName: "person.circle.fill")
                    .font(.title2)
                    .foregroundColor(.green)
                
                VStack(alignment: .leading, spacing: 2) {
                    Text(username)
                        .font(.headline)
                        .foregroundColor(.primary)
                    Text("Server user")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                
                Spacer()
                
                if isHovered && !isLoggingIn {
                    Button(action: onDelete) {
                        Image(systemName: "trash")
                            .font(.caption)
                            .foregroundColor(.red)
                            .padding(6)
                            .background(Color.red.opacity(0.1))
                            .cornerRadius(4)
                    }
                    .buttonStyle(.plain)
                    .onHover { hovering in
                        // Prevent hover state from propagating
                    }
                }
                
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
        .onHover { hovering in
            isHovered = hovering
        }
    }
}

// MARK: - Profile Button

struct ProfileButton: View {
    let profile: WorkspaceProfile
    let isLoggingIn: Bool
    let onDelete: () -> Void
    let action: () -> Void
    @State private var isHovered = false

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
                
                if isHovered && !isLoggingIn {
                    Button(action: onDelete) {
                        Image(systemName: "trash")
                            .font(.caption)
                            .foregroundColor(.red)
                            .padding(6)
                            .background(Color.red.opacity(0.1))
                            .cornerRadius(4)
                    }
                    .buttonStyle(.plain)
                    .onHover { hovering in
                        // Prevent hover state from propagating
                    }
                }
                
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
        .onHover { hovering in
            isHovered = hovering
        }
    }
}

// MARK: - Guest Role Sheet

struct GuestRoleSheet: View {
    let onSelect: (UserRole) -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            Text("Choose account type")
                .font(.headline)
            Text("Guest account will be local only (no sync).")
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)

            HStack(spacing: 16) {
                ForEach(UserRole.allCases, id: \.self) { role in
                    Button {
                        onSelect(role)
                    } label: {
                        VStack(spacing: 8) {
                            Image(systemName: role.icon)
                                .font(.title)
                            Text(role.displayName)
                                .font(.subheadline)
                            Text(role.description)
                                .font(.caption2)
                                .foregroundColor(.secondary)
                                .multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color(nsColor: .controlBackgroundColor))
                        .cornerRadius(8)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal)

            Button("Cancel", role: .cancel, action: onCancel)
                .padding(.top, 8)
        }
        .padding(32)
        .frame(width: 400)
    }
}

// MARK: - Guest Account Button

struct GuestAccountButton: View {
    let isLoggingIn: Bool
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: "person.crop.circle.badge.questionmark")
                    .font(.title2)
                    .foregroundColor(.orange)
                
                VStack(alignment: .leading, spacing: 2) {
                    Text("Guest Account")
                        .font(.headline)
                        .foregroundColor(.primary)
                    Text("Local only • No sync")
                        .font(.caption)
                        .foregroundColor(.secondary)
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
