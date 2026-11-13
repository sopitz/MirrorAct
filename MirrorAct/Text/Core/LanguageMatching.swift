// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Languages for a translator that knows a fixed set of them: which of its languages stands for
/// a wanted or recognized one, how certain the language of a text is, and which texts of a
/// request are translated from which language.
enum LanguageMatching {
    // MARK: Languages

    /// No language at all: "und", an empty identifier, "several languages" … `Locale.Language`
    /// takes such an identifier for English, so this has to be asked before anything else.
    static func isUndetermined(_ language: Locale.Language) -> Bool {
        guard let code = language.languageCode?.identifier.lowercased(), !code.isEmpty else { return true }
        return ["und", "mul", "mis", "zxx"].contains(code)
    }

    /// The language without script and region, in today's spelling ("iw" → "he", "deu" → "de");
    /// nil for an undetermined language
    static func code(of language: Locale.Language) -> String? {
        guard !isUndetermined(language) else { return nil }
        // the maximal identifier starts with the language as it is written today
        if let first = language.maximalIdentifier.split(whereSeparator: { $0 == "-" || $0 == "_" }).first {
            return first.lowercased()
        }
        return language.languageCode?.identifier.lowercased()
    }

    /// Key for dictionaries and sets. `Locale.Language` itself compares its parts, so "zh-TW"
    /// and "zh-Hant-TW" would be two keys for one language.
    static func key(_ language: Locale.Language) -> String {
        language.maximalIdentifier
    }

    /// The same language, whatever its script or region: nothing to translate between the two
    static func sameLanguage(_ first: Locale.Language, _ second: Locale.Language) -> Bool {
        guard let one = code(of: first), let other = code(of: second) else { return false }
        return one == other
    }

    /// The entry of `supported` that stands for `wanted`: an equivalent one ("zh-Hant" for
    /// "zh-TW", "en-US" for "en"), otherwise one for the same language, script and region
    /// ("de-CH" for "de-Latn-CH"), otherwise the closest wider form of the region ("en-GB" for
    /// "en-DE", "es-MX" for "es-AR", "pt-PT" for "pt-AO", "zh-HK" for "zh-MO"), otherwise the
    /// language as it is usually written in that script ("de" for "de-AT", "zh-TW" for
    /// "zh-Hant-MY"), otherwise one in the same language and script ("zh-TW" for "zh-HK"),
    /// otherwise one in the same language ("pt-BR" for "pt-PT"). Never one for an undetermined
    /// language. The order of `supported` only decides among entries that are equally good.
    static func match(_ wanted: Locale.Language, in supported: [Locale.Language]) -> Locale.Language? {
        guard let wantedCode = code(of: wanted) else { return nil }
        let known = supported.filter { !isUndetermined($0) }
        if let equivalent = known.first(where: { $0.isEquivalent(to: wanted) }) { return equivalent }
        let sameCode = known.filter { code(of: $0) == wantedCode }
        if let region = wanted.region,
           let sameRegion = sameCode.first(where: { $0.script == wanted.script && $0.region == region }) {
            return sameRegion
        }
        for wider in widerForms(of: wanted, code: wantedCode) {
            if let entry = sameCode.first(where: { $0.isEquivalent(to: wider) }) { return entry }
        }
        // macOS lists the countries of a language before the language itself (en-IN before en,
        // de-CH before de): the first entry in the script would be some other country's spelling
        let usual = Locale.Language(identifier: wanted.script.map { wantedCode + "-" + $0.identifier } ?? wantedCode)
        if let entry = sameCode.first(where: { $0.isEquivalent(to: usual) }) { return entry }
        if let script = wanted.script, let sameScript = sameCode.first(where: { $0.script == script }) {
            return sameScript
        }
        return sameCode.first
    }

    /// The entry that stands for `wanted` in the first of `lists` that has its language at all,
    /// for a translator with several kinds of models that it prefers in this order (Apple's
    /// on-device models before those that need Apple Intelligence). A region the first list
    /// lacks gets the closest form of that list ("es" for "es-AR", "pt" for "pt-PT", "en-GB" for
    /// "en-DE"), even where a later list has the region itself: only a language the first list
    /// does not have at all ("da") is looked for in the next one.
    static func match(_ wanted: Locale.Language, inFirstOf lists: [[Locale.Language]]) -> Locale.Language? {
        for list in lists {
            // nil only when the list has nothing in that language
            if let entry = match(wanted, in: list) { return entry }
        }
        return nil
    }

