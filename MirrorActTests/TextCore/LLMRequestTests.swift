// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import XCTest
@testable import MirrorAct

/// JSON text with sorted keys, to compare two bodies whatever the order of their keys; "" for no JSON
func llmCanonicalJSON(_ data: Data?) -> String {
    guard let data, let value = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]),
          JSONSerialization.isValidJSONObject(value),
          let sorted = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) else {
        return ""
    }
    return String(decoding: sorted, as: UTF8.self)
}

func llmCanonicalJSON(_ text: String) -> String {
    llmCanonicalJSON(Data(text.utf8))
}

/// What is sent to the language model services (Foundation only: also runs on Linux)
final class LLMRequestTests: XCTestCase {
    private let system = "Translate into German (de)."
    private let user = #"["Settings","Wi-Fi \"Home\""]"#
    /// the two messages of the OpenAI format, as JSON
    private let messages = #"[{"role":"system","content":"Translate into German (de)."},"#
        + #"{"role":"user","content":"[\"Settings\",\"Wi-Fi \\\"Home\\\"\"]"}]"#

    private func chat(_ provider: LLMProvider, baseURL: String? = nil, model: String? = nil, apiKey: String? = "sk-test",
                      options: LLMRequestOptions = LLMRequestOptions()) -> LLMHTTPRequest {
        let connection = LLMConnection(provider: provider, baseURL: baseURL, model: model, apiKey: apiKey)
        return LLMWire.chatRequest(connection, system: system, user: user, options: options)
    }

    // MARK: Chat, service by service

