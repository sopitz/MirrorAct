// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Translates the text found on the screen: on this Mac (`AppleTranslationClient` over the shared
/// `AppleTranslationEngine`) or through a language model service with the user's own API key
/// (`LLMTranslationEngine`). One object serves one turn of translating: after `cancel` it is not
/// used again.
protocol TranslationEngine: AnyObject {
    /// Name for notices and the log: "Apple", "OpenAI" …
    var name: String { get }
    /// true = the text leaves this Mac
    var isRemote: Bool { get }
    /// Slow or billed per request: translate once the picture has come to rest instead of line
    /// by line while it scrolls
    var prefersSettledText: Bool { get }

    /// Notices for the user that are no failures ("Loading German …"); may be called on any thread
    var notify: ((String) -> Void)? { get set }

    /// Translations in the order of `texts`.
    /// - A translation equal to its text means "leave it as it is" (already in the target
    ///   language, a language the engine does not know, nothing to translate).
    /// - nil means "not now": the caller asks again later (a language is still being loaded …).
    /// Throws `TranslationFailure` when the request as a whole failed.
    func translate(_ texts: [String], into target: Locale.Language) async throws -> [String?]

    /// Translating was turned off: drop pending work.
    func cancel()
}

/// Why a translation request failed, in words for the user
struct TranslationFailure: LocalizedError, Equatable {
    let message: String
    /// trying again soon is pointless (wrong key, unknown model, declined download …)
    var isPermanent = false

    var errorDescription: String? { message }
}
