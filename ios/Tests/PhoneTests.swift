import XCTest
@testable import FreeFlowPhone

final class PhoneTests: XCTestCase {
    private let dictionary = """
    # comment
    Ranklore
    EMIS+
    RankLore => Ranklore
    Rank Lore => Ranklore
    """

    func testDictionarySwapsSpellings() {
        XCTAssertEqual(PhonePipeline.finish("we love rank lore so much", dictionary: dictionary, removeFillers: true, quiet: false),
                       "we love Ranklore so much")
    }

    func testHintsAreTheWordsAndWhatTheyAreSwappedTo() {
        let hints = PhonePipeline.hints(dictionary: dictionary)
        XCTAssertTrue(hints.contains("Ranklore") && hints.contains("EMIS+"))
        XCTAssertFalse(hints.contains("RankLore"), "the wrong spelling is not a hint")
    }

    func testFillersAreTakenOutWhenAsked() {
        XCTAssertEqual(PhonePipeline.finish("We should, uh, ship it", dictionary: "", removeFillers: true, quiet: false), "We should ship it")
        XCTAssertTrue(PhonePipeline.finish("We should, uh, ship it", dictionary: "", removeFillers: false, quiet: false).contains("uh"))
    }

    func testBracketNoiseGoes() {
        XCTAssertEqual(PhonePipeline.finish("[BLANK_AUDIO] Hello there", dictionary: "", removeFillers: true, quiet: false), "Hello there")
    }

    func testAQuietTakeThatSaysThankYouIsDropped() {
        XCTAssertEqual(PhonePipeline.finish("Thank you.", dictionary: "", removeFillers: true, quiet: true), "")
        XCTAssertEqual(PhonePipeline.finish("Thank you.", dictionary: "", removeFillers: true, quiet: false), "Thank you.")
    }

    func testNewParagraphMakesABlankLine() {
        XCTAssertEqual(PhonePipeline.finish("First point. New paragraph. Second point.", dictionary: "", removeFillers: true, quiet: false),
                       "First point.\n\nSecond point.")
    }