    func testServicesWithTheOpenAIFormatAndAKey() {
        let expected: [(LLMProvider, String, String)] = [
            (.openAI, "https://api.openai.com/v1/chat/completions", "gpt-6-luna"),
            (.gemini, "https://generativelanguage.googleapis.com/v1beta/openai/chat/completions", "gemini-3.5-flash-lite"),
            (.mistral, "https://api.mistral.ai/v1/chat/completions", "mistral-small-latest"),
            (.xAI, "https://api.x.ai/v1/chat/completions", "grok-4.3"),
            (.deepSeek, "https://api.deepseek.com/chat/completions", "deepseek-flash"),
            (.groq, "https://api.groq.com/openai/v1/chat/completions", "openai/gpt-oss-120b"),
            (.openRouter, "https://openrouter.ai/api/v1/chat/completions", "openai/gpt-6-luna"),
        ]
        for (provider, url, model) in expected {
            let request = chat(provider)
            XCTAssertEqual(request.method, "POST", provider.id)
            XCTAssertEqual(request.url, url, provider.id)
            XCTAssertEqual(request.headers, [LLMHeader("Authorization", "Bearer sk-test"),
                                             LLMHeader("Content-Type", "application/json")], provider.id)
            // the model and the two messages and nothing else: every other field is rejected somewhere
            XCTAssertEqual(llmCanonicalJSON(request.body),
                           llmCanonicalJSON(#"{"model":"\#(model)","messages":\#(messages)}"#), provider.id)
        }
    }

    func testAnthropic() {
        let request = chat(.anthropic, apiKey: "sk-ant-api03-test")
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.url, "https://api.anthropic.com/v1/messages")
        XCTAssertEqual(request.headers, [LLMHeader("x-api-key", "sk-ant-api03-test"),
                                         LLMHeader("anthropic-version", "2026-10-21"),
                                         LLMHeader("content-type", "application/json")])
        XCTAssertEqual(llmCanonicalJSON(request.body), llmCanonicalJSON(#"""
            {"model":"claude-opus-5-5","max_tokens":16000,"system":"Translate into German (de).",
             "messages":[{"role":"user","content":"[\"Settings\",\"Wi-Fi \\\"Home\\\"\"]"}]}
            """#))
        // these are rejected by every model of this version of the API
        let body = String(decoding: request.body ?? Data(), as: UTF8.self)
        for field in ["temperature", "top_p", "top_k", "thinking", "stream"] {
            XCTAssertFalse(body.contains(field), field)
        }
    }

    func testAnthropicIgnoresAnAddressOfTheUser() {
        let request = chat(.anthropic, baseURL: "https://proxy.example.com/v1", model: " claude-haiku-5-5 ")
        XCTAssertEqual(request.url, "https://api.anthropic.com/v1/messages")
        XCTAssertTrue(llmCanonicalJSON(request.body).contains(#""model":"claude-haiku-5-5""#))
    }

    func testAnthropicExtras() {
        let quick = chat(.anthropic, options: LLMRequestOptions(effortLow: true))
        XCTAssertEqual(quick.headers.map(\.name), ["x-api-key", "anthropic-version", "content-type"])
        XCTAssertEqual(llmCanonicalJSON(quick.body), llmCanonicalJSON(#"""
            {"model":"claude-opus-5-5","max_tokens":16000,"system":"Translate into German (de).",
             "messages":[{"role":"user","content":"[\"Settings\",\"Wi-Fi \\\"Home\\\"\"]"}],
             "output_config":{"effort":"low"}}
            """#))

        let fallback = chat(.anthropic, options: LLMRequestOptions(refusalFallback: true))
        XCTAssertEqual(fallback.headers, [LLMHeader("x-api-key", "sk-test"),
                                          LLMHeader("anthropic-version", "2026-10-21"),
                                          LLMHeader("content-type", "application/json"),
                                          LLMHeader("anthropic-beta", "server-side-fallback-2026-07-01")])
        XCTAssertEqual(llmCanonicalJSON(fallback.body), llmCanonicalJSON(#"""
            {"model":"claude-opus-5-5","max_tokens":16000,"system":"Translate into German (de).",
             "messages":[{"role":"user","content":"[\"Settings\",\"Wi-Fi \\\"Home\\\"\"]"}],
             "fallbacks":"default"}
            """#))

        let both = chat(.anthropic, options: LLMRequestOptions(effortLow: true, refusalFallback: true, reasoningEffortLow: true))
        let body = llmCanonicalJSON(both.body)
        XCTAssertTrue(body.contains(#""output_config":{"effort":"low"}"#))
        XCTAssertTrue(body.contains(#""fallbacks":"default""#))
        XCTAssertFalse(body.contains("reasoning_effort"), "that is a field of the OpenAI format")
    }

    func testReasoningEffortOfTheOpenAIFormat() {
        let request = chat(.openAI, options: LLMRequestOptions(reasoningEffortLow: true))
        XCTAssertEqual(llmCanonicalJSON(request.body),
                       llmCanonicalJSON(#"{"model":"gpt-6-luna","messages":\#(messages),"reasoning_effort":"low"}"#))
        XCTAssertEqual(request.headers.map(\.name), ["Authorization", "Content-Type"])

        // the extras of Anthropic mean nothing here
        let other = chat(.openAI, options: LLMRequestOptions(effortLow: true, refusalFallback: true))
        XCTAssertEqual(llmCanonicalJSON(other.body), llmCanonicalJSON(#"{"model":"gpt-6-luna","messages":\#(messages)}"#))
        XCTAssertEqual(other.headers.map(\.name), ["Authorization", "Content-Type"])
    }

    func testWhichExtrasAreKnownToBeAccepted() {
        // Anthropic: only what the model says about itself
        XCTAssertEqual(LLMRequestOptions(for: .anthropic), LLMRequestOptions())
        XCTAssertEqual(LLMRequestOptions(for: .anthropic, capabilities: LLMModelCapabilities(supportsEffortLow: true, hasFallbackModels: false)),
                       LLMRequestOptions(effortLow: true))
        XCTAssertEqual(LLMRequestOptions(for: .anthropic, capabilities: LLMModelCapabilities(supportsEffortLow: true, hasFallbackModels: true)),
                       LLMRequestOptions(effortLow: true, refusalFallback: true))
        // the others: what their documentation says, whatever an Anthropic model can do
        let everything = LLMModelCapabilities(supportsEffortLow: true, hasFallbackModels: true)
        XCTAssertEqual(LLMRequestOptions(for: .openAI, capabilities: everything), LLMRequestOptions(reasoningEffortLow: true))
        XCTAssertEqual(LLMRequestOptions(for: .groq), LLMRequestOptions(reasoningEffortLow: true))
        for provider in [LLMProvider.mistral, .ollama, .lmStudio, .custom] {
            XCTAssertEqual(LLMRequestOptions(for: provider, capabilities: everything), LLMRequestOptions(), provider.id)
        }
    }

    func testAzureSendsTheKeyInItsOwnHeader() {
        let request = chat(.azure, baseURL: "https://example-resource.openai.azure.com/openai/v1/", model: "my-deployment",
                           apiKey: "azure-key")
        XCTAssertEqual(request.url, "https://example-resource.openai.azure.com/openai/v1/chat/completions")
        XCTAssertEqual(request.headers, [LLMHeader("api-key", "azure-key"), LLMHeader("Content-Type", "application/json")])
        XCTAssertEqual(llmCanonicalJSON(request.body), llmCanonicalJSON(#"{"model":"my-deployment","messages":\#(messages)}"#))
    }

    func testLocalServersNeedNoKey() {
        let ollama = chat(.ollama, model: "gemma4:12b", apiKey: nil)
        XCTAssertEqual(ollama.url, "http://localhost:11434/v1/chat/completions")
        XCTAssertEqual(ollama.headers, [LLMHeader("Content-Type", "application/json")])
        XCTAssertEqual(llmCanonicalJSON(ollama.body), llmCanonicalJSON(#"{"model":"gemma4:12b","messages":\#(messages)}"#))

        let lmStudio = chat(.lmStudio, model: "qwen/qwen3.8-27b", apiKey: "  ")
        XCTAssertEqual(lmStudio.url, "http://localhost:1234/v1/chat/completions")
        XCTAssertEqual(lmStudio.headers, [LLMHeader("Content-Type", "application/json")])

        // LM Studio can be set up to ask for a token
        let withToken = chat(.lmStudio, model: "qwen/qwen3.8-27b", apiKey: "lm-token")
        XCTAssertEqual(withToken.headers, [LLMHeader("Authorization", "Bearer lm-token"),
                                           LLMHeader("Content-Type", "application/json")])
    }

    func testAnotherComputerInTheNetwork() {
        let request = chat(.ollama, baseURL: "192.168.1.20:11434", model: "gpt-oss:20b", apiKey: nil)
        XCTAssertEqual(request.url, "http://192.168.1.20:11434/v1/chat/completions")
    }

    func testCustomServerWithAndWithoutAKey() {
        let open = chat(.custom, baseURL: "https://llm.example.com/v1", model: "my-model", apiKey: "")
        XCTAssertEqual(open.url, "https://llm.example.com/v1/chat/completions")
        XCTAssertEqual(open.headers, [LLMHeader("Content-Type", "application/json")])
        XCTAssertEqual(llmCanonicalJSON(open.body), llmCanonicalJSON(#"{"model":"my-model","messages":\#(messages)}"#))

        let closed = chat(.custom, baseURL: "https://llm.example.com/api/", model: "my-model", apiKey: "secret")
        XCTAssertEqual(closed.url, "https://llm.example.com/api/chat/completions", "no /v1 is forced on an own server")
        XCTAssertEqual(closed.headers.first, LLMHeader("Authorization", "Bearer secret"))
    }

    func testTheBodyIsTheSameTextEveryTime() {
        let connection = LLMConnection(provider: .openAI, model: "m", apiKey: "k")
        let first = LLMWire.chatRequest(connection, system: "S", user: "U")
        let second = LLMWire.chatRequest(connection, system: "S", user: "U")
        XCTAssertEqual(first, second)
        XCTAssertEqual(String(decoding: first.body ?? Data(), as: UTF8.self),
                       #"{"messages":[{"content":"S","role":"system"},{"content":"U","role":"user"}],"model":"m"}"#)
    }

    func testTextTravelsUnchanged() throws {
        let text = "Zeile 1\nZeile 2\t\"Zitat\" \\ / 😀 日本語 </think> \u{1}"
        let connection = LLMConnection(provider: .openAI, apiKey: "k")
        for request in [LLMWire.chatRequest(connection, system: text, user: text),
                        LLMWire.chatRequest(LLMConnection(provider: .anthropic, apiKey: "k"), system: text, user: text)] {
            let body = try XCTUnwrap(request.body)
            let root = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])
            let messages = try XCTUnwrap(root["messages"] as? [[String: Any]])
            XCTAssertEqual(messages.last?["content"] as? String, text)
            XCTAssertEqual((root["system"] as? String) ?? (messages.first?["content"] as? String), text)
            XCTAssertFalse(String(decoding: body, as: UTF8.self).contains("\\/"), "slashes are not escaped")
        }
    }

    // MARK: The connection

    func testTheAddressOfTheUserIsTidiedUp() {
        func address(_ provider: LLMProvider, _ entered: String) -> String {
            LLMConnection(provider: provider, baseURL: entered).baseURL
        }
        XCTAssertEqual(address(.custom, "  https://llm.example.com/v1//  \n"), "https://llm.example.com/v1")
        XCTAssertEqual(address(.custom, "https://llm.example.com/v1/chat/completions"), "https://llm.example.com/v1")
        XCTAssertEqual(address(.custom, "https://llm.example.com/v1/Chat/Completions/"), "https://llm.example.com/v1")
        XCTAssertEqual(address(.custom, "https://llm.example.com"), "https://llm.example.com", "no path is forced on an own server")
        XCTAssertEqual(address(.custom, "llm.example.com/v1"), "https://llm.example.com/v1")
        XCTAssertEqual(address(.custom, "localhost:8080/v1"), "http://localhost:8080/v1", "local servers speak plain HTTP")
        XCTAssertEqual(address(.custom, "HTTP://Server.local:8080/v1"), "HTTP://Server.local:8080/v1")
        XCTAssertEqual(address(.custom, ""), "")
        XCTAssertEqual(address(.custom, "   "), "")

        XCTAssertEqual(address(.ollama, ""), "http://localhost:11434/v1")
        XCTAssertEqual(address(.ollama, "http://192.168.1.20:11434"), "http://192.168.1.20:11434/v1")
        XCTAssertEqual(address(.ollama, "http://192.168.1.20:11434/"), "http://192.168.1.20:11434/v1")
        XCTAssertEqual(address(.ollama, "mac-mini:11434"), "http://mac-mini:11434/v1")
        XCTAssertEqual(address(.ollama, "https://ollama.com/v1"), "https://ollama.com/v1")
        // Ollama and LM Studio speak nothing but plain HTTP, wherever they run
        XCTAssertEqual(address(.ollama, "gpu-box.lan:11434"), "http://gpu-box.lan:11434/v1")
        XCTAssertEqual(address(.ollama, "100.101.102.103:11434"), "http://100.101.102.103:11434/v1")
        XCTAssertEqual(address(.lmStudio, "studio.tailnet.ts.net:1234"), "http://studio.tailnet.ts.net:1234/v1")
        // a server of one's own under such a name is more likely behind https
        XCTAssertEqual(address(.custom, "gpu-box.lan:8080/v1"), "https://gpu-box.lan:8080/v1")
        XCTAssertEqual(address(.lmStudio, "http://[::1]:1234"), "http://[::1]:1234/v1")
        XCTAssertEqual(address(.lmStudio, "http://localhost:1234/api/v0"), "http://localhost:1234/api/v0")

        XCTAssertEqual(address(.azure, "https://example-resource.openai.azure.com/"),
                       "https://example-resource.openai.azure.com/openai/v1", "the address as the Azure portal shows it")
        XCTAssertEqual(address(.azure, "example-resource.openai.azure.com"), "https://example-resource.openai.azure.com/openai/v1")
        XCTAssertEqual(address(.azure, "https://example-resource.services.ai.azure.com/openai/v1/"),
                       "https://example-resource.services.ai.azure.com/openai/v1")
        XCTAssertEqual(address(.azure, ""), "")

        // where the address is fixed, an entry left over in the settings does not count
        for provider in LLMProvider.all where provider.baseURLRule == .fixed {
            XCTAssertEqual(address(provider, "https://elsewhere.example.com/v1"), provider.defaultBaseURL, provider.id)
        }
    }

    func testModelAndKey() {
        XCTAssertEqual(LLMConnection(provider: .openAI).model, "gpt-6-luna")
        XCTAssertEqual(LLMConnection(provider: .openAI, model: "").model, "gpt-6-luna")
        XCTAssertEqual(LLMConnection(provider: .openAI, model: "  \n").model, "gpt-6-luna")
        XCTAssertEqual(LLMConnection(provider: .openAI, model: " gpt-6.1-terra ").model, "gpt-6.1-terra")
        XCTAssertEqual(LLMConnection(provider: .ollama).model, "")
        XCTAssertEqual(LLMConnection(provider: .openAI).apiKey, "")
        XCTAssertEqual(LLMConnection(provider: .openAI, apiKey: " sk-test\n").apiKey, "sk-test")
    }

    func testWhatIsStillMissing() {
        XCTAssertEqual(LLMConnection(provider: .openAI).missing, .apiKey)
        XCTAssertNil(LLMConnection(provider: .openAI, apiKey: "sk-test").missing)
        XCTAssertNil(LLMConnection(provider: .anthropic, apiKey: "sk-ant-test").missing)

        XCTAssertEqual(LLMConnection(provider: .azure, model: "deployment", apiKey: "key").missing, .address)
        XCTAssertEqual(LLMConnection(provider: .azure, baseURL: "https://x.openai.azure.com", model: "deployment").missing, .apiKey)
        XCTAssertEqual(LLMConnection(provider: .azure, baseURL: "https://x.openai.azure.com", apiKey: "key").missing, .model)
        XCTAssertNil(LLMConnection(provider: .azure, baseURL: "https://x.openai.azure.com", model: "deployment", apiKey: "key").missing)

        XCTAssertEqual(LLMConnection(provider: .ollama).missing, .model, "a local server needs no key, but a model")
        XCTAssertNil(LLMConnection(provider: .ollama, model: "gemma4").missing)
        XCTAssertNil(LLMConnection(provider: .lmStudio, model: "anything").missing)

        XCTAssertEqual(LLMConnection(provider: .custom, model: "m").missing, .address)
        XCTAssertEqual(LLMConnection(provider: .custom, baseURL: "ftp://llm.example.com", model: "m").missing, .address)
        XCTAssertEqual(LLMConnection(provider: .custom, baseURL: "not an address", model: "m").missing, .address)
        XCTAssertEqual(LLMConnection(provider: .custom, baseURL: "https://", model: "m").missing, .address)
        XCTAssertNil(LLMConnection(provider: .custom, baseURL: "llm.example.com", model: "m").missing)
    }

    func testWhetherTheTextLeavesTheNetwork() {
        func isLocal(_ provider: LLMProvider, _ address: String? = nil) -> Bool {
            LLMConnection(provider: provider, baseURL: address).isLocal
        }
        XCTAssertTrue(isLocal(.ollama))
        XCTAssertTrue(isLocal(.lmStudio))
        XCTAssertFalse(isLocal(.openAI))
        XCTAssertFalse(isLocal(.anthropic))
        XCTAssertFalse(isLocal(.custom), "no address yet")
        // the address decides, not the kind of server
        XCTAssertFalse(isLocal(.ollama, "https://ollama.com/v1"))
        XCTAssertTrue(isLocal(.custom, "http://localhost:8080/v1"))
        XCTAssertFalse(isLocal(.custom, "https://llm.example.com/v1"))

        for host in ["localhost", "LOCALHOST", "127.0.0.1", "127.1.2.3", "0.0.0.0", "10.0.0.5", "192.168.178.20", "172.16.0.1",
                     "172.31.255.254", "169.254.10.10", "mac-mini", "mac-mini.local", "api.localhost", "[::1]", "[fe80::1]",
                     "[fd12:3456:789a::1]"] {
            XCTAssertTrue(isLocal(.custom, "http://\(host):8080/v1"), host)
        }
        for host in ["llm.example.com", "8.8.8.8", "172.15.0.1", "172.32.0.1", "192.169.1.1", "11.0.0.1", "1.2.3",
                     "localhost.example.com", "[2001:db8::1]", "256.1.1.1.1", "user@example.com"] {
            XCTAssertFalse(isLocal(.custom, "http://\(host):8080/v1"), host)
        }
        XCTAssertEqual(LLMConnection.host(of: "https://User:Secret@Example.com:8443/v1?x=1#y"), "example.com")
        XCTAssertEqual(LLMConnection.host(of: "http://[FE80::1]:1234/v1"), "fe80::1")
        XCTAssertEqual(LLMConnection.host(of: "localhost:1234"), "localhost")
        XCTAssertEqual(LLMConnection.host(of: ""), "")
        XCTAssertEqual(LLMConnection.host(of: "http://[::1"), "")
    }

    // MARK: Models

    func testModelListRequests() {
        let openAI = LLMWire.modelsRequest(LLMConnection(provider: .openAI, apiKey: "sk-test"))
        XCTAssertEqual(openAI, LLMHTTPRequest(method: "GET", url: "https://api.openai.com/v1/models",
                                              headers: [LLMHeader("Authorization", "Bearer sk-test")], body: nil))

        let anthropic = LLMWire.modelsRequest(LLMConnection(provider: .anthropic, apiKey: "sk-ant-test"))
        XCTAssertEqual(anthropic, LLMHTTPRequest(method: "GET", url: "https://api.anthropic.com/v1/models?limit=1000",
                                                 headers: [LLMHeader("x-api-key", "sk-ant-test"),
                                                           LLMHeader("anthropic-version", "2026-10-21")], body: nil))

        let expected: [(LLMProvider, String)] = [
            (.gemini, "https://generativelanguage.googleapis.com/v1beta/openai/models"),
            (.mistral, "https://api.mistral.ai/v1/models"),
            (.xAI, "https://api.x.ai/v1/models"),
            (.deepSeek, "https://api.deepseek.com/models"),
            (.groq, "https://api.groq.com/openai/v1/models"),
            (.openRouter, "https://openrouter.ai/api/v1/models"),
            (.ollama, "http://localhost:11434/v1/models"),
            (.lmStudio, "http://localhost:1234/v1/models"),
        ]
        for (provider, url) in expected {
            let request = LLMWire.modelsRequest(LLMConnection(provider: provider))
            XCTAssertEqual(request, LLMHTTPRequest(method: "GET", url: url, headers: [], body: nil), provider.id)
        }

        let azure = LLMWire.modelsRequest(LLMConnection(provider: .azure, baseURL: "https://x.openai.azure.com", apiKey: "key"))
        XCTAssertEqual(azure, LLMHTTPRequest(method: "GET", url: "https://x.openai.azure.com/openai/v1/models",
                                             headers: [LLMHeader("api-key", "key")], body: nil))
    }

    func testCapabilityRequest() {
        let connection = LLMConnection(provider: .anthropic, model: "claude-sonnet-5-5", apiKey: "sk-ant-test")
        XCTAssertEqual(LLMWire.capabilitiesRequest(connection),
                       LLMHTTPRequest(method: "GET", url: "https://api.anthropic.com/v1/models/claude-sonnet-5-5",
                                      headers: [LLMHeader("x-api-key", "sk-ant-test"),
                                                LLMHeader("anthropic-version", "2026-10-21"),
                                                LLMHeader("anthropic-beta", "server-side-fallback-2026-07-01")], body: nil))
        // for an organization that may not use the beta
        XCTAssertEqual(LLMWire.capabilitiesRequest(connection, fallbackBeta: false).headers.map(\.name),
                       ["x-api-key", "anthropic-version"])
        // a name the user typed must not change the path
        let odd = LLMConnection(provider: .anthropic, model: "my model/../x?y#z", apiKey: "k")
        XCTAssertEqual(LLMWire.capabilitiesRequest(odd).url, "https://api.anthropic.com/v1/models/my%20model%2F..%2Fx%3Fy%23z")
    }

    // MARK: Headers

    func testHeadersAreFoundWhateverTheirCase() {
        let headers = [LLMHeader("Content-Type", "application/json"), LLMHeader("Retry-After", "3")]
        XCTAssertEqual(LLMHeader.value(of: "retry-after", in: headers), "3")
        XCTAssertEqual(LLMHeader.value(of: "CONTENT-TYPE", in: headers), "application/json")
        XCTAssertNil(LLMHeader.value(of: "x-request-id", in: headers))
    }

    func testTheKeyStaysOutOfTheLog() {
        let connection = LLMConnection(provider: .openAI, apiKey: "sk-secret-123")
        XCTAssertEqual("\(connection)", "OpenAI gpt-6-luna at https://api.openai.com/v1")
        XCTAssertEqual("\(LLMConnection(provider: .custom))", "Custom (no model) at (no address)")
        for provider in [LLMProvider.openAI, .anthropic, .azure] {
            let other = LLMConnection(provider: provider, baseURL: "https://x.openai.azure.com", model: "m", apiKey: "sk-secret-123")
            let request = LLMWire.chatRequest(other, system: "S", user: "U")
            XCTAssertTrue(request.headers.contains { $0.value.contains("sk-secret-123") }, "the key is sent")
            XCTAssertFalse("\(request)".contains("sk-secret-123"), provider.id)
            XCTAssertFalse("\(request.headers)".contains("sk-secret-123"), provider.id)
            XCTAssertFalse(String(reflecting: other).contains("sk-secret-123"), provider.id)
        }
        XCTAssertEqual("\(LLMHeader("Content-Type", "application/json"))", "Content-Type: application/json")
        XCTAssertEqual("\(LLMHeader("X-API-Key", "secret"))", "X-API-Key: …")
    }

    func testHeadersOfAReply() {
        let fields: [AnyHashable: Any] = ["retry-after": "2", "Content-Type": "application/json", "x-count": 3]
        XCTAssertEqual(LLMHeader.list(fields), [LLMHeader("Content-Type", "application/json"),
                                                LLMHeader("retry-after", "2"), LLMHeader("x-count", "3")])
        XCTAssertEqual(LLMHeader.list([:]), [])
    }
}
