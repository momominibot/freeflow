import SwiftUI

struct ContentView: View {
    @EnvironmentObject var d: Dictation
    @State private var pressing = false
    @State private var pressStart = Date()
    @State private var showSettings = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 22) {
                    CatPicture(name: CatArt.hero(for: d.phase), height: 190)
                        .id(CatArt.hero(for: d.phase))
                        .transition(.opacity)
                        .animation(.easeInOut(duration: 0.25), value: CatArt.hero(for: d.phase))
                    statusLine
                    RecordButton(phase: d.phase, level: d.level)
                        .gesture(DragGesture(minimumDistance: 0)
                            .onChanged { _ in
                                guard !pressing else { return }
                                pressing = true; pressStart = Date(); d.press()
                            }
                            .onEnded { _ in
                                pressing = false; d.release(heldFor: Date().timeIntervalSince(pressStart))
                            })
                        .accessibilityElement()
                        .accessibilityLabel(d.phase == .listening ? "Stop" : "Talk")
                        .accessibilityAddTraits(.isButton)
                        .accessibilityAction { if d.phase == .listening { d.end() } else { d.press(); d.release(heldFor: 1) } }
                        .padding(.top, 8)
                    Text(hint).font(.system(size: 14, weight: .medium)).foregroundColor(RT.ink3).multilineTextAlignment(.center)
                    if let r = d.result { ResultCard(entry: r) }
                    if !d.history.isEmpty { HistoryList() }
                }
                .padding(.horizontal, 18)
                .padding(.bottom, 40)
            }
            .background(RT.paper.ignoresSafeArea())
            .navigationTitle("FreeFlow")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showSettings = true } label: { Image(systemName: "slider.horizontal.3") }
                        .tint(RT.plum).accessibilityLabel("Settings")
                }
            }
            .sheet(isPresented: $showSettings) { SettingsView() }
        }
        .tint(RT.plum)
    }

    private var hint: String {
        switch d.phase {
        case .ready: return "Tap to start and tap to finish, or hold and let go.\nIt is turned into text on this iPhone."
        case .listening: return "Listening… \(d.seconds / 60):\(String(format: "%02d", d.seconds % 60))"
        case .transcribing: return "Writing it down…"
        case .preparing: return "Getting ready"
        case .failed: return ""
        }
    }

    @ViewBuilder private var statusLine: some View {
        switch d.phase {
        case .preparing(let text):
            HStack(spacing: 10) {
                ProgressView()
                Text(text).font(.system(size: 14, weight: .medium)).foregroundColor(RT.ink2)
            }
            .padding(12).frame(maxWidth: .infinity).background(RoundedRectangle(cornerRadius: 14).fill(RT.paper2))
        case .failed(let text):
            VStack(alignment: .leading, spacing: 8) {
                Text(text).font(.system(size: 14, weight: .semibold)).foregroundColor(RT.live)
                Button("Try again") { Task { await d.prepare() } }.buttonStyle(SoftButton())
            }
            .padding(12).frame(maxWidth: .infinity, alignment: .leading).background(RoundedRectangle(cornerRadius: 14).fill(RT.paper2))
        default:
            EmptyView()
        }
    }
}

struct RecordButton: View {
    let phase: Dictation.Phase
    let level: Float

    private var listening: Bool { phase == .listening }
    /// 0...1 from about -50 dB to -10 dB
    private var pulse: CGFloat { listening ? CGFloat(max(0, min(1, (level + 50) / 40))) : 0 }

    var body: some View {
        ZStack {
            Circle().fill(RT.lilac.opacity(0.25)).frame(width: 190 + 40 * pulse, height: 190 + 40 * pulse)
                .animation(.easeOut(duration: 0.12), value: pulse)
            Circle()
                .fill(LinearGradient(colors: listening ? [RT.live, RT.live.opacity(0.8)] : [RT.lilac, RT.primary],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: 150, height: 150)
                .shadow(color: (listening ? RT.live : RT.primary).opacity(0.35), radius: 16, y: 8)
            Group {
                if phase == .transcribing {
                    ProgressView().tint(.white).scaleEffect(1.5)
                } else {
                    Image(systemName: listening ? "stop.fill" : "mic.fill").font(.system(size: 46, weight: .semibold)).foregroundColor(.white)
                }
            }
        }
        .frame(height: 240)
        .opacity(phase == .ready || listening || phase == .transcribing ? 1 : 0.45)
        .contentShape(Circle())
    }
}

/// The two tabs: talk, and polish what you wrote.
struct RootView: View {
    @EnvironmentObject var router: Router

    var body: some View {
        TabView(selection: $router.tab) {
            ContentView().tabItem { Label("Talk", systemImage: "mic.fill") }.tag(Router.Tab.talk)
            PolishView().tabItem { Label("Polish", systemImage: "checkmark.seal") }.tag(Router.Tab.polish)
        }
        .tint(RT.primary)
    }
}

struct ResultCard: View {
    @EnvironmentObject var d: Dictation
    @EnvironmentObject var router: Router
    let entry: Entry

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                Text(entry.text).font(.system(size: 17)).foregroundColor(RT.ink).textSelection(.enabled)
                HStack(spacing: 10) {
                    Button(d.copiedFlash ? "Copied" : "Copy") { d.copy(entry.text) }.buttonStyle(SoftButton(prominent: true))
                    ShareLink(item: entry.text) { Label("Share", systemImage: "square.and.arrow.up") }.buttonStyle(SoftButton())
                    Button("Polish") { router.polish(entry.text) }.buttonStyle(SoftButton())
                    Spacer()
                }
                if d.autoCopy {
                    Text("Already copied. Paste it into any app.").font(.system(size: 12.5, weight: .medium)).foregroundColor(RT.ink3)
                }
            }
        }
    }
}

struct HistoryList: View {
    @EnvironmentObject var d: Dictation
    @EnvironmentObject var router: Router

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Earlier").font(.system(size: 13, weight: .bold)).foregroundColor(RT.ink3).textCase(.uppercase)
            ForEach(d.history.prefix(30)) { e in
                Card {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(e.text).font(.system(size: 15)).foregroundColor(RT.ink).lineLimit(3)
                        Text(e.date.formatted(date: .abbreviated, time: .shortened)).font(.system(size: 12, weight: .medium)).foregroundColor(RT.ink3)
                    }
                }
                .onTapGesture { d.copy(e.text) }
                .contextMenu {
                    Button("Copy") { d.copy(e.text) }
                    Button("Polish this") { router.polish(e.text) }
                    ShareLink(item: e.text)
                    Button("Delete", role: .destructive) { d.delete(e) }
                }
            }
            Text("Tap one to copy it. Press and hold for more.").font(.system(size: 12, weight: .medium)).foregroundColor(RT.ink3)
        }
    }
}
