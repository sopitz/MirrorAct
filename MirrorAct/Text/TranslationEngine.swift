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
    /// A notice that stays until the engine replaces it or withdraws it with nil ("macOS asks
    /// whether it may download …"); may be called on any thread
    var notifyStatus: ((String?) -> Void)? { get set }

    /// Translations in the order of `texts`.
    /// - A translation equal to its text means "leave it as it is" (already in the target
    ///   language, a language the engine does not know, nothing to translate).
    /// - nil means "not now": the caller asks again later (a language is still being loaded …).
    /// Throws `TranslationFailure` when the request as a whole failed, and `TranslationWait`
    /// when the engine sends nothing yet because it waits for the service.
    func translate(_ texts: [String], into target: Locale.Language) async throws -> [String?]

    /// Translating was turned off: drop pending work.
    func cancel()
}

extension TranslationEngine {
    /// engines without lasting notices
    var notifyStatus: ((String?) -> Void)? {
        get { nil }
        set {}
    }
}

/// Why a translation request failed, in words for the user
struct TranslationFailure: LocalizedError, Equatable {
    let message: String
    /// trying again soon is pointless (wrong key, unknown model, declined download …)
    var isPermanent = false
    /// Seconds before asking again is worth it (the service asked for a pause, or failed several
    /// times in a row); nil = the caller's usual pause
    var retryAfter: TimeInterval? = nil

    var errorDescription: String? { message }
}

/// The engine sent nothing, because it waits for the service: the requests of a moment ago
/// failed as a whole (the service is down or cannot be reached), or the service asked for a
/// pause. The texts themselves did not fail: the caller offers them again after `seconds`,
/// without counting a failure against them, and shows nothing (the failure was shown already).
struct TranslationWait: Error, Equatable {
    let seconds: TimeInterval
}
