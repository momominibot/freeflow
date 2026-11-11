import SwiftUI
import AppKit

struct ModesPage: View {
    @ObservedObject var model: StudioModel
    @State private var name = ""
    @State private var prompt = ""
    @State private var apps: [String] = []
    @State private var editing: String?
    @State private var error = ""

    private var file: ModesFile { model.modesFile }

    private func update(_ change: (inout ModesFile) -> Void) {
        var f = ModeStore.load()
        change(&f)
        ModeStore.save(f)
        model.reload()
    }

    private func runningApps() -> [(id: String, name: String)] {
        var seen = Set<String>()
        var out: [(String, String)] = []
        for a in NSWorkspace.shared.runningApplications where a.activationPolicy == .regular {
            guard let id = a.bundleIdentifier, id != Bundle.main.bundleIdentifier, !seen.contains(id) else { continue }
            seen.insert(id)
            out.append((id, a.localizedName ?? id))
        }
        return out.sorted { $0.1.localizedCaseInsensitiveCompare($1.1) == .orderedAscending }
    }

    var body: some View {
        PageScroll {
            PageTitle(title: "Tone", subtitle: "Tell the AI how to write for you. A tone is your own instruction, used in the apps you pick, or everywhere. For the built-in tone of each app, see Settings.")

            VStack(alignment: .leading, spacing: 12) {
                Text(editing == nil ? "New tone" : "Edit tone").font(Fonts.serif(20)).foregroundColor(RT.plum)
                SoftField(placeholder: "Name  (Client emails)", text: $name)
                MultiField(placeholder: "How should it write?  (Warm and brief. Use my first name. Never say \u{201C}kindly\u{201D}.)", text: $prompt)
                HStack(spacing: 8) {
                    FlowLayout(spacing: 8) {
                        ForEach(apps, id: \.self) { id in
                            Button { apps.removeAll { $0 == id } } label: {
                                HStack(spacing: 5) {
                                    Text(AppInfo.name(id)).font(Fonts.sans(12.5, .bold))
                                    Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
                                }
                                .foregroundColor(RT.plum).padding(.horizontal, 11).padding(.vertical, 6)
                                .background(Capsule().fill(RT.lilac2))
                            }.buttonStyle(.plain)
                        }
                        Menu {
                            ForEach(runningApps(), id: \.id) { a in
                                Button(a.name) { if !apps.contains(a.id) { apps.append(a.id) } }
                            }
                        } label: {
                            Label(apps.isEmpty ? "Use in an app…" : "Add an app…", systemImage: "plus")
                                .font(Fonts.sans(12.5, .bold)).foregroundColor(RT.mauve)
                                .padding(.horizontal, 11).padding(.vertical, 6)
                                .background(Capsule().strokeBorder(RT.lilac, lineWidth: 1.5))
                        }
                        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    }
                }
                HStack {
                    if !error.isEmpty { Text(error).font(Fonts.sans(12.5, .semibold)).foregroundColor(RT.high) }
                    Spacer()
                    if editing != nil { Button("Cancel") { resetMode() }.buttonStyle(GhostButton()) }
                    Button(editing == nil ? "Add tone" : "Save tone", action: saveMode).buttonStyle(PrimaryButton(small: true))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .rtCard(padding: 20)

            if file.modes.isEmpty {
                EmptyNote(text: "No tones yet. Without one, Purrscribe uses its built-in tone for each app: formal in Mail, casual in chat.", art: "modes")
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(file.modes.enumerated()), id: \.element.id) { i, m in
                        ModeRow(mode: m, active: file.activeMode == m.id,
                                toggleActive: { on in update { $0.activeMode = on ? m.id : nil } },
                                edit: { startEdit(m) },
                                remove: { update { f in f.modes.removeAll { $0.id == m.id }; if f.activeMode == m.id { f.activeMode = nil } } })
                        if i < file.modes.count - 1 { SoftDivider().padding(.horizontal, 16) }
                    }
                }
                .rtCard(padding: 6, radius: 18)
            }
        }
    }

    private func startEdit(_ m: CustomMode) {
        editing = m.id; name = m.name; prompt = m.prompt; apps = m.apps; error = ""
    }

    private func resetMode() { editing = nil; name = ""; prompt = ""; apps = []; error = "" }

    private func saveMode() {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let p = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty, !p.isEmpty else { error = "Give it a name and say how it should write."; return }
        guard p.count <= 1200 else { error = "Keep the instruction under 1,200 characters."; return }
        let id = editing
        let chosen = apps
        update { f in
            if let id = id, let i = f.modes.firstIndex(where: { $0.id == id }) {
                f.modes[i].name = n; f.modes[i].prompt = p; f.modes[i].apps = chosen
            } else {
                f.modes.append(CustomMode(id: ModeStore.newId(), name: n, prompt: p, apps: chosen))
            }
        }
        resetMode()
    }
}

struct MultiField: View {
    let placeholder: String
    @Binding var text: String
    var body: some View {
        TextField(placeholder, text: $text, axis: .vertical)
            .textFieldStyle(.plain).lineLimit(2...6)
            .font(Fonts.sans(14, .medium)).foregroundColor(RT.ink)
            .padding(.horizontal, 14).padding(.vertical, 11)
            .background(RoundedRectangle(cornerRadius: RT.radiusSmall, style: .continuous).fill(RT.paper2))
            .overlay(RoundedRectangle(cornerRadius: RT.radiusSmall, style: .continuous).strokeBorder(RT.line2, lineWidth: 1))
    }
}

struct ModeRow: View {
    let mode: CustomMode
    let active: Bool
    let toggleActive: (Bool) -> Void
    let edit: () -> Void
    let remove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(mode.name).font(Fonts.serif(18)).foregroundColor(RT.plum)
                    Text(mode.prompt).font(Fonts.sans(13, .medium)).foregroundColor(RT.ink2).lineLimit(3).fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button("Edit", action: edit).buttonStyle(GhostButton())
                TrashButton(action: remove)
            }
            HStack(spacing: 8) {
                if mode.apps.isEmpty {
                    Text("No app chosen").font(Fonts.sans(12, .semibold)).foregroundColor(RT.ink3)
                } else {
                    ForEach(mode.apps, id: \.self) { id in
                        Text(AppInfo.name(id)).font(Fonts.sans(12, .bold)).foregroundColor(RT.plum)
                            .padding(.horizontal, 10).padding(.vertical, 4).background(Capsule().fill(RT.lilac2))
                    }
                }
                Spacer()
                Toggle(isOn: Binding(get: { active }, set: toggleActive)) {
                    Text("Use everywhere else").font(Fonts.sans(12.5, .bold)).foregroundColor(RT.ink2)
                }
                .toggleStyle(RhythmeToggleStyle()).frame(width: 200)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 13)
    }
}