    /// The forms a region of a language falls back to, the closest first: "en-150", "en-GB" for
    /// "en-DE"; "es-419", "es-MX", "es-US" for "es-AR". Empty where the language itself is next.
    private static func widerForms(of language: Locale.Language, code: String) -> [Locale.Language] {
        guard let script = script(of: language), var region = language.region?.identifier else { return [] }
        let family = code + "-" + script
        guard let parents = widerRegions[family] else { return [] }
        var regions: [String] = []
        // a few steps at most; the bound only guards against a loop in the table
        for _ in 0..<4 {
            regions += standIns[family]?[region] ?? []
            guard let wider = parents[region] else { break }
            regions.append(wider)
            region = wider
        }
        return regions.map { Locale.Language(identifier: family + "-" + $0) }
    }

    /// The script of a language, also where the identifier names none ("Hant" for "zh-MO")
    private static func script(of language: Locale.Language) -> String? {
        language.maximalIdentifier.split(whereSeparator: { $0 == "-" || $0 == "_" })
            .dropFirst().first { $0.count == 4 && $0.allSatisfy(\.isLetter) }.map(String.init)
    }

    /// The region macOS puts a region of a language under (`Locale.Language.parent` on macOS 26,
    /// from CLDR's parent locales), by language and script. Only where that wider form is not
    /// the language itself: everywhere else the language as it is usually written is the
    /// closest. A Mac set to en-DE shows apps in British English for the same reason.
    private static let widerRegions: [String: [String: String]] = {
        func under(_ wider: String, _ regions: String) -> [String: String] {
            Dictionary(uniqueKeysWithValues: regions.split(separator: " ").map { (String($0), wider) })
        }
        return [
            "en-Latn": under("150", "AD AL AT BA BE BG BY CH CY CZ DE DK EE ES FI FO FR GE GL GR HR HU IS IT LI LT "
                                    + "LU LV MC MD ME MK NL NO PL PT RO RS RU SE SI SK UA VA")
                .merging(under("AU", "CC CK CX NF NR NU NZ WS")) { first, _ in first }
                .merging(under("GB", "AI AU BB BD BM BN BS BW BZ DG DM FJ FK GD GG GH GI GM GY HK IE IM IN IO JE "
                                     + "JM KE KI KN KY LC LK LS MO MS MT MU MV MW MY NA NG PK SB SC SD SG SH SL SS "
                                     + "SZ TC TO TT TV TZ UG VC VG VU ZA ZM ZW 150")) { first, _ in first },
            "es-Latn": under("419", "AG AI AR AW BB BL BM BO BQ BR BS BZ CA CL CO CR CU CW DM DO EC FK GD GF GL GP "
                                    + "GT GY HN HT JP KN KY LC MF MQ MS MX NI PA PE PM PR PY SR SV SX TC TT US UY "
                                    + "VC VE VG VI"),
            "pt-Latn": under("PT", "AO CH CV FR GQ GW LU MO MZ ST TL"),
            "zh-Hant": under("HK", "MO"),
        ]
    }()

    /// Countries that stand in for a wider form macOS does not list, the closest first: it
    /// translates Latin American Spanish as Mexico's and the United States', not as es-419
    private static let standIns: [String: [String: [String]]] = ["es-Latn": ["419": ["MX", "US"]]]

    /// The name of a language for a notice, in the language of `locale`: "German",
    /// "Chinese, Traditional"
    static func name(of language: Locale.Language, in locale: Locale) -> String {
        guard let spoken = code(of: language) else {
            return locale.localizedString(forLanguageCode: "und") ?? "und"
        }
        // Chinese is translated separately in its two scripts; elsewhere the script is worth a
        // word only when it is not the one the language is usually written in
        if let script = language.script, spoken == "zh" || script != Locale.Language(identifier: spoken).script,
           let name = locale.localizedString(forIdentifier: spoken + "-" + script.identifier) {
            return name
        }
        return locale.localizedString(forLanguageCode: spoken) ?? language.minimalIdentifier
    }

