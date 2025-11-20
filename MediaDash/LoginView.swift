import SwiftUI

struct LoginView: View {
    @ObservedObject var sessionManager: SessionManager

    @State private var selectedTab: LoginTab = .cloud
    @State private var username = ""
    @State private var password = ""
    @State private var workspaceName = ""
    @State private var showError = false
    @State private var errorMessage = ""

    enum LoginTab {
        case cloud, local
    }

    var body: some View {
        ZStack {
            // Background gradient
            LinearGradient(
                gradient: Gradient(colors: [Color.blue.opacity(0.6), Color.purple.opacity(0.6)]),
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer()

                // Logo Section
                Image("HeaderLogo")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(height: 120)
                    .shadow(radius: 10)
                    .padding(.bottom, 50)

                // Login Card
                VStack(spacing: 0) {
                    // Tab Selector
                    HStack(spacing: 0) {
                        TabButton(
                            title: "Connect to Workspace",
                            icon: "cloud",
                            isSelected: selectedTab == .cloud
                        ) {
                            selectedTab = .cloud
                        }

                        TabButton(
                            title: "Create Local Workspace",
                            icon: "desktopcomputer",
                            isSelected: selectedTab == .local
                        ) {
                            selectedTab = .local
                        }
                    }

                    Divider()

                    // Content Area
                    VStack(spacing: 24) {
                        if selectedTab == .cloud {
                            cloudLoginContent
                        } else {
                            localWorkspaceContent
                        }
                    }
                    .padding(32)
                    .frame(width: 500, height: 300)
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

    // MARK: - Cloud Login Content

    private var cloudLoginContent: some View {
        VStack(spacing: 20) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Sign in to your workspace")
                    .font(.headline)
                    .foregroundColor(.primary)

                Text("Use your Grayson Music credentials")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(spacing: 16) {
                // Username Field
                VStack(alignment: .leading, spacing: 4) {
                    Text("Username")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    TextField("Enter username", text: $username)
                        .textFieldStyle(.roundedBorder)
                        .textContentType(.username)
                }

                // Password Field
                VStack(alignment: .leading, spacing: 4) {
                    Text("Password")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    SecureField("Enter password", text: $password)
                        .textFieldStyle(.roundedBorder)
                        .textContentType(.password)
                        .onSubmit {
                            attemptCloudLogin()
                        }
                }
            }

            Spacer()

            // Login Button
            Button(action: attemptCloudLogin) {
                HStack {
                    Image(systemName: "arrow.right.circle.fill")
                    Text("Sign In")
                }
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
            }
            .buttonStyle(.borderedProminent)
            .disabled(username.isEmpty || password.isEmpty)
        }
    }

    // MARK: - Local Workspace Content

    private var localWorkspaceContent: some View {
        VStack(spacing: 20) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Create a local workspace")
                    .font(.headline)
                    .foregroundColor(.primary)

                Text("Work offline with your own settings")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .leading, spacing: 4) {
                Text("Workspace Name")
                    .font(.caption)
                    .foregroundColor(.secondary)
                TextField("Enter workspace name", text: $workspaceName)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit {
                        createLocalWorkspace()
                    }
            }

            Spacer()

            // Create Button
            Button(action: createLocalWorkspace) {
                HStack {
                    Image(systemName: "plus.circle.fill")
                    Text("Create Workspace")
                }
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
            }
            .buttonStyle(.borderedProminent)
            .disabled(workspaceName.isEmpty)
        }
    }

    // MARK: - Actions

    private func attemptCloudLogin() {
        if sessionManager.authenticateCloud(username: username, password: password) {
            // Successfully logged in
        } else {
            errorMessage = "Invalid credentials. Please try again."
            showError = true
            password = ""
        }
    }

    private func createLocalWorkspace() {
        guard !workspaceName.isEmpty else { return }
        sessionManager.createLocalWorkspace(name: workspaceName)
    }
}

// MARK: - Tab Button

struct TabButton: View {
    let title: String
    let icon: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                Text(title)
                    .font(.subheadline)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(isSelected ? Color.accentColor : Color.clear)
            .foregroundColor(isSelected ? .white : .primary)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Preview

#Preview {
    LoginView(sessionManager: SessionManager())
        .frame(width: 800, height: 600)
}
