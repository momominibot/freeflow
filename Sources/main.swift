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
    // choices: a custom folder holding other files, an age limit, and delete-all that never touches what FreeFlow did not write
    let cdir = FileManager.default.temporaryDirectory.appendingPathComponent("ff-takes-custom-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: cdir, withIntermediateDirectories: true)
    try? Data([9]).write(to: cdir.appendingPathComponent("my-own-memo.wav"))
    try? Data([9]).write(to: cdir.appendingPathComponent("notes.json"))
    let day: Double = 86_400
    TakeStore.keep(fake, engine: "qwen", heard: "old", final: "old", mode: "light", in: cdir, limit: 50, now: t0.addingTimeInterval(-10 * day))
    TakeStore.keep(fake, engine: "qwen", heard: "recent", final: "recent", mode: "light", in: cdir, limit: 50, maxAgeDays: 7, now: t0)
    let agedLeft = ((try? FileManager.default.contentsOfDirectory(atPath: cdir.path)) ?? []).filter { TakeStore.isTakeFile($0) && $0.hasSuffix(".wav") }
    check("takes: nothing older than the chosen days is kept", agedLeft.count == 1)
    TakeStore.keep(fake, engine: "qwen", heard: "x", final: "x", mode: "light", in: cdir, limit: 1, now: t0.addingTimeInterval(60))
    let ownLeft = ((try? FileManager.default.contentsOfDirectory(atPath: cdir.path)) ?? []).filter { !TakeStore.isTakeFile($0) }.sorted()
    check("takes: a folder you chose keeps your own files, even past the count", ownLeft == ["my-own-memo.wav", "notes.json"])
    let removed = TakeStore.deleteAll(in: cdir)
    let afterDelete = ((try? FileManager.default.contentsOfDirectory(atPath: cdir.path)) ?? []).sorted()
    check("takes: delete removes FreeFlow's recordings only and leaves the folder and your files", removed == 1 && afterDelete == ["my-own-memo.wav", "notes.json"])
    check("takes: only FreeFlow's own file names count", TakeStore.isTakeFile("20261109-185331-01-whisper.wav") && TakeStore.isTakeFile("20261109-185331-01-qwen.json")
          && !TakeStore.isTakeFile("meeting.wav") && !TakeStore.isTakeFile("20261109-185331-01-qwen.mp3") && !TakeStore.isTakeFile("../20261109-185331-01-q.wav"))
    try? FileManager.default.removeItem(at: cdir)
    try? FileManager.default.removeItem(at: fake)
    check("engine setting parses", SpeechEngine(rawValue: "qwen") == .qwen && SpeechEngine(rawValue: "nonsense") == nil)

    // Learning from corrections.
    func P(_ w: String, _ r: String) -> Learning.Pair { Learning.Pair(wrong: w, right: r) }
    check("learn: tokens keep EMIS+ and reinstate.sg whole", Learning.tokenize("Call EMIS+ at reinstate.sg, ok.").map { $0.text } == ["Call", "EMIS+", "at", "reinstate.sg", "ok"])
    check("learn: tokens split Chinese per character", Learning.tokenize("我们 send 给 Ranklore的").map { $0.text } == ["我", "们", "send", "给", "Ranklore", "的"])
    check("learn: spacing fix", Learning.pairs(original: "Call Rank Lore about the plan", edited: "Call Ranklore about the plan") == [P("Rank Lore", "Ranklore")])
    check("learn: misheard word", Learning.pairs(original: "Please open the Ranklor dashboard today", edited: "Please open the Ranklore dashboard today") == [P("Ranklor", "Ranklore")])
    check("learn: acronym case", Learning.pairs(original: "we sell through emis every day", edited: "we sell through EMIS every day") == [P("emis", "EMIS")])
    check("learn: sentence-start capital is not a fix", Learning.pairs(original: "we should go now", edited: "We should go now").isEmpty)
    check("learn: number change is content, not a slip", Learning.pairs(original: "pay alice 50k today", edited: "pay alice 75k today").isEmpty)
    check("learn: synonym is a rewrite, not a slip", Learning.pairs(original: "please send the report today", edited: "please share the report today").isEmpty)
    check("learn: rewrite of most of the text is ignored", Learning.pairs(original: "we should go there tomorrow morning for lunch", edited: "let us visit the office next week instead").isEmpty)
    check("learn: untouched text learns nothing", Learning.pairs(original: "nothing changed here", edited: "nothing changed here").isEmpty)
    check("learn: added words alone learn nothing", Learning.pairs(original: "see you at the office", edited: "see you at the office tomorrow morning").isEmpty)
    check("learn: Chinese fix takes a neighbour so it is not one lone character", Learning.pairs(original: "我们明天去开会", edited: "我们明天去开汇") == [P("开会", "开汇")])
    check("learn: two fixes in one sentence", Learning.pairs(original: "Rank Lore sells on Shopfy every day", edited: "Ranklore sells on Shopify every day") == [P("Rank Lore", "Ranklore"), P("Shopfy", "Shopify")])

    let t0s = "2026-11-08"
    var lf = LearnedFile()
    let common: (String) -> Bool = { $0.lowercased() == "their" }
    lf.record([P("Ranklor", "Ranklore")], today: t0s)
    check("learn: a made-up word swaps after one fix", lf.activeFixes(isCommon: common).map { $0.wrong } == ["Ranklor"])
    lf.record([P("their", "there")], today: t0s)
    check("learn: a real word needs three fixes", lf.activeFixes(isCommon: common).map { $0.wrong } == ["Ranklor"])
    lf.record([P("their", "there")], today: t0s); lf.record([P("their", "there")], today: t0s)
    check("learn: three fixes switch a real word on", Set(lf.activeFixes(isCommon: common).map { $0.wrong }) == ["Ranklor", "their"])
    lf.record([P("Rank Lore", "Ranklore")], today: t0s)
    check("learn: a phrase needs two fixes", !lf.activeFixes(isCommon: common).contains { $0.wrong == "Rank Lore" })
    lf.record([P("Rank Lore", "Ranklore")], today: t0s)
    check("learn: two fixes switch a phrase on", lf.activeFixes(isCommon: common).contains { $0.wrong == "Rank Lore" })
    var tie = LearnedFile()
    tie.record([P("Kobi", "Kobe")], today: t0s); tie.record([P("Kobi", "Cobie")], today: t0s)
    check("learn: two equal answers for one word apply neither", tie.activeFixes(isCommon: { _ in false }).isEmpty)
    var grow = LearnedFile()
    grow.record([P("Kobi", "Kobi Wong")], weight: 3, today: t0s)
    check("learn: a swap that would grow its own result is never applied", grow.activeFixes(isCommon: { _ in false }).isEmpty)
    let round = LearnedFile.parse(lf.render())
    check("learn: learned.txt round-trips", round.fixes.count == lf.fixes.count && round.terms.count == lf.terms.count
        && round.terms.first(where: { $0.term == "Ranklore" })?.votes == lf.terms.first(where: { $0.term == "Ranklore" })?.votes)
    var old = LearnedFile(); old.record([P("Ranklor", "Ranklore")], today: "2025-01-01"); old.record([P("Shopfy", "Shopify")], weight: 3, today: "2025-01-01")
    old.prune(today: "2026-11-08")
    check("learn: single old fixes fade, repeated ones stay", old.fixes.map { $0.wrong } == ["Shopfy"])

    var lv = Vocabulary.parse("Ranklore\nMS => EMIS\n")
    var lfv = LearnedFile()
    lfv.record([P("MS", "Em Is"), P("Shopfy", "Shopify")], weight: 3, today: t0s)
    lv.addLearned(lfv, isCommon: { _ in false })
    check("learn: your own dictionary wins over a learned swap", lv.apply("MS and Shopfy") == "EMIS and Shopify")
    check("learn: learned words join the prompt", lv.prompt.contains("Shopify") && lv.prompt.contains("Ranklore"))
    var big = Vocabulary()
    big.terms = (1...80).map { "word\($0)" }
    big.learnedTerms = (1...30).map { "learned\($0)" }
    check("learn: prompt stays at 60 words and keeps room for learned ones", big.promptTerms.count == 60 && big.promptTerms.contains("learned1") && big.promptTerms.contains("word1"))

    let field = "Hi team.\nCall Rank Lore about the plan today.\nThanks"
    let typed = "Call Rank Lore about the plan today."
    let startAt = (field as NSString).range(of: typed).location
    let anch = Learning.anchors(in: field, start: startAt, length: (typed as NSString).length)
    let fixedField = "Hi team.\nCall Ranklore about the plan today.\nThanks"
    check("learn: finds the typed text again after an edit", anch.flatMap { Learning.span($0, in: fixedField) } == "Call Ranklore about the plan today.")
    check("learn: finds it when text was added above", anch.flatMap { Learning.span($0, in: "Subject line\n" + field) } == typed)
    check("learn: gives up when its surroundings were rewritten", anch.flatMap { Learning.span($0, in: "completely different text") } == nil)

    // Meeting notes: which calls count, when to offer and stop, and what the saved file looks like.
    check("meeting: Zoom app", MeetingRules.classify(bundleId: "us.zoom.xos", titles: []) == "Zoom")
    check("meeting: Teams app", MeetingRules.classify(bundleId: "com.microsoft.teams2", titles: []) == "Microsoft Teams")
    check("meeting: Chrome on a Meet tab", MeetingRules.classify(bundleId: "com.google.Chrome", titles: ["Inbox - Gmail", "Meet - abc-defg-hij - Google Chrome"]) == "Google Meet")
    check("meeting: Chrome on a Teams tab", MeetingRules.classify(bundleId: "com.google.Chrome", titles: ["Calendar | Microsoft Teams"]) == "Microsoft Teams")
    check("meeting: Chrome on an ordinary page is not a call", MeetingRules.classify(bundleId: "com.google.Chrome", titles: ["Meet the team - Acme", "YouTube"]) == nil)
    check("meeting: Chrome helper still counts as Chrome", MeetingRules.classify(bundleId: "com.google.Chrome.helper", titles: ["Meet - abc-defg-hij"]) == "Google Meet")
    check("meeting: a notes app is not a call", MeetingRules.classify(bundleId: "com.apple.Notes", titles: ["Zoom notes"]) == nil)

    var brain = MeetingBrain()
    check("meeting: one sighting is not enough", brain.tick(inCall: true, mode: .auto) == nil)
    check("meeting: second sighting offers", brain.tick(inCall: true, mode: .auto) == .offer)
    brain.declinedByUser()
    check("meeting: declined call is not offered again", brain.tick(inCall: true, mode: .auto) == nil && brain.tick(inCall: true, mode: .auto) == nil)
    _ = brain.tick(inCall: false, mode: .auto)
    check("meeting: next call is offered again", brain.tick(inCall: true, mode: .auto) == nil && brain.tick(inCall: true, mode: .auto) == .offer)
    var off = MeetingBrain()
    check("meeting: off never offers", (0..<5).allSatisfy { _ in off.tick(inCall: true, mode: .off) == nil })
    var rec = MeetingBrain()
    rec.started(auto: true)
    var stopped = false
    for i in 0..<MeetingBrain.ticksToStop { if rec.tick(inCall: false, mode: .auto) == .stop { stopped = (i == MeetingBrain.ticksToStop - 1) } }
    check("meeting: stops after about a minute without the call", stopped)
    var rec2 = MeetingBrain()
    rec2.started(auto: true)
    for _ in 0..<(MeetingBrain.ticksToStop - 1) { _ = rec2.tick(inCall: false, mode: .auto) }
    _ = rec2.tick(inCall: true, mode: .auto)
    check("meeting: a short drop in the microphone does not stop notes", rec2.tick(inCall: false, mode: .auto) == nil)
    var manual = MeetingBrain()
    manual.started(auto: false)
    check("meeting: notes you started in a room do not end by themselves", (0..<40).allSatisfy { _ in manual.tick(inCall: false, mode: .auto) == nil })
    var cancelOffer = MeetingBrain()
    _ = cancelOffer.tick(inCall: true, mode: .ask)
    _ = cancelOffer.tick(inCall: true, mode: .ask)
    var cancelled = false
    for _ in 0..<MeetingBrain.ticksToCancelOffer { if cancelOffer.tick(inCall: false, mode: .ask) == .cancelOffer { cancelled = true } }
    check("meeting: card goes away when the call ends before you answer", cancelled)

    let meetStart = Date(timeIntervalSince1970: 1_800_000_000)
    let e1 = [MeetingFile.Entry(index: 0, isYou: false, text: "Can we move the launch to Thursday?"),
              MeetingFile.Entry(index: 0, isYou: true, text: "can we move the launch to thursday"),
              MeetingFile.Entry(index: 1, isYou: true, text: "Yes, Thursday works for me."),
              MeetingFile.Entry(index: 1, isYou: false, text: "Great, I will tell the team.")]
    let doc = MeetingFile.render(app: "Zoom", start: meetStart, seconds: 125, entries: e1, chunkSeconds: 30, bothSides: true, recording: false)
    check("meeting file: echo of the others is left out of You", !doc.contains("You: can we move"))
    check("meeting file: both voices kept when they differ", doc.contains("[00:30] Others: Great, I will tell the team.") && doc.contains("[00:30] You: Yes, Thursday works for me."))
    check("meeting file: others come before you in a piece", (doc.range(of: "[00:30] Others")?.lowerBound ?? doc.endIndex) < (doc.range(of: "[00:30] You")?.lowerBound ?? doc.startIndex))
    let parsed = MeetingFile.parse(doc, url: URL(fileURLWithPath: "/tmp/x.md"))
    check("meeting file: reads back app, length and sides", parsed?.app == "Zoom" && parsed?.seconds == 125 && parsed?.bothSides == true && parsed?.recording == false)
    check("meeting file: counts the spoken words only", parsed?.words == TextCleaner.wordCount("Can we move the launch to Thursday? Yes, Thursday works for me. Great, I will tell the team."))
    check("meeting file: name is sortable and safe", MeetingFile.fileName(app: "Slack huddle", start: meetStart).hasSuffix("-Slack-huddle.md"))

    check("overlap: repeated words at the start of the next piece are dropped",
          MeetingFile.trimOverlap(previous: "Maria will share the support rota on Monday and Sam", next: "on Monday and Sam will check the rota") == "will check the rota")
    check("overlap: nothing is dropped when the pieces do not repeat",
          MeetingFile.trimOverlap(previous: "We keep the budget", next: "Sam will check the rota") == "Sam will check the rota")
    check("overlap: punctuation and case do not matter",
          MeetingFile.trimOverlap(previous: "I will send the plan, by Friday.", next: "by friday morning please") == "morning please")
    check("overlap: one repeated word is not enough to cut anything",
          MeetingFile.trimOverlap(previous: "the launch is on Thursday", next: "Thursday we meet again") == "Thursday we meet again")

    // Modes and transforms
    var mf = ModesFile(modes: [CustomMode(id: "m1", name: "Client emails", prompt: "Warm and brief.", apps: ["com.apple.mail"]),
                               CustomMode(id: "m2", name: "Casual", prompt: "Relaxed, short sentences.", apps: [])],
                       transforms: ModeStore.seedTransforms, activeMode: nil)
    check("modes: an app's own mode is used", ModeStore.tone(for: "com.apple.mail", in: mf)?.id == "m1")
    check("modes: no mode for an app with none", ModeStore.tone(for: "com.apple.Notes", in: mf) == nil)
    mf.activeMode = "m2"
    check("modes: the one switched on is used elsewhere", ModeStore.tone(for: "com.apple.Notes", in: mf)?.id == "m2")
    check("modes: an app's own mode beats the one switched on", ModeStore.tone(for: "com.apple.mail", in: mf)?.id == "m1")
    mf.modes[0].prompt = "   "
    check("modes: an empty instruction is ignored", ModeStore.tone(for: "com.apple.mail", in: mf)?.id == "m2")
    let modesURL = FileManager.default.temporaryDirectory.appendingPathComponent("ff-modes-test-\(UUID().uuidString).json")
    ModeStore.save(mf, url: modesURL)
    check("modes: saved file reads back the same", ModeStore.load(url: modesURL) == mf)
    try? FileManager.default.removeItem(at: modesURL)
    check("modes: a new install starts with the ready-made transforms", ModeStore.load(url: modesURL).transforms.count == 5)

    // Summaries and recordings from files
    var longLines: [String] = []
    for i in 0..<10 { longLines.append("[\(String(format: "%02d", i)):00] " + Array(repeating: "word", count: 500).joined(separator: " ")) }
    let longParts = Summarizer.parts(longLines.joined(separator: "\n"), maxWords: 2200)
    check("summary: a long transcript is split into parts", longParts.count == 3)
    check("summary: no line is lost or cut when splitting", longParts.joined(separator: "\n") == longLines.joined(separator: "\n"))
    check("summary: a short transcript stays in one part", Summarizer.parts("[00:00] Hello there.\n[00:30] Fine.").count == 1)
    check("summary: tidy drops long dashes and a lead-in sentence", Summarizer.tidy("Here you go\n## Summary\n- a — b") == "## Summary\n- a, b")
    let sumBase = MeetingFile.render(app: "Zoom", start: meetStart, seconds: 125, entries: e1, chunkSeconds: 30, bothSides: true, recording: false)
    let sumWith = MeetingFile.withSummary("## Summary\n- Launch moves to Thursday", in: sumBase)
    check("summary block: read back", MeetingFile.summary(in: sumWith) == "## Summary\n- Launch moves to Thursday")
    check("summary block: transcript untouched", MeetingFile.transcriptLines(sumWith) == MeetingFile.transcriptLines(sumBase))
    check("summary block: file still reads as a note, summary included", MeetingFile.parse(sumWith, url: URL(fileURLWithPath: "/tmp/x.md"))?.summary?.contains("Thursday") == true)
    check("summary block: words are not counted from the summary", MeetingFile.parse(sumWith, url: URL(fileURLWithPath: "/tmp/x.md"))?.words == MeetingFile.parse(sumBase, url: URL(fileURLWithPath: "/tmp/x.md"))?.words)
    let sumAgain = MeetingFile.withSummary("## Summary\n- New", in: sumWith)
    check("summary block: a new summary replaces the old", MeetingFile.summary(in: sumAgain) == "## Summary\n- New" && !sumAgain.contains("Launch moves"))
    check("summary block: removing it restores the file exactly", MeetingFile.withSummary(nil, in: sumAgain) == sumBase)
    let fileDoc = MeetingFile.render(app: "interview", start: meetStart, seconds: 180,
                                     entries: [MeetingFile.Entry(index: 0, isYou: false, text: "Hello there."), MeetingFile.Entry(index: 1, isYou: false, text: "Second minute text.")],
                                     chunkSeconds: 60, bothSides: false, recording: false, kind: "file")
    let fileNote = MeetingFile.parse(fileDoc, url: URL(fileURLWithPath: "/tmp/f.md"))
    check("recording note: kind and word count", fileNote?.kind == "file" && fileNote?.words == 5)
    check("recording note: minute stamps and no speaker labels", fileDoc.contains("[01:00] Second minute text.") && !fileDoc.contains("Others:"))

    // Scratchpad: only the spoken openers count, and the rest is kept whole.
    check("scratchpad: note to self with a comma", ScratchStore.noteToSelf("Note to self, buy milk and eggs.") ?? "nil", "Buy milk and eggs.")
    check("scratchpad: colon and lower case", ScratchStore.noteToSelf("note to self: call mum at 5") ?? "nil", "Call mum at 5")
    check("scratchpad: add to my scratchpad", ScratchStore.noteToSelf("Add this to my scratchpad, the idea about pricing.") ?? "nil", "The idea about pricing.")
    check("scratchpad: an ordinary sentence is left alone", ScratchStore.noteToSelf("My scratchpad is full of notes to self.") == nil)
    check("scratchpad: the opener alone is not a note", ScratchStore.noteToSelf("Note to self.") == nil)
    check("scratchpad: a note keeps a second line", ScratchStore.noteToSelf("Note to self, first line.\nSecond line.") ?? "nil", "First line.\nSecond line.")
    let scratchDir = FileManager.default.temporaryDirectory.appendingPathComponent("freeflow-scratch-\(UUID().uuidString)", isDirectory: true)
    let first = ScratchStore.create(text: "  hello  ", in: scratchDir, now: Date(timeIntervalSince1970: 1_000_000))
    let second = ScratchStore.create(text: "second", in: scratchDir, now: Date(timeIntervalSince1970: 1_000_000))
    check("scratchpad: two notes in the same second keep both", ScratchStore.list(in: scratchDir).count == 2 && first?.id != second?.id)
    check("scratchpad: text is trimmed on save", first?.text == "hello")
    if let f = first { ScratchStore.update(f, text: "   "); }
    check("scratchpad: saving empty text deletes the note", ScratchStore.list(in: scratchDir).count == 1)
    check("scratchpad: blank notes are not created", ScratchStore.create(text: " \n ", in: scratchDir) == nil)
    try? FileManager.default.removeItem(at: scratchDir)

    // Insights
    check("insights: 1,500 words saves about 28 minutes", InsightMath.timeSavedMinutes(words: 1500) == 28)
    check("insights: nothing said, nothing saved", InsightMath.timeSavedMinutes(words: 0) == 0)
    check("insights: minutes read as hours past 60", InsightMath.hoursAndMinutes(125), "2 h 5 min")
    let ins0 = Date(timeIntervalSince1970: 1_700_000_000)
    let insCal = Calendar(identifier: .gregorian)
    let insEntries = [HistoryEntry(id: 1, date: ins0, app: "a", mode: "light", text: "one two three"),
                      HistoryEntry(id: 2, date: ins0, app: "a", mode: "command", text: "shorter please now"),
                      HistoryEntry(id: 3, date: ins0.addingTimeInterval(-86_400), app: "a", mode: "light", text: "four five")]
    let insDays = HistoryReader.dailyWords(insEntries, days: 3, now: ins0, calendar: insCal)
    check("insights: three days, oldest first", insDays.count == 3 && insDays[0].words == 0)
    check("insights: yesterday counts its own words", insDays[1].words == 2)
    check("insights: commands are not dictation", insDays[2].words == 3)

    // Importing lists from other apps
    check("import: plain text lines", ListImport.dictionaryLines(from: "Ranklore\n# note\n\nEMIS\n", ext: "txt") == ["Ranklore", "EMIS"])
    check("import: one comma line is a list", ListImport.dictionaryLines(from: "Ranklore, EMIS, Ovaire", ext: "txt") == ["Ranklore", "EMIS", "Ovaire"])
    check("import: csv with a header and a misspelling column", ListImport.dictionaryLines(from: "word,replacement\nOvaire,\nRank Lore,Ranklore\n", ext: "csv") == ["Ovaire", "Rank Lore => Ranklore"])
    check("import: csv fields keep quoted commas", ListImport.csvFields("a,\"b, c\",d") == ["a", "b, c", "d"])
    check("import: json strings and objects", ListImport.dictionaryLines(from: "[\"Ovaire\", {\"word\": \"Rank Lore\", \"replacement\": \"Ranklore\"}]", ext: "json") == ["Ovaire", "Rank Lore => Ranklore"])
    check("import: json inside a words key", ListImport.dictionaryLines(from: "{\"words\": [\"EMIS\"]}", ext: "json") == ["EMIS"])
    check("import: snippets from csv", ListImport.snippetLines(from: "cue,text\nmy email,\"a@b.com\"\n", ext: "csv") == ["my email => a@b.com"])
    check("import: snippets from json", ListImport.snippetLines(from: "[{\"trigger\":\"sig\",\"text\":\"Best,\\nMomo\"}]", ext: "json") == ["sig => Best,\\nMomo"])
    check("import: plain snippets keep only cue pairs", ListImport.snippetLines(from: "hello\nmy email => a@b.com\n", ext: "txt") == ["my email => a@b.com"])
    check("import: duplicates are skipped without case", ListImport.fresh(["EMIS", "emis", "Ovaire", "ovaire"], existing: ["Emis"]) == ["Ovaire"])
    let exportEntries = [HistoryEntry(id: 1, date: Date(timeIntervalSince1970: 1_700_000_000), app: "a", mode: "light", text: "Hello there.", raw: "hello there"),
                         HistoryEntry(id: 2, date: Date(timeIntervalSince1970: 1_700_000_100), app: "a", mode: "light", text: "Second one.")]
    check("export: markdown has the heading and both lines", HistoryExport.markdown(exportEntries).contains("# FreeFlow dictations") && HistoryExport.markdown(exportEntries).contains("Second one."))
    check("export: json keeps the original wording", HistoryExport.json(exportEntries).contains("\"original\" : \"hello there\""))
    check("export: plain text has one line per dictation", HistoryExport.plain(exportEntries).components(separatedBy: "\n").filter { !$0.isEmpty }.count == 2)
    let timed = (0..<3).map { HistoryEntry(id: $0, date: Date(), app: "a", mode: "light", text: "one two three four five six", raw: "", secs: 3) }
    check("wpm: 6 words in 3 seconds is 120", HistoryReader.wordsPerMinute(timed) == 120)
    check("wpm: too few timed dictations gives nothing", HistoryReader.wordsPerMinute(Array(timed.prefix(2))) == nil)

    // Workday: what is kept, what is left out, what is found, and what gets set up.
    do {
        func run(_ exe: String, _ args: [String]) -> (Int32, String) {
            let p = Process(); p.executableURL = URL(fileURLWithPath: exe); p.arguments = args
            let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
            do { try p.run() } catch { return (-1, "\(error)") }
            p.waitUntilExit()
            return (p.terminationStatus, String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "")
        }
        var utc = Calendar(identifier: .gregorian); utc.timeZone = TimeZone(identifier: "UTC")!
        let monday = utc.date(from: DateComponents(year: 2026, month: 11, day: 2))!          // a Monday
        func at(_ day: Int, _ h: Int, _ m: Int, _ s: Int = 0) -> Date { monday.addingTimeInterval(Double(day) * 86_400 + Double(h * 3600 + m * 60 + s)) }
        func seg(_ day: Int, _ h: Int, _ m: Int, secs: Int, _ bundle: String, _ name: String, _ title: String = "", idle: Bool = false, s: Int = 0) -> WorkSegment {
            WorkSegment(start: at(day, h, m, s), end: at(day, h, m, s).addingTimeInterval(Double(secs)), bundle: bundle, name: name, title: title, idle: idle)
        }

        // keeping private things out
        check("redact: an email address is swapped for a tag", Redact.title("Inbox - jamie@example.com - Mail"), "Inbox - <email> - Mail")
        check("redact: a link is swapped for a tag", Redact.title("see https://shop.example.com/admin?token=abc123 now"), "see <link> now")
        check("redact: a key is swapped for a tag", Redact.title("Key shpat_0123456789abcdef0123"), "Key <key>")
        check("redact: a long number is swapped for a tag", Redact.title("Card 4111 1111 1111 1111 saved"), "Card <number> saved")
        check("redact: ordinary words and short numbers stay", Redact.title("Orders (12) - Shopify admin"), "Orders (12) - Shopify admin")
        check("redact: a title is cut to 100 characters", Redact.title(String(repeating: "word ", count: 60)).count <= 100)
        check("redact: password managers are never recorded", Redact.skips(bundle: "com.1password.1password") && Redact.skips(bundle: "com.apple.keychainaccess") && !Redact.skips(bundle: "com.apple.Safari"))
        check("redact: private windows are hidden", Redact.hidden(title: "New Incognito Tab - Chrome", extra: []) && Redact.hidden(title: "Private Browsing", extra: []))
        check("redact: your own words hide a title", Redact.hidden(title: "Payroll June.xlsx", extra: ["payroll"]) && !Redact.hidden(title: "Plan.xlsx", extra: ["payroll"]))

        // samples become segments
        var b = SegmentBuilder()
        var closed: [WorkSegment] = []
        for (t, app, title, idle) in [(0, "A", "one", false), (5, "A", "one", false), (10, "A", "two", false), (15, "B", "x", false), (20, "B", "", true)] {
            if let c = b.observe(at: at(0, 9, 0, t), bundle: app, name: app, title: title, idle: idle) { closed.append(c) }
        }
        if let c = b.flush(at: at(0, 9, 0, 30)) { closed.append(c) }
        check("segments: five samples make four segments with the right lengths", closed.count == 4 && closed[0].seconds == 10 && closed[1].seconds == 5 && closed[2].seconds == 5 && closed[3].idle && closed[3].seconds == 10)

        // storing them
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ff-workday-test-\(getpid())", isDirectory: true)
        try? FileManager.default.removeItem(at: dir)
        let stored = seg(0, 9, 0, secs: 120, "com.apple.TextEdit", "TextEdit", "Notes")
        WorkdayStore.append(stored, in: dir)
        WorkdayStore.append(seg(0, 9, 5, secs: 0, "x", "x"), in: dir)          // too short to keep
        WorkdayStore.append(WorkSegment(start: Date().addingTimeInterval(-20 * 86_400), end: Date().addingTimeInterval(-20 * 86_400 + 60), bundle: "old", name: "Old", title: "", idle: false), in: dir)
        let back = WorkdayStore.load(in: dir)
        check("store: a segment survives writing and reading", back.contains(stored))
        check("store: a zero-length segment is not kept", !back.contains { $0.bundle == "x" })
        WorkdayStore.purge(in: dir)
        check("store: days older than 14 are deleted", !WorkdayStore.load(in: dir).contains { $0.bundle == "old" } && WorkdayStore.load(in: dir).contains(stored))
        WorkdayStore.forgetAll(in: dir)
        check("store: forget everything leaves nothing", WorkdayStore.load(in: dir).isEmpty)
        try? FileManager.default.removeItem(at: dir)

        // a working week: Chrome, Slack and Mail first thing, and a copy loop between Chrome and Sheets
        var week: [WorkSegment] = []
        for d in 0..<5 {
            week += [seg(d, 8, 50 + (d % 3), secs: 600, "com.google.Chrome", "Google Chrome", "Search"),
                     seg(d, 9, 2, secs: 300, "com.tinyspeck.slackmacgap", "Slack"),
                     seg(d, 9, 10, secs: 300, "com.apple.mail", "Mail")]
            if d < 3 { for k in 0..<4 { week += [seg(d, 11, k * 2, secs: 30, "com.google.Chrome", "Google Chrome", "Shop", s: 0), seg(d, 11, k * 2, secs: 30, "com.apple.Numbers", "Numbers", "Sheet", s: 31)] } }
            week.append(seg(d, 13, 0, secs: 900, "com.momominibot.freeflow", "FreeFlow"))
            week.append(seg(d, 14, 0, secs: 600, "com.apple.mail", "Mail", idle: true))
        }
        let habits = WorkdayAnalysis.habits(week, cal: utc)
        let chrome = habits.first { $0.bundle == "com.google.Chrome" }
        check("habits: an app opened first thing on 5 days is found", chrome?.days == 5 && chrome?.ofDays == 5)
        check("habits: the usual time is the middle of the days", chrome.map { abs($0.minuteOfDay - (8 * 60 + 51)) <= 2 } ?? false)
        check("habits: a weekday-only routine is marked weekdays only", chrome?.weekdaysOnly == true)
        check("habits: FreeFlow itself and idle time are not counted", !habits.contains { $0.bundle == "com.momominibot.freeflow" } && habits.filter { $0.bundle == "com.apple.mail" }.first?.minuteOfDay == 9 * 60 + 10)
        check("habits: fewer than three days of notes gives nothing", WorkdayAnalysis.habits(Array(week.prefix(6)), cal: utc).isEmpty)
        let loops = WorkdayAnalysis.loops(week, cal: utc)
        check("loops: going back and forth between two apps is found", loops.first.map { $0.times >= 6 && $0.days == 3 && Set($0.names) == ["Google Chrome", "Numbers"] } ?? false)
        check("loops: a few switches are not a loop", WorkdayAnalysis.loops(Array(week.prefix(12)), cal: utc).isEmpty)
        let today = WorkdayAnalysis.today(week, now: at(1, 12, 0), cal: utc)
        check("today: minutes by app for one day, busiest first, without FreeFlow or idle time", today.first?.bundle == "com.google.Chrome" && today.first?.minutes == 12 && !today.contains { $0.bundle == "com.momominibot.freeflow" } && !today.contains { $0.bundle == "com.apple.mail" && $0.minutes > 5 })

        // dictated again and again
        let said = "Please install all the skills required for this and use the AI visibility playbook until the project is complete"
        let hist = [HistoryEntry(id: 1, date: at(0, 9, 0), app: "x", mode: "m", text: "Hello there. \(said)."),
                    HistoryEntry(id: 2, date: at(1, 9, 0), app: "x", mode: "m", text: "\(said). Thanks."),
                    HistoryEntry(id: 3, date: at(2, 9, 0), app: "x", mode: "m", text: "OK so \(said.replacingOccurrences(of: "install all the skills", with: "install all of the skills"))."),
                    HistoryEntry(id: 4, date: at(3, 9, 0), app: "x", mode: "m", text: "Short one. Another different sentence about lunch plans for the team this week.")]
        let phr = WorkdayAnalysis.phrases(hist)
        check("phrases: a sentence said in three dictations is found, even reworded a little", phr.count == 1 && phr[0].times == 3 && phr[0].text.contains("AI visibility playbook"))
        check("phrases: two dictations are not enough", WorkdayAnalysis.phrases(Array(hist.prefix(2))).isEmpty)

        // ideas
        let ideas = Suggestions.list(segments: week, history: hist, cal: utc)
        let sched = ideas.first { $0.kind == .schedule }?.task
        check("ideas: the morning apps become one scheduled task", sched.map { Set($0.apps) == ["Google Chrome", "Slack", "Mail"] } ?? false)
        check("ideas: it runs 5 minutes before the first one, on weekdays", sched.map { $0.hour == 8 && $0.minute == 45 && $0.weekdays == [1, 2, 3, 4, 5] && $0.cron == "45 8 * * 1-5" } ?? false)
        check("ideas: a back-and-forth becomes a brief for another agent", ideas.contains { $0.kind == .hermes && $0.text.contains("Google Chrome") && $0.text.contains("Done when") })
        check("ideas: a repeated sentence becomes a phrase to save", ideas.contains { $0.kind == .phrase && $0.text.contains("playbook") && !$0.cue.isEmpty })
        check("ideas: briefs name apps and counts, never window titles", !ideas.filter { $0.kind == .hermes }.contains { $0.text.contains("Search") || $0.text.contains("Sheet") })
        check("ideas: the same notes always give the same ideas in the same order (30 tries)", (0..<30).allSatisfy { _ in Suggestions.list(segments: week, history: hist, cal: utc).map { $0.id } == ideas.map { $0.id } })

        // the task that gets written: a script that works, and a schedule file macOS accepts
        let task = ScheduledTask(id: "t1", title: "Open apps", hour: 8, minute: 45, weekdays: [1, 2, 3, 4, 5], apps: ["Google Chrome", "Slack"], why: "test")
        let evil = ScheduledTask(id: "t2", title: "Evil", hour: 9, minute: 0, weekdays: [1], apps: ["Bad'; touch /tmp/ff-pwned-\(getpid()); echo '"], why: "test")
        let sh1 = FileManager.default.temporaryDirectory.appendingPathComponent("ff-task-\(getpid()).sh")
        let sh2 = FileManager.default.temporaryDirectory.appendingPathComponent("ff-task-evil-\(getpid()).sh")
        try? task.script(log: "").write(to: sh1, atomically: true, encoding: .utf8)
        try? evil.script(log: "").write(to: sh2, atomically: true, encoding: .utf8)
        check("task: the script is valid bash", run("/bin/bash", ["-n", sh1.path]).0 == 0)
        let dry = run("/bin/bash", [sh1.path, "--dry-run"])
        check("task: a dry run lists the apps and opens nothing", dry.0 == 0 && dry.1.contains("would open: Google Chrome") && dry.1.contains("would open: Slack"))
        let dryEvil = run("/bin/bash", [sh2.path, "--dry-run"])
        check("task: an app name cannot run a command", dryEvil.0 == 0 && dryEvil.1.contains("would open: Bad'; touch") && !FileManager.default.fileExists(atPath: "/tmp/ff-pwned-\(getpid())"))
        try? FileManager.default.removeItem(at: sh1); try? FileManager.default.removeItem(at: sh2)
        check("task: cron form for chosen days", ScheduledTask(id: "x", title: "x", hour: 7, minute: 5, weekdays: [1, 3], apps: [], why: "").cron == "5 7 * * 1,3" && ScheduledTask(id: "x", title: "x", hour: 7, minute: 5, weekdays: [1, 2, 3, 4, 5, 6, 7], apps: [], why: "").cron == "5 7 * * *")
        if let data = task.plist(script: "/tmp/x.sh", log: "/tmp/x.log"), let obj = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] {
            let cal = obj["StartCalendarInterval"] as? [[String: Int]] ?? []
            check("task: the schedule file has the label, the command and one entry per weekday", obj["Label"] as? String == "com.momominibot.freeflow.task.t1" && (obj["ProgramArguments"] as? [String]) == ["/bin/bash", "/tmp/x.sh"] && cal.count == 5 && cal.allSatisfy { $0["Hour"] == 8 && $0["Minute"] == 45 } && Set(cal.compactMap { $0["Weekday"] }) == [1, 2, 3, 4, 5])
            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("ff-plist-\(getpid()).plist")
            try? data.write(to: tmp)
            check("task: plutil accepts the schedule file", run("/usr/bin/plutil", ["-lint", tmp.path]).0 == 0)
            try? FileManager.default.removeItem(at: tmp)
        } else { check("task: the schedule file can be made", false) }
        let agents = FileManager.default.temporaryDirectory.appendingPathComponent("ff-agents-\(getpid())", isDirectory: true)
        let tasksDir = FileManager.default.temporaryDirectory.appendingPathComponent("ff-tasks-\(getpid())", isDirectory: true)
        let st = LaunchAgentStore(dir: agents, tasks: tasksDir, load: false)
        try? st.install(task)
        check("task: adding it writes the script (runnable) and the schedule file", st.isInstalled(task) && FileManager.default.isExecutableFile(atPath: st.scriptURL(task).path) && run("/bin/bash", [st.scriptURL(task).path, "--dry-run"]).0 == 0)
        try? st.install(task)
        check("task: adding it twice changes nothing", (try? FileManager.default.contentsOfDirectory(atPath: agents.path))?.count == 1)
        st.remove(task)
        check("task: removing it deletes the schedule file and the script", !st.isInstalled(task) && !FileManager.default.fileExists(atPath: st.scriptURL(task).path))
        try? FileManager.default.removeItem(at: agents); try? FileManager.default.removeItem(at: tasksDir)

        // handing a brief over
        var sent: [(String, String)] = []
        let realSend = Hermes.send
        Hermes.send = { t, body in sent.append((t, body)); return .success("card ok") }
        let r = Hermes.send("T", "B")
        Hermes.send = realSend
        check("hermes: the hand-over goes through one replaceable sender", sent.count == 1 && sent[0].0 == "T" && { if case .success("card ok") = r { return true }; return false }())
        check("hermes: the card command takes the brief on standard input and assigns Eren",
              Hermes.cardArguments(title: "T", assignee: "eren") == ["kanban", "create", "T", "--body-file", "-", "--created-by", "freeflow", "--json", "--assignee", "eren"]
              && !Hermes.cardArguments(title: "T", assignee: nil).contains("--assignee")
              && !Hermes.cardArguments(title: "T", assignee: "eren").contains("a long brief"))
        check("hermes: the card id is read from the JSON, with or without a line before it",
              Hermes.cardID(from: "{\n  \"id\": \"t_abc123\",\n  \"status\": \"ready\"\n}") == "t_abc123"
              && Hermes.cardID(from: "Bitwarden Secrets Manager: applied 2 secrets\n{\"id\": \"t_x9\"}") == "t_x9"
              && Hermes.cardID(from: "nothing here") == nil && Hermes.cardID(from: "{\"status\": \"ready\"}") == nil)
        check("hermes: briefs go to Levi unless you pick Eren, and a made-up agent falls back to Levi",
              Hermes.agentName("levi") == "Levi" && Settings.hermesAgents.map { $0.id } == ["levi", "eren"]
              && Hermes.bridgeArguments(title: "T", body: "B", agent: "levi")[1] == "levi")
        check("hermes: the older route sends a number as the priority (the word normal broke every send)", Int(Hermes.bridgeArguments(title: "T", body: "B", agent: "levi").last ?? "") != nil)
    }

    // Learning from your own typing: what counts, what never does, and how the learning is measured.
    do {
        let common: (String) -> Bool = { ["the", "love", "much", "quick", "fox", "there", "rank"].contains($0.lowercased()) }
        let val = "first line\nsecond line here\nthird"
        let ln = TypingRules.line(in: val, caret: 15)
        check("typing: the line the caret is on, and where it starts", ln.text == "second line here" && ln.start == 11)
        // the same strings the live smoke test types, with the Mac's real spell checker (which may already know the name, but only with its capital)
        check("typing: the smoke test's exact lines give the fix with the real spell checker",
              TypingRules.pairs(previous: "FFTYPE we love Ranklor so much.", current: "FFTYPE we love Ranklore so much.", isCommon: Learning.isEnglishWord) == [Learning.Pair(wrong: "Ranklor", right: "Ranklore")])
        check("typing: the live smoke test's own name gives the fix with the real spell checker",
              TypingRules.pairs(previous: "FFTYPE we love Quillmor so much.", current: "FFTYPE we love Quillmore so much.", isCommon: Learning.isEnglishWord) == [Learning.Pair(wrong: "Quillmor", right: "Quillmore")])
        check("typing: with the real spell checker an everyday word is still not kept",
              TypingRules.pairs(previous: "FFTYPE teh cat sat today.", current: "FFTYPE the cat sat today.", isCommon: Learning.isEnglishWord).isEmpty
              && TypingRules.pairs(previous: "FFTYPE teh cat sat today.", current: "FFTYPE The cat sat today.", isCommon: Learning.isEnglishWord).isEmpty)
        check("typing: a name known only with its capital counts as a name", TypingRules.pairs(previous: "visit Pariss soon", current: "visit Paris soon", isCommon: { $0 == "Paris" }) == [Learning.Pair(wrong: "Pariss", right: "Paris")])
        check("typing: a name fixed into an unusual spelling is kept", TypingRules.pairs(previous: "we love Ranklor so much", current: "we love Ranklore so much", isCommon: common) == [Learning.Pair(wrong: "Ranklor", right: "Ranklore")])
        check("typing: a typo fixed into an everyday word is not kept", TypingRules.pairs(previous: "teh quick fox jumped", current: "the quick fox jumped", isCommon: common).isEmpty)
        check("typing: added words are not a fix", TypingRules.pairs(previous: "we love", current: "we love Ranklore a lot", isCommon: common).isEmpty)
        check("typing: a rewrite is not a fix", TypingRules.pairs(previous: "we love Ranklore so much", current: "completely different words arrive now today", isCommon: common).isEmpty)
        check("typing: numbers and Chinese are never learned this way", TypingRules.pairs(previous: "the model X is here", current: "the model 3000 is here", isCommon: common).isEmpty && TypingRules.pairs(previous: "我喜欢排行", current: "我喜欢排名", isCommon: common).isEmpty)
        check("typing: password managers, terminals and FreeFlow itself are never looked at", TypingRules.skips(bundle: "com.1password.1password") && TypingRules.skips(bundle: "com.apple.Terminal") && TypingRules.skips(bundle: "com.googlecode.iterm2") && TypingRules.skips(bundle: "com.momominibot.freeflow") && !TypingRules.skips(bundle: "com.apple.TextEdit"))

        // "keep a clear fix the first time": the fixes from a real day of typing, and the junk that came with them
        let P = { (a: String, b: String) in Learning.Pair(wrong: a, right: b) }
        check("typing: clear spelling fixes are kept the first time",
              TypingRules.confident(P("emis.asio", "Emis.asia")) && TypingRules.confident(P("michiomimi.io", "michiyomimi.io"))
              && TypingRules.confident(P("live loom", "LifeLoom")) && TypingRules.confident(P("singaporean seller", "SingaporeanSeller"))
              && TypingRules.confident(P("witsu.versil.app", "witzu.vercel.app")) && TypingRules.confident(P("Ranklor", "Ranklore")))
        check("typing: a word being deleted, a rewrite or a tiny word is not a clear fix",
              !TypingRules.confident(P("store da", "stor")) && !TypingRules.confident(P("store data", "stor"))
              && !TypingRules.confident(P("Rank", "Ranklore")) && !TypingRules.confident(P("completely", "Ranklore")) && !TypingRules.confident(P("teh", "the"))
              && !TypingRules.confident(P("same", "same")))
        check("unsent: a text box in a web page or an Electron app is trusted, not checked",
              Inserter.classify(role: "AXTextArea", settable: true, web: true) == .unknown
              && Inserter.classify(role: "AXButton", settable: false, web: true) == .unknown
              && Inserter.classify(role: "AXTextArea", settable: true) == .editable)
        var seen = TypingSeen()
        let p1 = Learning.Pair(wrong: "Ranklor", right: "Ranklore"), p2 = Learning.Pair(wrong: "Zorbitron", right: "Zorbitrone")
        check("typing: one fix teaches nothing", seen.see([p1]).isEmpty)
        check("typing: the same fix a second time is kept, once", seen.see([p1]) == [p1] && seen.see([p1]).isEmpty)
        check("typing: another spelling is counted on its own", seen.see([p2]).isEmpty && seen.counts["zorbitron > Zorbitrone"] == 1)

        // a timeline of looks at one line: only versions that stayed put count
        var tr = TypingTracker()
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        func look(_ text: String, _ s: Double) -> [Learning.Pair] { tr.observe(text: text, start: 0, sameField: true, at: t0.addingTimeInterval(s), isCommon: common) }
        var found: [Learning.Pair] = []
        found += tr.observe(text: "we love Ranklor so much", start: 0, sameField: false, at: t0, isCommon: common)   // first look
        found += look("we love Ranklor so much", 0.5) + look("we love Ranklor so much", 1.4)          // settled: nothing to compare yet
        found += look("we love Rank", 2.0) + look("we love ", 2.5) + look("we love Ranklore", 3.0)      // backspacing and retyping: not settled
        check("typing: a line that is still changing teaches nothing", found.isEmpty)
        found += look("we love Ranklore so much", 3.5) + look("we love Ranklore so much", 4.4) + look("we love Ranklore so much", 5.0)
        check("typing: the settled before and after give the fix, once", found == [Learning.Pair(wrong: "Ranklor", right: "Ranklore")])
        // a pause after deleting the wrong word: the half-deleted line settles too, the fix is still found against the line from before
        var tp = TypingTracker(); var foundP: [Learning.Pair] = []
        func lookP(_ t: String, _ sec: Double) { foundP += tp.observe(text: t, start: 0, sameField: true, at: t0.addingTimeInterval(sec), isCommon: common) }
        lookP("we love Ranklor so much", 0); lookP("we love Ranklor so much", 1.5)          // typed, settled
        lookP("we love ", 2.0); lookP("we love ", 3.5)                                      // deleted, thought about it for a while
        lookP("we love Ranklore so much", 4.0); lookP("we love Ranklore so much", 5.5)      // written again, settled
        check("typing: a pause after deleting the word does not hide the fix", foundP == [Learning.Pair(wrong: "Ranklor", right: "Ranklore")])
        check("typing: finishing a word you were still typing is not a correction", TypingRules.pairs(previous: "we love Ranklo", current: "we love Ranklore", isCommon: common).isEmpty
              && !TypingRules.pairs(previous: "we love Ranklor so much", current: "we love Ranklore so much", isCommon: common).isEmpty)
        check("typing: half-deleted words are never taken as the wrong word", !found.contains { $0.wrong == "Rank" })
        var tr2 = TypingTracker()
        _ = tr2.observe(text: "we love Ranklore", start: 0, sameField: false, at: t0, isCommon: common)
        check("typing: a different line or field starts again", tr2.observe(text: "other text here", start: 40, sameField: true, at: t0.addingTimeInterval(3), isCommon: common).isEmpty)

        // Telling whether a dictation reached a text box
        check("unsent: text boxes are recognised, and anything settable counts as one",
              Inserter.classify(role: "AXTextField", settable: false) == .editable && Inserter.classify(role: "AXTextArea", settable: false) == .editable
              && Inserter.classify(role: "AXGroup", settable: true) == .editable)
        check("unsent: a list, a button or a scroll area is not a text box",
              Inserter.classify(role: "AXOutline", settable: false) == .notText("AXOutline") && Inserter.classify(role: "AXButton", settable: false) == .notText("AXButton")
              && Inserter.classify(role: "AXScrollArea", settable: false) == .notText("AXScrollArea"))
        check("unsent: a web page or an app that does not describe itself is trusted as before",
              Inserter.classify(role: "AXWebArea", settable: false) == .unknown && Inserter.classify(role: "", settable: false) == .unknown)
        check("unsent: a box that changed took the words, one that did not did not, an unreadable one is not judged",
              Inserter.arrived(before: "hello", after: "hello there") == true && Inserter.arrived(before: "hello", after: "hello") == false
              && Inserter.arrived(before: nil, after: "x") == nil && Inserter.arrived(before: "x", after: nil) == nil)

        // The talk keys: each has its own key code and its own bit, so one key never answers for another
        check("talk keys: every key has its own key code and device bit",
              Set(TalkKey.allCases.map { $0.keyCode }).count == TalkKey.allCases.count && Set(TalkKey.allCases.map { $0.deviceMask }).count == TalkKey.allCases.count
              && TalkKey.leftControl.keyCode == 59 && TalkKey.leftControl.deviceMask == 0x1 && TalkKey.rightControl.keyCode == 62)
        check("talk keys: Left Control is in the list with its own names", TalkKey.allCases.contains(.leftControl) && TalkKey.leftControl.short == "left ⌃" && TalkKey.leftControl.chipTitle == "Left Control")
        do {
            func flags(_ code: UInt16, _ raw: UInt) -> NSEvent {
                NSEvent.keyEvent(with: .flagsChanged, location: .zero, modifierFlags: NSEvent.ModifierFlags(rawValue: raw), timestamp: 0, windowNumber: 0, context: nil,
                                 characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: code)!
            }
            let hk = HotkeyMonitor(); hk.key = .leftControl
            var downs = 0, ups = 0
            hk.onDown = { downs += 1 }; hk.onUp = { ups += 1 }
            hk.handle(flags(59, 0x40101))          // left Control goes down
            hk.handle(flags(59, 0x100))            // and comes up
            check("talk keys: pressing and releasing Left Control starts and ends a press", downs == 1 && ups == 1)
            hk.handle(flags(62, 0x42100))          // the right Control key is not the talk key
            hk.handle(flags(62, 0x100))
            hk.handle(flags(56, 0x20102))          // neither is Shift
            check("talk keys: the right Control key and Shift do nothing when Left Control is the talk key", downs == 1 && ups == 1)
            hk.handle(flags(59, 0x40101)); hk.handle(flags(59, 0x40101))
            check("talk keys: a repeated flags event while the key stays down is one press", downs == 2)
        }

        // Double tap of the talk key (as in Wispr Flow)
        var dt = DoubleTapGate()
        let g0 = Date(timeIntervalSince1970: 2_000_000)
        check("double tap: a press with no tap before it is not a second tap", !dt.pressBegan(at: g0) && !dt.waiting)
        dt.firstTapEnded(at: g0)
        check("double tap: after a quick tap the gate waits", dt.waiting)
        check("double tap: a second press soon after is the double tap", dt.pressBegan(at: g0.addingTimeInterval(0.25)))
        check("double tap: and then the gate is empty again", !dt.waiting && !dt.pressBegan(at: g0.addingTimeInterval(0.3)))
        dt.firstTapEnded(at: g0)
        check("double tap: a press after the window is not a second tap", !dt.pressBegan(at: g0.addingTimeInterval(DoubleTapGate.window + 0.1)))
        dt.firstTapEnded(at: g0); dt.expire()
        check("double tap: once the window is over (or the recording ended) nothing is waiting", !dt.waiting && !dt.pressBegan(at: g0.addingTimeInterval(0.1)))
        dt.firstTapEnded(at: g0)
        check("double tap: a press just inside the window still counts", dt.pressBegan(at: g0.addingTimeInterval(DoubleTapGate.window - 0.01)))

        // Deeper notes: screen text, typing, pictures. What is kept, what never is, and that they can be forgotten.
        check("detail: emails, links, keys and long numbers become tags",
              Redact.line("mail jamie@example.com or https://x.io/a?b=1 key sk_live_abcdefgh12345 call 1234 5678 9012") == "mail <email> or <link> key <key> call <number>")
        check("detail: a line about a password or a code is hidden whole",
              Redact.line("Password: hunter2") == "<hidden line>" && Redact.line("Your verification code is 482913") == "<hidden line>" && Redact.line("Invoice for March") == "Invoice for March")
        let rawScreen = "ab\n-----\nInvoice for the March order\nInvoice for the March order\nsend to jamie@example.com\nthe api key is abc\n"
        check("detail: tiny, symbol and repeated lines are dropped and the rest is cleaned",
              ScreenText.clean(rawScreen) == "Invoice for the March order\nsend to <email>\n<hidden line>")
        check("detail: screen text is cut to the limit", ScreenText.clean((0..<400).map { "Line number \($0) of a long page" }.joined(separator: "\n"), limit: 500).count <= 500)
        let ddir = FileManager.default.temporaryDirectory.appendingPathComponent("ff-detail-test-\(getpid())", isDirectory: true)
        try? FileManager.default.removeItem(at: ddir)
        let when = Date()
        let rs = DetailRecord(t: when, kind: "screen", app: "com.apple.TextEdit", name: "TextEdit", title: "Notes", text: "ZEBRA invoice schedule")
        let rt = DetailRecord(t: when, kind: "typing", app: "com.apple.TextEdit", name: "TextEdit", title: "Notes", text: "we ship on Monday", typed: 120, deleted: 9, secs: 31)
        DetailStore.append(rs, in: ddir); DetailStore.append(rt, in: ddir)
        check("detail: records are written and read back", DetailStore.load(kind: "screen", date: when, in: ddir).map { $0.text } == [rs.text] && DetailStore.load(kind: "typing", date: when, in: ddir).first?.typed == 120)
        check("detail: a record leaves out what is empty", !(String(data: (try? JSONEncoder().encode(rs)) ?? Data(), encoding: .utf8) ?? "").contains("typed"))
        let old = Calendar.current.date(byAdding: .day, value: -(DetailStore.keepDays + 3), to: when)!
        DetailStore.append(DetailRecord(t: old, kind: "screen", app: "x", name: "x", title: "", text: "old words here"), in: ddir)
        DetailStore.purge(in: ddir)
        check("detail: notes older than a week are deleted, newer ones stay", DetailStore.load(kind: "screen", date: old, in: ddir).isEmpty && DetailStore.count(kind: "screen", date: when, in: ddir) == 1)
        let img: CGImage? = {
            guard let ctx = CGContext(data: nil, width: 40, height: 30, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
            ctx.setFillColor(CGColor(red: 0.4, green: 0.3, blue: 0.7, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: 40, height: 30))
            return ctx.makeImage()
        }()
        let pic = img.flatMap { DetailStore.savePicture($0, app: "Text Edit!", at: when, in: ddir) }
        check("detail: a picture is a small jpg named for the app", pic.map { $0.pathExtension == "jpg" && $0.lastPathComponent.hasSuffix("-Text-Edit-.jpg") && FileManager.default.fileExists(atPath: $0.path) } == true)
        let oldPic = DetailStore.picturesDir(in: ddir).appendingPathComponent(DetailStore.dayString(Calendar.current.date(byAdding: .day, value: -(DetailStore.keepPictureDays + 2), to: when)!), isDirectory: true)
        try? FileManager.default.createDirectory(at: oldPic, withIntermediateDirectories: true)
        DetailStore.purge(in: ddir)
        check("detail: pictures older than three days are deleted, today's stay", !FileManager.default.fileExists(atPath: oldPic.path) && pic.map { FileManager.default.fileExists(atPath: $0.path) } == true)
        let brief = Hermes.deepReviewBrief(days: 7, workday: ddir, detail: ddir, now: when)
        check("detail: the brief names the files and the rules but holds none of their text",
              brief.contains("screen-YYYY-MM-DD.jsonl") && brief.contains("typing-YYYY-MM-DD.jsonl") && brief.contains("Do not run, publish, send, buy or change anything outside this Mac")
              && !brief.contains("ZEBRA") && !brief.contains("we ship on Monday") && brief.contains("screen: 1 records today"))
        DetailStore.forgetAll(in: ddir)
        check("detail: forgetting removes the notes and the pictures", !FileManager.default.fileExists(atPath: ddir.path))
        var meter = TypingMeter()
        meter.observe(length: 100, sameBox: false)
        meter.observe(length: 104, sameBox: true); meter.observe(length: 110, sameBox: true); meter.observe(length: 107, sameBox: true)
        check("detail: typed and deleted characters are counted", meter.typed == 10 && meter.deleted == 3 && meter.seconds == 3)
        meter.observe(length: 900, sameBox: true); meter.observe(length: 890, sameBox: true)
        check("detail: a paste or a dictation is not typing", meter.typed == 10 && meter.deleted == 13)
        meter.observe(length: 5, sameBox: false); meter.observe(length: 5, sameBox: true)
        check("detail: another text box starts a fresh count and nothing changing counts nothing", meter.typed == 10 && meter.deleted == 13)
        check("detail: the apps that are never read",
              Redact.skips(bundle: "com.1password.1password") && TypingRules.skips(bundle: "com.apple.Terminal") && TypingRules.skips(bundle: "com.momominibot.freeflow") && !TypingRules.skips(bundle: "com.apple.Safari"))

        // is it getting better?
        var tc = Calendar(identifier: .gregorian); tc.timeZone = TimeZone(identifier: "UTC")!
        let end = tc.date(from: DateComponents(year: 2026, month: 11, day: 15))!
        let daily14: [(day: Date, words: Int)] = (0..<14).map { (tc.date(byAdding: .day, value: $0 - 13, to: end)!, 100) }
        var fixes: [String: Int] = [:]
        for d in 0..<7 { fixes[LearningStats.dayKey(tc.date(byAdding: .day, value: d - 13, to: end)!, tc)] = 2 }       // last week: 14 fixes in 700 words
        for d in 7..<14 { fixes[LearningStats.dayKey(tc.date(byAdding: .day, value: d - 13, to: end)!, tc)] = 1 }      // this week: 7 fixes in 700 words
        let wk = LearningStats.weeks(fixesByDay: fixes, daily: daily14, cal: tc)
        check("stats: fixes and words for this week and the week before", wk.this == LearningStats.Week(fixes: 7, words: 700) && wk.last == LearningStats.Week(fixes: 14, words: 700))
        check("stats: fewer fixes per 100 words says it is getting more accurate", LearningStats.verdict(this: wk.this, last: wk.last) == "Down from 2.0 to 1.0 fixes per 100 words. It is getting more accurate for you.")
        check("stats: more fixes is said plainly, not spun", LearningStats.verdict(this: wk.last, last: wk.this).hasPrefix("Up from 1.0 to 2.0"))
        check("stats: too little dictation gives no verdict", LearningStats.verdict(this: LearningStats.Week(fixes: 1, words: 40), last: wk.last).hasPrefix("Not enough"))
        check("stats: no week to compare with is said so", LearningStats.verdict(this: wk.this, last: LearningStats.Week(fixes: 0, words: 0)).contains("something to compare"))
    }

    // The AI tidy-up never holds typed words for long: a short budget that grows with the length, capped.
    check("ai budget: a short dictation waits about five seconds", Rewriter.cleanupBudget(words: 10) < 6)
    check("ai budget: a long dictation gets more time", Rewriter.cleanupBudget(words: 200) > Rewriter.cleanupBudget(words: 10))
    check("ai budget: never more than twenty seconds", Rewriter.cleanupBudget(words: 5000) == 20)

    // The greeting name: a real name is used, the bare account name in lower case is not.
    check("name: first word of a full name", Settings.guessFirstName(full: "Jamie Tan", account: "jamietan"), "Jamie")
    check("name: the lower-case account name is not a name", Settings.guessFirstName(full: "michiyomimi", account: "michiyomimi"), "")
    check("name: a one-word capitalised name is kept", Settings.guessFirstName(full: "Jamie", account: "jamie"), "Jamie")
    check("name: spaces around the name do not matter", Settings.guessFirstName(full: "  Michiyo Mimi ", account: "michiyomimi"), "Michiyo")
    check("name: an empty name gives nothing", Settings.guessFirstName(full: "", account: "x"), "")

    // Per-app word counts: text that looks like a number still counts, so one odd entry never wipes the rest.
    let counted = Settings.counts(["a": 5, "b": "33", "c": " 7 ", "d": "x", "e": 2.5])
    check("word counts: numbers and numeric text are kept", counted["a"] == 5 && counted["b"] == 33 && counted["c"] == 7)
    check("word counts: junk is dropped without touching the rest", counted["d"] == nil && counted.count >= 3)

    // Appearance: dark royal purple has its own value for every page colour, and the choice maps to the right window appearance.
    func brightness(_ c: NSColor, _ ap: NSAppearance) -> CGFloat {
        var out: CGFloat = -1
        ap.performAsCurrentDrawingAppearance {
            if let s = c.usingColorSpace(.sRGB) { out = (s.redComponent + s.greenComponent + s.blueComponent) / 3 }
        }
        return out
    }
    let aqua = NSAppearance(named: .aqua)!, darkAqua = NSAppearance(named: .darkAqua)!
    check("appearance: the page is pale in light", brightness(RT.windowBackground, aqua) > 0.9)
    check("appearance: the page is deep purple in dark", brightness(RT.windowBackground, darkAqua) < 0.15)
    check("appearance: dark purple still has blue and red above green", {
        var ok = false
        darkAqua.performAsCurrentDrawingAppearance {
            if let s = RT.windowBackground.usingColorSpace(.sRGB) { ok = s.blueComponent > s.redComponent && s.redComponent > s.greenComponent }
        }
        return ok
    }())
    check("appearance: the light page colour is the one Rhythme uses", abs(brightness(NSColor.dyn(0xF8F3FB, 0x180D31), aqua) - (0xF8 + 0xF3 + 0xFB) / 3.0 / 255) < 0.004)
    check("appearance: system follows the Mac", AppearanceChoice.system.nsAppearance == nil)
    check("appearance: light is aqua", AppearanceChoice.light.nsAppearance?.name == .aqua)
    check("appearance: dark is dark aqua", AppearanceChoice.dark.nsAppearance?.name == .darkAqua)
    check("appearance: an unknown saved value falls back to the Mac", AppearanceChoice(rawValue: "sepia") == nil)
    check("appearance: three choices with their own titles", Set(AppearanceChoice.allCases.map { $0.chipTitle }).count == 3)

    // Polish: the grammar, tone and rewrite layer (Sources/Polish.swift). The rule checks run with or without Harper linked in.
    func fixed(_ text: String) -> String { GrammarChecker.autoFix(text).text }
    func kinds(_ text: String) -> [PolishKind] { GrammarChecker.check(text).map(\.kind) }
    check("polish: a repeated word is taken out", fixed("This is is a test."), "This is a test.")
    check("polish: that that is left alone", GrammarChecker.check("I know that that works.").filter { $0.message.contains("repeated") }.isEmpty)
    check("polish: a before a vowel becomes an", fixed("She ate a apple."), "She ate an apple.")
    check("polish: an before a consonant becomes a", fixed("It is an car."), "It is a car.")
    check("polish: an hour is right", GrammarChecker.check("Wait for an hour.").filter { $0.message.contains("Use \"a\"") }.isEmpty)
    check("polish: a university is right", GrammarChecker.check("She went to a university.").filter { $0.message.contains("Use \"an\"") }.isEmpty)
    check("polish: an MBA is right", GrammarChecker.check("He has an MBA.").filter { $0.message.contains("Use \"a\"") }.isEmpty)
    check("polish: lowercase i becomes I", fixed("Yesterday i went home and i slept."), "Yesterday I went home and I slept.")
    check("polish: i'm becomes I'm", fixed("Today i'm here."), "Today I'm here.")
    check("polish: sentence starts with a capital", fixed("It works. then we left."), "It works. Then we left.")
    check("polish: e.g. does not start a sentence", GrammarChecker.check("Bring snacks, e.g. fruit and nuts.").filter { $0.message.contains("capital") }.isEmpty)
    check("polish: a numbered list is not a sentence", GrammarChecker.check("Steps:\n1. open the app\n2. press talk").filter { $0.message.contains("capital") }.isEmpty)
    check("polish: an ellipsis is not a sentence end", GrammarChecker.check("Well... maybe later.").filter { $0.message.contains("capital") }.isEmpty)
    check("polish: a web address is left alone", GrammarChecker.check("Visit www.emis.asia for more.").isEmpty)
    check("polish: should of becomes should have", fixed("I should of called."), "I should have called.")
    check("polish: then after a comparison becomes than", fixed("It is bigger then mine."), "It is bigger than mine.")
    check("polish: a misspelling is a spelling problem", kinds("I will definately come.").contains(.spelling))
    check("polish: a double space is closed", fixed("One  two."), "One two.")
    check("polish: a space before a comma goes", fixed("Yes , please."), "Yes, please.")
    check("polish: a missing space after a comma is added", fixed("Red,green and blue."), "Red, green and blue.")
    check("polish: 1,000 is left alone", GrammarChecker.check("It costs 1,000 dollars.").isEmpty)
    check("polish: clear writing has no issues", GrammarChecker.check("We ship the new version on Friday. Please test it before then.").filter { $0.kind.isCorrectness }.isEmpty)
    check("polish: Chinese is never judged as English", GrammarChecker.check("我们明天要 send the invoice 给客户，然后 update 一下。").filter { $0.kind.isCorrectness }.isEmpty)
    check("polish: your own words are not misspellings", GrammarChecker.check("We sell Ranklore plans.", words: ["Ranklore"]).filter { $0.kind == .spelling }.isEmpty)
    check("polish: a dismissed problem stays dismissed", GrammarChecker.check("It is is fine.", ignored: ["is is"]).filter { $0.message.contains("repeated") }.isEmpty)
    check("polish: wordy phrase is shortened", GrammarChecker.check("We did it in order to win.").contains { $0.kind == .clarity && $0.fixes == ["to"] })
    check("polish: a word left out also takes its space", PolishText.apply("", start: 6, end: 15, to: "It is basically fine"), "It is fine")
    check("polish: very good offers a stronger word", GrammarChecker.check("The food was very good.").contains { $0.kind == .style && $0.fixes.contains("excellent") })
    check("polish: a word used three times is pointed out", GrammarChecker.check("It is a nice room. The view is nice. The staff are nice.").contains { $0.message.contains("3 times") })
    check("polish: a long sentence does not hide the mistakes inside it", GrammarChecker.check((1...40).map { "word\($0)" }.joined(separator: " ") + " is is done.").count >= 2)
    check("polish: a long sentence is pointed out", GrammarChecker.check((1...45).map { "word\($0)" }.joined(separator: " ") + ".").contains { $0.message.contains("words long") })
    check("polish: apply keeps text around the fix", PolishText.apply("an", start: 8, end: 9, to: "She ate a apple."), "She ate an apple.")
    check("polish: positions count scalars not UTF-16", fixed("😀 We said it is is fine."), "😀 We said it is fine.")
    check("polish: nothing for empty text", GrammarChecker.check("  \n").isEmpty)
    check("polish: nothing broken by one-fix-at-a-time", PolishText.apply(GrammarChecker.check("i went home.")[0], to: "i went home.").hasPrefix("I"))
    check("polish: stats count words and sentences", { let s = WritingStats.of("One two three. Four five six."); return s.words == 6 && s.sentences == 2 }())
    check("polish: plain writing reads as easy", (WritingStats.of("The cat sat on the mat. It was a sunny day. We had tea and cake.").readingEase ?? 0) > 70)
    check("polish: reading time is about a minute for 230 words", abs(WritingStats.of(Array(repeating: "word", count: 230).joined(separator: " ")).readingSeconds - 60) <= 1)
    check("polish: syllables", WritingStats.syllableCount("beautiful") == 3 && WritingStats.syllableCount("the") == 1 && WritingStats.syllableCount("table") == 2)
    check("polish: tone formal", ToneReader.read("Dear Mr Tan, please find attached the invoice. Kindly confirm receipt. Regards, Jamie").first?.name == "Formal")
    check("polish: tone casual", ToneReader.read("hey guys, yeah that was awesome lol, cheers").first?.name == "Casual")
    check("polish: tone urgent", ToneReader.read("I need the report ASAP, the deadline is today and it is urgent").contains { $0.name == "Urgent" })
    check("polish: tone hesitant", ToneReader.read("Sorry to bother you, I was wondering if maybe you could possibly help, I think").contains { $0.name == "Hesitant" })
    check("polish: tone of a very short text is not guessed", ToneReader.read("ok").isEmpty)
    let guardOriginal = "Please pay Alice 50 dollars and Bob 75 dollars for the Ranklore work by Friday, as we agreed last week."
    check("polish: a good rewrite passes the guard", RewriteGuard.looksLikeRewrite(original: guardOriginal, rewritten: "Please pay Alice 50 dollars and Bob 75 dollars for the Ranklore work by Friday, as agreed last week.", mode: .clearer, protectedTerms: ["Ranklore"]))
    check("polish: an invented number fails the guard", !RewriteGuard.looksLikeRewrite(original: guardOriginal, rewritten: "Please pay Alice 50 dollars and Bob 80 dollars for the Ranklore work by Friday, as we agreed.", mode: .clearer))
    check("polish: a lost brand word fails the guard", !RewriteGuard.looksLikeRewrite(original: guardOriginal, rewritten: "Please pay Alice 50 dollars and Bob 75 dollars for the rank lore work by Friday, as we agreed last week.", mode: .clearer, protectedTerms: ["Ranklore"]))
    check("polish: a chatty answer fails the guard", !RewriteGuard.looksLikeRewrite(original: guardOriginal, rewritten: "Here is the rewritten version: Please pay Alice 50 dollars and Bob 75 dollars for the work by Friday.", mode: .clearer))
    check("polish: shorter may drop a number but not add one", RewriteGuard.looksLikeRewrite(original: guardOriginal, rewritten: "Pay Alice 50 dollars for the Ranklore work by Friday.", mode: .shorter, protectedTerms: ["Ranklore"]))
    check("polish: shorter that grew fails the guard", !RewriteGuard.looksLikeRewrite(original: guardOriginal, rewritten: guardOriginal + " Thank you very much for your help with all of this, it means a lot to the whole team here.", mode: .shorter))
    check("polish: a translation fails the guard", !RewriteGuard.looksLikeRewrite(original: "我们明天要 send the invoice 给客户，然后 update 一下 EMIS 的 Shopify theme。", rewritten: "We will send the invoice to the client tomorrow and update the EMIS Shopify theme.", mode: .rephrase))
    check("polish: Chinese kept passes the guard", RewriteGuard.looksLikeRewrite(original: "我们明天要 send the invoice 给客户，然后 update 一下 EMIS 的 Shopify theme。", rewritten: "我们明天会 send the invoice 给客户，之后 update EMIS 的 Shopify theme。", mode: .rephrase))
    check("polish: the model's wrapping is stripped", RewriteGuard.tidy("```\n\"Hello there.\"\n```") == "\"Hello there.\"" || RewriteGuard.tidy("\"Hello there.\"") == "Hello there.")
    check("polish: prompts name the text and keep your words", { let u = RewritePrompt.user("Pay Ranklore today", mode: .shorter, terms: ["Ranklore", "EMIS"]); return u.contains("Ranklore") && !u.contains("EMIS") && u.contains("Text:") }())
    check("polish: every rewrite mode has a title, symbol and instruction", RewriteMode.allCases.allSatisfy { !$0.title.isEmpty && !$0.symbol.isEmpty && $0.instruction.count > 20 })
    check("polish: Rewriter and the guard agree on numbers", Rewriter.numbers("75,000 and 3") == RewriteGuard.numbers("75,000 and 3"))
    check("polish: a short word list is offered without Harper", HarperEngine.isLinked || !GrammarChecker.synonyms(for: "good").isEmpty)
    check("polish: synonyms of good are the hand-picked ones", GrammarChecker.synonyms(for: "good").first == "great")
    check("polish: synonyms of nothing are nothing", GrammarChecker.synonyms(for: "  ").isEmpty && GrammarChecker.synonyms(for: "two words").isEmpty)
    check("polish: an e-mail address is left alone", GrammarChecker.check("Mail jamie@emis.asia today.").isEmpty)
    check("polish: a file name is left alone", GrammarChecker.check("Open the notes in meetingnotes.pdf now.").filter { $0.kind.isCorrectness }.isEmpty)
    check("polish: a word with a symbol in your dictionary is left alone", GrammarChecker.autoFix("We sell EMIS+ plans.", words: ["EMIS+"]).text == "We sell EMIS+ plans.")
    check("polish: its not becomes it's not", fixed("Its not ready."), "It's not ready.")
    check("polish: their going to becomes they're going to", fixed("Their going to win."), "They're going to win.")
    check("polish: their going away party is left alone", fixed("Their going away party was fun."), "Their going away party was fun.")
    check("polish: a list item needs no capital", fixed("Steps:\n- open the app\n- press talk"), "Steps:\n- open the app\n- press talk")
    check("polish: protected ranges cover a web address", { let r = GrammarChecker.protectedRanges(in: "Go to www.emis.asia now", words: []); return r.count == 1 && r[0] == 6..<19 }())
    check("polish: protected ranges count scalars after an emoji", { let r = GrammarChecker.protectedRanges(in: "😀 EMIS+ ok", words: ["EMIS+"]); return r.count == 1 && r[0] == 2..<7 }())
    check("polish: only-clear fixes skip spelling and guesses", GrammarChecker.autoFix("i will definately come", onlyClear: true).text.hasPrefix("I will definately"))
    #if HARPER
    GrammarChecker.check("This is a apple.")  // warm Harper before the checks below
    check("harper: catches a/an", GrammarChecker.check("She ate a apple.").contains { $0.fixes.contains("an") })
    check("harper: catches a misspelling", GrammarChecker.check("I will recieve it tomorow.").filter { $0.kind == .spelling }.count >= 1)
    check("harper: knows your words", GrammarChecker.check("We sell Ranklore plans.", words: ["Ranklore"]).filter { $0.kind == .spelling }.isEmpty)
    check("harper: leaves clean writing alone", GrammarChecker.check("We ship the new version on Friday.").filter { $0.kind.isCorrectness }.isEmpty)
    check("harper: ignores the Chinese in mixed text", GrammarChecker.check("我们明天要 send the invoice 给客户。").filter { $0.kind.isCorrectness }.isEmpty)
    check("harper: offsets fit text with emoji", GrammarChecker.check("😀 She ate a apple.").contains { $0.original == "a" && PolishText.apply($0, to: "😀 She ate a apple.") == "😀 She ate an apple." })
    check("harper: synonyms for a common word", GrammarChecker.synonyms(for: "big").count >= 3)
    #endif

    print(fails == 0 ? "ALL PASSED" : "\(fails) FAILED")
    exit(fails == 0 ? 0 : 1)
}