    /// The tags a language recognizer knows these languages by (BCP 47: the language, Chinese
    /// with its script), each once and in their order
    static func recognizerTags(for languages: [Locale.Language]) -> [String] {
        var tags: [String] = []
        for language in languages {
            guard var tag = code(of: language) else { continue }
            if tag == "zh", let script = language.script { tag += "-" + script.identifier }
            if !tags.contains(tag) { tags.append(tag) }
        }
        return tags
    }

    // MARK: The words of a text

    /// What of a text can speak for a language: its words, without what is written the same in
    /// every language (numbers, model names, identifiers, addresses, acronyms)
    struct Wording: Equatable {
        /// the words, one space between two: what a language recognizer is given
        var text: String
        /// how many words
        var words: Int
        /// letters in the words, where a letter of Chinese, Japanese or Korean counts
        /// `denseLetterWeight` times (see `letterWeight`): what the words weigh
        var letters: Int
        /// most of the letters are of a script with case (Latin, Greek, Cyrillic …), whose words
        /// are set apart by spaces. Chinese, Japanese or Thai do not set words apart: there a
        /// "word" may be a whole sentence, and the number of words says nothing.
        var isCased: Bool

        init(text: String = "", words: Int = 0, letters: Int = 0, isCased: Bool = true) {
            self.text = text
            self.words = words
            self.letters = letters
            self.isCased = isCased
        }

        /// The words of several texts, read as one text
        init(joining wordings: [Wording]) {
            let parts = wordings.filter { $0.words > 0 }
            text = parts.map(\.text).joined(separator: " ")
            words = parts.reduce(0) { $0 + $1.words }
            letters = parts.reduce(0) { $0 + $1.letters }
            let cased = parts.reduce(0) { $0 + ($1.isCased ? $1.letters : 0) }
            isCased = cased * 2 >= letters
        }

        /// A text with a single word, or with fewer letters, says nothing about its language
        var canDecide: Bool {
            letters >= lettersToDecide && (!isCased || words >= wordsToDecide)
        }

        /// Enough of a text to be in another language than the rest of the screen
        var canStandApart: Bool {
            letters >= lettersToStandApart && (!isCased || words >= wordsToStandApart)
        }
    }

    /// Characters a word never contains: they make identifiers, addresses, paths and formulas
    private static let identifierMarks: Set<Character> = ["_", "@", "/", "\\", "#", "=", "|", "<", ">", "~"]
    /// Characters that join the parts of one word ("E-Mail", "aujourd’hui", "スクリーン・タイム")
    private static let joiners: Set<Character> = ["-", "\u{2010}", "\u{2011}", "'", "\u{2019}", "\u{30FB}"]

    /// The words of `text`. It is split at white space into tokens, and each token into parts
    /// (`parts`): letters of a script without case (Chinese, Japanese, Thai …) apart from
    /// everything else, so that a number or a Latin name inside a sentence of such a script
    /// ("3件", "iPhoneを") drops out alone and leaves the rest of the sentence. A part with a digit
    /// in it ("arm64", "5G", "12:30"), or with one of `identifierMarks` ("sdk_gphone", an e-mail
    /// address, a URL), is no word. Every other character that is neither a letter nor one of
    /// `joiners` separates two words ("、" in Japanese), except between two letters of a script
    /// with case: there it makes the part a name or an address ("example.com", "z.B.",
    /// "Ton&Vibration"), and the part is no word. Joiners at the ends of a word are dropped. A
    /// word in which a lowercase letter is directly followed by an uppercase one ("AndroidWifi",
    /// "iPhone", "YouTube") is a name, and one of two or more letters without a lowercase one
    /// ("WLAN", "IMEI", "OK") an acronym: neither counts.
    static func wording(of text: String) -> Wording {
        var words: [String] = []
        var letters = 0, cased = 0
        for token in text.split(whereSeparator: { $0.isWhitespace }).flatMap(parts(of:)) {
            guard !token.contains(where: { isDigit($0) || identifierMarks.contains($0) }) else { continue }
            var runs: [String] = []
            var run = ""
            var lastLetter: Character?
            var pendingSeparator = false
            var isName = false
            for character in token {
                if character.isLetter || joiners.contains(character) {
                    if character.isLetter {
                        if pendingSeparator, let before = lastLetter, before.isCased, character.isCased {
                            isName = true
                        }
                        pendingSeparator = false
                        lastLetter = character
                    }
                    run.append(character)
                } else {
                    if !run.isEmpty { runs.append(run) }
                    run = ""
                    pendingSeparator = true
                }
            }
            if !run.isEmpty { runs.append(run) }
            guard !isName else { continue }
            for piece in runs {
                var word = Substring(piece)
                while let first = word.first, joiners.contains(first) { word.removeFirst() }
                while let last = word.last, joiners.contains(last) { word.removeLast() }
                guard !word.isEmpty, isWord(word) else { continue }
                words.append(String(word))
                for character in word where character.isLetter {
                    let weight = letterWeight(character)
                    letters += weight
                    if character.isCased { cased += weight }
                }
            }
        }
        return Wording(text: words.joined(separator: " "), words: words.count, letters: letters,
                       isCased: cased * 2 >= letters)
    }

