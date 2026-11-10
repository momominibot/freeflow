import SwiftUI

@main
struct FreeFlowPhoneApp: App {
    @StateObject private var dictation = Dictation()
    @StateObject private var router = Router()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(dictation)
                .environmentObject(router)
                .task { await dictation.start() }
        }
    }
}
