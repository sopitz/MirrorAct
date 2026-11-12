// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import XCTest
@testable import MirrorAct

/// Languages of a translator that knows a fixed set of them (Foundation only: also runs on Linux)
final class LanguageMatchingTests: XCTestCase {
    private func language(_ identifier: String) -> Locale.Language {
        Locale.Language(identifier: identifier)
    }

    /// Languages as Apple's translation lists them: language and region, no script
    private let supported: [Locale.Language] = [
        ("ar", "AE"), ("de", "DE"), ("en", "GB"), ("en", "US"), ("es", "ES"), ("fr", "FR"), ("hi", "IN"),
        ("id", "ID"), ("it", "IT"), ("ja", "JP"), ("ko", "KR"), ("nl", "NL"), ("pl", "PL"), ("pt", "BR"),
        ("ru", "RU"), ("th", "TH"), ("tr", "TR"), ("uk", "UA"), ("vi", "VN"), ("zh", "CN"), ("zh", "TW"),
    ].map { Locale.Language(languageCode: Locale.LanguageCode($0.0), script: nil, region: Locale.Region($0.1)) }

    /// language and region of the entry of `supported` that stands for a language
    private func matched(_ identifier: String) -> String? {
        guard let match = LanguageMatching.match(language(identifier), in: supported) else { return nil }
        return "\(match.languageCode?.identifier ?? "?")-\(match.region?.identifier ?? "?")"
    }

    private func hypotheses(_ candidates: [(String, Double)]) -> [LanguageMatching.Hypothesis] {
        candidates.map { LanguageMatching.Hypothesis(tag: $0.0, probability: $0.1) }
    }

    private func finding(letters: Int, open: [(String, Double)], constrained: [(String, Double)]) -> LanguageMatching.Finding {
        LanguageMatching.finding(letters: letters, open: hypotheses(open), constrained: hypotheses(constrained),
                                 supported: supported)
    }

    private func decided(_ identifier: String, letters: Int) -> LanguageMatching.Finding {
        LanguageMatching.Finding(decided: language(identifier), letters: letters)
    }

    // MARK: Languages

    func testAnEquivalentLanguageIsMatchedFirst() {
        XCTAssertEqual(matched("de"), "de-DE")
        XCTAssertEqual(matched("en"), "en-US")
        XCTAssertEqual(matched("en-GB"), "en-GB")
        XCTAssertEqual(matched("pt"), "pt-BR")
        // what a language recognizer calls the two kinds of Chinese
        XCTAssertEqual(matched("zh-Hans"), "zh-CN")
        XCTAssertEqual(matched("zh-Hant"), "zh-TW")
        // whatever the order of the list
        let reversed = Array(supported.reversed())
        XCTAssertEqual(LanguageMatching.match(language("en"), in: reversed)?.region?.identifier, "US")
    }

    func testOtherwiseTheSameLanguageInTheSameScriptIsMatched() {
        XCTAssertEqual(matched("de-CH"), "de-DE")
        XCTAssertEqual(matched("zh-HK"), "zh-TW")
        // the language as it is usually written, not the first other country in the list
        XCTAssertEqual(matched("en-AU"), "en-US")
    }

    /// The languages exactly as macOS 26 lists them (`LanguageAvailability().supportedLanguages`):
    /// the countries of a language before the language itself, with or without a region
    private let listedByMacOS: [Locale.Language] = [
        "en-IN", "it-CH", "ko", "nb", "da", "en-CA", "en-SG", "es-MX", "uk", "fr-CA", "it", "zh-TW", "es", "nl",
        "ar-AE", "zh-HK", "vi", "zh", "ru", "en-GB", "es-US", "fr", "hi", "en-ZA", "th", "en-AU", "de-CH", "de",
        "en", "pt", "pl", "en-IE", "en-NZ", "sv", "id", "tr", "ja", "pt-PT",
    ].map { Locale.Language(identifier: $0) }

    private func matchedAsListed(_ identifier: String) -> String? {
        LanguageMatching.match(language(identifier), in: listedByMacOS)?.minimalIdentifier
    }

