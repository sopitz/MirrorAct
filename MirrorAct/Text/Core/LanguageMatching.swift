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
    /// ("de-CH" for "de-Latn-CH"), otherwise the language as it is usually written in that script
    /// ("de" for "de-AT", "zh-TW" for "zh-MO"), otherwise one in the same language and script
    /// ("zh-TW" for "zh-HK"), otherwise one in the same language ("pt-BR" for "pt-PT"). Never one
    /// for an undetermined language. The order of `supported` only decides among entries that are
    /// equally good.
    static func match(_ wanted: Locale.Language, in supported: [Locale.Language]) -> Locale.Language? {
        guard let wantedCode = code(of: wanted) else { return nil }
        let known = supported.filter { !isUndetermined($0) }
        if let equivalent = known.first(where: { $0.isEquivalent(to: wanted) }) { return equivalent }
        let sameCode = known.filter { code(of: $0) == wantedCode }
        if let region = wanted.region,
           let sameRegion = sameCode.first(where: { $0.script == wanted.script && $0.region == region }) {
            return sameRegion
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

    // MARK: The language of a text

    /// fewer letters than this and a recognizer's answer is a guess
    static let lettersToDecide = 12
    /// probability from which the best candidate is taken
    static let probabilityToDecide = 0.6
    /// share of the probability that has to lie with languages the translator does not know
    /// before a text counts as written in one of them
    static let probabilityOfAnUnknownLanguage = 0.8
    /// letters from which the best candidate is used when nothing else is known about a text
    static let lettersToTrustAGuess = 20
    /// letters of text in a language the translator does not know from which the user is told
    /// (a recognizer now and then takes a single word for some other language)
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
        /// the language, when it is certain enough to go by
        var decided: Locale.Language?
        /// the most likely language when it is not
        var guess: Locale.Language?
        /// letters in the text: what this finding weighs
        var letters: Int

        init(decided: Locale.Language? = nil, guess: Locale.Language? = nil, letters: Int) {
            self.decided = decided
            self.guess = guess
            self.letters = letters
        }
    }

    static func letterCount(_ text: String) -> Int {
        text.reduce(0) { $1.isLetter ? $0 + 1 : $0 }
    }

    /// Weighs what a recognizer says about a text with `letters` letters. `open`: its candidates
    /// among all languages; `constrained`: its candidates when only the languages of the
    /// translator (`supported`) were allowed.
    static func finding(letters: Int, open: [Hypothesis], constrained: [Hypothesis],
                        supported: [Locale.Language]) -> Finding {
        let candidates = ranked(constrained)
        var finding = Finding(guess: candidates.first?.language, letters: letters)
        guard letters >= lettersToDecide else { return finding }
        // Limited to the translator's languages, a recognizer finds one of them in any text. A
        // text that clearly is in another language must not be translated as if it were.
        let unknown = ranked(open).filter { match($0.language, in: supported) == nil }
        if let first = unknown.first,
           unknown.reduce(0, { $0 + $1.probability }) >= probabilityOfAnUnknownLanguage {
            finding.decided = first.language
        } else if let best = candidates.first, best.probability >= probabilityToDecide {
            finding.decided = best.language
        }
        return finding
    }

    /// The language most of the text with a decided language is in, by letters; of two with the
    /// same amount the one that comes first
    static func prevailingLanguage(of findings: [Finding]) -> Locale.Language? {
        var languages: [(language: Locale.Language, letters: Int)] = []
        for finding in findings {
            guard let language = finding.decided, !isUndetermined(language) else { continue }
            if let known = languages.firstIndex(where: { key($0.language) == key(language) }) {
                languages[known].letters += finding.letters
            } else {
                languages.append((language, finding.letters))
            }
        }
        var prevailing: (language: Locale.Language, letters: Int)?
        for entry in languages where entry.letters > (prevailing?.letters ?? -1) {
            prevailing = entry
        }
        return prevailing?.language
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

        /// - `common`: the language of the texts that have none of their own (most of this or
        ///   of an earlier request was in it); nil = not known
        init(findings: [Finding], common: Locale.Language?, target: Locale.Language, supported: [Locale.Language]) {
            var positions: [String: Int] = [:]
            var strangers: [(language: Locale.Language, letters: Int)] = []
            for (index, finding) in findings.enumerated() {
                guard finding.letters > 0 else {
                    unchanged.append(index)
                    continue
                }
                let trusted = finding.letters >= LanguageMatching.lettersToTrustAGuess ? finding.guess : nil
                guard let language = finding.decided ?? common ?? trusted, !LanguageMatching.isUndetermined(language) else {
                    postponed.append(index)
                    continue
                }
                if LanguageMatching.sameLanguage(language, target) {
                    unchanged.append(index)
                } else if let source = LanguageMatching.match(language, in: supported) {
                    let key = LanguageMatching.key(source)
                    if let position = positions[key] {
                        groups[position].indices.append(index)
                    } else {
                        positions[key] = groups.count
                        groups.append(Group(source: source, indices: [index]))
                    }
                } else {
                    unchanged.append(index)
                    let key = LanguageMatching.key(language)
                    if let position = strangers.firstIndex(where: { LanguageMatching.key($0.language) == key }) {
                        strangers[position].letters += finding.letters
                    } else {
                        strangers.append((language, finding.letters))
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
