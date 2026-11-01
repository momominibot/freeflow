import AppKit
import AVFoundation
import ApplicationServices

let args = CommandLine.arguments

// FreeFlow --selftest file.wav [language]: transcribe a file on a spare port and print the result.
if let i = args.firstIndex(of: "--selftest"), i + 1 < args.count {
    let server = WhisperServer(port: 8179)
    server.start()
    Vocabulary.ensureFile()
    let vocab = Vocabulary.load()
    let started = Date()
    let done = DispatchSemaphore(value: 0)
    var output = ""
    server.transcribe(URL(fileURLWithPath: args[i + 1]), language: i + 2 < args.count ? args[i + 2] : "en",
                      prompt: vocab.prompt) { result in
        switch result {
        case .success(let raw):
            output = "RAW:   \(raw.trimmingCharacters(in: .whitespacesAndNewlines))\n"
                + "CLEAN: \(TextCleaner.clean(raw, removeFillers: true, vocab: vocab, quiet: false))"
        case .failure(let error):
            output = "ERROR: \(error.localizedDescription)"
        }
        done.signal()
    }
    done.wait()
    print(output)
    print(String(format: "SECONDS (including model load): %.2f", Date().timeIntervalSince(started)))
    server.stop()
    exit(0)
}

// FreeFlow --status: what macOS has granted this app, and whether the speech engine is in place.
if args.contains("--status") {
    let mic = ["notDetermined", "restricted", "denied", "authorized"][AVCaptureDevice.authorizationStatus(for: .audio).rawValue]
    print("accessibility (typing into apps): \(AXIsProcessTrusted() ? "granted" : "NOT granted")")
    print("microphone: \(mic)")
    print("speech engine: \(WhisperServer.binaryPath ?? "MISSING")")
    print("speech model: \(FileManager.default.fileExists(atPath: Paths.model.path) ? "present" : "MISSING")")
    exit(0)
}

// FreeFlow --debug-post down|up: press or release the talk key in the running app (debugTriggers must be on).
if let i = args.firstIndex(of: "--debug-post"), i + 1 < args.count {
    DistributedNotificationCenter.default().postNotificationName(
        Notification.Name("com.momominibot.freeflow.debug"), object: args[i + 1], userInfo: nil, deliverImmediately: true)
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