    func testARegionMacOSDoesNotTranslateGetsTheLanguageAsItIsUsuallyWritten() {
        // not the first country of the list: Austrian German is not Swiss German (no ß there)
        XCTAssertEqual(matchedAsListed("de-AT"), "de")
        XCTAssertEqual(matchedAsListed("de-LU"), "de")
        XCTAssertEqual(matchedAsListed("en-DE"), "en")
        XCTAssertEqual(matchedAsListed("en-150"), "en")
        XCTAssertEqual(matchedAsListed("fr-BE"), "fr")
        XCTAssertEqual(matchedAsListed("fr-CH"), "fr")
        XCTAssertEqual(matchedAsListed("it-SM"), "it")
        // Chinese in the script of the region
        XCTAssertEqual(matchedAsListed("zh-MO"), "zh-TW")
        XCTAssertEqual(matchedAsListed("zh-SG"), "zh")
        XCTAssertEqual(matchedAsListed("zh-Hant"), "zh-TW")
        XCTAssertEqual(matchedAsListed("zh-Hans"), "zh")
    }

    func testARegionMacOSTranslatesIsTakenAsItIs() {
        XCTAssertEqual(matchedAsListed("de-CH"), "de-CH")
        XCTAssertEqual(matchedAsListed("de-DE"), "de")
        XCTAssertEqual(matchedAsListed("en-US"), "en")
        XCTAssertEqual(matchedAsListed("en-IN"), "en-IN")
        XCTAssertEqual(matchedAsListed("en-AU"), "en-AU")
        XCTAssertEqual(matchedAsListed("fr-CA"), "fr-CA")
        XCTAssertEqual(matchedAsListed("pt-PT"), "pt-PT")
        XCTAssertEqual(matchedAsListed("zh-HK"), "zh-HK")
        // the region in another script is another language
        XCTAssertEqual(matchedAsListed("zh-Hans-HK"), "zh")
        XCTAssertNil(matchedAsListed("fi-FI"))
    }

    func testOtherwiseTheSameLanguageIsMatched() {
        XCTAssertEqual(matched("pt-PT"), "pt-BR")
        let simplifiedOnly = [language("de-DE"), language("zh-CN")]
        XCTAssertEqual(LanguageMatching.match(language("zh-Hant"), in: simplifiedOnly)?.region?.identifier, "CN")
    }

    func testALanguageTheTranslatorDoesNotKnowHasNoMatch() {
        XCTAssertNil(matched("fi"))
        XCTAssertNil(matched("he"))
        XCTAssertNil(LanguageMatching.match(language("de"), in: []))
    }

    func testAnUndeterminedLanguageNeverMatches() {
        // Foundation takes "und" and "" for English
        XCTAssertTrue(LanguageMatching.isUndetermined(language("und")))
        XCTAssertTrue(LanguageMatching.isUndetermined(language("")))
        XCTAssertFalse(LanguageMatching.isUndetermined(language("en")))
        XCTAssertNil(matched("und"))
        XCTAssertNil(matched(""))
        XCTAssertNil(LanguageMatching.code(of: language("und")))
        // and is never what something else is matched to
        XCTAssertNil(LanguageMatching.match(language("en"), in: [language("und")]))
    }

    func testSameLanguageIgnoresScriptAndRegion() {
        XCTAssertTrue(LanguageMatching.sameLanguage(language("en-GB"), language("en")))
        XCTAssertTrue(LanguageMatching.sameLanguage(language("zh-Hans"), language("zh-TW")))
        XCTAssertTrue(LanguageMatching.sameLanguage(language("de-AT"), language("de-CH")))
        XCTAssertFalse(LanguageMatching.sameLanguage(language("de"), language("nl")))
        XCTAssertFalse(LanguageMatching.sameLanguage(language("und"), language("en")))
        XCTAssertFalse(LanguageMatching.sameLanguage(language("und"), language("und")))
    }