// FreeFlow --probe-learn "typed text": watches the focused text box the way the app does after typing,
// prints what it would learn from your edits, and saves nothing. For checking the learning against a real app.
if let i = args.firstIndex(of: "--probe-learn"), i + 1 < args.count {
    Learning.dryRun = true
    let watcher = CorrectionWatcher()
    var learned: [Learning.Pair] = []
    watcher.onLearned = { learned = $0 }
    // Optional: --probe-activate com.apple.TextEdit brings that app forward first (another app may grab focus between steps).
    let front = args.firstIndex(of: "--probe-activate").flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil }
    for _ in 0..<8 where !watcher.isWatching {
        if let id = front { NSRunningApplication.runningApplications(withBundleIdentifier: id).first?.activate(options: []) }
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))
        watcher.begin(pasted: args[i + 1])
    }
    print(watcher.isWatching ? "watching" : "NOT WATCHING: could not find that text in the focused box")
    fflush(stdout)
    let end = Date().addingTimeInterval(40)
    while Date() < end, watcher.isWatching { RunLoop.main.run(until: Date().addingTimeInterval(0.5)) }
    watcher.finish()
    print("learned: " + (learned.isEmpty ? "nothing" : learned.map { "\($0.wrong) -> \($0.right)" }.joined(separator: " | ")))
    exit(0)
}