    /// A token cut where a letter of a script without case (a letter that is not `isCased`)
    /// meets a character that is not one, in either direction. A joiner belongs to the part it
    /// follows (to the next one at the start of the token). A token without such letters, as in
    /// Latin, Greek or Cyrillic text, is one part: "2025年11月13日のお知らせ" gives "2025", "年",
    /// "11", "月", "13", "日のお知らせ"; "iPhoneを最新の…。" gives "iPhone", "を最新の…", "。".
    private static func parts(of token: Substring) -> [Substring] {
        var parts: [Substring] = []
        var start = token.startIndex
        // whether the part so far is of letters without case; nil while it has only joiners
        var uncased: Bool?
        var index = token.startIndex
        while index < token.endIndex {
            let character = token[index]
            if !joiners.contains(character) {
                let kind = character.isLetter && !character.isCased
                if let current = uncased, current != kind {
                    parts.append(token[start..<index])
                    start = index
                }
                uncased = kind
            }
            index = token.index(after: index)
        }
        if start < token.endIndex { parts.append(token[start...]) }
        return parts
    }

    /// how many letters of an alphabet one character of Chinese, Japanese or Korean stands for:
    /// it is a syllable or a whole word, and the same is said in about a third of the characters
    static let denseLetterWeight = 3

    /// What a letter weighs: `denseLetterWeight` for one of the Han ideographs (U+3400–U+4DBF,
    /// U+4E00–U+9FFF, U+F900–U+FAFF, U+20000–U+3FFFF), Hiragana and Katakana (U+3040–U+30FF,
    /// U+31F0–U+31FF, U+FF66–U+FF9D) and the Hangul syllables (U+AC00–U+D7A3), by the first
    /// scalar of the character; 1 for every other letter
    static func letterWeight(_ character: Character) -> Int {
        guard let scalar = character.unicodeScalars.first?.value else { return 1 }
        let dense: [ClosedRange<UInt32>] = [0x3040...0x30FF, 0x31F0...0x31FF, 0x3400...0x4DBF, 0x4E00...0x9FFF,
                                            0xAC00...0xD7A3, 0xF900...0xFAFF, 0xFF66...0xFF9D, 0x20000...0x3FFFF]
        return dense.contains { $0.contains(scalar) } ? denseLetterWeight : 1
    }

    /// A decimal digit of any script (general category Nd: "7", "٧", "７"). Not the numerals that
    /// are letters of a word as well ("十" in "二十分", "Ⅻ").
    private static func isDigit(_ character: Character) -> Bool {
        character.unicodeScalars.contains { $0.properties.generalCategory == .decimalNumber }
    }

    /// Neither a name written in one ("AndroidWifi") nor an acronym ("WLAN")
    private static func isWord(_ word: Substring) -> Bool {
        // the letter just before, if there was no joiner in between ("Android-Version" is a word)
        var previous: Character?
        var hasLowercase = false
        var uppercase = 0
        for character in word {
            guard character.isLetter else {
                previous = nil
                continue
            }
            if character.isUppercase {
                if let previous, previous.isLowercase { return false }
                uppercase += 1
            }
            if character.isLowercase { hasLowercase = true }
            previous = character
        }
        return hasLowercase || uppercase < 2
    }