    func testKeyIsTheSameForDifferentSpellingsOfALanguage() {
        XCTAssertEqual(LanguageMatching.key(language("zh-TW")), LanguageMatching.key(language("zh-Hant-TW")))
        XCTAssertEqual(LanguageMatching.key(language("de")), LanguageMatching.key(language("de-DE")))
        XCTAssertNotEqual(LanguageMatching.key(language("zh-TW")), LanguageMatching.key(language("zh-CN")))
        XCTAssertNotEqual(LanguageMatching.key(language("en-GB")), LanguageMatching.key(language("en-US")))
    }

    func testNamesForNotices() {
        let english = Locale(identifier: "en"), german = Locale(identifier: "de")
        XCTAssertEqual(LanguageMatching.name(of: language("de-DE"), in: english), "German")
        XCTAssertEqual(LanguageMatching.name(of: language("en-GB"), in: german), "Englisch")
        XCTAssertEqual(LanguageMatching.name(of: language("fi"), in: english), "Finnish")
        // the two kinds of Chinese are told apart
        let traditional = LanguageMatching.name(of: language("zh-TW"), in: english)
        XCTAssertTrue(traditional.contains("Chinese") && traditional.contains("Traditional"), traditional)
        let simplified = LanguageMatching.name(of: language("zh-CN"), in: english)
        XCTAssertTrue(simplified.contains("Chinese") && simplified.contains("Simplified"), simplified)
        XCTAssertFalse(LanguageMatching.name(of: language("und"), in: english).isEmpty)
        XCTAssertFalse(LanguageMatching.name(of: language("xx"), in: english).isEmpty)
    }

    func testRecognizerTags() {
        XCTAssertEqual(LanguageMatching.recognizerTags(for: supported),
                       ["ar", "de", "en", "es", "fr", "hi", "id", "it", "ja", "ko", "nl", "pl", "pt", "ru", "th", "tr",
                        "uk", "vi", "zh-Hans", "zh-Hant"])
        XCTAssertEqual(LanguageMatching.recognizerTags(for: [language("und"), language("pt-BR"), language("pt-PT")]), ["pt"])
    }

    // MARK: The language of a text

    func testLettersAreCountedInEveryScript() {
        XCTAssertEqual(LanguageMatching.letterCount("Hello, world! 123"), 10)
        XCTAssertEqual(LanguageMatching.letterCount("設定を変更"), 5)
        XCTAssertEqual(LanguageMatching.letterCount("€ 12.50 – 9:41"), 0)
    }

    func testALikelyLanguageOfALongEnoughTextIsDecided() {
        let sure = finding(letters: 12, open: [("de", 0.7), ("nl", 0.2)], constrained: [("de", 0.75), ("nl", 0.2)])
        XCTAssertEqual(sure.decided, language("de"))
        XCTAssertEqual(sure.letters, 12)
        let exactly = finding(letters: 40, open: [], constrained: [("fr", 0.6), ("it", 0.4)])
        XCTAssertEqual(exactly.decided, language("fr"))
    }

    func testAShortOrUncertainTextIsOnlyGuessed() {
        let short = finding(letters: 11, open: [("de", 0.99)], constrained: [("de", 0.99)])
        XCTAssertNil(short.decided)
        XCTAssertEqual(short.guess, language("de"))
        let unsure = finding(letters: 40, open: [("es", 0.5), ("pt", 0.4)], constrained: [("es", 0.55), ("pt", 0.45)])
        XCTAssertNil(unsure.decided)
        XCTAssertEqual(unsure.guess, language("es"))
        let nothing = finding(letters: 40, open: [], constrained: [])
        XCTAssertNil(nothing.decided)
        XCTAssertNil(nothing.guess)
    }

    func testUndeterminedIsNeverTheLanguage() {
        let found = finding(letters: 40, open: [("und", 0.9)], constrained: [("und", 0.9), ("de", 0.1)])
        XCTAssertNil(found.decided)
        XCTAssertEqual(found.guess, language("de"))
    }

