import SwiftUI

@main
struct FreeFlowPhoneApp: App {
    @StateObject private var dictation = Dictation()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(dictation)
                .task { await dictation.start() }
        }
    }
}
