// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import XCTest
@testable import MirrorAct

/// Which models a service offers and what an Anthropic model can do (Foundation only, like the
/// core). The lists have the shapes the services document; the ids are those of November 2026.
final class LLMModelListTests: XCTestCase {
    private func models(_ provider: LLMProvider, _ body: String, status: Int = 200) throws -> [String] {
        try LLMWire.modelIDs(provider: provider, status: status, body: Data(body.utf8))
    }

    private func failure(_ body: () throws -> Any) -> LLMError? {
        do {
            let value = try body()
            XCTFail("no error, but \(value)")
            return nil
        } catch {
            return error as? LLMError
        }
    }

    // MARK: Model lists

    func testOpenAIListHasOnlyNamesToGoBy() throws {
        let ids = ["gpt-6.1-sol", "text-embedding-3-small", "gpt-6-luna", "gpt-image-2", "gpt-4o-mini-tts", "gpt-audio-1.5",
                   "gpt-realtime-2.1", "whisper-1", "gpt-4o-transcribe", "omni-moderation-latest", "gpt-6.1-terra", "dall-e-3",
                   "babbage-002", "davinci-002", "sora-2", "gpt-6-astra", "o4-mini", "gpt-4.1", "chatgpt-image-latest"]
        let entries = ids.map { #"{"id":"\#($0)","object":"model","created":1790000000,"owned_by":"openai","shutdown_date":null}"# }
        let list = try models(.openAI, #"{"object":"list","data":[\#(entries.joined(separator: ","))]}"#)
        // the default, the suggestions, then the others by name; nothing that embeds, draws, speaks or listens
        XCTAssertEqual(list, ["gpt-6-luna", "gpt-6.1-terra", "gpt-6.1-sol", "gpt-4.1", "gpt-6-astra", "o4-mini"])
    }

    func testAnthropicList() throws {
        let list = try models(.anthropic, #"""
            {"data":[
              {"type":"model","id":"claude-fable-5-2","display_name":"Claude Fable 5.2","created_at":"2026-10-06T00:00:00Z",
               "capabilities":null,"lifecycle":"active","line":"fable","max_input_tokens":1000000,"max_tokens":128000,
               "deprecated_at":null,"retires_at":null},
              {"type":"model","id":"claude-opus-4-8","display_name":"Claude Opus 4.8","lifecycle":"active","line":"opus"},
              {"type":"model","id":"claude-haiku-5-5","display_name":"Claude Haiku 5.5","lifecycle":"active","line":"haiku"},
              {"type":"model","id":"claude-opus-5-5","display_name":"Claude Opus 5.5","lifecycle":"active","line":"opus"},
              {"type":"model","id":"claude-sonnet-5-5","display_name":"Claude Sonnet 5.5","lifecycle":"active","line":"sonnet"},
              {"type":"model","id":"claude-sonnet-4-5","display_name":"Claude Sonnet 4.5","lifecycle":"deprecated","line":"sonnet"},
              {"type":"model","id":"claude-opus-4-1","display_name":"Claude Opus 4.1","lifecycle":"retired","line":"opus"}
            ],"first_id":"claude-fable-5-2","has_more":false,"last_id":"claude-opus-4-1"}
            """#)
        // a retired model cannot be used any more; a deprecated one can
        XCTAssertEqual(list, ["claude-opus-5-5", "claude-sonnet-5-5", "claude-haiku-5-5", "claude-fable-5-2",
                              "claude-opus-4-8", "claude-sonnet-4-5"])
    }

    func testGeminiListNamesModelsWithAPrefix() throws {
        let list = try models(.gemini, #"""
            {"object":"list","data":[
              {"id":"models/gemini-3.8-flash","object":"model","owned_by":"google"},
              {"id":"models/gemini-embedding-001","object":"model","owned_by":"google"},
              {"id":"models/gemini-3.5-flash-lite","object":"model","owned_by":"google"},
              {"id":"gemini-3.1-flash-lite","object":"model","owned_by":"google"},
              {"id":"models/imagen-4.0-generate-001","object":"model","owned_by":"google"},
              {"id":"models/veo-3.1-generate-preview","object":"model","owned_by":"google"},
              {"id":"models/gemini-3.6-flash","object":"model","owned_by":"google"},
              {"id":"models/gemini-3.6-flash-preview-tts","object":"model","owned_by":"google"},
              {"id":"models/gemma-3-27b-it","object":"model","owned_by":"google"}
            ]}
            """#)
        XCTAssertEqual(list, ["gemini-3.5-flash-lite", "gemini-3.8-flash", "gemini-3.1-flash-lite", "gemini-3.6-flash", "gemma-3-27b-it"])
    }

    func testGeminisOwnListSaysWhatAModelCanDo() throws {
        let list = try models(.gemini, #"""
            {"models":[
              {"name":"models/gemini-3.8-flash","displayName":"Gemini 3.8 Flash","thinking":true,
               "supportedGenerationMethods":["generateContent","countTokens"]},
              {"name":"models/aqa","supportedGenerationMethods":["generateAnswer"]},
              {"name":"models/text-multilingual-002","supportedGenerationMethods":["embedContent"]}
            ],"nextPageToken":"abc"}
            """#)
        XCTAssertEqual(list, ["gemini-3.8-flash"])
    }

    func testMistralListSaysWhichModelsChat() throws {
        let list = try models(.mistral, #"""
            {"object":"list","data":[
              {"id":"mistral-large-4","object":"model","created":1790000000,"owned_by":"mistralai",
               "capabilities":{"completion_chat":true,"reasoning":true,"function_calling":true},"name":"mistral-large-4",
               "max_context_length":262144,"aliases":[],"deprecation":null},
              {"id":"mistral-embed","object":"model","capabilities":{"completion_chat":false}},
              {"id":"mistral-small-latest","object":"model","capabilities":{"completion_chat":true},"aliases":["mistral-small-2603"]},
              {"id":"mistral-ocr-latest","object":"model","capabilities":{"completion_chat":false}},
              {"id":"classifier-ft-1","object":"model","capabilities":{"completion_chat":false,"classification":true}},
              {"id":"ministral-8b-2512","object":"model","capabilities":{"completion_chat":true}},
              {"id":"mistral-small-latest","object":"model","capabilities":{"completion_chat":true}},
              {"id":"codestral-latest","object":"model","capabilities":{"completion_chat":true}}
            ]}
            """#)
        XCTAssertEqual(list, ["mistral-small-latest", "mistral-large-4", "ministral-8b-2512", "codestral-latest"])
    }

    func testXAIListWithAModelThatDrawsPictures() throws {
        let list = try models(.xAI, #"""
            {"data":[
              {"id":"latest","aliases":[],"context_length":131072,"created":1776556800,"object":"model","owned_by":"xai",
               "prompt_text_token_price":12500,"cached_prompt_text_token_price":2000,"prompt_image_token_price":12500,
               "completion_text_token_price":25000},
              {"id":"grok-4.7","aliases":[],"context_length":256000,"created":1768003200,"object":"model","owned_by":"xai",
               "prompt_text_token_price":20000,"completion_text_token_price":60000,
               "capabilities":{"reasoning_effort":["low","medium","high","xhigh"],"default_reasoning_effort":"high"}},
              {"id":"grok-4.3","aliases":[],"object":"model","owned_by":"xai","completion_text_token_price":25000},
              {"id":"grok-imagine-image","aliases":[],"context_length":1024,"created":1769472000,"object":"model","owned_by":"xai",
               "image_price":200000000},
              {"id":"aurora","aliases":[],"object":"model","owned_by":"xai","image_price":7000000}
            ],"object":"list"}
            """#)
        XCTAssertEqual(list, ["grok-4.3", "grok-4.7", "latest"])
    }

    func testDeepSeekList() throws {
        let list = try models(.deepSeek, #"""
            {"object":"list","data":[
              {"id":"deepseek-v4-pro","object":"model","owned_by":"deepseek","name":"DeepSeek V4 Pro","context_window":1000000,
               "max_output_tokens":64000,"input_modalities":["text"],"output_modalities":["text"],
               "effort":{"supported_levels":["low","high","max"],"default_level":"high"}},
              {"id":"deepseek-flash","object":"model","owned_by":"deepseek","input_modalities":["text","image"],"output_modalities":["text"]},
              {"id":"deepseek-voice","object":"model","owned_by":"deepseek","output_modalities":["audio"]}
            ]}
            """#)
        XCTAssertEqual(list, ["deepseek-flash", "deepseek-v4-pro"])
    }

    func testGroqListWithModelsForSpeechAndForGuarding() throws {
        let ids = ["whisper-large-v3", "openai/gpt-oss-20b", "canopylabs/orpheus-v1-english", "qwen/qwen3.8-27b",
                   "meta-llama/llama-prompt-guard-2-86m", "openai/gpt-oss-120b", "openai/gpt-oss-safeguard-20b",
                   "whisper-large-v3-turbo", "llama-3.1-8b-instant"]
        var entries = ids.map {
            #"{"id":"\#($0)","object":"model","created":1693721698,"owned_by":"x","active":true,"context_window":131072,"public_apps":null}"#
        }
        // switched off
        entries.append(#"{"id":"llama-3.3-70b-versatile","object":"model","owned_by":"Meta","active":false,"context_window":131072}"#)
        let list = try models(.groq, #"{"object":"list","data":[\#(entries.joined(separator: ","))]}"#)
        XCTAssertEqual(list, ["openai/gpt-oss-120b", "openai/gpt-oss-20b", "qwen/qwen3.8-27b", "llama-3.1-8b-instant"])
    }

    func testOpenRouterList() throws {
        let list = try models(.openRouter, #"""
            {"data":[
              {"id":"baidu/ernie-5.5-flash-preview:free","name":"Baidu: ERNIE-5.5-Flash-Preview (free)","context_length":1024000,
               "architecture":{"modality":"text->text","input_modalities":["text"],"output_modalities":["text"],"tokenizer":"Other"},
               "pricing":{"prompt":"0","completion":"0"},"supported_parameters":["reasoning","reasoning_effort"],
               "reasoning":{"mandatory":true,"default_enabled":true,"supported_efforts":["high"],"default_effort":"high"}},
              {"id":"deepseek/deepseek-v4.1-flash","architecture":{"output_modalities":["text"]}},
              {"id":"acme/painter","architecture":{"input_modalities":["text"],"output_modalities":["image"]}},
              {"id":"~openai/gpt-luna-latest","architecture":{"output_modalities":["text"]}},
              {"id":"google/gemini-3.8-flash","architecture":{"output_modalities":["text","image"]}},
              {"id":"openai/gpt-6-luna","architecture":{"output_modalities":["text"]}},
              {"id":"openai/gpt-6-luna:free","architecture":{"output_modalities":["text"]}}
            ],"total_count":469}
            """#)
        XCTAssertEqual(list, ["openai/gpt-6-luna", "openai/gpt-6-luna:free", "google/gemini-3.8-flash", "deepseek/deepseek-v4.1-flash",
                              "baidu/ernie-5.5-flash-preview:free", "~openai/gpt-luna-latest"])
    }

    func testOllamaListsModelsWithTheirTags() throws {
        let ids = ["qwen3.8:27b", "gpt-oss:120b", "nomic-embed-text:latest", "gemma4:e4b", "deepseek-v4.1-flash:1017",
                   "embeddinggemma:300m", "gemma4:12b", "gemma40:latest"]
        let entries = ids.map { #"{"id":"\#($0)","object":"model","created":1790092800,"owned_by":"ollama"}"# }
        let list = try models(.ollama, #"{"object":"list","data":[\#(entries.joined(separator: ","))]}"#)
        // the families the catalogue suggests first, whatever their tag
        XCTAssertEqual(list, ["gemma4:12b", "gemma4:e4b", "gpt-oss:120b", "deepseek-v4.1-flash:1017", "gemma40:latest", "qwen3.8:27b"])
    }

    func testOllamasOwnList() throws {
        let list = try models(.ollama, #"""
            {"models":[{"name":"llama3.2:latest","model":"llama3.2:latest","modified_at":"2026-10-01T10:00:00Z","size":2019393189,
                        "digest":"a80c4f17acd5","details":{"format":"gguf","family":"llama"}},
                       {"name":"mxbai-embed-large:latest","model":"mxbai-embed-large:latest"}]}
            """#)
        XCTAssertEqual(list, ["llama3.2:latest"])
    }

    func testLMStudioList() throws {
        let list = try models(.lmStudio, #"""
            {"data":[{"id":"qwen/qwen3.8-27b","object":"model","owned_by":"organization_owner"},
                     {"id":"text-embedding-nomic-embed-text-v1.5","object":"model","owned_by":"organization_owner"},
                     {"id":"google/gemma-4-12b","object":"model","owned_by":"organization_owner"},
                     {"id":"bge-small","type":"embeddings","object":"model"}],
             "object":"list"}
            """#)
        XCTAssertEqual(list, ["google/gemma-4-12b", "qwen/qwen3.8-27b"])
    }

    func testOnlyGeminiNamesLoseThePrefix() throws {
        // a server of one's own can name a model after the folder it is in
        XCTAssertEqual(try models(.custom, #"{"object":"list","data":[{"id":"models/qwen3.8-27b"}]}"#), ["models/qwen3.8-27b"])
        XCTAssertEqual(try models(.gemini, #"{"object":"list","data":[{"id":"models/models/odd"},{"id":"models/"}]}"#), ["models/odd"])
    }

    func testListsOfOtherShapes() throws {
        XCTAssertEqual(try models(.custom, #"[{"id":"b-model"},{"id":"A-model"},{"id":"a-model"}]"#), ["A-model", "a-model", "b-model"])
        XCTAssertEqual(try models(.custom, #"{"data":["zeta","alpha"]}"#), ["alpha", "zeta"])
        XCTAssertEqual(try models(.custom, #"{"object":"list","data":[]}"#), [])
        XCTAssertEqual(try models(.custom, "[]"), [])
        // entries without a usable name are skipped
        XCTAssertEqual(try models(.custom, #"{"data":[{"id":7},{"object":"model"},null,{"id":"  "},{"id":" padded "},3,[]]}"#), ["padded"])
        // "data" that is no list
        XCTAssertEqual(failure { try self.models(.custom, #"{"object":"list","data":{"id":"x"}}"#) },
                       .malformedReply("the reply contains no list of models"))
        XCTAssertEqual(failure { try self.models(.custom, "{}") }, .malformedReply("the reply contains no list of models"))
        XCTAssertEqual(failure { try self.models(.custom, "<html>It works!</html>") }, .malformedReply("the reply contains no list of models"))
        XCTAssertEqual(failure { try self.models(.custom, "") }, .malformedReply("the reply contains no list of models"))
        XCTAssertEqual(failure { try self.models(.custom, #""models""#) }, .malformedReply("the reply contains no list of models"))
    }

    func testAListThatCouldNotBeFetched() {
        XCTAssertEqual(failure { try self.models(.openAI, #"""
            {"error":{"message":"Incorrect API key provided","type":"invalid_request_error","code":"invalid_api_key"}}
            """#, status: 401) }, .invalidKey)
        XCTAssertEqual(failure { try self.models(.gemini, #"""
            {"error":{"code":400,"message":"Please pass a valid API key","status":"INVALID_ARGUMENT"}}
            """#, status: 400) }, .invalidKey)
        XCTAssertEqual(failure { try self.models(.custom, #"{"detail":"Not Found"}"#, status: 404) },
                       .server(status: 404, message: "Not Found"))
        XCTAssertEqual(failure { try self.models(.openRouter, #"{"error":{"code":503,"message":"No provider"}}"#) }, .overloaded)
        let limited = failure {
            try LLMWire.modelIDs(provider: .groq, status: 429, headers: [LLMHeader("retry-after", "4")], body: Data())
        }
        XCTAssertEqual(limited, .rateLimited(retryAfterSeconds: 4))
    }

    // MARK: What an Anthropic model can do

    private func capabilities(_ body: String, status: Int = 200) throws -> LLMModelCapabilities {
        try LLMWire.capabilities(status: status, body: Data(body.utf8))
    }

    func testCapabilitiesOfACurrentModel() throws {
        let found = try capabilities(#"""
            {
              "id": "claude-opus-5-5",
              "allowed_fallback_models": ["claude-opus-4-8", "claude-opus-5"],
              "capabilities": {
                "batch": {"supported": true},
                "effort": {
                  "high": {"supported": true},
                  "low": {"supported": true},
                  "max": {"supported": true},
                  "medium": {"supported": true},
                  "supported": true,
                  "xhigh": {"supported": true}
                },
                "structured_outputs": {"supported": true},
                "thinking": {"supported": true, "types": {"adaptive": {"supported": true}, "disabled": {"supported": false}}}
              },
              "created_at": "2026-09-15T00:00:00Z",
              "display_name": "Claude Opus 5.5",
              "lifecycle": "active",
              "line": "opus",
              "max_input_tokens": 1000000,
              "max_tokens": 128000,
              "type": "model"
            }
            """#)
        XCTAssertEqual(found, LLMModelCapabilities(supportsEffortLow: true, hasFallbackModels: true))
    }

    func testCapabilitiesOfAModelWithoutEffortAndWithoutFallback() throws {
        let found = try capabilities(#"""
            {"id":"claude-haiku-4-5","type":"model","allowed_fallback_models":[],
             "capabilities":{"effort":{"high":{"supported":false},"low":{"supported":false},"max":{"supported":false},
                                       "medium":{"supported":false},"supported":false,"xhigh":null}}}
            """#)
        XCTAssertEqual(found, LLMModelCapabilities(supportsEffortLow: false, hasFallbackModels: false))
    }

    func testWhatIsMissingCountsAsNo() throws {
        let effortOnly = #"{"id":"m","capabilities":{"effort":{"low":{"supported":true}}}}"#
        // asked without the beta header, the service does not list the fallback models
        XCTAssertEqual(try capabilities(effortOnly), LLMModelCapabilities(supportsEffortLow: true, hasFallbackModels: false))
        XCTAssertEqual(try capabilities(#"{"id":"m","allowed_fallback_models":null,"capabilities":null}"#), LLMModelCapabilities())
        XCTAssertEqual(try capabilities(#"{"id":"m","allowed_fallback_models":["x"]}"#),
                       LLMModelCapabilities(supportsEffortLow: false, hasFallbackModels: true))
        XCTAssertEqual(try capabilities(#"{"id":"m","capabilities":{"effort":{"supported":true}}}"#), LLMModelCapabilities())
        XCTAssertEqual(try capabilities(#"{"id":"m","capabilities":{"effort":{"low":{"supported":"true"}}}}"#), LLMModelCapabilities())
        XCTAssertEqual(try capabilities(#"{"id":"m","capabilities":{"effort":{"low":true}},"allowed_fallback_models":"all"}"#),
                       LLMModelCapabilities())
        XCTAssertEqual(try capabilities("{}"), LLMModelCapabilities())
        XCTAssertEqual(try capabilities("[]"), LLMModelCapabilities())
        XCTAssertEqual(try capabilities("not json"), LLMModelCapabilities())
        XCTAssertEqual(try capabilities(""), LLMModelCapabilities())
    }

    func testCapabilitiesThatCouldNotBeFetched() {
        XCTAssertEqual(failure { try self.capabilities(#"""
            {"type":"error","error":{"type":"not_found_error","message":"model: claude-nope"},"request_id":"req_1"}
            """#, status: 404) }, .unknownModel)
        XCTAssertEqual(failure { try self.capabilities(#"""
            {"type":"error","error":{"type":"authentication_error","message":"invalid x-api-key"}}
            """#, status: 401) }, .invalidKey)
        // the organization may not use the beta: the caller asks again without the header
        XCTAssertEqual(failure { try self.capabilities(#"""
            {"type":"error","error":{"type":"invalid_request_error",
             "message":"Unexpected value(s) `server-side-fallback-2026-07-01` for the `anthropic-beta` header."}}
            """#, status: 400) }, .badRequest("Unexpected value(s) `server-side-fallback-2026-07-01` for the `anthropic-beta` header."))
    }
}