    func testTheOrderOfTheCandidatesDoesNotMatter() {
        let first = finding(letters: 40, open: [], constrained: [("nl", 0.3), ("de", 0.7)])
        XCTAssertEqual(first.decided, language("de"))
        let tie = finding(letters: 40, open: [], constrained: [("nl", 0.5), ("de", 0.5)])
        let same = finding(letters: 40, open: [], constrained: [("de", 0.5), ("nl", 0.5)])
        XCTAssertEqual(tie.guess, same.guess)
    }

    func testATextInALanguageTheTranslatorDoesNotKnowIsNotTakenForOneItKnows() {
        // limited to the translator's languages, the recognizer is sure of Italian
        let finnish = finding(letters: 30, open: [("fi", 0.97), ("et", 0.02)], constrained: [("it", 0.7), ("tr", 0.2)])
        XCTAssertEqual(finnish.decided, language("fi"))
        // several unknown languages share the probability
        let swedish = finding(letters: 30, open: [("sv", 0.5), ("da", 0.35)], constrained: [("nl", 0.8), ("de", 0.1)])
        XCTAssertEqual(swedish.decided, language("sv"))
        // a script none of the translator's languages is written in
        let hebrew = finding(letters: 30, open: [("he", 1)], constrained: [])
        XCTAssertEqual(hebrew.decided, language("he"))
        // not for a short text
        let short = finding(letters: 8, open: [("fi", 0.97)], constrained: [("it", 0.7)])
        XCTAssertNil(short.decided)
    }

    func testAKnownLanguageWinsOverAnUnknownRelative() {
        // Indonesian that looks like Malay at first sight
        let indonesian = finding(letters: 30, open: [("ms", 0.55), ("id", 0.4)], constrained: [("id", 0.95), ("tr", 0.02)])
        XCTAssertEqual(indonesian.decided, language("id"))
        let vague = finding(letters: 30, open: [("ca", 0.5), ("es", 0.3)], constrained: [("es", 0.5), ("pt", 0.3)])
        XCTAssertNil(vague.decided)
        XCTAssertEqual(vague.guess, language("es"))
    }

    func testThePrevailingLanguageHasTheMostLetters() {
        let findings = [decided("de", letters: 30), decided("en", letters: 20), decided("en", letters: 15),
                        LanguageMatching.Finding(guess: language("fr"), letters: 500)]
        XCTAssertEqual(LanguageMatching.prevailingLanguage(of: findings), language("en"))
        XCTAssertEqual(LanguageMatching.prevailingLanguage(of: [decided("de", letters: 20), decided("en", letters: 20)]),
                       language("de"))
        XCTAssertNil(LanguageMatching.prevailingLanguage(of: [LanguageMatching.Finding(guess: language("fr"), letters: 500)]))
        XCTAssertNil(LanguageMatching.prevailingLanguage(of: []))
    }

    // MARK: A request

    func testTextsAreGroupedByLanguageInTheOrderOfTheRequest() {
        let findings = [
            decided("en", letters: 30),                                     // 0
            decided("de", letters: 25),                                     // 1: the target language
            LanguageMatching.Finding(guess: language("nl"), letters: 5),    // 2: takes the common language
            decided("fr", letters: 20),                                     // 3
            LanguageMatching.Finding(letters: 0),                           // 4: nothing to translate
            decided("fi", letters: 40),                                     // 5: not known to the translator
            decided("en", letters: 14),                                     // 6
            decided("zh-Hant", letters: 12),                                // 7
        ]
        let plan = LanguageMatching.Plan(findings: findings, common: language("en"), target: language("de-DE"),
                                         supported: supported)
        XCTAssertEqual(plan.groups.map(\.indices), [[0, 2, 6], [3], [7]])
        XCTAssertEqual(plan.groups.map { $0.source.languageCode?.identifier }, ["en", "fr", "zh"])
        // the languages are the translator's own
        XCTAssertEqual(plan.groups.map { $0.source.region?.identifier }, ["US", "FR", "TW"])
        XCTAssertEqual(plan.unchanged, [1, 4, 5])
        XCTAssertEqual(plan.postponed, [])
        XCTAssertEqual(plan.unknown, [language("fi")])
    }

