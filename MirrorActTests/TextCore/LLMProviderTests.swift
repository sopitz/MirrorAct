// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import XCTest
@testable import MirrorAct

/// The catalogue of language model services (Foundation only, like the core)
final class LLMProviderTests: XCTestCase {
    func testTheServicesInTheOrderTheyAreOffered() {
        XCTAssertEqual(LLMProvider.all.map(\.id),
                       ["openai", "anthropic", "gemini", "mistral", "xai", "deepseek", "groq", "openrouter",
                        "azure", "ollama", "lmstudio", "custom"])
        XCTAssertEqual(LLMProvider.all.map(\.name),
                       ["OpenAI", "Anthropic", "Google Gemini", "Mistral", "xAI", "DeepSeek", "Groq", "OpenRouter",
                        "Azure OpenAI", "Ollama", "LM Studio", "Custom"])
    }

    func testIdsAreStoredInTheSettingsSoTheyAreLowerCaseASCIIAndUnique() {
        for provider in LLMProvider.all {
            XCTAssertFalse(provider.id.isEmpty)
            XCTAssertTrue(provider.id.allSatisfy { $0.isASCII && ($0.isLowercase || $0.isNumber) }, provider.id)
            XCTAssertEqual(LLMProvider.with(id: provider.id), provider)
        }
        XCTAssertEqual(Set(LLMProvider.all.map(\.id)).count, LLMProvider.all.count)
        XCTAssertNil(LLMProvider.with(id: "OpenAI"), "ids are compared as they are")
        XCTAssertNil(LLMProvider.with(id: ""))
    }

    func testAddressesModelsAndKeyPages() {
        // id: address, default model, suggestions, key page, needs a key, local
        let expected: [(String, String, String, [String], String, Bool, Bool)] = [
            ("openai", "https://api.openai.com/v1", "gpt-6-luna", ["gpt-6.1-terra", "gpt-6.1-sol"],
             "https://platform.openai.com/api-keys", true, false),
            ("anthropic", "https://api.anthropic.com/v1", "claude-opus-5-5",
             ["claude-sonnet-5-5", "claude-haiku-5-5", "claude-fable-5-2"],
             "https://platform.claude.com/settings/keys", true, false),
            ("gemini", "https://generativelanguage.googleapis.com/v1beta/openai", "gemini-3.5-flash-lite",
             ["gemini-3.8-flash", "gemini-3.1-flash-lite"], "https://aistudio.google.com/apikey", true, false),
            ("mistral", "https://api.mistral.ai/v1", "mistral-small-latest",
             ["mistral-large-4", "ministral-8b-2512", "ministral-3b-2512"], "https://console.mistral.ai/api-keys", true, false),
            ("xai", "https://api.x.ai/v1", "grok-4.3", ["grok-4.7", "grok-4.20-0309-non-reasoning"],
             "https://console.x.ai/team/default/api-keys", true, false),
            ("deepseek", "https://api.deepseek.com", "deepseek-flash", ["deepseek-v4-pro"],
             "https://platform.deepseek.com/api_keys", true, false),
            ("groq", "https://api.groq.com/openai/v1", "openai/gpt-oss-120b", ["openai/gpt-oss-20b", "qwen/qwen3.8-27b"],
             "https://console.groq.com/keys", true, false),
            ("openrouter", "https://openrouter.ai/api/v1", "openai/gpt-6-luna",
             ["google/gemini-3.8-flash", "deepseek/deepseek-v4.1-flash"], "https://openrouter.ai/keys", true, false),
            ("azure", "", "", [], "", true, false),
            ("ollama", "http://localhost:11434/v1", "", ["gemma4", "gpt-oss"], "", false, true),
            ("lmstudio", "http://localhost:1234/v1", "", [], "", false, true),
            ("custom", "", "", [], "", false, false),
        ]
        XCTAssertEqual(expected.map { $0.0 }, LLMProvider.all.map(\.id))
        for (id, address, model, suggestions, keyPage, needsKey, isLocal) in expected {
            guard let provider = LLMProvider.with(id: id) else {
                XCTFail("no service \(id)")
                continue
            }
            XCTAssertEqual(provider.defaultBaseURL, address, id)
            XCTAssertEqual(provider.defaultModel, model, id)
            XCTAssertEqual(provider.suggestedModels, suggestions, id)
            XCTAssertEqual(provider.keyPage, keyPage, id)
            XCTAssertEqual(provider.needsAPIKey, needsKey, id)
            XCTAssertEqual(provider.isLocal, isLocal, id)
            XCTAssertFalse(provider.defaultBaseURL.hasSuffix("/"), id)
            XCTAssertFalse(provider.suggestedModels.contains(provider.defaultModel), "\(id): the default is no suggestion")
        }
    }

    func testOnlyAnthropicSpeaksItsOwnFormat() {
        for provider in LLMProvider.all {
            XCTAssertEqual(provider.format, provider.id == "anthropic" ? .anthropic : .openAICompatible, provider.id)
        }
    }

    func testWhoDecidesTheAddress() {
        for provider in LLMProvider.all {
            switch provider.id {
            case "azure", "custom":
                XCTAssertEqual(provider.baseURLRule, .required, provider.id)
                XCTAssertTrue(provider.defaultBaseURL.isEmpty, provider.id)
            case "ollama", "lmstudio":
                XCTAssertEqual(provider.baseURLRule, .editable, provider.id)
            default:
                XCTAssertEqual(provider.baseURLRule, .fixed, provider.id)
            }
            XCTAssertFalse(provider.baseURLExample.isEmpty, "\(provider.id): the address field needs an example")
        }
        XCTAssertEqual(LLMProvider.azure.baseURLExample, "https://<resource>.openai.azure.com/openai/v1")
        XCTAssertEqual(LLMProvider.azure.pathWhenMissing, "/openai/v1")
        XCTAssertEqual(LLMProvider.ollama.pathWhenMissing, "/v1")
        XCTAssertEqual(LLMProvider.lmStudio.pathWhenMissing, "/v1")
        XCTAssertEqual(LLMProvider.custom.pathWhenMissing, "", "an own server decides its paths itself")
        XCTAssertEqual(LLMProvider.openAI.baseURLExample, "https://api.openai.com/v1")
    }

    func testKnownModelsStartWithTheDefault() {
        XCTAssertEqual(LLMProvider.anthropic.knownModels,
                       ["claude-opus-5-5", "claude-sonnet-5-5", "claude-haiku-5-5", "claude-fable-5-2"])
        XCTAssertEqual(LLMProvider.ollama.knownModels, ["gemma4", "gpt-oss"])
        XCTAssertEqual(LLMProvider.custom.knownModels, [])
    }

    func testWhereTheKeyAndTheReasoningEffortGo() {
        XCTAssertEqual(LLMProvider.all.filter(\.keyInAPIKeyHeader).map(\.id), ["azure"])
        XCTAssertEqual(LLMProvider.all.filter { !$0.listedModelPrefix.isEmpty }.map(\.id), ["gemini"])
        XCTAssertEqual(LLMProvider.gemini.listedModelPrefix, "models/")
        // not where the documentation names no value that all models accept, and not for unknown servers
        XCTAssertEqual(LLMProvider.all.filter(\.sendsReasoningEffortLow).map(\.id),
                       ["openai", "gemini", "xai", "deepseek", "groq", "openrouter", "azure"])
    }
}
