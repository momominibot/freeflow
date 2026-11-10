import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @EnvironmentObject var d: Dictation
    @Environment(\.dismiss) private var dismiss
    @State private var pickFile = false
    @State private var confirmClear = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ForEach(SpeechModel.allCases) { m in
                        Button { d.model = m } label: {
                            HStack(alignment: .top) {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(m.title).font(.system(size: 16, weight: .semibold)).foregroundColor(RT.ink)
                                    Text(m.note).font(.system(size: 13)).foregroundColor(RT.ink3)
                                }
                                Spacer()
                                if d.model == m { Image(systemName: "checkmark.circle.fill").foregroundColor(RT.primary) }
                            }
                        }
                    }
                } header: { Text("Speech model") } footer: {
                    Text("Downloaded once, then it works with no connection. Changing it downloads the new one.")
                }

                Section("Language") {
                    Picker("Language", selection: $d.language) {
                        ForEach(SpeechLanguage.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.inline).labelsHidden()
                }

                Section("The text") {
                    Toggle("Take out um and uh", isOn: $d.removeFillers)
                    Toggle("Copy it as soon as it is written", isOn: $d.autoCopy)
                }

                Section {
                    Picker("Spelling", selection: $d.variety) {
                        Text("British").tag(1)
                        Text("American").tag(0)
                        Text("Canadian").tag(2)
                        Text("Australian").tag(3)
                        Text("Indian").tag(4)
                    }
                    Toggle("Fix clear slips as I talk", isOn: $d.fixSlips)
                } header: { Text("Writing") } footer: {
                    Text("Spelling sets which words the Polish tab calls mistakes (colour or color). Clear slips are a wrong a or an, a lowercase \"I\" and a doubled word; spelling is left alone.")
                }

                Section {
                    NavigationLink("Dictionary") { DictionaryView() }
                    Button("Write down an audio file…") { pickFile = true }
                } footer: {
                    Text("The dictionary uses the same file as FreeFlow on the Mac, and shows in the Files app under On My iPhone › FreeFlow.")
                }

                Section {
                    NavigationLink("About and licences") { AcknowledgementsView() }
                }

                Section {
                    Button("Delete the history", role: .destructive) { confirmClear = true }
                } footer: {
                    Text("Nothing leaves this iPhone: no account, no server. The audio is thrown away as soon as it has been written down.")
                }
            }
            .scrollContentBackground(.hidden)
            .background(RT.paper.ignoresSafeArea())
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
            .fileImporter(isPresented: $pickFile, allowedContentTypes: [.audio, .movie]) { result in
                if case .success(let url) = result { d.transcribeFile(url); dismiss() }
            }
            .confirmationDialog("Delete every saved dictation?", isPresented: $confirmClear, titleVisibility: .visible) {
                Button("Delete", role: .destructive) { d.clearHistory() }
            }
        }
    }
}

struct DictionaryView: View {
    @EnvironmentObject var d: Dictation
    @State private var pickFile = false

    var body: some View {
        VStack(spacing: 0) {
            Text("One word or name per line, so it is spelled your way. To always swap a spelling write  wrong => right").font(.system(size: 13))
                .foregroundColor(RT.ink3).padding(.horizontal, 16).padding(.vertical, 10).frame(maxWidth: .infinity, alignment: .leading)
            TextEditor(text: $d.dictionaryText)
                .font(.system(size: 15, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 14).fill(RT.card))
                .padding(.horizontal, 12)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
        }
        .background(RT.paper.ignoresSafeArea())
        .navigationTitle("Dictionary")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("Use the one from my Mac…") { pickFile = true }
                    Button("Start again with the starter list", role: .destructive) { d.resetDictionary() }
                } label: { Image(systemName: "ellipsis.circle") }
            }
        }
        .fileImporter(isPresented: $pickFile, allowedContentTypes: [.plainText, .text]) { result in
            if case .success(let url) = result { d.importDictionary(from: url) }
        }
    }
}
