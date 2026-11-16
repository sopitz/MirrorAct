// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// How a language model service is spoken to
enum LLMWireFormat: String, Equatable {
    /// `POST …/chat/completions` as OpenAI defined it; most services and local servers offer it
    case openAICompatible
    /// Anthropic's Messages API
    case anthropic
}

/// A language model service that translates with the user's own API key, or a server that runs
/// a model on the user's computer.
///
/// Addresses and models are those the services documented in November 2026. What a service
/// offers today is in the list it sends (`LLMWire.modelsRequest`).
struct LLMProvider: Equatable, Identifiable {
    /// Who decides the address of the service
    enum BaseURLRule: Equatable {
        /// always `defaultBaseURL`
        case fixed
        /// `defaultBaseURL`, unless the user enters another one (a model on another computer)
        case editable
        /// there is no default: the user has to enter it
        case required
    }

    /// lower-case ASCII; stored in the settings
    let id: String
    /// As the brand writes it. Only the name of `custom` is a word to translate.
    let name: String
    let format: LLMWireFormat
    /// without a slash at the end; "" where the user has to enter the address
    let defaultBaseURL: String
    let baseURLRule: BaseURLRule
    /// what an address looks like, for the field it is typed into
    let baseURLExample: String
    /// added to an address that was entered without a path ("http://192.168.1.20:11434")
    let pathWhenMissing: String
    /// "" where the model has to be picked from the server's list
    let defaultModel: String
    /// other models worth offering
    let suggestedModels: [String]
    /// What the service's list of models puts in front of every name although requests do not
    /// need it ("models/"); "" = nothing
    let listedModelPrefix: String
    /// false = the service works without a key, or the key is optional
    let needsAPIKey: Bool
    /// The key travels as "api-key: <key>" instead of "Authorization: Bearer <key>"
    let keyInAPIKeyHeader: Bool
    /// "reasoning_effort": "low" is documented for the service's current models, or ignored by
    /// models that do not know it: worth sending for a quicker answer. The caller still leaves
    /// it out once the server has answered 400 or 422.
    let sendsReasoningEffortLow: Bool
    /// page on which the user creates a key; "" = there is none
    let keyPage: String
    /// Runs on the user's computer or network: nothing leaves it. True for the address the
    /// service has by default; `LLMConnection.isLocal` looks at the address in use.
    let isLocal: Bool

    init(id: String, name: String, format: LLMWireFormat = .openAICompatible, baseURL: String,
         baseURLRule: BaseURLRule = .fixed, baseURLExample: String = "", pathWhenMissing: String = "",
         defaultModel: String, suggestedModels: [String] = [], listedModelPrefix: String = "",
         needsAPIKey: Bool = true, keyInAPIKeyHeader: Bool = false, sendsReasoningEffortLow: Bool = false,
         keyPage: String = "", isLocal: Bool = false) {
        self.id = id
        self.name = name
        self.format = format
        self.defaultBaseURL = baseURL
        self.baseURLRule = baseURLRule
        self.baseURLExample = baseURLExample.isEmpty ? baseURL : baseURLExample
        self.pathWhenMissing = pathWhenMissing
        self.defaultModel = defaultModel
        self.suggestedModels = suggestedModels
        self.listedModelPrefix = listedModelPrefix
        self.needsAPIKey = needsAPIKey
        self.keyInAPIKeyHeader = keyInAPIKeyHeader
        self.sendsReasoningEffortLow = sendsReasoningEffortLow
        self.keyPage = keyPage
        self.isLocal = isLocal
    }

    /// The default model and the suggestions, the default first
    var knownModels: [String] {
        (defaultModel.isEmpty ? [] : [defaultModel]) + suggestedModels
    }

    // MARK: The services

    static let openAI = LLMProvider(
        id: "openai", name: "OpenAI", baseURL: "https://api.openai.com/v1",
        defaultModel: "gpt-6-luna", suggestedModels: ["gpt-6.1-terra", "gpt-6.1-sol"],
        sendsReasoningEffortLow: true, keyPage: "https://platform.openai.com/api-keys")