    func testHistoryRoundTripKeepsTheNewestTwoHundred() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ff-history-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let entries = (0..<250).map { Entry(text: "note \($0)", raw: "raw \($0)", seconds: 1, model: "base") }
        HistoryStore.save(entries, to: url)
        let back = HistoryStore.load(from: url)
        XCTAssertEqual(back.count, HistoryStore.keep)
        XCTAssertEqual(back.first?.text, "note 0")
        XCTAssertEqual(HistoryStore.load(from: url.appendingPathExtension("missing")), [])
    }

    func testTheModelsAndLanguages() {
        XCTAssertEqual(SpeechModel.allCases.map(\.rawValue), ["base", "small", "large-v3-v20240930_626MB"])
        XCTAssertNil(SpeechLanguage.auto.code)
        XCTAssertEqual(SpeechLanguage.chinese.code, "zh")
    }
    // MARK: - Polish (the grammar and wording checker, shared with the Mac app)

    func testHarperIsLinkedIntoThePhoneApp() {
        XCTAssertTrue(HarperEngine.isLinked, "the Rust library must be linked, or Polish falls back to the small built-in rules")
    }

    func testPolishFindsAndFixesCommonMistakes() {
        let text = "i think we should of sent the the invoice yesterday, it was a unusual delay."
        let issues = GrammarChecker.check(text)
        XCTAssertGreaterThanOrEqual(issues.count, 3)
        let fixed = GrammarChecker.autoFix(text).text
        XCTAssertTrue(fixed.contains("should have"), fixed)
        XCTAssertFalse(fixed.contains("the the"), fixed)
        XCTAssertTrue(fixed.contains("an unusual"), fixed)
        XCTAssertTrue(fixed.hasPrefix("I think"), fixed)
    }

    func testYourDictionaryWordsAreNotCalledMistakes() {
        let text = "We sent it to Ranklore today."
        XCTAssertFalse(GrammarChecker.check(text, words: ["Ranklore"]).contains { $0.kind == .spelling })
    }

    func testIgnoredWordsAreSkipped() {
        let text = "The flurbish was here."
        let first = GrammarChecker.check(text)
        XCTAssertTrue(first.contains { $0.original.lowercased() == "flurbish" })
        XCTAssertFalse(GrammarChecker.check(text, ignored: ["flurbish"]).contains { $0.original.lowercased() == "flurbish" })
    }

    func testAcceptingASuggestionChangesOnlyThatWord() {
        let text = "I recieve the files today."
        guard let issue = GrammarChecker.check(text).first(where: { $0.original == "recieve" }) else { return XCTFail("recieve not flagged") }
        XCTAssertEqual(PolishText.apply(issue, fix: 0, to: text), "I receive the files today.")
    }

    func testBritishAndAmericanSpellingDiffer() {
        defer { HarperEngine.dialect = 1 }
        HarperEngine.dialect = 1
        XCTAssertTrue(GrammarChecker.check("The colour is nice.").allSatisfy { $0.original != "colour" })
        HarperEngine.dialect = 0
        XCTAssertTrue(GrammarChecker.check("The colour is nice.").contains { $0.original == "colour" })
    }

    func testSlipsAreFixedWhileDictatingOnlyWhenAsked() {
        let spoken = "this is a apple and i like it"
        let off = PhonePipeline.finish(spoken, dictionary: "", removeFillers: true, quiet: false)
        XCTAssertEqual(off, spoken, "off by default")
        let on = PhonePipeline.finish(spoken, dictionary: "", removeFillers: true, quiet: false, fixSlips: true)
        XCTAssertTrue(on.contains("an apple"), on)
        XCTAssertTrue(on.contains("I like"), on)
    }

    func testSynonymsComeBack() {
        XCTAssertFalse(GrammarChecker.synonyms(for: "good").isEmpty)
        XCTAssertTrue(GrammarChecker.synonyms(for: "").isEmpty)
    }

    func testARewriteThatChangesANumberIsRefused() {
        XCTAssertFalse(RewriteGuard.looksLikeRewrite(original: "Please pay 250 dollars by Friday, thank you very much.",
                                                      rewritten: "Please pay 300 dollars by Friday, thank you very much.", mode: .clearer))
        XCTAssertTrue(RewriteGuard.looksLikeRewrite(original: "Please pay 250 dollars by Friday, thank you very much.",
                                                     rewritten: "Please pay 250 dollars by Friday. Thank you.", mode: .clearer))
    }

    func testRewritesExplainWhenTheyAreUnavailable() {
        switch PhoneRewriter.availability {
        case .ready: break
        case .unavailable(let why): XCTAssertFalse(why.isEmpty)
        }
    }

    @MainActor func testThePolishButtonHandsTheTextToTheOtherTab() {
        let router = Router()
        XCTAssertEqual(router.tab, .talk)
        router.polish("send it tomorrow")
        XCTAssertEqual(router.tab, .polish)
        XCTAssertEqual(router.draft, "send it tomorrow")
    }

    @MainActor func testThePolishModelChecksAndFixesAll() async {
        let model = PhonePolish()
        model.text = PhonePolish.example
        await model.check()
        XCTAssertTrue(model.checked)
        XCTAssertGreaterThan(model.fixableCount, 0)
        XCTAssertNotNil(model.stats)
        model.fixAll()
        await model.check()
        XCTAssertLessThan(model.fixableCount, 3)
        XCTAssertFalse(model.text.contains("the the"))
    }

    func testBuilderRewritesKeepFilesAndNamesOrAreRefused() {
        let notes = "in src/auth/refresh.ts the function refreshToken fails after 30 minutes, add a failing test first and run npm test --coverage"
        let good = "Goal: Fix refreshToken.\nContext:\n- In src/auth/refresh.ts the function refreshToken fails after 30 minutes.\nRequirements:\n- Add a failing test first.\nDone when: npm test --coverage passes."
        XCTAssertTrue(RewriteGuard.looksLikeRewrite(original: notes, rewritten: good, mode: .codingPrompt))
        XCTAssertFalse(RewriteGuard.looksLikeRewrite(original: notes, rewritten: good.replacingOccurrences(of: "src/auth/refresh.ts", with: "the auth file"), mode: .codingPrompt))
        XCTAssertFalse(RewriteGuard.looksLikeRewrite(original: notes, rewritten: good.replacingOccurrences(of: "30 minutes", with: "45 minutes"), mode: .codingPrompt))
        XCTAssertTrue(RewriteMode.builders.contains(.commitMessage))
        XCTAssertEqual(RewriteMode.writing.count + RewriteMode.builders.count, RewriteMode.allCases.count)
    }

    func testSpokenCodeNamesWorkInDictation() {
        XCTAssertEqual(CodeSpeech.apply("Camel case user profile card."), "userProfileCard")
        XCTAssertEqual(CodeSpeech.apply("Open index dot ts and fix it."), "Open index.ts and fix it.")
        XCTAssertEqual(SpokenCommands.parse("Snake case max retry count").text, "max_retry_count")
        XCTAssertEqual(CodeSpeech.apply("I like camel case names."), "I like camel case names.")
    }
}
