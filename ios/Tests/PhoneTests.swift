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
}