    // MARK: The language of a text

    /// fewer letters in words than this and a recognizer's answer is a guess
    static let lettersToDecide = 12
    /// fewer words than this (in a script with case) and a recognizer's answer is a guess: a
    /// single word looks like a word of many languages ("Telefonnummer" like Norwegian)
    static let wordsToDecide = 2
    /// probability from which the best candidate is taken
    static let probabilityToDecide = 0.6
    /// letters in words from which a text may be in another language than the screen it is on
    static let lettersToStandApart = 25
    /// words (in a script with case) from which a text may be in another language than the screen
    static let wordsToStandApart = 3
    /// probability from which a text may be in another language than the screen
    static let probabilityToStandApart = 0.9
    /// letters in words of the texts of a request in a new language from which the screen is
    /// taken to be in that language instead of the one it was in before
    static let lettersToChangeTheScreensLanguage = 25
    /// letters in words that must speak for a language before a translator is asked to load it
    /// (macOS asks the user whether it may download it)
    static let lettersToAskForALanguage = 25
    /// share of the probability that has to lie with languages the translator does not know
    /// before a text counts as written in one of them
    static let probabilityOfAnUnknownLanguage = 0.8
    /// letters in words from which the best candidate is used when nothing else is known about a text
    static let lettersToTrustAGuess = 20
    /// letters in words of text in a language the translator does not know from which the user is told
    static let lettersToMentionAnUnknownLanguage = 40

    /// One candidate of a language recognizer
    struct Hypothesis: Equatable {
        /// BCP 47: "de", "zh-Hant"
        var tag: String
        /// 0…1
        var probability: Double
    }

    /// What is known about the language of one text
    struct Finding: Equatable {
        /// its own language, when it is certain enough to count for the language of the screen
        var decided: Locale.Language?
        /// the most likely language when it is not
        var guess: Locale.Language?
        /// letters in the text; 0 = nothing to translate
        var letters: Int
        /// letters in its words: what speaks for its language
        var weight: Int
        /// `decided` is certain enough for the text to be in another language than the screen
        var standsApart: Bool

        init(decided: Locale.Language? = nil, guess: Locale.Language? = nil, letters: Int, weight: Int? = nil,
             standsApart: Bool = false) {
            self.decided = decided
            self.guess = guess
            self.letters = letters
            self.weight = weight ?? letters
            self.standsApart = standsApart
        }
    }

    static func letterCount(_ text: String) -> Int {
        text.reduce(0) { $1.isLetter ? $0 + 1 : $0 }
    }

    /// Weighs what a recognizer says about the words of a text (`wording`, which is what it was
    /// given) that has `letters` letters in all. `open`: its candidates among all languages;
    /// `constrained`: its candidates when only the languages of the translator (`supported`)
    /// were allowed.
    static func finding(of wording: Wording, letters: Int, open: [Hypothesis], constrained: [Hypothesis],
                        supported: [Locale.Language]) -> Finding {
        let candidates = ranked(constrained)
        var finding = Finding(guess: wording.letters > 0 ? candidates.first?.language : nil, letters: letters,
                              weight: wording.letters)
        guard wording.canDecide else { return finding }
        // Limited to the translator's languages, a recognizer finds one of them in any text. A
        // text that clearly is in another language must not be translated as if it were.
        let unknown = ranked(open).filter { match($0.language, in: supported) == nil }
        let unknownShare = unknown.reduce(0) { $0 + $1.probability }
        var probability = 0.0
        if let first = unknown.first, unknownShare >= probabilityOfAnUnknownLanguage {
            finding.decided = first.language
            probability = unknownShare
        } else if let best = candidates.first, best.probability >= probabilityToDecide {
            finding.decided = best.language
            probability = best.probability
        }
        finding.standsApart = finding.decided != nil && wording.canStandApart && probability >= probabilityToStandApart
        return finding
    }

    /// The language of a screen, and how many letters in words speak for it
    struct ScreenLanguage: Equatable {
        var language: Locale.Language
        var letters: Int
    }

    /// The words of the texts that decide nothing on their own (short labels), read as one
    /// text: together they may say what language the screen is in. nil for fewer than two.
    static func jointWording(of wordings: [Wording], findings: [Finding]) -> Wording? {
        let undecided = zip(wordings, findings).filter { $0.1.decided == nil && $0.0.words > 0 }.map(\.0)
        guard undecided.count >= 2 else { return nil }
        return Wording(joining: undecided)
    }

