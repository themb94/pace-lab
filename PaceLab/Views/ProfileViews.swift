import SwiftUI

/// Round badge with the profile's initial.
struct ProfileAvatar: View {
    let profile: Profile
    var size: CGFloat = 22

    var body: some View {
        Text(profile.initial)
            .font(.system(size: size * 0.48, weight: .bold, design: .rounded))
            .foregroundStyle(Color.brand)
            .frame(width: size, height: size)
            .background(Color.brand.opacity(0.18), in: Circle())
            .accessibilityHidden(true)
    }
}

/// Choosing the active profile — as checkmarks in a menu.
struct ProfilePicker: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Picker("Profile", selection: Binding(get: { model.profiles.activeID }, set: { model.switchProfile(to: $0) })) {
            ForEach(model.profiles.profiles) { profile in
                Text(profile.displayName).tag(profile.id)
            }
        }
        .pickerStyle(.inline)
    }
}

/// Who is training — in the sidebar and the menu bar: switch, create and manage profiles.
struct ProfileMenu: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Menu {
            ProfilePicker()
            Divider()
            Button("New profile …") {
                model.showNewProfile = true
                openWindow(id: "main")
            }
            Button("Manage profiles …") {
                UserDefaults.standard.set(SettingsTab.profiles, forKey: SettingsTab.key)
                openSettings()
                NSApp.activate()
            }
        } label: {
            HStack(spacing: 8) {
                ProfileAvatar(profile: model.profile)
                Text(model.profile.displayName)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .contentShape(.rect)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Profile — switch, create or manage profiles")
    }
}

/// Form for a new profile: only the name; everything else happens in the setup afterwards.
struct NewProfileSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openWindow) private var openWindow
    @State private var name = ""

    private var trimmed: String { name.trimmingCharacters(in: .whitespaces) }

    private var isTaken: Bool {
        model.profiles.profiles.contains { $0.displayName.localizedCaseInsensitiveCompare(trimmed) == .orderedSame }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("New profile", systemImage: "person.crop.circle.badge.plus")
                .font(.title2.bold())
                .foregroundStyle(Color.brand)
            Text("A profile is a Pace Lab of its own for another person: its own training folder with plan and runs, its own coach conversations and settings, and its own sign-ins for Claude Code, Codex, the watch (Garmin or Polar) and Strava. Nothing is shared between profiles — the new profile is set up from scratch.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TextField("Name", text: $name, prompt: Text("e.g. Anna — the coach addresses the person by it"))
                .textFieldStyle(.roundedBorder)
                .onSubmit(create)
            if isTaken {
                Label("A profile with this name already exists.", systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
            }
            if model.isBusy {
                Label("Pace Lab is working right now — the profile is created, you switch to it afterwards.", systemImage: "hourglass")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Create and set up", action: create)
                    .keyboardShortcut(.defaultAction)
                    .disabled(trimmed.isEmpty || isTaken)
            }
        }
        .padding(24)
        .frame(width: 480)
    }

    private func create() {
        guard !trimmed.isEmpty, !isTaken else { return }
        let profile = model.createProfile(named: trimmed)
        dismiss()
        if model.profile.id == profile.id { openWindow(id: "setup") }
    }
}

/// Keys of the Settings tabs (stored, so other places can open a certain tab).
enum SettingsTab {
    static let key = "settingsTab"
    static let general = "general"
    static let runs = "runs"
    static let coach = "coach"
    static let profiles = "profiles"
}

/// Settings → Profiles: all profiles, switch, create, delete.
struct ProfileSettings: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @State private var showNew = false
    @State private var deleting: Profile?

    var body: some View {
        Form {
            Section {
                ForEach(model.profiles.profiles) { profile in
                    row(profile)
                }
            } header: {
                Text("Profiles")
            } footer: {
                Text("Profiles are completely separate: each has its own training folder, settings and coach conversations, and its own sign-ins for Claude Code, Codex, the watch (Garmin or Polar) and Strava. The main profile uses the sign-ins of this Mac (~/.claude, ~/.codex, ~/.garminconnect); every further profile keeps its own in Application Support/Pace Lab/Profiles.")
            }

            Section {
                HStack {
                    Button("New profile …") { showNew = true }
                    Spacer()
                    Button("Set up “\(model.profile.displayName)” …") { openWindow(id: "setup") }
                }
            } footer: {
                Text("You rename the active profile under General → About you.")
            }
        }
        .formStyle(.grouped)
        .frame(height: 560)
        .sheet(isPresented: $showNew) { NewProfileSheet() }
        .confirmationDialog(deleting.map { String(localized: "Delete profile “\($0.displayName)”?") } ?? "",
                            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            presenting: deleting) { profile in
            Button("Delete profile", role: .destructive) { model.deleteProfile(profile.id) }
            Button("Cancel", role: .cancel) {}
        } message: { profile in
            Text("Its settings, coach conversations and sign-ins for Claude Code, Codex, Garmin and Polar are removed from this Mac. The training folder with plan, runs and history stays: \(profile.projectPath)")
        }
    }

    private func row(_ profile: Profile) -> some View {
        let active = profile.id == model.profiles.activeID
        return HStack(spacing: 12) {
            ProfileAvatar(profile: profile, size: 30)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(profile.displayName).font(.headline)
                    if profile.isMain {
                        Text("Main profile").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                    }
                    if active {
                        Text("Active").font(.caption2.weight(.semibold)).foregroundStyle(Color.brand)
                    }
                }
                Text(profile.projectPath.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(profile.projectPath)
                Text(profile.isMain ? "Sign-ins of this Mac" : "Own sign-ins")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            if !active {
                Button("Switch to") { model.switchProfile(to: profile.id) }
                    .disabled(model.isBusy)
            }
            if !profile.isMain {
                Button {
                    deleting = profile
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .help("Delete profile")
                .disabled(model.isBusy)
            }
        }
        .padding(.vertical, 2)
    }
}
