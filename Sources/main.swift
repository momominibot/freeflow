import AppKit
import AVFoundation
import ApplicationServices

let args = CommandLine.arguments

// FreeFlow --selftest file.wav [language]: transcribe a file on a spare port and print the result.
if let i = args.firstIndex(of: "--selftest"), i + 1 < args.count {
    let server = WhisperServer(port: 8179)
    // Optional 3rd argument picks the engine: whisper (default) or qwen.
    server.switchTo(i + 3 < args.count ? (SpeechEngine(rawValue: args[i + 3]) ?? .whisper) : .whisper)
    let p = Personalization.load()
    let started = Date()
    let done = DispatchSemaphore(value: 0)
    var output = ""
    let testLang = i + 2 < args.count ? args[i + 2] : "en"
    server.transcribe(URL(fileURLWithPath: args[i + 1]), language: testLang,
                      prompt: testLang == "zh-en" ? p.vocab.promptMixed : p.vocab.prompt) { result in
        switch result {
        case .success(let raw):
            let light = TextCleaner.clean(raw, removeFillers: true, vocab: p.vocab, quiet: false)
            output = "RAW:   \(raw.trimmingCharacters(in: .whitespacesAndNewlines))\n"
                + "LIGHT: \(light)\n"
                + "SNIPS: \(Snippet.apply(p.snippets, to: light))"
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

// FreeFlow --test-ai "some dictated text" [formal|casual|neutral|code]: run the AI clean-up once and time it.
if let i = args.firstIndex(of: "--test-ai"), i + 1 < args.count {
    let style = i + 2 < args.count ? (Style(rawValue: args[i + 2]) ?? .neutral) : .neutral
    let ai = Rewriter.shared
    guard ai.isAvailable(force: true) else { print("Ollama not reachable or model \(ai.model) missing"); exit(1) }
    let done = DispatchSemaphore(value: 0)
    let started = Date()
    ai.cleanup(args[i + 1], style: style, fallback: args[i + 1]) { text, used in
        print(used ? "AI:    \(text)" : "FALLBACK: \(text)  (\(ai.lastError ?? "no error"))")
        print(String(format: "SECONDS: %.2f", Date().timeIntervalSince(started)))
        done.signal()
    }
    done.wait()
    exit(0)
}

// FreeFlow --test: unit checks for the text pipeline. Exit code 1 on any failure.
if args.contains("--test") {
    var fails = 0
    func check(_ name: String, _ got: String, _ want: String) {
        if got == want { print("ok    \(name)") } else { fails += 1; print("FAIL  \(name)\n      got:  \(got.debugDescription)\n      want: \(want.debugDescription)") }
    }
    func check(_ name: String, _ cond: Bool) {
        if cond { print("ok    \(name)") } else { fails += 1; print("FAIL  \(name)") }
    }

    let vocab = Vocabulary.parse("Ranklore\nRank Lore => Ranklore\nMS => EMIS\n")
    check("filler removal", TextCleaner.clean("So, um, we should, uh, ship it.", removeFillers: true, vocab: vocab, quiet: false), "So we should ship it.")
    let c0 = SpokenCommands.parse("Is that okay? Press enter.")
    check("question mark kept before press enter", c0.text, "Is that okay?")
    check("dictionary swap", TextCleaner.clean("Call Rank Lore about MS.", removeFillers: true, vocab: vocab, quiet: false), "Call Ranklore about EMIS.")
    check("hallucination on silence", TextCleaner.clean("Thank you.", removeFillers: true, vocab: vocab, quiet: true), "")
    check("raw level keeps fillers", TextCleaner.raw("um so yeah", quiet: false), "um so yeah")

    var snippets: [Snippet] = []
    Snippet.parse("my email address => hello@ranklore.ai\nsign off => Best,\\nJamie\nmy email address => duplicate ignored\n", into: &snippets)
    check("snippet count, duplicate dropped", snippets.count == 2)
    check("whole dictation is a cue", Snippet.apply(snippets, to: "My email address."), "hello@ranklore.ai")
    check("cue inside a sentence", Snippet.apply(snippets, to: "You can reach me at my email address, thanks."), "You can reach me at hello@ranklore.ai, thanks.")
    check("multi-line expansion", Snippet.apply(snippets, to: "sign off"), "Best,\nJamie")
    check("no partial-word trigger", Snippet.apply(snippets, to: "Please sign offline forms."), "Please sign offline forms.")

    check("team entry does not override personal", {
        var list: [Snippet] = []
        Snippet.parse("my email address => personal@x.com", into: &list)
        Snippet.parse("my email address => team@x.com\nteam cue => team text", into: &list)
        return list.count == 2 && list[0].expansion == "personal@x.com"
    }())

    let c1 = SpokenCommands.parse("Sounds good, see you at 3. Press enter")
    check("press enter stripped", c1.text, "Sounds good, see you at 3.")
    check("press enter flag", c1.pressEnter)
    let c2 = SpokenCommands.parse("First point. New paragraph. Second point.")
    check("new paragraph", c2.text, "First point.\n\nSecond point.")
    let c3 = SpokenCommands.parse("We need a new line of products.")
    check("new line mid-sentence untouched", c3.text, "We need a new line of products.")
    check("no false enter", !SpokenCommands.parse("Do not press enter yet, wait for me.").pressEnter)
    let c4 = SpokenCommands.parse("Type your password and then press enter.")
    check("press enter inside a sentence is text", c4.text == "Type your password and then press enter." && !c4.pressEnter)
    check("press enter after a comma", SpokenCommands.parse("ok see you there, press enter").text == "ok see you there")
    check("new paragraph inside a sentence is text", SpokenCommands.parse("We need a new paragraph here.").text, "We need a new paragraph here.")
    check("ai guard: swapped amounts rejected", !Rewriter.looksLikeSameDictation(original: "pay alice 50k and bob 75k for the ranklore work", rewritten: "Pay Alice 75K and Bob 50K for the Ranklore work."))
    check("ai guard: invented number rejected", !Rewriter.looksLikeSameDictation(original: "send the ranklore invoice to alice by friday", rewritten: "Send the Ranklore invoice to Alice by Friday at 3pm."))
    check("ai guard: thousands separator ok", Rewriter.looksLikeSameDictation(original: "the ranklore budget is 75000 for alice", rewritten: "The Ranklore budget is 75,000 for Alice."))

    check("ai guard: answer rejected", !Rewriter.looksLikeSameDictation(original: "what is the capital of france", rewritten: "Paris."))
    check("ai guard: self-correction accepted", Rewriter.looksLikeSameDictation(original: "budget fifty k actually make that seventy five k for ranklore", rewritten: "Budget seventy five k for Ranklore."))
    let mixedIn = "嗯 我们明天要 send the invoice 给 Ranklore 然后呢 update 一下 EMIS 的 Shopify theme"
    check("ai guard: Chinese kept, accepted", Rewriter.looksLikeSameDictation(original: mixedIn, rewritten: "我们明天要 send the invoice 给 Ranklore，然后 update 一下 EMIS 的 Shopify theme。"))
    check("ai guard: translated to English rejected", !Rewriter.looksLikeSameDictation(original: mixedIn, rewritten: "We will send the invoice to Ranklore tomorrow and update the EMIS Shopify theme."))
    check("ai guard: English turned into Chinese rejected", !Rewriter.looksLikeSameDictation(original: "send the ranklore invoice to alice", rewritten: "把 Ranklore 的 invoice 发给 Alice。"))
    check("ai guard: Chinese reworded away rejected", !Rewriter.looksLikeSameDictation(original: "今天 meeting 改到四点 记得 book 会议室", rewritten: "Meeting moved to four, book the room."))
    check("ai guard: pure Chinese cleanup accepted", Rewriter.looksLikeSameDictation(original: "嗯 明天下午三点开会 记得带电脑", rewritten: "明天下午三点开会，记得带电脑。"))
    check("language: mixed option", Language(rawValue: "zh-en") == .mixed && Vocabulary.parse("Ranklore\nEMIS+\n").promptMixed == "词汇：Ranklore, EMIS+。")
    check("ai guard: empty rejected", !Rewriter.looksLikeSameDictation(original: "hello there team", rewritten: ""))
    check("ai guard: preamble rejected", !Rewriter.looksLikeSameDictation(original: "send the invoice on monday", rewritten: "Here is the cleaned text: send the invoice on Monday."))
    check("tidy strips quotes and fences", Rewriter.tidy("```\n\"Hello.\"\n```"), "Hello.")

    let styles = Personalization.parseStyles("com.apple.Notes => casual\ncom.apple.Notes => formal\nbad.id => nonsense\n")
    check("styles: first wins, bad value ignored", styles == ["com.apple.Notes": .casual])
    var p = Personalization()
    p.styles = styles
    check("style lookup personal", p.style(for: "com.apple.Notes") == .casual)
    check("style lookup built-in", p.style(for: "com.apple.mail") == .formal)
    check("style lookup unknown", p.style(for: "x.y.z") == .neutral)
    check("style lookup nil app", p.style(for: nil) == .neutral)

    // Saved recordings: pairs of .wav + .json, newest kept, same-second takes do not overwrite each other.
    let tdir = FileManager.default.temporaryDirectory.appendingPathComponent("ff-takes-\(UUID().uuidString)")
    let fake = FileManager.default.temporaryDirectory.appendingPathComponent("ff-fake-\(UUID().uuidString).wav")
    try? Data([1, 2, 3]).write(to: fake)
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    for k in 0..<5 {
        TakeStore.keep(fake, engine: "qwen", heard: "heard \(k)", final: "final \(k)", mode: "light",
                       in: tdir, limit: 3, now: t0.addingTimeInterval(Double(k)))
    }
    TakeStore.keep(fake, engine: "qwen", heard: "same second", final: "x", mode: "light", in: tdir, limit: 3, now: t0.addingTimeInterval(4))
    let kept = ((try? FileManager.default.contentsOfDirectory(atPath: tdir.path)) ?? [])
    check("takes: newest 3 kept as wav+json pairs", kept.filter { $0.hasSuffix(".wav") }.count == 3 && kept.filter { $0.hasSuffix(".json") }.count == 3)
    let metaFile = kept.filter { $0.hasSuffix(".json") }.sorted().last ?? ""
    let meta = (try? JSONSerialization.jsonObject(with: Data(contentsOf: tdir.appendingPathComponent(metaFile)))) as? [String: Any]
    check("takes: sidecar holds engine and what was heard", (meta?["engine"] as? String) == "qwen" && (meta?["heard"] as? String) == "same second")
    try? FileManager.default.removeItem(at: tdir)
    try? FileManager.default.removeItem(at: fake)
    check("engine setting parses", SpeechEngine(rawValue: "qwen") == .qwen && SpeechEngine(rawValue: "nonsense") == nil)

    print(fails == 0 ? "ALL PASSED" : "\(fails) FAILED")
    exit(fails == 0 ? 0 : 1)
}

// FreeFlow --status: what macOS has granted this app, and whether the speech engine is in place.
if args.contains("--status") {
    let mic = ["notDetermined", "restricted", "denied", "authorized"][AVCaptureDevice.authorizationStatus(for: .audio).rawValue]
    print("accessibility (typing into apps): \(AXIsProcessTrusted() ? "granted" : "NOT granted")")
    print("microphone: \(mic)")
    print("speech engine: \(WhisperServer.binaryPath ?? "MISSING")")
    print("speech model: \(FileManager.default.fileExists(atPath: Paths.model.path) ? "present" : "MISSING")")
    print("local AI (Ollama, \(Settings.shared.aiModel)): \(Rewriter.shared.isAvailable(force: true) ? "ready" : "not running")")
    print("team folder: \(Settings.shared.teamFolder ?? "none")")
    exit(0)
}

// FreeFlow --debug-post down|up|command|lock: drive the running app (debugTriggers must be on).
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
