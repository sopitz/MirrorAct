// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import XCTest
@testable import MirrorAct

/// Stands in for the network: answers the requests of an engine the way a test wants it and
/// keeps what was asked
private final class ScriptedTransport: LLMTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var sent: [LLMHTTPRequest] = []
    private let answer: (LLMHTTPRequest, Int) async throws -> LLMHTTPReply

    /// `answer` gets each request and its number, counted from 0
    init(_ answer: @escaping (LLMHTTPRequest, Int) async throws -> LLMHTTPReply) {
        self.answer = answer
    }

    var requests: [LLMHTTPRequest] {
        lock.lock()
        defer { lock.unlock() }
        return sent
    }

    func send(_ request: LLMHTTPRequest) async throws -> LLMHTTPReply {
        try await answer(request, record(request))
    }

    private func record(_ request: LLMHTTPRequest) -> Int {
        lock.lock()
        defer { lock.unlock() }
        sent.append(request)
        return sent.count - 1
    }
}

/// Collects what a test is told from other threads
private final class Collected<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Value] = []

    var all: [Value] {
        lock.lock()
        defer { lock.unlock() }
        return values
    }

    func add(_ value: Value) {
        lock.lock()
        values.append(value)
        lock.unlock()
    }
}

/// The body of a request, read as JSON
private func sentJSON(_ request: LLMHTTPRequest) -> [String: Any] {
    guard let body = request.body, let object = try? JSONSerialization.jsonObject(with: body) else { return [:] }
    return object as? [String: Any] ?? [:]
}

/// The texts a chat request asks to translate
private func sentTexts(_ request: LLMHTTPRequest) -> [String] {
    let messages = sentJSON(request)["messages"] as? [[String: Any]] ?? []
    guard let content = messages.last?["content"] as? String,
          let list = try? JSONSerialization.jsonObject(with: Data(content.utf8)) else { return [] }
    return list as? [String] ?? []
}

/// What a model answers when it does as it was told: a JSON array of the translations
private func translated(_ request: LLMHTTPRequest) -> String {
    TranslationPrompt.user(sentTexts(request).map { "de:" + $0 })
}

private func reply(_ status: Int, _ body: String, headers: [LLMHeader] = []) -> LLMHTTPReply {
    (status, headers, Data(body.utf8))
}

private func jsonReply(_ body: [String: Any]) -> LLMHTTPReply {
    (200, [LLMHeader("Content-Type", "application/json")], (try? JSONSerialization.data(withJSONObject: body)) ?? Data())
}

/// A reply in the OpenAI format with `content` as the answer of the model
private func openAIReply(_ content: String) -> LLMHTTPReply {
    jsonReply(["id": "chatcmpl-1", "object": "chat.completion",
               "choices": [["index": 0, "message": ["role": "assistant", "content": content], "finish_reason": "stop"]]])
}

/// A reply of Anthropic with `content` as the answer of the model
private func anthropicReply(_ content: String, model: String = "claude-opus-5-5", fallbackFrom declined: String? = nil) -> LLMHTTPReply {
    var blocks: [[String: Any]] = []
    if let declined {
        blocks.append(["type": "fallback", "from": ["model": declined], "to": ["model": model], "trigger": [String: Any]()])
    }
    blocks.append(["type": "text", "text": content])
    return jsonReply(["id": "msg_1", "type": "message", "role": "assistant", "model": model, "content": blocks,
                      "stop_reason": "end_turn"])
}

/// What Anthropic says about a model
private func capabilitiesReply(effortLow: Bool, fallbackModels: [String] = []) -> LLMHTTPReply {
    jsonReply(["id": "claude-opus-5-5", "type": "model", "allowed_fallback_models": fallbackModels,
               "capabilities": ["effort": ["supported": effortLow, "low": ["supported": effortLow]]]])
}

private let rateLimited = #"{"error":{"message":"Rate limit reached for requests","type":"requests","param":null,"code":"rate_limit_exceeded"}}"#

/// Translating through a language model service, with a script in place of the network: what is
/// sent in which order, and what becomes of the answers and failures of a service.
final class LLMTranslationEngineTests: XCTestCase {
    private let german = Locale.Language(identifier: "de")

    /// Mistral unless a test says otherwise: its requests carry no extra fields
    private func makeEngine(_ provider: LLMProvider = .mistral, baseURL: String? = nil, model: String? = nil,
                            transport: ScriptedTransport) -> LLMTranslationEngine {
        let connection = LLMConnection(provider: provider, baseURL: baseURL, model: model, apiKey: "sk-test-key")
        let engine = LLMTranslationEngine(connection: connection, transport: transport)
        // no test waits for a service
        engine.pause = { _ in }
        return engine
    }

    private func failure(of work: () async throws -> [String?]) async -> TranslationFailure? {
        do {
            let translations = try await work()
            XCTFail("no failure, but \(translations)")
            return nil
        } catch {
            XCTAssertTrue(error is TranslationFailure, "\(error)")
            return error as? TranslationFailure
        }
    }

    // MARK: Requests and answers

