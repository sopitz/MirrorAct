// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import XCTest
@testable import MirrorAct

/// How the replies of the language model services are read (Foundation only, like the core).
/// The replies are written out the way the services document them.
final class LLMReplyTests: XCTestCase {
    private func openAI(_ body: String, status: Int = 200) throws -> String {
        try LLMWire.reply(format: .openAICompatible, status: status, body: Data(body.utf8))
    }

    private func anthropic(_ body: String, status: Int = 200) throws -> String {
        try LLMWire.reply(format: .anthropic, status: status, body: Data(body.utf8))
    }

    private func failure(_ body: () throws -> String) -> LLMError? {
        do {
            let text = try body()
            XCTFail("no error, but \(text)")
            return nil
        } catch {
            return error as? LLMError
        }
    }

    // MARK: OpenAI format

    func testOpenAIReply() throws {
        let text = try openAI(#"""
            {"id":"chatcmpl-CZ1","object":"chat.completion","created":1794400000,"model":"gpt-6-luna",
             "choices":[{"index":0,"message":{"role":"assistant","content":"[\"Einstellungen\",\"WLAN\"]","refusal":null},
                         "finish_reason":"stop"}],
             "usage":{"prompt_tokens":120,"completion_tokens":14,"total_tokens":134}}
            """#)
        XCTAssertEqual(text, #"["Einstellungen","WLAN"]"#)
    }

    func testWhiteSpaceAroundTheAnswerIsDropped() throws {
        XCTAssertEqual(try openAI(#"{"choices":[{"message":{"role":"assistant","content":"\n  [\"a\"]\n\n"},"finish_reason":"stop"}]}"#),
                       #"["a"]"#)
    }

    func testContentInPartsAsMistralSendsItWithReasoning() throws {
        let text = try openAI(#"""
            {"id":"cmpl-1","object":"chat.completion","model":"mistral-large-4",
             "choices":[{"index":0,"finish_reason":"stop","message":{"role":"assistant","content":[
                {"type":"thinking","thinking":[{"type":"text","text":"Two labels of a settings screen."}]},
                {"type":"text","text":"[\"Einstellungen\","},
                {"type":"text","text":"\"WLAN\"]"}]}}]}
            """#)
        XCTAssertEqual(text, #"["Einstellungen","WLAN"]"#)
    }

    func testReasoningBesideTheContentIsIgnored() throws {
        // DeepSeek: "reasoning_content"; Groq, OpenRouter, Ollama: "reasoning"
        XCTAssertEqual(try openAI(#"""
            {"choices":[{"index":0,"message":{"role":"assistant","content":"[\"Hallo\"]",
             "reasoning_content":"The user wants [\"Hello\"] in German."},"finish_reason":"stop"}]}
            """#), #"["Hallo"]"#)
        XCTAssertEqual(try openAI(#"""
            {"choices":[{"index":0,"message":{"role":"assistant","content":"[\"Hallo\"]","reasoning":"Short greeting."},
             "finish_reason":"stop","native_finish_reason":"stop"}]}
            """#), #"["Hallo"]"#)
    }

    func testThinkingInsideTheContentIsRemoved() throws {
        // Groq with "reasoning_format": "raw", and models on local servers
        XCTAssertEqual(try openAI(#"""
            {"choices":[{"message":{"role":"assistant","content":"<think>\nThe user wants a JSON array [like this].\n</think>\n\n[\"Hallo\"]"},
             "finish_reason":"stop"}]}
            """#), #"["Hallo"]"#)
        // the reply ended while the model was still thinking
        XCTAssertEqual(failure { try self.openAI(#"{"choices":[{"message":{"content":"<think>Let me see"},"finish_reason":"stop"}]}"#) },
                       .malformedReply("the reply contains no text"))
    }

    func testAnswersThatWereCutOff() {
        // also with text: half a list cannot be used
        XCTAssertEqual(failure { try self.openAI(#"{"choices":[{"message":{"content":"[\"Einstell"},"finish_reason":"length"}]}"#) },
                       .truncated)
        // a reasoning model can spend the whole limit on thinking
        XCTAssertEqual(failure { try self.openAI(#"{"choices":[{"message":{"content":""},"finish_reason":"length"}]}"#) },
                       .truncated)
        // Mistral: the model's own limit
        XCTAssertEqual(failure { try self.openAI(#"{"choices":[{"message":{"content":"[\"a\""},"finish_reason":"model_length"}]}"#) },
                       .truncated)
    }

    func testAnswersThatWereDeclined() {
        // OpenAI: the model says no in "refusal"
        XCTAssertEqual(failure { try self.openAI(#"""
            {"choices":[{"index":0,"message":{"role":"assistant","content":null,"refusal":"I can't help with that."},
             "finish_reason":"stop"}]}
            """#) }, .refused)
        // Azure: the answer was filtered and there is no content
        XCTAssertEqual(failure { try self.openAI(#"""
            {"choices":[{"index":0,"message":{"role":"assistant"},"finish_reason":"content_filter"}]}
            """#) }, .refused)
        // OpenRouter passes a refusal of Anthropic on like this
        XCTAssertEqual(failure { try self.openAI(#"""
            {"choices":[{"message":{"role":"assistant","content":"","refusal":"The model declined."},"finish_reason":"content_filter"}]}
            """#) }, .refused)
        // "refusal": null and "" are no refusal
        XCTAssertNoThrow(try openAI(#"{"choices":[{"message":{"content":"[\"a\"]","refusal":""},"finish_reason":"stop"}]}"#))
    }

    func testOtherEndingsOfAnAnswer() {
        // DeepSeek ran out of capacity while answering
        XCTAssertEqual(failure { try self.openAI(#"""
            {"choices":[{"message":{"content":"[\"a\""},"finish_reason":"insufficient_system_resource"}]}
            """#) }, .overloaded)
        // Mistral and OpenRouter: the model stopped with an error
        XCTAssertEqual(failure { try self.openAI(#"{"choices":[{"message":{"content":""},"finish_reason":"error"}]}"#) },
                       .server(status: 200, message: ""))
    }

    func testErrorsInsideAReplyWithStatus200() {
        // OpenRouter: the service behind it failed after the status had been sent
        XCTAssertEqual(failure { try self.openAI(#"""
            {"id":"gen-1","error":{"code":429,"message":"Rate limit exceeded",
             "metadata":{"error_type":"rate_limit_exceeded","provider_code":"rate_limited"}}}
            """#) }, .rateLimited(retryAfterSeconds: nil))
        XCTAssertEqual(failure { try self.openAI(#"""
            {"error":{"code":502,"message":"Provider returned error","metadata":{"error_type":"provider_unavailable"}}}
            """#) }, .overloaded)
        XCTAssertEqual(failure { try self.openAI(#"""
            {"error":{"code":500,"message":"Internal Server Error","metadata":{"error_type":"server"}}}
            """#) }, .server(status: 500, message: "Internal Server Error"))
        // … or after it had begun to answer
        XCTAssertEqual(failure { try self.openAI(#"""
            {"choices":[{"message":{"role":"assistant","content":"partial output..."},"finish_reason":"error",
             "error":{"code":502,"message":"Provider disconnected mid-stream","metadata":{"error_type":"provider_unavailable"}}}]}
            """#) }, .overloaded)
        XCTAssertEqual(failure { try self.openAI(#"""
            {"object":"chat.completion.chunk","error":{"code":403,"message":"Flagged","metadata":{"error_type":"content_policy_violation"}},
             "choices":[{"index":0,"delta":{"content":""},"finish_reason":"error"}]}
            """#) }, .refused)
        // "error": null is no error
        XCTAssertNoThrow(try openAI(#"{"error":null,"choices":[{"message":{"content":"[\"a\"]"},"finish_reason":"stop"}]}"#))
    }

    func testRepliesWithoutAnAnswer() {
        XCTAssertEqual(failure { try self.openAI(#"{"choices":[{"message":{"role":"assistant","content":""},"finish_reason":"stop"}]}"#) },
                       .malformedReply("the reply contains no text"))
        XCTAssertEqual(failure { try self.openAI(#"{"choices":[{"message":{"role":"assistant","content":null},"finish_reason":"stop"}]}"#) },
                       .malformedReply("the reply contains no text"))
        XCTAssertEqual(failure { try self.openAI(#"""
            {"choices":[{"message":{"content":[{"type":"thinking","thinking":[]}]},"finish_reason":"stop"}]}
            """#) }, .malformedReply("the reply contains no text"))
        XCTAssertEqual(failure { try self.openAI(#"{"choices":[]}"#) }, .malformedReply("the reply has no choices"))
        XCTAssertEqual(failure { try self.openAI(#"{"object":"list","data":[]}"#) }, .malformedReply("the reply has no choices"))
        XCTAssertEqual(failure { try self.openAI("<html><body>Welcome to nginx</body></html>") },
                       .malformedReply("the reply is not a JSON object"))
        XCTAssertEqual(failure { try self.openAI("") }, .malformedReply("the reply is not a JSON object"))
        XCTAssertEqual(failure { try self.openAI("[]") }, .malformedReply("the reply is not a JSON object"))
        XCTAssertEqual(failure { try self.openAI(#""text""#) }, .malformedReply("the reply is not a JSON object"))
    }

    func testAStatusThatIsNoSuccessIsAnErrorWhateverTheBodyLooksLike() {
        let good = #"{"choices":[{"message":{"content":"[\"a\"]"},"finish_reason":"stop"}]}"#
        XCTAssertEqual(failure { try self.openAI(good, status: 500) }, .server(status: 500, message: ""))
        XCTAssertEqual(failure { try self.openAI(good, status: 401) }, .invalidKey)
        XCTAssertEqual(failure { try self.openAI(good, status: 199) }, .server(status: 199, message: ""))
        XCTAssertNoThrow(try openAI(good, status: 201))
    }

    func testRetryHeaderOfAReplyReachesTheError() {
        let error = failure {
            try LLMWire.reply(format: .openAICompatible, status: 429, headers: [LLMHeader("Retry-After", "20")],
                              body: Data(#"{"error":{"message":"Rate limit reached","type":"requests","code":"rate_limit_exceeded"}}"#.utf8))
        }
        XCTAssertEqual(error, .rateLimited(retryAfterSeconds: 20))
    }

    // MARK: Anthropic

    func testAnthropicReply() throws {
        let text = try anthropic(#"""
            {"id":"msg_01XFDUDYJgAACzvnptvVoYEL","type":"message","role":"assistant","model":"claude-opus-5-5",
             "content":[{"type":"thinking","thinking":"","signature":"EuYBCkQYAiJA"},
                        {"type":"text","text":"[\"Einstellungen\",\"WLAN\"]"}],
             "stop_reason":"end_turn","stop_sequence":null,"stop_details":null,
             "usage":{"input_tokens":212,"output_tokens":31}}
            """#)
        XCTAssertEqual(text, #"["Einstellungen","WLAN"]"#)
    }

    func testAnthropicTextBlocksAreJoined() throws {
        XCTAssertEqual(try anthropic(#"""
            {"type":"message","content":[{"type":"text","text":"[\"a\","},{"type":"text","text":"\"b\"]"}],"stop_reason":"end_turn"}
            """#), #"["a","b"]"#)
    }

    func testAnthropicReplyOfAFallbackModel() throws {
        // the block that marks the change of model comes before the text
        let text = try anthropic(#"""
            {"id":"msg_02","type":"message","role":"assistant","model":"claude-opus-4-8",
             "content":[{"type":"fallback","from":{"model":"claude-opus-5-5"},"to":{"model":"claude-opus-4-8"},"trigger":{}},
                        {"type":"text","text":"[\"Hallo\"]"}],
             "stop_reason":"end_turn"}
            """#)
        XCTAssertEqual(text, #"["Hallo"]"#)
    }

    func testAnthropicRefusalIsReadBeforeTheContent() {
        XCTAssertEqual(failure { try self.anthropic(#"""
            {"id":"msg_03","type":"message","role":"assistant","model":"claude-opus-5-5","content":[],
             "stop_reason":"refusal","stop_details":{"type":"refusal","category":"cyber","explanation":"Declined."}}
            """#) }, .refused)
        // a refusal in the middle of an answer leaves text behind that must not be used
        XCTAssertEqual(failure { try self.anthropic(#"""
            {"type":"message","content":[{"type":"text","text":"[\"Ha"}],"stop_reason":"refusal",
             "stop_details":{"type":"refusal","category":null,"explanation":null}}
            """#) }, .refused)
    }

    func testAnthropicAnswersThatWereCutOff() {
        XCTAssertEqual(failure { try self.anthropic(#"""
            {"type":"message","content":[{"type":"text","text":"[\"Einstell"}],"stop_reason":"max_tokens"}
            """#) }, .truncated)
        XCTAssertEqual(failure { try self.anthropic(#"""
            {"type":"message","content":[],"stop_reason":"model_context_window_exceeded"}
            """#) }, .truncated)
    }

    func testAnthropicRepliesWithoutAnAnswer() {
        XCTAssertEqual(failure { try self.anthropic(#"{"type":"message","content":[],"stop_reason":"end_turn"}"#) },
                       .malformedReply("the reply contains no text"))
        XCTAssertEqual(failure { try self.anthropic(#"""
            {"type":"message","content":[{"type":"thinking","thinking":"x"}],"stop_reason":"end_turn"}
            """#) }, .malformedReply("the reply contains no text"))
        XCTAssertEqual(failure { try self.anthropic(#"{"type":"message","stop_reason":"end_turn"}"#) },
                       .malformedReply("the reply has no content"))
        XCTAssertEqual(failure { try self.anthropic(#"{"type":"message","content":"text","stop_reason":"end_turn"}"#) },
                       .malformedReply("the reply has no content"))
        XCTAssertEqual(failure { try self.anthropic("not json") }, .malformedReply("the reply is not a JSON object"))
    }

    func testAnthropicErrorWithStatus200() {
        XCTAssertEqual(failure { try self.anthropic(#"""
            {"type":"error","error":{"type":"overloaded_error","message":"Overloaded"},"request_id":"req_1"}
            """#) }, .overloaded)
        XCTAssertEqual(failure { try self.anthropic(#"{"type":"error","error":{"type":"api_error","message":"Internal server error"}}"#) },
                       .server(status: 200, message: "Internal server error"))
    }

    // MARK: Thinking in the text

    func testThinkingAtTheBeginningIsRemoved() {
        XCTAssertEqual(LLMText.withoutThinking("<think>one</think>[\"a\"]"), #"["a"]"#)
        XCTAssertEqual(LLMText.withoutThinking("  <THINK>\none\n</Think>\n\n<think>two</think>\n[\"a\"]  "), #"["a"]"#)
        XCTAssertEqual(LLMText.withoutThinking("<think>never ends"), "")
        XCTAssertEqual(LLMText.withoutThinking("<think></think>"), "")
        XCTAssertEqual(LLMText.withoutThinking("no tags at all"), "no tags at all")
        XCTAssertEqual(LLMText.withoutThinking(""), "")
        // some servers swallow the opening tag
        XCTAssertEqual(LLMText.withoutThinking("The user wants [x].\n</think>\n[\"a\"]"), #"["a"]"#)
    }

    func testTagsInsideTheAnswerStay() {
        // a screen can show these very characters
        XCTAssertEqual(LLMText.withoutThinking(#"["<think>","</think>"]"#), #"["<think>","</think>"]"#)
        XCTAssertEqual(LLMText.withoutThinking(#"["</think> is a tag"]"#), #"["</think> is a tag"]"#)
        XCTAssertEqual(LLMText.withoutThinking(#"{"translations":["</think>"]}"#), #"{"translations":["</think>"]}"#)
        XCTAssertEqual(LLMText.withoutThinking(#"<think>a</think>["<think>b</think>"]"#), #"["<think>b</think>"]"#)
    }

    // MARK: No input may crash

    /// one reply of every kind, to be taken apart
    private static let samples = [
        #"{"choices":[{"index":0,"message":{"role":"assistant","content":"[\"Einstellungen\",\"WLAN\"]","refusal":null},"#
            + #""finish_reason":"stop"}],"usage":{"total_tokens":134}}"#,
        #"{"choices":[{"finish_reason":"stop","message":{"content":[{"type":"thinking","thinking":[{"type":"text","text":"x"}]},"#
            + #"{"type":"text","text":"[\"a\"]"}]}}]}"#,
        #"{"type":"message","content":[{"type":"thinking","thinking":""},{"type":"text","text":"[\"a\",\"b\"]"}],"#
            + #""stop_reason":"end_turn","stop_details":null}"#,
        #"{"type":"error","error":{"type":"rate_limit_error","message":"Slow down","#
            + #""details":{"error_code":"enforced_spend_limit_reached"}},"request_id":"req_1"}"#,
        #"[{"error":{"code":400,"message":"API key not valid.","status":"INVALID_ARGUMENT","#
            + #""details":[{"reason":"API_KEY_INVALID","metadata":{"service":"x"}}]}}]"#,
        #"{"error":{"code":403,"message":"Flagged","metadata":{"reasons":["x"],"flagged_input":"y","error_type":"refusal","#
            + #""limit_source":"openrouter_key_limit"}}}"#,
        #"{"detail":[{"loc":["body","reasoning_effort"],"msg":"Input should be 'high' or 'none'","type":"enum"}]}"#,
        #"{"object":"list","data":[{"id":"mistral-small-latest","capabilities":{"completion_chat":true}},"#
            + #"{"id":"models/gemini-3.8-flash","architecture":{"output_modalities":["text"]},"active":true,"lifecycle":"active","#
            + #""type":"model","image_price":null}]}"#,
        #"{"id":"claude-opus-5-5","allowed_fallback_models":["claude-opus-4-8"],"#
            + #""capabilities":{"effort":{"supported":true,"low":{"supported":true}}}}"#,
    ]

    /// Every reader with one input: nothing may crash, and whatever is thrown is an `LLMError`
    private func readEverything(_ body: Data, status: Int) {
        let headers = [LLMHeader("retry-after", String(decoding: body.prefix(12), as: UTF8.self))]
        let readers: [() throws -> Void] = [
            { _ = try LLMWire.reply(format: .openAICompatible, status: status, headers: headers, body: body) },
            { _ = try LLMWire.reply(format: .anthropic, status: status, headers: headers, body: body) },
            { _ = try LLMWire.modelIDs(provider: .openAI, status: status, headers: headers, body: body) },
            { _ = try LLMWire.capabilities(status: status, headers: headers, body: body) },
            { _ = try TranslationPrompt.parse(String(decoding: body, as: UTF8.self), count: 2) },
        ]
        for reader in readers {
            do {
                try reader()
            } catch {
                XCTAssertTrue(error is LLMError, "\(error)")
            }
        }
        let error = LLMError.from(status: status, headers: headers, body: body)
        XCTAssertLessThanOrEqual(LLMError.message(in: body).count, 200)
        if case .badRequest(let message) = error {
            XCTAssertLessThanOrEqual(message.count, 200)
            XCTAssertFalse(message.contains("\n"))
        }
        _ = LLMText.withoutThinking(String(decoding: body, as: UTF8.self))
    }

    func testRepliesCutOffAnywhere() {
        for sample in Self.samples {
            let bytes = Array(sample.utf8)
            for length in 0...bytes.count {
                readEverything(Data(bytes[0..<length]), status: length % 2 == 0 ? 200 : 400)
            }
        }
    }

    func testRepliesWithDamagedBytes() {
        var dice = Dice(state: 20261111)
        let statuses = [200, 200, 400, 401, 403, 404, 429, 500, 529]
        let junk = Array("}]</think>\\\"[{<think>".utf8)
        for round in 0..<600 {
            var bytes = Array(Self.samples[round % Self.samples.count].utf8)
            for _ in 0...dice.roll(4) {
                let position = dice.roll(bytes.count)
                switch dice.roll(4) {
                case 0: bytes[position] = UInt8(dice.roll(256))
                case 1: bytes.remove(at: position)
                case 2: bytes.insert(contentsOf: junk[dice.roll(junk.count)...], at: position)
                default: bytes.insert(UInt8(dice.roll(256)), at: position)
                }
                if bytes.isEmpty { bytes = [0x7B] }
            }
            readEverything(Data(bytes), status: statuses[dice.roll(statuses.count)])
        }
    }

    /// All copies of `value` in which one part is replaced by something of another type
    private func withOnePartReplaced(_ value: Any) -> [Any] {
        let replacements: [Any] = [NSNull(), 0, 1.5, true, "x", "", [Any](), [String: Any](), [[Any]()], ["a": [String: Any]()]]
        var results = replacements
        if let object = value as? [String: Any] {
            for key in object.keys.sorted() {
                guard let part = object[key] else { continue }
                for changed in withOnePartReplaced(part) {
                    var copy = object
                    copy[key] = changed
                    results.append(copy)
                }
                var without = object
                without[key] = nil
                results.append(without)
            }
        } else if let list = value as? [Any] {
            for index in list.indices {
                for changed in withOnePartReplaced(list[index]) {
                    var copy = list
                    copy[index] = changed
                    results.append(copy)
                }
            }
        }
        return results
    }

    func testRepliesWithValuesOfTheWrongType() throws {
        var count = 0
        for sample in Self.samples {
            let value = try JSONSerialization.jsonObject(with: Data(sample.utf8), options: [.fragmentsAllowed])
            for changed in withOnePartReplaced(value) {
                guard JSONSerialization.isValidJSONObject(changed) else { continue }
                let body = try JSONSerialization.data(withJSONObject: changed)
                for status in [200, 400] {
                    readEverything(body, status: status)
                }
                count += 1
            }
        }
        XCTAssertGreaterThan(count, 1000, "the samples are taken apart")
    }

    func testHugeAndDeepReplies() {
        // hundreds of kilobytes, where real replies have a few
        let long = String(repeating: "Lorem ipsum [dolor] \"sit\" <think> amet {\\} ", count: 5_000)
        let escaped = long.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let answer = #"{"choices":[{"message":{"content":""# + escaped + #""},"finish_reason":"stop"}]}"#
        let rejection = #"{"error":{"message":""# + escaped + #"","type":"invalid_request_error"}}"#
        let list = #"{"data":["# + (0..<5_000).map { #"{"id":"model-\#($0)"}"# }.joined(separator: ",") + "]}"
        let bodies = [
            long, answer, rejection, list,
            #"{"type":"message","content":[{"type":"text","text":""# + escaped + #""}],"stop_reason":"end_turn"}"#,
            "<html><head><title>" + long + "</title></head></html>",
            String(repeating: "[", count: 100_000),
            String(repeating: "[", count: 5_000) + String(repeating: "]", count: 5_000),
            String(repeating: "{\"error\":", count: 5_000) + "1" + String(repeating: "}", count: 5_000),
            String(repeating: "[\"a\",", count: 30_000),
            String(repeating: "<think>", count: 10_000) + String(repeating: "</think>", count: 10_000),
            String(repeating: "<think></think>", count: 10_000) + "[\"a\",\"b\"]",
            String(repeating: "\"", count: 30_001) + "[",
        ]
        for body in bodies {
            readEverything(Data(body.utf8), status: 200)
            _ = LLMError.from(status: 400, headers: [], body: Data(body.utf8))
        }
        // what is long stays long where it is the answer, and gets short where it is a message
        let text = try? LLMWire.reply(format: .openAICompatible, status: 200, body: Data(answer.utf8))
        XCTAssertEqual(text, long.trimmingCharacters(in: .whitespaces))
        guard case .badRequest(let message) = LLMError.from(status: 400, headers: [], body: Data(rejection.utf8)) else {
            XCTFail("a rejected request")
            return
        }
        XCTAssertEqual(message.count, 200)
        XCTAssertTrue(message.hasPrefix("Lorem ipsum [dolor] \"sit\" <think> amet {\\} Lorem"))
        XCTAssertTrue(message.hasSuffix("…"))
        let ids = try? LLMWire.modelIDs(provider: .custom, status: 200, body: Data(list.utf8))
        XCTAssertEqual(ids?.count, 5_000)
        XCTAssertEqual(ids?.first, "model-0")
    }
}

/// Numbers that look random and are the same in every run
private struct Dice {
    var state: UInt64

    /// 0 ..< sides
    mutating func roll(_ sides: Int) -> Int {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return Int((state >> 33) % UInt64(max(1, sides)))
    }
}