    /// The most likely language of a screen on which no text decides one: the guess of the
    /// `jointWording` (`joint`) if there is one, otherwise the guess of the text with the most
    /// letters in words (the first of several)
    static func screenGuess(of findings: [Finding], joint: Finding?) -> Locale.Language? {
        if let joint { return joint.guess }
        var best: Finding?
        for finding in findings where finding.guess != nil && finding.weight > (best?.weight ?? 0) {
            best = finding
        }
        return best?.guess
    }

    /// The language of the screen after a request with these findings (those of its texts, and
    /// the one of `jointWording`), when it was `before`. The letters in words of the findings
    /// with a decided language are added up by language; texts that decide nothing take no part.
    /// The language with the most letters wins; of several with the same amount, the one of
    /// `before`, otherwise the one that comes first. It replaces the language of `before` only
    /// with at least `lettersToChangeTheScreensLanguage` letters, and more than this request has
    /// in the language of `before`. The letters kept are the most any request had for the language.
    /// When nothing at all is known, the screen is taken to be in `guess` (the most likely
    /// language of its words, see `screenGuess`) with 0 letters: its texts can be translated
    /// where the translator has the language at hand, and it is never asked for. Such a guess is
    /// not kept: a `before` with 0 letters counts as nothing known, so the next request guesses
    /// again, and any language it decides replaces the guess.
    static func screenLanguage(of findings: [Finding], before: ScreenLanguage?,
                               guess: Locale.Language? = nil) -> ScreenLanguage? {
        let before = before.flatMap { $0.letters > 0 ? $0 : nil }
        var languages: [(language: Locale.Language, letters: Int)] = []
        for finding in findings {
            guard let language = finding.decided, !isUndetermined(language) else { continue }
            if let known = languages.firstIndex(where: { key($0.language) == key(language) }) {
                languages[known].letters += finding.weight
            } else {
                languages.append((language, finding.weight))
            }
        }
        var best: (language: Locale.Language, letters: Int)?
        for entry in languages {
            guard let current = best else {
                best = entry
                continue
            }
            let winsTie = entry.letters == current.letters && before.map { key($0.language) == key(entry.language) } == true
            if entry.letters > current.letters || winsTie { best = entry }
        }
        guard let best else {
            if before == nil, let guess, !isUndetermined(guess) { return ScreenLanguage(language: guess, letters: 0) }
            return before
        }
        guard let before else { return ScreenLanguage(language: best.language, letters: best.letters) }
        if key(best.language) == key(before.language) {
            return ScreenLanguage(language: before.language, letters: max(before.letters, best.letters))
        }
        let forBefore = languages.first { key($0.language) == key(before.language) }?.letters ?? 0
        guard best.letters >= lettersToChangeTheScreensLanguage, best.letters > forBefore else { return before }
        return ScreenLanguage(language: best.language, letters: best.letters)
    }

    /// Candidates with a language, the most likely first
    private static func ranked(_ hypotheses: [Hypothesis]) -> [(language: Locale.Language, probability: Double)] {
        hypotheses
            .sorted { ($0.probability, $1.tag) > ($1.probability, $0.tag) }
            .compactMap { hypothesis in
                let language = Locale.Language(identifier: hypothesis.tag)
                return isUndetermined(language) ? nil : (language, hypothesis.probability)
            }
    }

    // MARK: A request

    /// What happens to each text of a translation request
    struct Plan: Equatable {
        /// Texts that are translated in one go
        struct Group: Equatable {
            /// their language, as the translator knows it
            var source: Locale.Language
            /// their positions in the request, ascending
            var indices: [Int]
            /// Enough text speaks for the language to ask for it where the translator would
            /// have to load it first: the screen is in it (with at least
            /// `lettersToAskForALanguage` letters in words), or a text of the group stands apart
            /// in it. Never for a single short text, a name or a number.
            var mayAskForTheLanguage = false

            /// Puts the translations of this group (in the order of `indices`) where they belong
            func place(_ translations: [String?], in results: inout [String?]) {
                for (position, index) in indices.enumerated()
                where position < translations.count && results.indices.contains(index) {
                    results[index] = translations[position]
                }
            }
        }