    func testOneRequestTranslatesTheTextsOfAScreen() async throws {
        let transport = ScriptedTransport { request, _ in openAIReply(translated(request)) }
        let engine = makeEngine(transport: transport)
        let translations = try await engine.translate(["Settings", "Wi-Fi \"Home\"", "General"], into: german)
        XCTAssertEqual(translations, ["de:Settings", "de:Wi-Fi \"Home\"", "de:General"])

        let requests = transport.requests
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests.first?.method, "POST")
        XCTAssertEqual(requests.first?.url, "https://api.mistral.ai/v1/chat/completions")
        XCTAssertEqual(LLMHeader.value(of: "Authorization", in: requests.first?.headers ?? []), "Bearer sk-test-key")
        // the model is told the language by its English name and its code
        let messages = sentJSON(requests[0])["messages"] as? [[String: Any]] ?? []
        XCTAssertEqual(messages.first?["content"] as? String, TranslationPrompt.system(targetName: "German", targetCode: "de"))
        XCTAssertEqual(sentTexts(requests[0]), ["Settings", "Wi-Fi \"Home\"", "General"])
        XCTAssertEqual(sentJSON(requests[0])["model"] as? String, "mistral-small-latest")
    }

    func testNoTextsNoRequest() async throws {
        let transport = ScriptedTransport { request, _ in openAIReply(translated(request)) }
        let translations = try await makeEngine(transport: transport).translate([], into: german)
        XCTAssertTrue(translations.isEmpty)
        XCTAssertTrue(transport.requests.isEmpty)
    }

    func testTheOrderIsKeptAcrossTwoRequests() async throws {
        let texts = (1...50).map { "Text \($0)" }
        let transport = ScriptedTransport { request, _ in openAIReply(translated(request)) }
        let translations = try await makeEngine(transport: transport).translate(texts, into: german)
        XCTAssertEqual(translations, texts.map { "de:" + $0 })
        // forty texts travel in one request, the rest in the next one
        XCTAssertEqual(transport.requests.map { sentTexts($0) }, [Array(texts[..<40]), Array(texts[40...])])
    }

    func testAnEmptyTranslationMeansLeaveItAsItIs() async throws {
        let transport = ScriptedTransport { _, _ in openAIReply(#"["Einstellungen", "  ", " WLAN "]"#) }
        let translations = try await makeEngine(transport: transport).translate(["Settings", "12:30", "Wi-Fi"], into: german)
        XCTAssertEqual(translations, ["Einstellungen", "12:30", "WLAN"])
    }

    func testTheLanguageIsNamedInEnglishWithItsCode() {
        XCTAssertEqual(LLMTranslationEngine.instruction(for: Locale.Language(identifier: "de")),
                       TranslationPrompt.system(targetName: "German", targetCode: "de"))
        // the region stays where it tells two kinds of a language apart
        let taiwan = LLMTranslationEngine.instruction(for: Locale.Language(identifier: "zh-TW"))
        XCTAssertTrue(taiwan.contains("(zh-TW)"), taiwan)
        XCTAssertTrue(taiwan.contains("Chinese"), taiwan)
    }

    // MARK: Answers that cannot be used

    func testAnAnswerWithTheWrongNumberOfItemsIsAskedForAgainInTwoHalves() async throws {
        let transport = ScriptedTransport { request, number in
            // the first answer has merged two of the texts
            if number == 0 { return openAIReply(#"["a", "b", "c", "d"]"#) }
            return openAIReply(translated(request))
        }
        let texts = ["one", "two", "three", "four", "five"]
        let translations = try await makeEngine(transport: transport).translate(texts, into: german)
        XCTAssertEqual(translations, ["de:one", "de:two", "de:three", "de:four", "de:five"])
        XCTAssertEqual(transport.requests.map { sentTexts($0) }, [texts, ["one", "two", "three"], ["four", "five"]])
    }

    func testASingleTextThatStillFailsStaysAsItIs() async throws {
        let transport = ScriptedTransport { request, _ in
            // whatever contains "two" is answered with a sentence instead of a list
            if sentTexts(request).contains("two") { return openAIReply("Sorry, I cannot do that.") }
            return openAIReply(translated(request))
        }
        let translations = try await makeEngine(transport: transport).translate(["one", "two", "three"], into: german)
        XCTAssertEqual(translations, ["de:one", "two", "de:three"])
        XCTAssertEqual(transport.requests.map { sentTexts($0) },
                       [["one", "two", "three"], ["one", "two"], ["one"], ["two"], ["three"]])
    }

    func testAnAnswerThatWasCutOffIsAskedForAgainInTwoHalves() async throws {
        let transport = ScriptedTransport { request, _ in
            if sentTexts(request).count > 2 {
                return reply(200, #"{"choices":[{"message":{"content":"[\"de:o"},"finish_reason":"length"}]}"#)
            }
            return openAIReply(translated(request))
        }
        let translations = try await makeEngine(transport: transport).translate(["one", "two", "three", "four"], into: german)
        XCTAssertEqual(translations, ["de:one", "de:two", "de:three", "de:four"])
        XCTAssertEqual(transport.requests.count, 3)
    }

    func testARequestThatTimesOutIsAskedForAgainInTwoHalves() async throws {
        let texts = (1...25).map { "Text \($0)" }
        // a slow model: more than ten texts take longer than a request may wait
        let transport = ScriptedTransport { request, _ in
            if sentTexts(request).count > 10 { throw URLError(.timedOut) }
            return openAIReply(translated(request))
        }
        let engine = makeEngine(transport: transport)
        let translations = try await engine.translate(texts, into: german)
        XCTAssertEqual(translations, texts.map { Optional("de:" + $0) })
        XCTAssertEqual(transport.requests.map { sentTexts($0).count }, [25, 13, 7, 6, 12, 6, 6])
    }

    func testASingleTextThatTimesOutIsAskedForLater() async {
        let transport = ScriptedTransport { _, _ in throw URLError(.timedOut) }
        let engine = makeEngine(transport: transport)
        let failure = await failure { try await engine.translate(["Settings", "General"], into: self.german) }
        // not left as it is: the next time the model may be quicker
        XCTAssertEqual(failure?.isPermanent, false)
        XCTAssertEqual(transport.requests.map { sentTexts($0) }, [["Settings", "General"], ["Settings"]])
    }

    func testAServerOnThisMacOrInTheNetworkHasMoreTimeToAnswer() {
        let local = LLMTranslationEngine.timeout(for: LLMConnection(provider: .ollama, baseURL: "192.168.1.20:11434", model: "m"))
        let remote = LLMTranslationEngine.timeout(for: LLMConnection(provider: .openAI, apiKey: "k"))
        XCTAssertEqual(remote, LLMTranslationEngine.requestTimeout)
        XCTAssertEqual(local, LLMTranslationEngine.localRequestTimeout)
        XCTAssertGreaterThan(local, remote)
    }

    func testATextTheModelDeclinesStaysAsItIsAndTheUserIsToldOnce() async throws {
        let transport = ScriptedTransport { request, _ in
            if sentTexts(request).contains("two") {
                return reply(200, #"{"choices":[{"message":{"role":"assistant","content":null,"refusal":"I can't help with that."},"finish_reason":"stop"}]}"#)
            }
            return openAIReply(translated(request))
        }
        let engine = makeEngine(.openAI, transport: transport)
        let notices = Collected<String>()
        engine.notify = { notices.add($0) }
        let first = try await engine.translate(["one", "two"], into: german)
        XCTAssertEqual(first, ["de:one", "two"])
        let second = try await engine.translate(["two"], into: german)
        XCTAssertEqual(second, ["two"])
        XCTAssertEqual(notices.all, ["OpenAI: " + String(localized: "the model declined to translate this text")])
    }

    func testAModelThatNeverAnswersUsablyIsGivenUp() async {
        let transport = ScriptedTransport { _, _ in openAIReply("Here are your translations!") }
        let engine = makeEngine(.ollama, model: "tiny", transport: transport)
        let texts = (1...40).map { "Text \($0)" }
        let failure = await failure { try await engine.translate(texts, into: self.german) }
        // translating ends: asking on would cost request after request
        XCTAssertEqual(failure?.isPermanent, true)
        XCTAssertEqual(failure?.message, "Ollama: "
                       + String(localized: "the model’s answer cannot be used – choose another model in the settings"))
        XCTAssertEqual(transport.requests.count, LLMTranslationEngine.patience)
    }

    func testAModelThatHasAnsweredUsablyIsNotGivenUp() async throws {
        let transport = ScriptedTransport { request, number in
            if number == 0 { return openAIReply(translated(request)) }
            return openAIReply("Here are your translations!")
        }
        let engine = makeEngine(transport: transport)
        let first = try await engine.translate(["Settings"], into: german)
        XCTAssertEqual(first, ["de:Settings"])
        // from here on nothing usable: every text is asked for down to itself and stays as it is
        let texts = (1...16).map { "Text \($0)" }
        let second = try await engine.translate(texts, into: german)
        XCTAssertEqual(second, texts)
        XCTAssertEqual(transport.requests.count, 1 + 31)
    }

    // MARK: Failures of the service

    func testAWrongKeyEndsTranslatingWithANoticeThatNamesTheService() async {
        let transport = ScriptedTransport { _, _ in
            reply(401, #"{"error":{"message":"Incorrect API key provided: sk-test-****.","type":"invalid_request_error","param":null,"code":"invalid_api_key"}}"#)
        }
        let engine = makeEngine(.openAI, transport: transport)
        let failure = await failure { try await engine.translate(["Settings"], into: self.german) }
        XCTAssertEqual(failure?.isPermanent, true)
        XCTAssertEqual(failure?.message, "OpenAI: " + String(localized: "the API key was not accepted"))
        XCTAssertEqual(failure?.message.contains("sk-test"), false)
        // asked once: neither another try nor a request without the extra fields helps here
        XCTAssertEqual(transport.requests.count, 1)
    }

    func testAnUnknownModelIsNamedInTheNotice() async {
        let transport = ScriptedTransport { _, _ in
            reply(404, #"{"error":{"message":"The model `gpt-nope` does not exist or you do not have access to it.","type":"invalid_request_error","param":null,"code":"model_not_found"}}"#)
        }
        let engine = makeEngine(.openAI, model: "gpt-nope", transport: transport)
        let failure = await failure { try await engine.translate(["Settings"], into: self.german) }
        XCTAssertEqual(failure?.isPermanent, true)
        XCTAssertEqual(failure?.message, "OpenAI: "
                       + String(localized: "the model \("gpt-nope") is not available – choose another one in the settings"))
    }

    func testARejectedExtraFieldIsLeftOutFromThenOn() async throws {
        let transport = ScriptedTransport { request, _ in
            if sentJSON(request)["reasoning_effort"] != nil {
                return reply(400, #"{"error":{"message":"Unsupported value: 'reasoning_effort' does not support 'low' with this model.","type":"invalid_request_error","param":"reasoning_effort","code":"unsupported_value"}}"#)
            }
            return openAIReply(translated(request))
        }
        let engine = makeEngine(.openAI, transport: transport)
        let first = try await engine.translate(["Settings"], into: german)
        XCTAssertEqual(first, ["de:Settings"])
        let second = try await engine.translate(["General"], into: german)
        XCTAssertEqual(second, ["de:General"])
        // sent with the field once, then again without it, and without it ever after
        XCTAssertEqual(transport.requests.map { sentJSON($0)["reasoning_effort"] as? String }, ["low", nil, nil])
        XCTAssertEqual(transport.requests.map { sentTexts($0) }, [["Settings"], ["Settings"], ["General"]])
    }

    func testARequestWithoutExtraFieldsThatIsRejectedFails() async {
        let transport = ScriptedTransport { _, _ in
            reply(422, #"{"detail":[{"type":"missing","loc":["body","messages"],"msg":"Field required"}]}"#)
        }
        let engine = makeEngine(transport: transport)
        let failure = await failure { try await engine.translate(["Settings"], into: self.german) }
        XCTAssertEqual(failure?.isPermanent, false)
        XCTAssertEqual(failure?.message, "Mistral: " + String(localized: "the request was rejected (\("messages: Field required"))"))
        XCTAssertEqual(transport.requests.count, 1)
    }

    func testABusyServiceIsAskedOnceMoreAfterTheTimeItNames() async throws {
        let transport = ScriptedTransport { request, number in
            if number == 0 { return reply(429, rateLimited, headers: [LLMHeader("Retry-After", "1")]) }
            return openAIReply(translated(request))
        }
        let engine = makeEngine(transport: transport)
        let waits = Collected<TimeInterval>()
        engine.pause = { waits.add($0) }
        let translations = try await engine.translate(["Settings"], into: german)
        XCTAssertEqual(translations, ["de:Settings"])
        XCTAssertEqual(waits.all, [1])
        XCTAssertEqual(transport.requests.count, 2)
    }

    func testAServiceThatStaysBusyFailsAfterOneMoreTry() async {
        let transport = ScriptedTransport { _, _ in reply(503, #"{"error":{"message":"The model is overloaded.","code":"server_is_overloaded"}}"#) }
        let engine = makeEngine(transport: transport)
        let waits = Collected<TimeInterval>()
        engine.pause = { waits.add($0) }
        let failure = await failure { try await engine.translate(["Settings"], into: self.german) }
        XCTAssertEqual(failure?.isPermanent, false)
        XCTAssertEqual(failure?.message, "Mistral: " + String(localized: "the service is busy right now"))
        // no time was named: the short wait of the engine
        XCTAssertEqual(waits.all, [LLMTranslationEngine.retryWait])
        XCTAssertEqual(transport.requests.count, 2)
    }

    func testALongWaitIsNotSatOut() async {
        let transport = ScriptedTransport { _, _ in reply(429, rateLimited, headers: [LLMHeader("Retry-After", "20")]) }
        let engine = makeEngine(transport: transport)
        let waits = Collected<TimeInterval>()
        engine.pause = { waits.add($0) }
        let failure = await failure { try await engine.translate(["Settings"], into: self.german) }
        XCTAssertEqual(failure?.isPermanent, false)
        XCTAssertEqual(failure?.message, "Mistral: " + String(localized: "too many requests right now"))
        XCTAssertTrue(waits.all.isEmpty)
        XCTAssertEqual(transport.requests.count, 1)
    }

    func testALongWaitTheServiceAsksForIsKeptWithoutARequest() async throws {
        let transport = ScriptedTransport { request, number in
            if number == 0 { return reply(429, rateLimited, headers: [LLMHeader("Retry-After", "60")]) }
            return openAIReply(translated(request))
        }
        let engine = makeEngine(transport: transport)
        var clock: TimeInterval = 1000
        engine.now = { clock }
        let failure = await failure { try await engine.translate(["Settings"], into: self.german) }
        // the caller is told when to come back
        XCTAssertEqual(failure?.retryAfter, 60)

        // asked again before then: "not now", and the service hears nothing of it
        clock += 30
        let early = try await engine.translate(["Settings"], into: german)
        XCTAssertEqual(early, [nil])
        XCTAssertEqual(transport.requests.count, 1)

        clock += 31
        let later = try await engine.translate(["Settings"], into: german)
        XCTAssertEqual(later, ["de:Settings"])
        XCTAssertEqual(transport.requests.count, 2)
    }

    func testAServiceThatKeepsFailingIsAskedLessAndLessOften() async throws {
        var failing = true
        let transport = ScriptedTransport { request, _ in
            failing ? reply(500, #"{"error":{"message":"Internal server error","type":"server_error"}}"#)
                : openAIReply(translated(request))
        }
        let engine = makeEngine(transport: transport)
        var clock: TimeInterval = 1000
        engine.now = { clock }
        var waits: [TimeInterval?] = []
        for _ in 0..<7 {
            let failure = await failure { try await engine.translate(["Settings"], into: self.german) }
            waits.append(failure?.retryAfter)
            clock += failure?.retryAfter ?? 0
        }
        XCTAssertEqual(waits, [5, 10, 20, 40, 80, 120, 120])
        // each time the one short retry of the engine itself, and nothing in between
        XCTAssertEqual(transport.requests.count, 14)

        // an answer ends the series: the next failure waits as briefly as the first
        failing = false
        _ = try await engine.translate(["Settings"], into: german)
        failing = true
        let failure = await failure { try await engine.translate(["General"], into: self.german) }
        XCTAssertEqual(failure?.retryAfter, 5)
    }

    func testAnAddressThatLeadsToNoServiceEndsTranslating() async {
        // the address without "/v1": the server answers with a page of its own
        let transport = ScriptedTransport { _, _ in
            reply(404, "<!DOCTYPE html><html><head><title>404 Not Found</title></head><body>Not Found</body></html>")
        }
        let engine = makeEngine(.custom, baseURL: "https://llm.example.com", model: "m", transport: transport)
        let failure = await failure { try await engine.translate(["Settings"], into: self.german) }
        XCTAssertEqual(failure?.isPermanent, true)
        XCTAssertEqual(failure?.message, "llm.example.com: "
                       + String(localized: "the address \("https://llm.example.com") cannot be used – check it in the settings"))
        XCTAssertEqual(transport.requests.count, 1)
    }

    func testAFailureAfterTheFirstPortionKeepsWhatWasTranslated() async throws {
        let texts = (1...45).map { "Text \($0)" }
        let transport = ScriptedTransport { request, number in
            if number == 0 { return openAIReply(translated(request)) }
            return reply(500, #"{"error":{"message":"Internal server error","type":"server_error"}}"#)
        }
        let engine = makeEngine(transport: transport)
        let notices = Collected<String>()
        engine.notify = { notices.add($0) }
        let translations = try await engine.translate(texts, into: german)
        // "not now" for the texts of the portion that failed: the caller asks again
        XCTAssertEqual(translations, texts[..<40].map { Optional("de:" + $0) } + [String?](repeating: nil, count: 5))
        XCTAssertEqual(notices.all, ["Mistral: " + String(localized: "the service reported an error (\("500: Internal server error"))")])
    }

    func testALocalServerThatDoesNotAnswerIsProbablyNotRunning() async {
        let transport = ScriptedTransport { _, _ in throw URLError(.cannotConnectToHost) }
        let engine = makeEngine(.ollama, model: "gemma4", transport: transport)
        let failure = await failure { try await engine.translate(["Settings"], into: self.german) }
        XCTAssertEqual(failure?.isPermanent, false)
        XCTAssertEqual(failure?.message, "Ollama: "
                       + String(localized: "cannot be reached at \("http://localhost:11434/v1") – is it running?"))
    }

    func testAServiceThatCannotBeReachedIsNamed() async {
        let transport = ScriptedTransport { _, _ in throw URLError(.notConnectedToInternet) }
        let engine = makeEngine(.openAI, transport: transport)
        let failure = await failure { try await engine.translate(["Settings"], into: self.german) }
        XCTAssertEqual(failure?.isPermanent, false)
        XCTAssertEqual(failure?.message.hasPrefix("OpenAI: "), true)
    }

    func testPlainHTTPThatTheSystemDoesNotAllowSaysWhatWorks() async {
        let transport = ScriptedTransport { _, _ in throw URLError(.appTransportSecurityRequiresSecureConnection) }
        let lan = makeEngine(.ollama, baseURL: "gpu-box.lan:11434", model: "gemma4", transport: transport)
        let failure = await failure { try await lan.translate(["Settings"], into: self.german) }
        // nothing changes by itself: asking again every few seconds would be no use
        XCTAssertEqual(failure?.isPermanent, true)
        XCTAssertEqual(failure?.message, "Ollama: "
                       + String(localized: "plain HTTP to \("gpu-box.lan") is not allowed – use a private IP address, a .local name or https"))

        // a name under .localhost is this Mac, but the system treats it like any other name
        let named = makeEngine(.custom, baseURL: "http://llm.localhost:8080/v1", model: "m", transport: transport)
        let other = await self.failure { try await named.translate(["Settings"], into: self.german) }
        XCTAssertEqual(other?.isPermanent, true)
        XCTAssertEqual(other?.message, "llm.localhost: "
                       + String(localized: "plain HTTP to \("llm.localhost") is not allowed – use localhost or 127.0.0.1 instead"))
    }

    func testAServerWithoutASecureConnectionIsNotAskedAgainAndAgain() async {
        for code in [URLError.Code.secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasUnknownRoot] {
            let transport = ScriptedTransport { _, _ in throw URLError(code) }
            let engine = makeEngine(.custom, baseURL: "gpu-box.lan:8080/v1", model: "m", transport: transport)
            let failure = await failure { try await engine.translate(["Settings"], into: self.german) }
            XCTAssertEqual(failure?.isPermanent, true, "\(code)")
            XCTAssertEqual(failure?.message, "gpu-box.lan: "
                           + String(localized: "no secure connection to \("gpu-box.lan") – for a server without https, enter its address with http:// and a private IP address or a .local name"))
            XCTAssertEqual(transport.requests.count, 1)
        }
    }

    // MARK: Turning translating off

    func testCancelEndsARequestThatWaitsForItsAnswer() async throws {
        let transport = ScriptedTransport { request, _ in
            // an answer that takes a minute
            try await Task.sleep(nanoseconds: 60_000_000_000)
            return openAIReply(translated(request))
        }
        let engine = makeEngine(transport: transport)
        let target = german
        let translating = Task { try await engine.translate(["Settings", "General"], into: target) }
        // until the request is on its way
        let deadline = Date().addingTimeInterval(10)
        while transport.requests.isEmpty, Date() < deadline {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertEqual(transport.requests.count, 1)

        let start = Date()
        engine.cancel()
        let translations = try await translating.value
        XCTAssertLessThan(Date().timeIntervalSince(start), 10)
        // no failure, but "not now" for every text
        XCTAssertEqual(translations, [nil, nil])

        // the engine has served its turn: it sends nothing anymore
        let later = try await engine.translate(["Settings"], into: german)
        XCTAssertEqual(later, [nil])
        XCTAssertEqual(transport.requests.count, 1)
    }

    func testCancellingTheTaskEndsTheRequestAsWell() async throws {
        let transport = ScriptedTransport { request, _ in
            try await Task.sleep(nanoseconds: 60_000_000_000)
            return openAIReply(translated(request))
        }
        let engine = makeEngine(transport: transport)
        let target = german
        let translating = Task { try await engine.translate(["Settings"], into: target) }
        let deadline = Date().addingTimeInterval(10)
        while transport.requests.isEmpty, Date() < deadline {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        let start = Date()
        translating.cancel()
        let translations = try await translating.value
        XCTAssertLessThan(Date().timeIntervalSince(start), 10)
        XCTAssertEqual(translations, [nil])
    }

    func testAnEngineWithASessionOfItsOwnCanBeCancelledWithoutEverSending() {
        // the session of the app: made, never used, given up
        let engine = LLMTranslationEngine(connection: LLMConnection(provider: .ollama, model: "gemma4"))
        engine.cancel()
        engine.cancel()
        XCTAssertEqual(engine.name, "Ollama")
    }

    // MARK: Anthropic

    func testAnthropicIsAskedOnceWhatTheModelCanDo() async throws {
        let transport = ScriptedTransport { request, _ in
            if request.method == "GET" { return capabilitiesReply(effortLow: true) }
            return anthropicReply(translated(request))
        }
        let engine = makeEngine(.anthropic, transport: transport)
        let first = try await engine.translate(["Settings"], into: german)
        XCTAssertEqual(first, ["de:Settings"])
        let second = try await engine.translate(["General"], into: german)
        XCTAssertEqual(second, ["de:General"])

        let requests = transport.requests
        XCTAssertEqual(requests.map(\.method), ["GET", "POST", "POST"])
        XCTAssertEqual(requests.first?.url, "https://api.anthropic.com/v1/models/claude-opus-5-5")
        XCTAssertEqual(LLMHeader.value(of: "x-api-key", in: requests.first?.headers ?? []), "sk-test-key")
        for chat in requests.dropFirst() {
            XCTAssertEqual(chat.url, "https://api.anthropic.com/v1/messages")
            // the model takes the field for a quicker answer
            XCTAssertEqual((sentJSON(chat)["output_config"] as? [String: Any])?["effort"] as? String, "low")
            // it has no model to fall back on
            XCTAssertNil(sentJSON(chat)["fallbacks"])
            XCTAssertNil(LLMHeader.value(of: "anthropic-beta", in: chat.headers))
            XCTAssertEqual(sentJSON(chat)["system"] as? String, TranslationPrompt.system(targetName: "German", targetCode: "de"))
        }
    }

    func testAnthropicModelThatDoesNotTakeTheEffortFieldGetsThePlainRequest() async throws {
        let transport = ScriptedTransport { request, _ in
            if request.method == "GET" { return capabilitiesReply(effortLow: false) }
            return anthropicReply(translated(request))
        }
        let translations = try await makeEngine(.anthropic, model: "claude-haiku-4-5", transport: transport)
            .translate(["Settings"], into: german)
        XCTAssertEqual(translations, ["de:Settings"])
        let requests = transport.requests
        XCTAssertEqual(requests.map(\.method), ["GET", "POST"])
        XCTAssertEqual(requests.first?.url, "https://api.anthropic.com/v1/models/claude-haiku-4-5")
        XCTAssertEqual(Set(sentJSON(requests[1]).keys), ["model", "max_tokens", "system", "messages"])
    }

    func testAnthropicFallbackIsUsedWhereTheModelHasOneAndDroppedWhenItIsRejected() async throws {
        let transport = ScriptedTransport { request, _ in
            if request.method == "GET" { return capabilitiesReply(effortLow: true, fallbackModels: ["claude-opus-4-8"]) }
            if LLMHeader.value(of: "anthropic-beta", in: request.headers) != nil {
                return reply(400, #"{"type":"error","error":{"type":"invalid_request_error","message":"Unexpected value(s) `server-side-fallback-2026-07-01` for the `anthropic-beta` header."}}"#)
            }
            return anthropicReply(translated(request))
        }
        let engine = makeEngine(.anthropic, transport: transport)
        let first = try await engine.translate(["Settings"], into: german)
        XCTAssertEqual(first, ["de:Settings"])
        let second = try await engine.translate(["General"], into: german)
        XCTAssertEqual(second, ["de:General"])

        let chats = transport.requests.filter { $0.method == "POST" }
        XCTAssertEqual(transport.requests.count, 4)
        // with the fallback once, then without it for good; the effort field was not the reason and stays
        XCTAssertEqual(chats.map { sentJSON($0)["fallbacks"] as? String }, ["default", nil, nil])
        XCTAssertEqual(chats.map { LLMHeader.value(of: "anthropic-beta", in: $0.headers) },
                       ["server-side-fallback-2026-07-01", nil, nil])
        XCTAssertEqual(chats.map { (sentJSON($0)["output_config"] as? [String: Any])?["effort"] as? String }, ["low", "low", "low"])
    }

    func testAnthropicOrganizationWithoutTheBetaIsAskedAgainWithoutIt() async throws {
        let transport = ScriptedTransport { request, _ in
            if request.method == "GET" {
                if LLMHeader.value(of: "anthropic-beta", in: request.headers) != nil {
                    return reply(400, #"{"type":"error","error":{"type":"invalid_request_error","message":"Unexpected value(s) for the `anthropic-beta` header."}}"#)
                }
                return capabilitiesReply(effortLow: true)
            }
            return anthropicReply(translated(request))
        }
        let translations = try await makeEngine(.anthropic, transport: transport).translate(["Settings"], into: german)
        XCTAssertEqual(translations, ["de:Settings"])
        XCTAssertEqual(transport.requests.map(\.method), ["GET", "GET", "POST"])
        XCTAssertEqual((sentJSON(transport.requests[2])["output_config"] as? [String: Any])?["effort"] as? String, "low")
    }

    func testAnthropicWrongKeyIsReportedBeforeAnyTextIsSent() async {
        let transport = ScriptedTransport { _, _ in
            reply(401, #"{"type":"error","error":{"type":"authentication_error","message":"invalid x-api-key"},"request_id":"req_1"}"#)
        }
        let engine = makeEngine(.anthropic, transport: transport)
        let failure = await failure { try await engine.translate(["Settings"], into: self.german) }
        XCTAssertEqual(failure?.isPermanent, true)
        XCTAssertEqual(failure?.message, "Anthropic: " + String(localized: "the API key was not accepted"))
        XCTAssertEqual(transport.requests.map(\.method), ["GET"])
    }

    func testAnthropicIsAskedAgainLaterWhenTheModelCouldNotBeLookedUp() async throws {
        let transport = ScriptedTransport { request, number in
            if request.method == "GET" {
                return number == 0 ? reply(529, #"{"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}"#)
                    : capabilitiesReply(effortLow: true)
            }
            return anthropicReply(translated(request))
        }
        let engine = makeEngine(.anthropic, transport: transport)
        _ = try await engine.translate(["Settings"], into: german)
        _ = try await engine.translate(["General"], into: german)
        _ = try await engine.translate(["Sounds"], into: german)
        let requests = transport.requests
        XCTAssertEqual(requests.map(\.method), ["GET", "POST", "GET", "POST", "POST"])
        // nothing is taken for granted while the model has not said what it takes
        XCTAssertNil(sentJSON(requests[1])["output_config"])
        XCTAssertNotNil(sentJSON(requests[3])["output_config"])
        XCTAssertNotNil(sentJSON(requests[4])["output_config"])
    }

    func testTheUserIsToldOnceWhenAnotherModelAnswered() async throws {
        let transport = ScriptedTransport { request, _ in
            if request.method == "GET" { return capabilitiesReply(effortLow: true, fallbackModels: ["claude-opus-4-8"]) }
            return anthropicReply(translated(request), model: "claude-opus-4-8", fallbackFrom: "claude-opus-5-5")
        }
        let engine = makeEngine(.anthropic, transport: transport)
        let notices = Collected<String>()
        engine.notify = { notices.add($0) }
        let first = try await engine.translate(["Settings"], into: german)
        XCTAssertEqual(first, ["de:Settings"])
        _ = try await engine.translate(["General"], into: german)
        XCTAssertEqual(notices.all, ["Anthropic: "
            + String(localized: "\("claude-opus-4-8") answered instead, because the chosen model declined")])
    }

    // MARK: The settings page

    func testTheTestOfTheSettingsTakesNoAnswerButAUsableOne() async throws {
        let good = ScriptedTransport { request, _ in openAIReply(translated(request)) }
        let translation = try await makeEngine(transport: good).test("Hello", into: german)
        XCTAssertEqual(translation, "de:Hello")
        XCTAssertEqual(sentTexts(good.requests[0]), ["Hello"])

        let bad = ScriptedTransport { _, _ in openAIReply("Hallo! Wie kann ich helfen?") }
        do {
            let answer = try await makeEngine(.lmStudio, model: "tiny", transport: bad).test("Hello", into: german)
            XCTFail("no failure, but \(answer)")
        } catch {
            XCTAssertEqual((error as? TranslationFailure)?.message, "LM Studio: "
                           + String(localized: "the model’s answer cannot be used – choose another model in the settings"))
        }
        XCTAssertEqual(bad.requests.count, 1)
    }

    func testTheModelsOfAServiceAreListed() async throws {
        let transport = ScriptedTransport { _, _ in
            reply(200, #"{"object":"list","data":[{"id":"whisper-large-v3"},{"id":"qwen/qwen3.8-27b"},{"id":"openai/gpt-oss-120b"},{"id":"llama-next"}]}"#)
        }
        let models = try await makeEngine(.groq, transport: transport).models()
        // the model the app names first, then by name; the one for speech is left out
        XCTAssertEqual(models, ["openai/gpt-oss-120b", "qwen/qwen3.8-27b", "llama-next"])
        XCTAssertEqual(transport.requests.first?.method, "GET")
        XCTAssertEqual(transport.requests.first?.url, "https://api.groq.com/openai/v1/models")

        let refused = ScriptedTransport { _, _ in reply(401, #"{"error":{"message":"Invalid API Key","code":"invalid_api_key"}}"#) }
        do {
            let list = try await makeEngine(.groq, transport: refused).models()
            XCTFail("no failure, but \(list)")
        } catch {
            XCTAssertEqual((error as? TranslationFailure)?.message, "Groq: " + String(localized: "the API key was not accepted"))
        }
    }

    // MARK: Names, and what leaves the Mac

    func testTheEngineIsCalledByItsServiceAndSaysWhetherTheTextLeavesTheNetwork() {
        let transport = ScriptedTransport { request, _ in openAIReply(translated(request)) }
        let openAI = makeEngine(.openAI, transport: transport)
        XCTAssertEqual(openAI.name, "OpenAI")
        XCTAssertTrue(openAI.isRemote)
        XCTAssertTrue(openAI.prefersSettledText)

        let ollama = makeEngine(.ollama, model: "gemma4", transport: transport)
        XCTAssertEqual(ollama.name, "Ollama")
        XCTAssertFalse(ollama.isRemote)
        // the address decides: the same program on a server far away gets the text sent
        XCTAssertTrue(makeEngine(.ollama, baseURL: "https://ollama.example.com", model: "gemma4", transport: transport).isRemote)
        XCTAssertFalse(makeEngine(.lmStudio, baseURL: "192.168.1.20:1234", model: "m", transport: transport).isRemote)

        // a server of one's own is called by its host
        let custom = makeEngine(.custom, baseURL: "https://llm.example.com/v1", model: "m", transport: transport)
        XCTAssertEqual(custom.name, "llm.example.com")
        XCTAssertTrue(custom.isRemote)
        XCTAssertEqual(LLMProvider.custom.localizedName, String(localized: "Custom"))
        XCTAssertEqual(LLMProvider.lmStudio.localizedName, "LM Studio")
    }

    func testARequestBecomesAURLRequest() throws {
        let connection = LLMConnection(provider: .azure, baseURL: "https://example.openai.azure.com", model: "my-deployment",
                                       apiKey: "azure-key")
        let request = LLMWire.chatRequest(connection, system: "S", user: "U")
        let urlRequest = try LLMTranslationEngine.urlRequest(for: request)
        XCTAssertEqual(urlRequest.httpMethod, "POST")
        XCTAssertEqual(urlRequest.url?.absoluteString, "https://example.openai.azure.com/openai/v1/chat/completions")
        XCTAssertEqual(urlRequest.value(forHTTPHeaderField: "api-key"), "azure-key")
        XCTAssertEqual(urlRequest.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(urlRequest.httpBody, request.body)

        let list = try LLMTranslationEngine.urlRequest(for: LLMWire.modelsRequest(LLMConnection(provider: .ollama)))
        XCTAssertEqual(list.httpMethod, "GET")
        XCTAssertEqual(list.url?.absoluteString, "http://localhost:11434/v1/models")
        XCTAssertNil(list.httpBody)
        XCTAssertNil(list.value(forHTTPHeaderField: "Authorization"))
    }

    // MARK: Which engine

    func testASettingThatIsMissingIsAskedForByName() {
        let noKey = LLMConnection(provider: .openAI)
        XCTAssertEqual(noKey.missing, .apiKey)
        let key = TranslationEngines.failure(for: .apiKey, in: noKey)
        XCTAssertTrue(key.isPermanent)
        XCTAssertEqual(key.message, String(localized: "Enter the API key for \("OpenAI") in the settings first"))

        let noModel = LLMConnection(provider: .ollama)
        XCTAssertEqual(noModel.missing, .model)
        let model = TranslationEngines.failure(for: .model, in: noModel)
        XCTAssertTrue(model.isPermanent)
        XCTAssertEqual(model.message, String(localized: "Choose a model for \("Ollama") in the settings first"))

        let noAddress = LLMConnection(provider: .azure, model: "my-deployment", apiKey: "key")
        XCTAssertEqual(noAddress.missing, .address)
        let address = TranslationEngines.failure(for: .address, in: noAddress)
        XCTAssertTrue(address.isPermanent)
        XCTAssertEqual(address.message, String(localized: "Enter the address of the service in the settings first"))

        let oddAddress = LLMConnection(provider: .custom, baseURL: "ftp://example.com", model: "m")
        XCTAssertEqual(oddAddress.missing, .address)
        XCTAssertEqual(TranslationEngines.failure(for: .address, in: oddAddress).message,
                       String(localized: "The address \("ftp://example.com") cannot be used – check it in the settings"))
    }

    func testAServiceTheAppDoesNotKnowIsReplacedByTheFirstOne() {
        XCTAssertEqual(TranslationEngines.llmProvider(id: "anthropic"), .anthropic)
        XCTAssertEqual(TranslationEngines.llmProvider(id: "a-service-of-the-future"), LLMProvider.all.first)
        XCTAssertEqual(TranslationEngines.llmProvider(id: ""), .openAI)
    }
}

/// The API keys in the login keychain. Skipped where the keychain cannot be used (a machine
/// without a login session, for example).
final class KeychainStoreTests: XCTestCase {
    func testAKeyIsStoredReadReplacedAndRemoved() throws {
        // an account that belongs to this test alone: no key of the user is touched
        let service = "test-" + UUID().uuidString.lowercased()
        defer {
            KeychainStore.set(nil, for: service)
            KeychainStore.forgetRememberedKeys()
        }
        XCTAssertFalse(KeychainStore.hasKey(for: service))
        XCTAssertNil(KeychainStore.key(for: service))

        let revision = AppSettings.shared.llmKeyRevision
        // white space around a pasted key is not part of it
        try XCTSkipUnless(KeychainStore.set(" sk-test-123\n", for: service), "the keychain of this machine cannot be used")
        // whoever translates is told that the key has changed
        XCTAssertEqual(AppSettings.shared.llmKeyRevision, revision + 1)
        XCTAssertTrue(KeychainStore.hasKey(for: service))
        XCTAssertEqual(KeychainStore.key(for: service), "sk-test-123")
        // what the next start of the app finds in the keychain
        KeychainStore.forgetRememberedKeys()
        XCTAssertTrue(KeychainStore.hasKey(for: service))
        XCTAssertEqual(KeychainStore.key(for: service), "sk-test-123")

        XCTAssertTrue(KeychainStore.set("sk-test-456", for: service))
        KeychainStore.forgetRememberedKeys()
        XCTAssertEqual(KeychainStore.key(for: service), "sk-test-456")

        XCTAssertTrue(KeychainStore.set(nil, for: service))
        XCTAssertFalse(KeychainStore.hasKey(for: service))
        XCTAssertNil(KeychainStore.key(for: service))
        // removing what is not there is no failure, and an empty key removes as well
        XCTAssertTrue(KeychainStore.set("", for: service))
        XCTAssertEqual(AppSettings.shared.llmKeyRevision, revision + 4)
    }
}
