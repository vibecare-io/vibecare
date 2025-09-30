import SwiftUI

// MARK: - Placeholder Views for Compilation

public struct CompactDashboard: View {
    public init() {}

    public var body: some View {
        TabView {
            Text("Routines")
                .tabItem {
                    Image(systemName: "list.bullet")
                    Text("Routines")
                }

            Text("Schedules")
                .tabItem {
                    Image(systemName: "calendar")
                    Text("Schedules")
                }

            Text("Actions")
                .tabItem {
                    Image(systemName: "bolt")
                    Text("Actions")
                }

            Text("Settings")
                .tabItem {
                    Image(systemName: "gearshape")
                    Text("Settings")
                }
        }
    }
}

public struct ProfileSelectorView: View {
    @EnvironmentObject private var appState: AppState
    @State private var showCreateProfile = false

    public init() {}

    public var body: some View {
        VStack(spacing: 20) {
            Text("Select Profile")
                .font(.title)
                .fontWeight(.semibold)

            if appState.profiles.isEmpty {
                VStack(spacing: 16) {
                    Text("No profiles found")
                        .foregroundColor(.secondary)

                    Button("Create Profile") {
                        showCreateProfile = true
                    }
                    .buttonStyle(.borderedProminent)
                }
            } else {
                ForEach(appState.profiles, id: \.id) { profile in
                    Button(profile.name) {
                        appState.selectProfile(profile)
                    }
                    .buttonStyle(.bordered)
                }

                Button("Create New Profile") {
                    showCreateProfile = true
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(40)
        .sheet(isPresented: $showCreateProfile) {
            CreateProfileView()
                .environmentObject(appState)
        }
    }
}

struct CreateProfileView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var email = ""

    var body: some View {
        VStack(spacing: 20) {
            Text("Create Profile")
                .font(.title)
                .fontWeight(.semibold)

            Form {
                TextField("Name", text: $name)
                TextField("Email", text: $email)
            }
            .formStyle(.grouped)

            HStack {
                Button("Cancel") {
                    dismiss()
                }
                .buttonStyle(.bordered)

                Spacer()

                Button("Create") {
                    Task {
                        await appState.createProfile(name: name, email: email)
                        dismiss()
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(name.isEmpty || email.isEmpty)
            }
        }
        .padding(40)
        .frame(minWidth: 400, minHeight: 300)
    }
}

public struct MenuBarView: View {
    @EnvironmentObject private var appState: AppState

    public init() {}

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("VibeCare")
                .font(.headline)
                .padding(.horizontal)

            Divider()

            if let profile = appState.currentProfile {
                Text("Profile: \(profile.name)")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.horizontal)
            }

            Button("Open Dashboard") {
                // Open main window
            }
            .padding(.horizontal)

            Button("Settings") {
                // Open settings
            }
            .padding(.horizontal)

            Divider()

            Button("Quit VibeCare") {
                NSApplication.shared.terminate(nil)
            }
            .padding(.horizontal)
        }
        .padding(.vertical, 8)
    }
}

struct HelpView: View {
    var body: some View {
        VStack(spacing: 20) {
            Text("VibeCare Help")
                .font(.title)
                .fontWeight(.semibold)

            Text("Keyboard Shortcuts:")
                .font(.headline)

            VStack(alignment: .leading, spacing: 8) {
                HelpShortcut(key: "j/k", description: "Navigate up/down")
                HelpShortcut(key: "/", description: "Search")
                HelpShortcut(key: "?", description: "Show help")
                HelpShortcut(key: "⌘N", description: "Create new item")
                HelpShortcut(key: "⌘⌥I", description: "Toggle inspector")
                HelpShortcut(key: "Esc", description: "Close panels")
            }

            Spacer()

            Button("Close") {
                // Handle close
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(40)
        .frame(minWidth: 400, minHeight: 500)
    }
}

struct HelpShortcut: View {
    let key: String
    let description: String

    var body: some View {
        HStack {
            Text(key)
                .font(.system(.body, design: .monospaced))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.secondary.opacity(0.2))
                .clipShape(RoundedRectangle(cornerRadius: 4))

            Text(description)
                .foregroundColor(.secondary)

            Spacer()
        }
    }
}

// MARK: - Form and Inspector Placeholders

struct ScheduleInspectorView: View {
    @ObservedObject var viewModel: ScheduleViewModel

    var body: some View {
        VStack {
            Text("Schedule Inspector")
                .font(.title2)
                .fontWeight(.semibold)

            Text("Select a schedule to edit")
                .foregroundColor(.secondary)

            Spacer()
        }
        .padding()
    }
}

struct ActionInspectorView: View {
    @ObservedObject var viewModel: ActionViewModel

    var body: some View {
        VStack {
            Text("Action Inspector")
                .font(.title2)
                .fontWeight(.semibold)

            Text("Select an action to edit")
                .foregroundColor(.secondary)

            Spacer()
        }
        .padding()
    }
}

struct RoutineFormView: View {
    @ObservedObject var viewModel: RoutineViewModel
    var editingRoutine: Routine?

    var body: some View {
        VStack {
            Text(editingRoutine == nil ? "Create Routine" : "Edit Routine")
                .font(.title2)
                .fontWeight(.semibold)

            Text("Routine form will be implemented here")
                .foregroundColor(.secondary)

            Spacer()

            HStack {
                Button("Cancel") {
                    // Handle cancel
                }
                .buttonStyle(.bordered)

                Spacer()

                Button("Save") {
                    // Handle save
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(40)
        .frame(minWidth: 500, minHeight: 600)
    }
}

struct ScheduleFormView: View {
    @ObservedObject var viewModel: ScheduleViewModel
    var editingSchedule: Schedule?
    var duplicatingSchedule: Schedule?
    let onCancel: (() -> Void)?

    init(
        viewModel: ScheduleViewModel,
        editingSchedule: Schedule? = nil,
        duplicatingSchedule: Schedule? = nil,
        onCancel: (() -> Void)? = nil
    ) {
        self.viewModel = viewModel
        self.editingSchedule = editingSchedule
        self.duplicatingSchedule = duplicatingSchedule
        self.onCancel = onCancel
    }

    private var formTitle: String {
        if editingSchedule != nil {
            return "Edit Schedule"
        } else if duplicatingSchedule != nil {
            return "Duplicate Schedule"
        } else {
            return "Create Schedule"
        }
    }

    var body: some View {
        VStack {
            Text(formTitle)
                .font(.title2)
                .fontWeight(.semibold)

            Text("Schedule form will be implemented here")
                .foregroundColor(.secondary)

            if let schedule = editingSchedule ?? duplicatingSchedule {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Schedule: \(schedule.name)")
                    Text("Routine: \(schedule.routineId)")
                    Text("Pattern: \(schedule.displayName)")
                }
                .padding()
                .background(Color.secondary.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }

            Spacer()

            HStack {
                Button("Cancel") {
                    onCancel?()
                }
                .buttonStyle(.bordered)

                Spacer()

                Button("Save") {
                    // Handle save
                    onCancel?()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(40)
        .frame(minWidth: 500, minHeight: 600)
    }
}

struct ActionFormView: View {
    @ObservedObject var viewModel: ActionViewModel

    var body: some View {
        VStack {
            Text("Create Action")
                .font(.title2)
                .fontWeight(.semibold)

            Text("Action form will be implemented here")
                .foregroundColor(.secondary)

            Spacer()
        }
        .padding(40)
        .frame(minWidth: 500, minHeight: 600)
    }
}