        /// positions of the texts that come back as they are: nothing to translate in them,
        /// already in the target language, or in a language the translator does not know
        var unchanged: [Int] = []
        /// positions of the texts whose language is not known yet: asked again later
        var postponed: [Int] = []
        /// the other texts by language, the languages in the order in which they first appear
        var groups: [Group] = []
        /// languages the translator does not know that enough of the text is in to tell the user
        var unknown: [Locale.Language] = []

        /// - `screen`: the language of the screen (`screenLanguage`), which the texts take that
        ///   have none of their own, or one that does not stand apart from it; nil = not known
        init(findings: [Finding], screen: ScreenLanguage?, target: Locale.Language, supported: [Locale.Language]) {
            self.init(findings: findings, screen: screen, target: target, lists: [supported])
        }

        /// The same for a translator with several lists of languages, the one it prefers first
        /// (see `match(_:inFirstOf:)`)
        ///
        /// A text is translated from its own language (`decided`) when it stands apart, when it
        /// is in the language of the screen anyway, or when the screen's language is not known;
        /// otherwise from the language of the screen; without either, from its guess if it has
        /// `lettersToTrustAGuess` letters in words; otherwise it is postponed. A text that would
        /// be in the target language only because the screen's language is a guess (0 letters)
        /// is postponed as well, not left as it is.
        init(findings: [Finding], screen: ScreenLanguage?, target: Locale.Language, lists: [[Locale.Language]]) {
            var positions: [String: Int] = [:]
            var strangers: [(language: Locale.Language, letters: Int)] = []
            let screenSource = screen.flatMap { LanguageMatching.match($0.language, inFirstOf: lists) }
            let screenIsEvident = (screen?.letters ?? 0) >= LanguageMatching.lettersToAskForALanguage
            for (index, finding) in findings.enumerated() {
                guard finding.letters > 0 else {
                    unchanged.append(index)
                    continue
                }
                var own = finding.decided
                if let language = own, LanguageMatching.isUndetermined(language) { own = nil }
                if let language = own, let screen, !finding.standsApart,
                   !LanguageMatching.sameLanguage(language, screen.language) {
                    own = nil
                }
                let trusted = finding.weight >= LanguageMatching.lettersToTrustAGuess ? finding.guess : nil
                guard let language = own ?? screen?.language ?? trusted, !LanguageMatching.isUndetermined(language) else {
                    postponed.append(index)
                    continue
                }
                if LanguageMatching.sameLanguage(language, target) {
                    // "Nothing to translate" holds for good, the caller does not ask again: not
                    // on the strength of a screen language that is only guessed (0 letters)
                    if own == nil, let screen, screen.letters == 0 {
                        postponed.append(index)
                    } else {
                        unchanged.append(index)
                    }
                } else if let source = LanguageMatching.match(language, inFirstOf: lists) {
                    let key = LanguageMatching.key(source)
                    let position: Int
                    if let known = positions[key] {
                        position = known
                        groups[position].indices.append(index)
                    } else {
                        position = groups.count
                        positions[key] = position
                        var group = Group(source: source, indices: [index])
                        group.mayAskForTheLanguage = screenIsEvident
                            && screenSource.map { LanguageMatching.key($0) == key } == true
                        groups.append(group)
                    }
                    if own != nil, finding.standsApart { groups[position].mayAskForTheLanguage = true }
                } else {
                    unchanged.append(index)
                    let key = LanguageMatching.key(language)
                    if let position = strangers.firstIndex(where: { LanguageMatching.key($0.language) == key }) {
                        strangers[position].letters += finding.weight
                    } else {
                        strangers.append((language, finding.weight))
                    }
                }
            }
            unknown = strangers.filter { $0.letters >= LanguageMatching.lettersToMentionAnUnknownLanguage }.map(\.language)
        }

        /// The answer before anything is translated: the unchanged texts, nil everywhere else
        func results(for texts: [String]) -> [String?] {
            var results = [String?](repeating: nil, count: texts.count)
            for index in unchanged where results.indices.contains(index) {
                results[index] = texts[index]
            }
            return results
        }
    }
}
