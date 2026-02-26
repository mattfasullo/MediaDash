import SwiftUI

/// Contacts "family tree" page: navigate people ↔ companies from a CSV (Company, Name, Email, Role, City, Country).
struct ContactsView: View {
    @EnvironmentObject var settingsManager: SettingsManager
    @State private var tree: ContactsTree?
    @State private var loadError: String?
    @State private var isLoading = false
    @State private var viewMode: ContactsViewMode = .byCompany
    @State private var selectedCompany: String?
    @State private var selectedPersonKey: String?
    @State private var breadcrumb: [ContactsBreadcrumbItem] = []

    private var settings: AppSettings { settingsManager.currentSettings }
    private let contentPadding: CGFloat = 20

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if let err = loadError, tree == nil {
                errorView(err)
            } else if tree == nil && !isLoading {
                noCSVView
            } else if let t = tree {
                mainContent(tree: t)
            } else {
                ProgressView("Loading contacts…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 350, maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { loadIfNeeded() }
        .onChange(of: settings.contactsCSVPath) { _, _ in loadIfNeeded() }
    }

    private var header: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "person.2.fill")
                    .foregroundColor(.blue)
                Text("CONTACTS")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.primary)
                if let t = tree {
                    Text("\(t.entries.count) links")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.blue)
                        .cornerRadius(10)
                }
                Spacer()
                if tree != nil {
                    Picker("View", selection: $viewMode) {
                        Text("By Company").tag(ContactsViewMode.byCompany)
                        Text("By Person").tag(ContactsViewMode.byPerson)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 220)
                    .onChange(of: viewMode) { _, _ in
                        selectedCompany = nil
                        selectedPersonKey = nil
                        breadcrumb = []
                    }
                }
            }
            .padding(.horizontal, contentPadding)
            .padding(.top, 16)
            .padding(.bottom, 16)
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
            Divider().opacity(0.3)
        }
    }

    private func errorView(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.orange)
                .font(.system(size: 24))
            Text("Couldn’t load contacts")
                .font(.headline)
            Text(message)
                .font(.subheadline)
                .foregroundColor(.secondary)
                .textSelection(.enabled)
            Button("Reload") { loadIfNeeded() }
                .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(contentPadding)
    }

    private var noCSVView: some View {
        VStack(alignment: .leading, spacing: 12) {
            Image(systemName: "doc.text.magnifyingglass")
                .foregroundColor(.secondary)
                .font(.system(size: 32))
            Text("No contacts file")
                .font(.headline)
            Text("Connect a CSV in Settings to build the contacts map. The CSV should have columns: Company, Name, Email, Role, City, Country.")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Open Settings") {
                Foundation.NotificationCenter.default.post(name: Foundation.Notification.Name("OpenSettings"), object: nil)
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(contentPadding)
    }

    private func mainContent(tree t: ContactsTree) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if !breadcrumb.isEmpty {
                breadcrumbBar
                    .padding(.horizontal, contentPadding)
                    .padding(.top, 12)
                    .padding(.bottom, 8)
            }
            if t.entries.isEmpty {
                emptyParsedView
            } else {
                ScrollView {
                    if selectedCompany != nil {
                        companyDetailView(tree: t)
                            .padding(contentPadding)
                    } else if selectedPersonKey != nil {
                        personDetailView(tree: t)
                            .padding(contentPadding)
                    } else {
                        topLevelView(tree: t)
                            .padding(contentPadding)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private var emptyParsedView: some View {
        VStack(alignment: .leading, spacing: 12) {
            Image(systemName: "doc.text.magnifyingglass")
                .foregroundColor(.orange)
                .font(.system(size: 32))
            Text("No contacts found in CSV")
                .font(.headline)
            Text("The file was read but no rows had Company or Name. Check that the first row is a header with columns like Company, Name, Email, Role, City, Country, and that data rows use commas (or semicolons). Save as “CSV UTF-8” from Excel if needed.")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Reload") { loadIfNeeded() }
                .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(contentPadding)
    }

    private var breadcrumbBar: some View {
        HStack(spacing: 6) {
            Button {
                selectedCompany = nil
                selectedPersonKey = nil
                breadcrumb = []
            } label: {
                Text("All")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.accentColor)
            }
            .buttonStyle(.plain)
            ForEach(Array(breadcrumb.enumerated()), id: \.offset) { idx, item in
                Text("›")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Button {
                    popBreadcrumb(to: idx)
                } label: {
                    Text(item.title)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.accentColor)
                        .lineLimit(1)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func topLevelView(tree t: ContactsTree) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(viewMode == .byCompany ? "Tap a company to see who’s worked there" : "Tap a person to see where they’ve worked")
                .font(.subheadline)
                .foregroundColor(.secondary)
            if viewMode == .byCompany {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(t.companies, id: \.self) { company in
                        companyCard(company: company, tree: t)
                    }
                }
            } else {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(t.personKeys, id: \.self) { key in
                        personCard(personKey: key, tree: t)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private func companyCard(company: String, tree: ContactsTree) -> some View {
        let count = tree.people(atCompany: company).count
        return Button {
            selectedCompany = company
            selectedPersonKey = nil
            breadcrumb = [.company(company)]
        } label: {
            HStack {
                Image(systemName: "building.2")
                    .foregroundColor(.blue)
                    .frame(width: 24, alignment: .center)
                VStack(alignment: .leading, spacing: 2) {
                    Text(company)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.primary)
                    Text("\(count) contact\(count == 1 ? "" : "s")")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(12)
            .background(Color.primary.opacity(0.04))
            .cornerRadius(8)
        }
        .buttonStyle(.plain)
    }

    private func personCard(personKey: String, tree: ContactsTree) -> some View {
        let name = tree.displayName(forPersonKey: personKey)
        let count = tree.companies(forPersonKey: personKey).count
        return Button {
            selectedCompany = nil
            selectedPersonKey = personKey
            breadcrumb = [.person(key: personKey, displayName: name)]
        } label: {
            HStack {
                Image(systemName: "person")
                    .foregroundColor(.green)
                    .frame(width: 24, alignment: .center)
                VStack(alignment: .leading, spacing: 2) {
                    Text(name)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.primary)
                    Text("\(count) compan\(count == 1 ? "y" : "ies")")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(12)
            .background(Color.primary.opacity(0.04))
            .cornerRadius(8)
        }
        .buttonStyle(.plain)
    }

    private func companyDetailView(tree t: ContactsTree) -> some View {
        guard let company = selectedCompany else { return AnyView(EmptyView()) }
        let people = t.people(atCompany: company)
        return AnyView(
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Image(systemName: "building.2")
                        .foregroundColor(.blue)
                    Text(company)
                        .font(.headline)
                }
                Text("\(people.count) contact\(people.count == 1 ? "" : "s")")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                Text("Tap a person to see their other companies.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(people) { entry in
                        Button {
                            selectedPersonKey = entry.normalizedPersonKey
                            let name = entry.name != "—" ? entry.name : entry.email
                            breadcrumb = [.company(company), .person(key: entry.normalizedPersonKey, displayName: name)]
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(entry.name != "—" ? entry.name : entry.email)
                                        .font(.system(size: 13, weight: .medium))
                                        .foregroundColor(.primary)
                                    if !entry.role.isEmpty {
                                        Text(entry.role)
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                    }
                                    if !entry.city.isEmpty || !entry.country.isEmpty {
                                        Text([entry.city, entry.country].filter { !$0.isEmpty }.joined(separator: ", "))
                                            .font(.caption2)
                                            .foregroundColor(.secondary)
                                    }
                                }
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            .padding(12)
                            .background(Color.primary.opacity(0.04))
                            .cornerRadius(8)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
        )
    }

    private func personDetailView(tree t: ContactsTree) -> some View {
        guard let key = selectedPersonKey else { return AnyView(EmptyView()) }
        let entries = t.companies(forPersonKey: key)
        let displayName = t.displayName(forPersonKey: key)
        return AnyView(
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Image(systemName: "person")
                        .foregroundColor(.green)
                    Text(displayName)
                        .font(.headline)
                }
                Text("\(entries.count) compan\(entries.count == 1 ? "y" : "ies")")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                Text("Tap a company to see who else works there.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(entries) { entry in
                        Button {
                            selectedCompany = entry.normalizedCompany
                            selectedPersonKey = nil
                            breadcrumb = [.person(key: key, displayName: displayName), .company(entry.normalizedCompany)]
                        } label: {
                            HStack {
                                Image(systemName: "building.2")
                                    .foregroundColor(.blue)
                                    .frame(width: 24, alignment: .center)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(entry.normalizedCompany)
                                        .font(.system(size: 13, weight: .medium))
                                        .foregroundColor(.primary)
                                    if !entry.role.isEmpty {
                                        Text(entry.role)
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                    }
                                }
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            .padding(12)
                            .background(Color.primary.opacity(0.04))
                            .cornerRadius(8)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
        )
    }

    private func popBreadcrumb(to index: Int) {
        guard index < breadcrumb.count else { return }
        let item = breadcrumb[index]
        switch item {
        case .company(let name):
            selectedCompany = name
            selectedPersonKey = nil
            breadcrumb = Array(breadcrumb.prefix(index + 1))
        case .person(let key, _):
            selectedPersonKey = key
            selectedCompany = nil
            breadcrumb = Array(breadcrumb.prefix(index + 1))
        }
    }

    private func loadIfNeeded() {
        guard let path = settings.contactsCSVPath, !path.trimmingCharacters(in: .whitespaces).isEmpty else {
            tree = nil
            loadError = nil
            return
        }
        loadError = nil
        isLoading = true
        Task.detached(priority: .userInitiated) {
            let result = Self.loadTree(from: path)
            await MainActor.run {
                isLoading = false
                switch result {
                case .success(let t):
                    tree = t
                    loadError = nil
                case .failure(let err):
                    tree = nil
                    loadError = err.localizedDescription
                }
            }
        }
    }

    private nonisolated static func loadTree(from path: String) -> Result<ContactsTree, Error> {
        let trimmed = path.trimmingCharacters(in: .whitespaces)
        let url: URL
        if trimmed.hasPrefix("file://") {
            guard let u = URL(string: trimmed) else { return .failure(NSError(domain: "Contacts", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid file URL"])) }
            url = u
        } else {
            url = URL(fileURLWithPath: trimmed)
        }
        guard FileManager.default.fileExists(atPath: url.path) else {
            return .failure(NSError(domain: "Contacts", code: 2, userInfo: [NSLocalizedDescriptionKey: "File not found: \(url.path)"]))
        }
        do {
            let data = try Data(contentsOf: url)
            var content: String? = String(data: data, encoding: .utf8)
            if content == nil { content = String(data: data, encoding: .utf16) }
            if content == nil { content = String(data: data, encoding: .isoLatin1) }
            guard let csvString = content else {
                return .failure(NSError(domain: "Contacts", code: 3, userInfo: [NSLocalizedDescriptionKey: "File encoding not supported."]))
            }
            let ext = url.pathExtension
            let entries = ContactsCSVParser.parse(content: csvString, fileExtension: ext.isEmpty ? nil : ext)
            return .success(ContactsTree(entries: entries))
        } catch {
            return .failure(error)
        }
    }
}

// MARK: - View mode & breadcrumb

private enum ContactsViewMode {
    case byCompany
    case byPerson
}

private enum ContactsBreadcrumbItem: Equatable {
    case company(String)
    case person(key: String, displayName: String)

    var title: String {
        switch self {
        case .company(let n): return n
        case .person(_, let n): return n
        }
    }
}

#Preview {
    ContactsView()
        .environmentObject(SettingsManager())
        .frame(width: 500, height: 500)
}
