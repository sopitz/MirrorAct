// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Picks what translates the text on the screen, the way the settings say
enum TranslationEngines {
    /// The engine for the next turn of translating. Throws a `TranslationFailure` that says
    /// what the user still has to enter in the settings.
    @MainActor
    static func make(for settings: AppSettings) throws -> TranslationEngine {
        // a client of its own over the engine all windows share: its notices and its cancel
        // concern this turn of translating only
        guard settings.translationEngine == "llm" else { return AppleTranslationClient(engine: .shared) }
        let connection = llmConnection(for: settings)
        if let missing = connection.missing { throw failure(for: missing, in: connection) }
        return LLMTranslationEngine(connection: connection)
    }

    /// The language model service with this id. Settings can name a service this version of
    /// the app does not know; the first one stands in for it.
    static func llmProvider(id: String) -> LLMProvider {
        LLMProvider.with(id: id) ?? LLMProvider.all[0]
    }

    /// The service of the settings the way the user has set it up.
    /// - Parameter enteredKey: a key that is being typed in the settings and is not stored
    ///   yet; without one the key comes from the keychain
    static func llmConnection(for settings: AppSettings, enteredKey: String = "") -> LLMConnection {
        let provider = llmProvider(id: settings.llmProvider)
        let entered = enteredKey.trimmingCharacters(in: .whitespacesAndNewlines)
        return LLMConnection(provider: provider, baseURL: settings.llmBaseURLs[provider.id],
                             model: settings.llmModels[provider.id],
                             apiKey: entered.isEmpty ? KeychainStore.key(for: provider.id) : entered)
    }

    /// What the user has to do before `connection` can be used, in words for a notice.
    /// Trying again is pointless until then.
    static func failure(for missing: LLMMissingSetting, in connection: LLMConnection) -> TranslationFailure {
        let service = LLMTranslationEngine.name(for: connection)
        let message: String
        switch missing {
        case .address:
            if connection.baseURL.isEmpty {
                message = String(localized: "Enter the address of the service in the settings first")
            } else {
                message = String(localized: "The address \(connection.baseURL) cannot be used – check it in the settings")
            }
        case .apiKey:
            message = String(localized: "Enter the API key for \(service) in the settings first")
        case .model:
            message = String(localized: "Choose a model for \(service) in the settings first")
        }
        return TranslationFailure(message: message, isPermanent: true)
    }
}