// FreeFlow --probe-meetings: lists every app that is recording from a microphone right now and whether it counts as a call.
if args.contains("--probe-meetings") {
    print("supported: \(MicWatch.supported)   accessibility (window titles): \(AXIsProcessTrusted())")
    let clients = MicWatch.clients()
    if clients.isEmpty { print("nothing is recording from a microphone") }
    for c in clients {
        let o = MicWatch.owner(of: c)
        let titles = MeetingRules.isBrowser(o.bundleId) ? MicWatch.windowTitles(of: o.pid) : []
        let verdict = MeetingRules.classify(bundleId: o.bundleId, titles: titles)
        print("pid \(c.pid)  audio process \(c.bundleId.isEmpty ? "-" : c.bundleId)  app \(o.bundleId)  titles \(titles.prefix(3))  ->  \(verdict.map { "CALL: \($0)" } ?? "not a call")")
    }
    print("current call: \(MicWatch.currentCall().map { $0.name } ?? "none")")
    exit(0)
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

// FreeFlow --render-ui <folder>: draws the window pages and the floating bar to PNG files, without showing anything.
if let i = args.firstIndex(of: "--render-ui"), i + 1 < args.count {
    let dir = URL(fileURLWithPath: args[i + 1], isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    _ = NSApplication.shared
    Fonts.registerAll()
    UIShots.render(to: dir)
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(Settings.shared.showInDock ? .regular : .accessory)
app.run()