    func testWithoutACommonLanguageOnlyLongTextsAreTranslatedOnAGuess() {
        let findings = [
            LanguageMatching.Finding(guess: language("en"), letters: 8),
            LanguageMatching.Finding(guess: language("en"), letters: 20),
            LanguageMatching.Finding(letters: 30),
            LanguageMatching.Finding(guess: language("de"), letters: 25),
        ]
        let plan = LanguageMatching.Plan(findings: findings, common: nil, target: language("de"), supported: supported)
        XCTAssertEqual(plan.postponed, [0, 2])
        XCTAssertEqual(plan.groups.map(\.indices), [[1]])
        XCTAssertEqual(plan.unchanged, [3])
        XCTAssertEqual(plan.unknown, [])
    }

    func testTextsInTheTargetLanguageOrAnUnknownOneStayAsTheyAre() {
        let short = LanguageMatching.Finding(guess: language("en"), letters: 6)
        let german = LanguageMatching.Plan(findings: [short, decided("de-CH", letters: 30)], common: language("de"),
                                           target: language("de-DE"), supported: supported)
        XCTAssertEqual(german.unchanged, [0, 1])
        XCTAssertTrue(german.groups.isEmpty)
        XCTAssertTrue(german.unknown.isEmpty)

        let finnish = LanguageMatching.Plan(findings: [short, decided("fi", letters: 30), short], common: language("fi"),
                                            target: language("de-DE"), supported: supported)
        XCTAssertEqual(finnish.unchanged, [0, 1, 2])
        XCTAssertTrue(finnish.groups.isEmpty)
        XCTAssertEqual(finnish.unknown, [language("fi")])
    }

    func testAnUnknownLanguageIsOnlyMentionedWhenEnoughTextIsInIt() {
        // one word the recognizer took for Romanian, on an Italian screen
        let stray = LanguageMatching.Plan(findings: [decided("ro", letters: 14), decided("it", letters: 60)],
                                          common: language("it"), target: language("de"), supported: supported)
        XCTAssertEqual(stray.unchanged, [0])
        XCTAssertEqual(stray.groups.map(\.indices), [[1]])
        XCTAssertEqual(stray.unknown, [])
        // several texts add up
        let more = LanguageMatching.Plan(findings: [decided("ro", letters: 14), decided("ro", letters: 13),
                                                    decided("ro", letters: 13), decided("el", letters: 39)],
                                         common: nil, target: language("de"), supported: supported)
        XCTAssertEqual(more.unchanged, [0, 1, 2, 3])
        XCTAssertEqual(more.unknown, [language("ro")])
    }

    func testResultsComeBackInTheOrderOfTheRequest() {
        let texts = ["Hello there, how are you?", "Guten Tag zusammen", "Bonjour tout le monde", "OK", "12:30"]
        let findings = [decided("en", letters: 20), decided("de", letters: 16), decided("fr", letters: 18),
                        LanguageMatching.Finding(letters: 2), LanguageMatching.Finding(letters: 0)]
        let plan = LanguageMatching.Plan(findings: findings, common: language("en"), target: language("de"),
                                         supported: supported)
        var results = plan.results(for: texts)
        XCTAssertEqual(results, [nil, "Guten Tag zusammen", nil, nil, "12:30"])
        XCTAssertEqual(plan.groups.map(\.indices), [[0, 3], [2]])
        plan.groups[1].place(["Hallo zusammen"], in: &results)
        plan.groups[0].place(["Hallo, wie geht es dir?", nil], in: &results)
        XCTAssertEqual(results, ["Hallo, wie geht es dir?", "Guten Tag zusammen", "Hallo zusammen", nil, "12:30"])
        // more or fewer translations than texts do no harm
        plan.groups[0].place(["a", "b", "c"], in: &results)
        XCTAssertEqual(results, ["a", "Guten Tag zusammen", "Hallo zusammen", "b", "12:30"])
        plan.groups[0].place([], in: &results)
        XCTAssertEqual(results.count, texts.count)
    }
}