    static let anthropic = LLMProvider(
        id: "anthropic", name: "Anthropic", format: .anthropic, baseURL: "https://api.anthropic.com/v1",
        defaultModel: "claude-opus-5-5", suggestedModels: ["claude-sonnet-5-5", "claude-haiku-5-5", "claude-fable-5-2"],
        keyPage: "https://platform.claude.com/settings/keys")

    /// through its OpenAI-compatible endpoint
    static let gemini = LLMProvider(
        id: "gemini", name: "Google Gemini", baseURL: "https://generativelanguage.googleapis.com/v1beta/openai",
        defaultModel: "gemini-3.5-flash-lite", suggestedModels: ["gemini-3.8-flash", "gemini-3.1-flash-lite"],
        listedModelPrefix: "models/", sendsReasoningEffortLow: true, keyPage: "https://aistudio.google.com/apikey")

    /// No "reasoning_effort": its models accept different values, and none of them is common to all.
    static let mistral = LLMProvider(
        id: "mistral", name: "Mistral", baseURL: "https://api.mistral.ai/v1",
        defaultModel: "mistral-small-latest", suggestedModels: ["mistral-large-4", "ministral-8b-2512", "ministral-3b-2512"],
        keyPage: "https://console.mistral.ai/api-keys")

    static let xAI = LLMProvider(
        id: "xai", name: "xAI", baseURL: "https://api.x.ai/v1",
        defaultModel: "grok-4.3", suggestedModels: ["grok-4.7", "grok-4.20-0309-non-reasoning"],
        sendsReasoningEffortLow: true, keyPage: "https://console.x.ai/team/default/api-keys")

    static let deepSeek = LLMProvider(
        id: "deepseek", name: "DeepSeek", baseURL: "https://api.deepseek.com",
        defaultModel: "deepseek-flash", suggestedModels: ["deepseek-v4-pro"],
        sendsReasoningEffortLow: true, keyPage: "https://platform.deepseek.com/api_keys")

    static let groq = LLMProvider(
        id: "groq", name: "Groq", baseURL: "https://api.groq.com/openai/v1",
        defaultModel: "openai/gpt-oss-120b", suggestedModels: ["openai/gpt-oss-20b", "qwen/qwen3.8-27b"],
        sendsReasoningEffortLow: true, keyPage: "https://console.groq.com/keys")

    static let openRouter = LLMProvider(
        id: "openrouter", name: "OpenRouter", baseURL: "https://openrouter.ai/api/v1",
        defaultModel: "openai/gpt-6-luna", suggestedModels: ["google/gemini-3.8-flash", "deepseek/deepseek-v4.1-flash"],
        sendsReasoningEffortLow: true, keyPage: "https://openrouter.ai/keys")

    /// The address belongs to the user's resource, the model is the name of the user's
    /// deployment, and the keys are in the Azure portal, on the page of that resource.
    static let azure = LLMProvider(
        id: "azure", name: "Azure OpenAI", baseURL: "", baseURLRule: .required,
        baseURLExample: "https://<resource>.openai.azure.com/openai/v1", pathWhenMissing: "/openai/v1",
        defaultModel: "", keyInAPIKeyHeader: true, sendsReasoningEffortLow: true)

    /// The suggestions are the names of model families; the server lists them with a tag ("gemma4:12b").
    static let ollama = LLMProvider(
        id: "ollama", name: "Ollama", baseURL: "http://localhost:11434/v1", baseURLRule: .editable,
        pathWhenMissing: "/v1", defaultModel: "", suggestedModels: ["gemma4", "gpt-oss"],
        needsAPIKey: false, isLocal: true)

    static let lmStudio = LLMProvider(
        id: "lmstudio", name: "LM Studio", baseURL: "http://localhost:1234/v1", baseURLRule: .editable,
        pathWhenMissing: "/v1", defaultModel: "", needsAPIKey: false, isLocal: true)

    /// Any other server that speaks the OpenAI format
    static let custom = LLMProvider(
        id: "custom", name: "Custom", baseURL: "", baseURLRule: .required,
        baseURLExample: "https://example.com/v1", defaultModel: "", needsAPIKey: false)

    /// in the order they are offered
    static let all: [LLMProvider] = [
        openAI, anthropic, gemini, mistral, xAI, deepSeek, groq, openRouter, azure, ollama, lmStudio, custom,
    ]

    static func with(id: String) -> LLMProvider? {
        all.first { $0.id == id }
    }
}
