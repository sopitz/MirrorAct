// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import XCTest
@testable import MirrorAct

/// Languages of a translator that knows a fixed set of them (Foundation only, like the core)
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

    /// What a recognizer said about a text of `words` words with `letters` letters in them
    private func finding(letters: Int, words: Int = 4, open: [(String, Double)],
                         constrained: [(String, Double)]) -> LanguageMatching.Finding {
        LanguageMatching.finding(of: LanguageMatching.Wording(words: words, letters: letters), letters: letters,
                                 open: hypotheses(open), constrained: hypotheses(constrained), supported: supported)
    }

    /// A text that counts for the screen's language, but goes with another one the screen is in
    private func decided(_ identifier: String, letters: Int) -> LanguageMatching.Finding {
        LanguageMatching.Finding(decided: language(identifier), letters: letters)
    }

    /// A text that keeps its language on a screen in another one
    private func apart(_ identifier: String, letters: Int) -> LanguageMatching.Finding {
        LanguageMatching.Finding(decided: language(identifier), letters: letters, standsApart: true)
    }

    private func screen(_ identifier: String, letters: Int = 100) -> LanguageMatching.ScreenLanguage {
        LanguageMatching.ScreenLanguage(language: language(identifier), letters: letters)
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
        // the form macOS falls back to, not the first other country in the list
        XCTAssertEqual(matched("en-AU"), "en-GB")
        XCTAssertEqual(matched("en-CA"), "en-US")
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
        XCTAssertEqual(matchedAsListed("fr-BE"), "fr")
        XCTAssertEqual(matchedAsListed("fr-CH"), "fr")
        // French in Africa is written as in France; macOS has no wider form for it
        XCTAssertEqual(matchedAsListed("fr-SN"), "fr")
        XCTAssertEqual(matchedAsListed("fr-CI"), "fr")
        XCTAssertEqual(matchedAsListed("fr-MA"), "fr")
        XCTAssertEqual(matchedAsListed("it-SM"), "it")
        XCTAssertEqual(matchedAsListed("es-ES"), "es")
        XCTAssertEqual(matchedAsListed("es-GQ"), "es")
        // English where macOS puts it under en-001: as in the United States
        XCTAssertEqual(matchedAsListed("en-001"), "en")
        XCTAssertEqual(matchedAsListed("en-AO"), "en")
        XCTAssertEqual(matchedAsListed("en-JP"), "en")
        XCTAssertEqual(matchedAsListed("en-PR"), "en")
        // Chinese in the script of the region
        XCTAssertEqual(matchedAsListed("zh-SG"), "zh")
        XCTAssertEqual(matchedAsListed("zh-MY"), "zh")
        XCTAssertEqual(matchedAsListed("zh-Hant-MY"), "zh-TW")
        XCTAssertEqual(matchedAsListed("zh-Hans-MO"), "zh")
        XCTAssertEqual(matchedAsListed("zh-Hant"), "zh-TW")
        XCTAssertEqual(matchedAsListed("zh-Hans"), "zh")
    }

    /// The form macOS itself falls back to for a region (`Locale.Language.parent`, which is how
    /// a Mac set to en-DE shows apps in British English), where macOS lists it
    func testARegionMacOSDoesNotTranslateGetsTheClosestWiderFormItLists() {
        // English in Europe and the Commonwealth is British English, never the first country
        // of the list (Indian English)
        XCTAssertEqual(matchedAsListed("en-DE"), "en-GB")
        XCTAssertEqual(matchedAsListed("en-150"), "en-GB")
        XCTAssertEqual(matchedAsListed("en-CH"), "en-GB")
        XCTAssertEqual(matchedAsListed("en-HK"), "en-GB")
        XCTAssertEqual(matchedAsListed("en-NG"), "en-GB")
        XCTAssertEqual(matchedAsListed("en-WS"), "en-AU")
        // Latin American Spanish: macOS lists Mexico and the United States, not es-419
        XCTAssertEqual(matchedAsListed("es-419"), "es-MX")
        XCTAssertEqual(matchedAsListed("es-AR"), "es-MX")
        XCTAssertEqual(matchedAsListed("es-CO"), "es-MX")
        XCTAssertEqual(matchedAsListed("es-PR"), "es-MX")
        let withoutMexico = listedByMacOS.filter { $0.minimalIdentifier != "es-MX" }
        XCTAssertEqual(LanguageMatching.match(language("es-AR"), in: withoutMexico)?.minimalIdentifier, "es-US")
        XCTAssertEqual(LanguageMatching.match(language("es-419"), in: withoutMexico)?.minimalIdentifier, "es-US")
        // whatever the order of the list
        XCTAssertEqual(LanguageMatching.match(language("es-AR"), in: listedByMacOS.reversed())?.minimalIdentifier,
                       "es-MX")
        // Portuguese in Africa and Asia is written as in Portugal
        XCTAssertEqual(matchedAsListed("pt-AO"), "pt-PT")
        XCTAssertEqual(matchedAsListed("pt-MZ"), "pt-PT")
        XCTAssertEqual(matchedAsListed("pt-MO"), "pt-PT")
        // Macau writes Traditional Chinese as Hong Kong does
        XCTAssertEqual(matchedAsListed("zh-MO"), "zh-HK")
        XCTAssertEqual(matchedAsListed("zh-Hant-MO"), "zh-HK")
    }

    func testARegionMacOSTranslatesIsTakenAsItIs() {
        XCTAssertEqual(matchedAsListed("de-CH"), "de-CH")
        XCTAssertEqual(matchedAsListed("de-DE"), "de")
        XCTAssertEqual(matchedAsListed("en-US"), "en")
        XCTAssertEqual(matchedAsListed("en-IN"), "en-IN")
        XCTAssertEqual(matchedAsListed("en-AU"), "en-AU")
        XCTAssertEqual(matchedAsListed("fr-CA"), "fr-CA")
        XCTAssertEqual(matchedAsListed("pt-PT"), "pt-PT")
        XCTAssertEqual(matchedAsListed("pt-BR"), "pt")
        XCTAssertEqual(matchedAsListed("es-MX"), "es-MX")
        XCTAssertEqual(matchedAsListed("es-US"), "es-US")
        XCTAssertEqual(matchedAsListed("zh-HK"), "zh-HK")
        // the region in another script is another language
        XCTAssertEqual(matchedAsListed("zh-Hans-HK"), "zh")
        XCTAssertNil(matchedAsListed("fi-FI"))
    }

    /// The languages of Apple's on-device models on macOS 26.4 and later
    /// (`LanguageAvailability(preferredStrategy: .lowLatency)`), as macOS lists them; the 38 of
    /// `listedByMacOS` are those of all its models, many of which need Apple Intelligence
    private let onDevice: [Locale.Language] = [
        "vi", "pt", "uk", "it", "zh-TW", "ko", "de", "en-GB", "zh", "ja", "id", "nl", "fr", "th", "es", "tr", "pl",
        "ar-AE", "ru", "en", "hi",
    ].map { Locale.Language(identifier: $0) }

    /// The on-device list first: its closest form even where only the longer list has the region,
    /// the longer list only for a language the first one does not have at all
    func testTheFirstListThatHasTheLanguageDecides() {
        let cases: [(wanted: String, expected: String?)] = [
            // regions the on-device models do not have: their closest form
            ("es-419", "es"), ("es-AR", "es"), ("es-MX", "es"), ("es-US", "es"), ("es-ES", "es"),
            ("pt-PT", "pt"), ("pt-AO", "pt"), ("pt-BR", "pt"),
            ("en-DE", "en-GB"), ("en-150", "en-GB"), ("en-IN", "en-GB"), ("en-AU", "en-GB"), ("en-NZ", "en-GB"),
            ("en-CA", "en"), ("en-US", "en"), ("en-001", "en"),
            ("zh-HK", "zh-TW"), ("zh-MO", "zh-TW"), ("zh-Hant", "zh-TW"), ("zh-Hans-HK", "zh"), ("zh-SG", "zh"),
            ("de-CH", "de"), ("de-AT", "de"), ("fr-CA", "fr"), ("fr-CH", "fr"), ("it-CH", "it"),
            // what both lists have
            ("en-GB", "en-GB"), ("de", "de"), ("ar-AE", "ar-AE"), ("ja", "ja"),
            // only the longer list has these languages
            ("da", "da"), ("da-DK", "da"), ("sv", "sv"), ("sv-FI", "sv"), ("nb", "nb"),
            // neither
            ("fi", nil), ("he", nil), ("und", nil), ("", nil),
        ]
        for (wanted, expected) in cases {
            let match = LanguageMatching.match(language(wanted), inFirstOf: [onDevice, listedByMacOS])
            XCTAssertEqual(match?.minimalIdentifier, expected, wanted)
        }
        // only one kind of models (before macOS 26.4), or one list: as `match(_:in:)`
        for wanted in ["es-AR", "pt-PT", "en-DE", "en-IN", "zh-HK", "de-CH", "da", "fi"] {
            XCTAssertEqual(LanguageMatching.match(language(wanted), inFirstOf: [listedByMacOS])?.minimalIdentifier,
                           matchedAsListed(wanted), wanted)
            XCTAssertEqual(LanguageMatching.match(language(wanted), inFirstOf: [listedByMacOS, listedByMacOS]),
                           LanguageMatching.match(language(wanted), in: listedByMacOS), wanted)
        }
        // an empty first list leaves it to the next
        XCTAssertEqual(LanguageMatching.match(language("pt-PT"), inFirstOf: [[], listedByMacOS])?.minimalIdentifier,
                       "pt-PT")
        XCTAssertNil(LanguageMatching.match(language("de"), inFirstOf: []))
    }

    /// The languages of the texts are matched the same way
    func testAPlanTakesTheSourcesFromTheFirstListThatHasThem() {
        let findings = [decided("da", letters: 30), decided("pt", letters: 30), decided("en", letters: 30),
                        decided("fi", letters: 40), decided("de", letters: 30), decided("zh-Hant", letters: 20)]
        let plan = LanguageMatching.Plan(findings: findings, screen: nil, target: language("de"),
                                         lists: [onDevice, listedByMacOS])
        XCTAssertEqual(plan.groups.map(\.source.minimalIdentifier), ["da", "pt", "en", "zh-TW"])
        XCTAssertEqual(plan.groups.map(\.indices), [[0], [1], [2], [5]])
        XCTAssertEqual(plan.unchanged, [3, 4])
        XCTAssertEqual(plan.unknown, [language("fi")])
        // one list: as before
        let single = LanguageMatching.Plan(findings: findings, screen: nil, target: language("de"),
                                           supported: onDevice)
        XCTAssertEqual(single.groups.map(\.source.minimalIdentifier), ["pt", "en", "zh-TW"])
        XCTAssertEqual(single.unchanged, [0, 3, 4])
        XCTAssertEqual(single.unknown, [language("fi")])
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

    // MARK: The words of a text

    private func words(_ text: String) -> String {
        LanguageMatching.wording(of: text).text
    }

    /// Model names, serial numbers, identifiers, addresses, numbers and acronyms are written the
    /// same in every language: the recognizer is not given them
    func testOnlyWordsSpeakForALanguage() {
        for identifier in ["sdk_gphone64_arm64", "EMULATOR37X1X11X0", "SM-G991B", "A2848", "anna.mueller@example.com",
                           "https://www.example.com/help", "www.example.org", "192.168.1.20", "12,99 €", "03.03.2025",
                           "12:30", "AndroidWifi", "iPhone", "YouTube", "WhatsApp", "IMEI", "WLAN", "OK", "3月3日(月)",
                           "#hashtag", "a=b", "C:\\Users", "~/Documents", "z.B.", "Ton&Vibration", "", " – "] {
            let wording = LanguageMatching.wording(of: identifier)
            XCTAssertEqual(wording.words, 0, identifier)
            XCTAssertEqual(wording.letters, 0, identifier)
            XCTAssertEqual(wording.text, "", identifier)
        }
        XCTAssertEqual(words("VPN Kein VPN"), "Kein")
        XCTAssertEqual(words("Android-Version 16"), "Android-Version")
        XCTAssertEqual(words("Status der SIM-Karte"), "Status der SIM-Karte")
        XCTAssertEqual(words("Ton & Vibration"), "Ton Vibration")
        XCTAssertEqual(words("Wird aktiviert, wenn der Modus „Bedtime“ beginnt."), "Wird aktiviert wenn der Modus Bedtime beginnt")
        // a name written like a word is a word
        XCTAssertEqual(words("Modell: sdk_gphone64_arm64 (Android 16)"), "Modell Android")
        XCTAssertEqual(words("aujourd’hui l'heure -Test- T-Mobile"), "aujourd’hui l'heure Test T-Mobile")
        XCTAssertEqual(words("¿Me puedes ayudar?"), "Me puedes ayudar")
        let wording = LanguageMatching.wording(of: "Hotspot und Tethering")
        XCTAssertEqual(wording.words, 3)
        XCTAssertEqual(wording.letters, 19)
        XCTAssertTrue(wording.isCased)
    }

    /// Chinese, Japanese and Thai set no spaces between words: other punctuation separates, a
    /// numeral that is a letter stays, and a letter of Chinese, Japanese or Korean weighs three
    func testWordsOfScriptsWithoutSpaces() {
        let japanese = LanguageMatching.wording(of: "ケーキはオーブンの中で、あと二十分かかります。")
        XCTAssertEqual(japanese.text, "ケーキはオーブンの中で あと二十分かかります")
        XCTAssertEqual(japanese.words, 2)
        XCTAssertEqual(japanese.letters, 21 * LanguageMatching.denseLetterWeight)
        XCTAssertFalse(japanese.isCased)
        XCTAssertEqual(LanguageMatching.wording(of: "設定").letters, 6)
        XCTAssertEqual(LanguageMatching.wording(of: "설정").letters, 6)
        // Thai and Arabic letters stand for sounds, as Latin ones do
        XCTAssertEqual(LanguageMatching.wording(of: "ภาษาไทย").letters, 7)
        XCTAssertEqual(LanguageMatching.wording(of: "الإعدادات").letters, 9)
        XCTAssertEqual(LanguageMatching.letterWeight("a"), 1)
        XCTAssertEqual(LanguageMatching.letterWeight("ア"), 3)
        XCTAssertEqual(LanguageMatching.letterWeight("漢"), 3)
        // the digits of every script are digits
        XCTAssertEqual(LanguageMatching.wording(of: "Version ٣").words, 1)
        XCTAssertEqual(LanguageMatching.wording(of: "Seite ７").text, "Seite")
    }

    func testTheWordsOfSeveralTextsAreReadTogether() {
        let joint = LanguageMatching.Wording(joining: ["Akku", "sdk_gphone64_arm64", "An", "設定"].map(LanguageMatching.wording(of:)))
        XCTAssertEqual(joint.text, "Akku An 設定")
        XCTAssertEqual(joint.words, 3)
        XCTAssertEqual(joint.letters, 12)
        // half of the weight has case
        XCTAssertTrue(joint.isCased)
        let findings = [LanguageMatching.Finding(letters: 4), LanguageMatching.Finding(decided: language("de"), letters: 30),
                        LanguageMatching.Finding(letters: 2), LanguageMatching.Finding(letters: 18)]
        let wordings = ["Akku", "Rechtliche Informationen und Hinweise", "An", "sdk_gphone64_arm64"].map(LanguageMatching.wording(of:))
        // the texts without a language and with words
        XCTAssertEqual(LanguageMatching.jointWording(of: wordings, findings: findings)?.text, "Akku An")
        XCTAssertNil(LanguageMatching.jointWording(of: Array(wordings.prefix(2)), findings: Array(findings.prefix(2))))
    }

    // MARK: The language of a text

    func testLettersAreCountedInEveryScript() {
        XCTAssertEqual(LanguageMatching.letterCount("Hello, world! 123"), 10)
        XCTAssertEqual(LanguageMatching.letterCount("設定を変更"), 5)
        XCTAssertEqual(LanguageMatching.letterCount("€ 12.50 – 9:41"), 0)
    }

    func testALikelyLanguageOfALongEnoughTextIsDecided() {
        let sure = finding(letters: 12, words: 2, open: [("de", 0.7), ("nl", 0.2)], constrained: [("de", 0.75), ("nl", 0.2)])
        XCTAssertEqual(sure.decided, language("de"))
        XCTAssertEqual(sure.letters, 12)
        XCTAssertEqual(sure.weight, 12)
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

    /// One word looks like a word of many languages: "Telefonnummer" was taken for Norwegian
    /// (0.65), "Seriennummer" for German (0.65). In a script without case one "word" may be a
    /// whole sentence.
    func testASingleWordDecidesNothing() {
        let single = finding(letters: 13, words: 1, open: [("nb", 0.64), ("da", 0.22)], constrained: [("nb", 0.65), ("da", 0.22)])
        XCTAssertNil(single.decided)
        XCTAssertEqual(single.guess, language("nb"))
        XCTAssertFalse(single.standsApart)
        let two = finding(letters: 13, words: 2, open: [("nb", 0.64)], constrained: [("nb", 0.65)])
        XCTAssertEqual(two.decided, language("nb"))
        let japanese = LanguageMatching.finding(of: LanguageMatching.wording(of: "明日の会議は何時からですか"), letters: 13,
                                                open: hypotheses([("ja", 1)]), constrained: hypotheses([("ja", 1)]),
                                                supported: supported)
        XCTAssertEqual(japanese.decided, language("ja"))
        XCTAssertTrue(japanese.standsApart)
        // a text without words is not even guessed
        let model = LanguageMatching.finding(of: LanguageMatching.wording(of: "sdk_gphone64_arm64"), letters: 12,
                                             open: hypotheses([("id", 0.67)]), constrained: hypotheses([("id", 0.67)]),
                                             supported: supported)
        XCTAssertNil(model.decided)
        XCTAssertNil(model.guess)
        XCTAssertEqual(model.letters, 12)
        XCTAssertEqual(model.weight, 0)
    }

    /// Only enough words, letters and a clear probability let a text keep a language of its own
    /// on a screen in another one
    func testATextStandsApartWithEnoughWordsLettersAndCertainty() {
        let paragraph = finding(letters: 70, words: 14, open: [("fr", 1)], constrained: [("fr", 1)])
        XCTAssertTrue(paragraph.standsApart)
        let atTheLimit = finding(letters: LanguageMatching.lettersToStandApart, words: LanguageMatching.wordsToStandApart,
                                 open: [("fr", 0.9)], constrained: [("fr", LanguageMatching.probabilityToStandApart)])
        XCTAssertTrue(atTheLimit.standsApart)
        // "Do Not Disturb, Bedtime" on a German screen: 19 letters
        let fewLetters = finding(letters: 19, words: 4, open: [("en", 0.91)], constrained: [("en", 0.92)])
        XCTAssertEqual(fewLetters.decided, language("en"))
        XCTAssertFalse(fewLetters.standsApart)
        let fewWords = finding(letters: 30, words: 2, open: [("de", 0.99)], constrained: [("de", 0.99)])
        XCTAssertFalse(fewWords.standsApart)
        let unclear = finding(letters: 40, words: 6, open: [("en", 0.85)], constrained: [("en", 0.89)])
        XCTAssertEqual(unclear.decided, language("en"))
        XCTAssertFalse(unclear.standsApart)
        // a language the translator does not know: by the share of all such languages
        let finnish = finding(letters: 40, words: 6, open: [("fi", 0.85), ("et", 0.1)], constrained: [("it", 0.7)])
        XCTAssertEqual(finnish.decided, language("fi"))
        XCTAssertTrue(finnish.standsApart)
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

    // MARK: The language of the screen

    func testTheScreensLanguageIsTheOneMostTextSpeaksFor() {
        let findings = [decided("de", letters: 30), decided("en", letters: 20), decided("en", letters: 15),
                        LanguageMatching.Finding(guess: language("fr"), letters: 500)]
        XCTAssertEqual(LanguageMatching.screenLanguage(of: findings, before: nil), screen("en", letters: 35))
        // a tie: the one that comes first
        XCTAssertEqual(LanguageMatching.screenLanguage(of: [decided("de", letters: 20), decided("en", letters: 20)], before: nil),
                       screen("de", letters: 20))
        // texts that decide nothing take no part, whatever their letters
        XCTAssertNil(LanguageMatching.screenLanguage(of: [LanguageMatching.Finding(guess: language("fr"), letters: 500)], before: nil))
        XCTAssertNil(LanguageMatching.screenLanguage(of: [], before: nil))
        // what speaks for a language is its words: a model name next to it weighs nothing
        let weighed = [LanguageMatching.Finding(decided: language("id"), letters: 40, weight: 12),
                       decided("de", letters: 13)]
        XCTAssertEqual(LanguageMatching.screenLanguage(of: weighed, before: nil), screen("de", letters: 13))
    }

    /// A request brings new texts only: what it holds replaces the language the screen was in
    /// only with enough text, and more than it has in the language before
    func testTheScreensLanguageChangesOnlyWithEnoughText() {
        let german = screen("de", letters: 300)
        let limit = LanguageMatching.lettersToChangeTheScreensLanguage
        // nothing decided: as before
        XCTAssertEqual(LanguageMatching.screenLanguage(of: [LanguageMatching.Finding(letters: 13)], before: german), german)
        // one short text in another language
        XCTAssertEqual(LanguageMatching.screenLanguage(of: [decided("nb", letters: limit - 1)], before: german), german)
        // enough of it
        XCTAssertEqual(LanguageMatching.screenLanguage(of: [decided("fr", letters: limit)], before: german),
                       screen("fr", letters: limit))
        // but not more than what this request has in the language before
        XCTAssertEqual(LanguageMatching.screenLanguage(of: [decided("fr", letters: 40), decided("de", letters: 40)],
                                                       before: german), german)
        XCTAssertEqual(LanguageMatching.screenLanguage(of: [decided("de", letters: 40), decided("fr", letters: 40)],
                                                       before: german), german)
        XCTAssertEqual(LanguageMatching.screenLanguage(of: [decided("de", letters: 30), decided("fr", letters: 40)],
                                                       before: german), screen("fr", letters: 40))
        // the same language keeps the most letters it ever had
        XCTAssertEqual(LanguageMatching.screenLanguage(of: [decided("de-CH", letters: 20)], before: german), german)
        XCTAssertEqual(LanguageMatching.screenLanguage(of: [decided("de", letters: 20)], before: screen("de", letters: 5)),
                       screen("de", letters: 20))
    }

    /// A screen on which nothing decides a language (Android's Modell page: "Modell", "Modell",
    /// "Seriennummer" read together are German at 0.47) is taken to be in the likeliest one, with
    /// no letters behind it: never enough to ask for it
    func testWhenNothingDecidesTheScreenIsInTheLikeliestLanguage() {
        let undecided = [LanguageMatching.Finding(guess: language("nb"), letters: 6),
                         LanguageMatching.Finding(guess: language("de"), letters: 12),
                         LanguageMatching.Finding(letters: 18, weight: 0)]
        let joint = LanguageMatching.Finding(guess: language("de"), letters: 24)
        XCTAssertEqual(LanguageMatching.screenGuess(of: undecided, joint: joint), language("de"))
        // without a joint reading: the text with the most letters in words
        XCTAssertEqual(LanguageMatching.screenGuess(of: undecided, joint: nil), language("de"))
        XCTAssertNil(LanguageMatching.screenGuess(of: [LanguageMatching.Finding(letters: 18, weight: 0)], joint: nil))
        XCTAssertEqual(LanguageMatching.screenLanguage(of: undecided + [joint], before: nil, guess: language("de")),
                       screen("de", letters: 0))
        // what is known goes first
        XCTAssertEqual(LanguageMatching.screenLanguage(of: undecided, before: screen("fr"), guess: language("de")), screen("fr"))
        XCTAssertEqual(LanguageMatching.screenLanguage(of: [decided("en", letters: 13)], before: nil, guess: language("de")),
                       screen("en", letters: 13))
        XCTAssertNil(LanguageMatching.screenLanguage(of: undecided, before: nil, guess: language("und")))
        // a guess is no reason to ask for the language, and a real screen replaces it
        let plan = LanguageMatching.Plan(findings: undecided, screen: screen("de", letters: 0), target: language("en"),
                                         supported: supported)
        XCTAssertEqual(plan.groups.map(\.indices), [[0, 1, 2]])
        XCTAssertEqual(plan.groups.map(\.mayAskForTheLanguage), [false])
        XCTAssertEqual(LanguageMatching.screenLanguage(of: [decided("fr", letters: LanguageMatching.lettersToChangeTheScreensLanguage)],
                                                       before: screen("de", letters: 0)),
                       screen("fr", letters: LanguageMatching.lettersToChangeTheScreensLanguage))
    }

    // MARK: A request

    func testTextsAreGroupedByLanguageInTheOrderOfTheRequest() {
        let findings = [
            decided("en", letters: 30),                                     // 0
            apart("de", letters: 25),                                       // 1: the target language
            LanguageMatching.Finding(guess: language("nl"), letters: 5),    // 2: takes the screen's language
            apart("fr", letters: 30),                                       // 3
            LanguageMatching.Finding(letters: 0),                           // 4: nothing to translate
            apart("fi", letters: 40),                                       // 5: not known to the translator
            decided("en", letters: 14),                                     // 6
            apart("zh-Hant", letters: 36),                                  // 7
        ]
        let plan = LanguageMatching.Plan(findings: findings, screen: screen("en"), target: language("de-DE"),
                                         supported: supported)
        XCTAssertEqual(plan.groups.map(\.indices), [[0, 2, 6], [3], [7]])
        XCTAssertEqual(plan.groups.map { $0.source.languageCode?.identifier }, ["en", "fr", "zh"])
        // the languages are the translator's own
        XCTAssertEqual(plan.groups.map { $0.source.region?.identifier }, ["US", "FR", "TW"])
        XCTAssertEqual(plan.unchanged, [1, 4, 5])
        XCTAssertEqual(plan.postponed, [])
        XCTAssertEqual(plan.unknown, [language("fi")])
    }

    /// The Modell page of Android's About phone, as the recognizer read it: "sdk_gphone64_arm64"
    /// was Indonesian (0.67), "Telefonnummer" Norwegian (0.65). None of it is a language of its
    /// own on a German screen, and none of it gets a pair.
    func testATextThatDoesNotStandApartGoesWithTheScreen() {
        let texts = ["Modell", "sdk_gphone64_arm64", "Telefonnummer", "Hotspot und Tethering", "Seriennummer"]
        let recorded: [[(String, Double)]] = [[("nb", 0.35), ("sv", 0.26)], [("id", 0.67), ("ms", 0.2)],
                                              [("nb", 0.65), ("da", 0.22)], [("nb", 0.7), ("de", 0.25)],
                                              [("de", 0.65), ("sv", 0.22)]]
        let findings = zip(texts, recorded).map { text, hypotheses in
            LanguageMatching.finding(of: LanguageMatching.wording(of: text), letters: LanguageMatching.letterCount(text),
                                     open: self.hypotheses(hypotheses), constrained: self.hypotheses(hypotheses),
                                     supported: supported)
        }
        XCTAssertEqual(findings.map(\.decided), [nil, nil, nil, language("nb"), nil])
        XCTAssertTrue(findings.allSatisfy { !$0.standsApart })
        let plan = LanguageMatching.Plan(findings: findings, screen: screen("de"), target: language("en"), supported: supported)
        XCTAssertEqual(plan.groups.map { $0.source.languageCode?.identifier }, ["de"])
        XCTAssertEqual(plan.groups.map(\.indices), [[0, 1, 2, 3, 4]])
        // with nothing else known, a text keeps its own language, and a word or a name waits
        let alone = LanguageMatching.Plan(findings: findings, screen: nil, target: language("en"),
                                          supported: supported + [language("nb")])
        XCTAssertEqual(alone.groups.map { $0.source.languageCode?.identifier }, ["nb"])
        XCTAssertEqual(alone.groups.map(\.indices), [[3]])
        XCTAssertEqual(alone.postponed, [0, 1, 2, 4])
    }

    /// A paragraph in another language keeps its own, on a screen in any language
    func testATextThatStandsApartKeepsItsLanguage() {
        let findings = [decided("de", letters: 20), apart("fr", letters: 70), decided("fr", letters: 16),
                        LanguageMatching.Finding(letters: 6)]
        let plan = LanguageMatching.Plan(findings: findings, screen: screen("de"), target: language("en"), supported: supported)
        XCTAssertEqual(plan.groups.map { $0.source.languageCode?.identifier }, ["de", "fr"])
        XCTAssertEqual(plan.groups.map(\.indices), [[0, 2, 3], [1]])
    }

    /// Asking for a language that has to be loaded first takes a screen written in it, or a
    /// text that stands apart in it: never one short text, a name or a number
    func testOnlyALanguageEnoughTextIsInMayBeAskedFor() {
        let limit = LanguageMatching.lettersToAskForALanguage
        let findings = [decided("de", letters: 20), apart("fr", letters: 70), decided("es", letters: 16),
                        LanguageMatching.Finding(letters: 6)]
        let plan = LanguageMatching.Plan(findings: findings, screen: screen("de", letters: limit), target: language("en"),
                                         supported: supported)
        XCTAssertEqual(plan.groups.map { $0.source.languageCode?.identifier }, ["de", "fr"])
        XCTAssertEqual(plan.groups.map(\.mayAskForTheLanguage), [true, true])
        // too little of the screen is in its language
        let little = LanguageMatching.Plan(findings: findings, screen: screen("de", letters: limit - 1), target: language("en"),
                                           supported: supported)
        XCTAssertEqual(little.groups.map(\.mayAskForTheLanguage), [false, true])
        // the language of the screen is Norwegian only because of one text
        let norwegian = LanguageMatching.Plan(findings: [decided("nb", letters: 19), LanguageMatching.Finding(letters: 6)],
                                              screen: screen("nb", letters: 19), target: language("en"),
                                              lists: [supported, supported + [language("nb")]])
        XCTAssertEqual(norwegian.groups.map(\.indices), [[0, 1]])
        XCTAssertEqual(norwegian.groups.map(\.mayAskForTheLanguage), [false])
        // nothing known: a guess is no reason to ask either
        let guessed = LanguageMatching.Plan(findings: [LanguageMatching.Finding(guess: language("fr"), letters: 30)],
                                            screen: nil, target: language("en"), supported: supported)
        XCTAssertEqual(guessed.groups.map(\.mayAskForTheLanguage), [false])
    }

    func testWithoutAScreenLanguageOnlyLongTextsAreTranslatedOnAGuess() {
        let findings = [
            LanguageMatching.Finding(guess: language("en"), letters: 8),
            LanguageMatching.Finding(guess: language("en"), letters: 20),
            LanguageMatching.Finding(letters: 30),
            LanguageMatching.Finding(guess: language("de"), letters: 25),
            // its letters are in a model name
            LanguageMatching.Finding(guess: language("en"), letters: 30, weight: 6),
        ]
        let plan = LanguageMatching.Plan(findings: findings, screen: nil, target: language("de"), supported: supported)
        XCTAssertEqual(plan.postponed, [0, 2, 4])
        XCTAssertEqual(plan.groups.map(\.indices), [[1]])
        XCTAssertEqual(plan.unchanged, [3])
        XCTAssertEqual(plan.unknown, [])
    }

    func testTextsInTheTargetLanguageOrAnUnknownOneStayAsTheyAre() {
        let short = LanguageMatching.Finding(guess: language("en"), letters: 6)
        let german = LanguageMatching.Plan(findings: [short, decided("de-CH", letters: 30)], screen: screen("de"),
                                           target: language("de-DE"), supported: supported)
        XCTAssertEqual(german.unchanged, [0, 1])
        XCTAssertTrue(german.groups.isEmpty)
        XCTAssertTrue(german.unknown.isEmpty)

        let finnish = LanguageMatching.Plan(findings: [short, decided("fi", letters: 30), short], screen: screen("fi"),
                                            target: language("de-DE"), supported: supported)
        XCTAssertEqual(finnish.unchanged, [0, 1, 2])
        XCTAssertTrue(finnish.groups.isEmpty)
        XCTAssertEqual(finnish.unknown, [language("fi")])
    }

    func testAnUnknownLanguageIsOnlyMentionedWhenEnoughTextIsInIt() {
        // one word the recognizer took for Romanian, on an Italian screen: it goes with the screen
        let stray = LanguageMatching.Plan(findings: [decided("ro", letters: 14), decided("it", letters: 60)],
                                          screen: screen("it"), target: language("de"), supported: supported)
        XCTAssertEqual(stray.unchanged, [])
        XCTAssertEqual(stray.groups.map(\.indices), [[0, 1]])
        XCTAssertEqual(stray.unknown, [])
        // several texts add up
        let more = LanguageMatching.Plan(findings: [decided("ro", letters: 14), decided("ro", letters: 13),
                                                    decided("ro", letters: 13), decided("el", letters: 39)],
                                         screen: nil, target: language("de"), supported: supported)
        XCTAssertEqual(more.unchanged, [0, 1, 2, 3])
        XCTAssertEqual(more.unknown, [language("ro")])
    }

    func testResultsComeBackInTheOrderOfTheRequest() {
        let texts = ["Hello there, how are you?", "Guten Tag zusammen", "Bonjour tout le monde", "OK", "12:30"]
        let findings = [decided("en", letters: 20), apart("de", letters: 16), apart("fr", letters: 18),
                        LanguageMatching.Finding(letters: 2), LanguageMatching.Finding(letters: 0)]
        let plan = LanguageMatching.Plan(findings: findings, screen: screen("en"), target: language("de"),
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
