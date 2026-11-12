// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// What a service answered: the HTTP status, the headers and the body of the reply
typealias LLMHTTPReply = (status: Int, headers: [LLMHeader], body: Data)

/// Takes a request to a language model service and brings back the reply: `URLSession` in the
/// app, a script in the tests. Throws when no reply arrives (no connection, cancelled).
protocol LLMTransport {
    func send(_ request: LLMHTTPRequest) async throws -> LLMHTTPReply
}

extension URLSession: LLMTransport {
    func send(_ request: LLMHTTPRequest) async throws -> LLMHTTPReply {
        let (body, response) = try await data(for: LLMTranslationEngine.urlRequest(for: request))
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return (http.statusCode, LLMHeader.list(http.allHeaderFields), body)
    }
}

/// Keeps every request of the engine at the address it was sent to. URLSession would follow a
/// redirect on its own and drop only the Authorization header on the way: the keys that travel
/// in "x-api-key" (Anthropic) and "api-key" (Azure) would go along to the new host, and after a
/// 307 or 308 the texts of the screen as well. Refused, the redirect arrives as the reply.
private final class RedirectRefusal: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? {
        nil
    }
}

extension LLMConnection {
    /// The address for notices: without a name and password typed into it
    /// ("http://user:secret@192.168.1.5:8080/v1"), and without its query and fragment, where a
    /// proxy may take the key ("…/v1?key=…"). Notices of failures also go to the log file,
    /// which people attach to bug reports.
    var shownAddress: String { Self.shown(baseURL) }

    /// `address` without credentials, query and fragment
    static func shown(_ address: String) -> String {
        let bare = withoutCredentials(address)
        return String(bare[..<(bare.firstIndex { $0 == "?" || $0 == "#" } ?? bare.endIndex)])
    }

    static func withoutCredentials(_ address: String) -> String {
        let start = address.range(of: "://")?.upperBound ?? address.startIndex
        let rest = address[start...]
        let end = rest.firstIndex { $0 == "/" || $0 == "?" || $0 == "#" } ?? rest.endIndex
        guard let at = rest[..<end].lastIndex(of: "@") else { return address }
        return String(address[..<start]) + String(address[address.index(after: at)...])
    }
}

extension LLMProvider {
    /// The name to show: as the brand writes it; only "Custom" is a word to translate
    var localizedName: String {
        id == LLMProvider.custom.id ? String(localized: "Custom") : name
    }
}

/// Translates through a language model service with the user's own API key, or through a model
/// that a server on this Mac or in the network runs (`LLMProvider`).
///
/// The texts go out in portions (`TranslationPrompt.batches`), one request after the other. An
/// engine serves one turn of translating: `cancel` ends it for good, and what the engine has
/// learned about the service by then (which extra fields it takes) is kept that long.
///
/// The log gets the service, the model, the number of texts, the time and the kind of a failure;
/// never the key, the texts or the translations.
final class LLMTranslationEngine: TranslationEngine, @unchecked Sendable {
    let name: String
    let isRemote: Bool
    /// every request takes a while and, with most services, costs money
    let prefersSettledText = true

    var notify: ((String) -> Void)? {
        get { locked { notice } }
        set { locked { notice = newValue } }
    }

    /// Waits before a request is sent again. The tests replace it, so that they need not wait.
    var pause: (TimeInterval) async throws -> Void = { seconds in
        try await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
    }
    /// Seconds of a steady clock. The tests replace it, so that they need not wait.
    var now: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }

    /// Seconds a request to a service waits for its answer. A request gets no byte before the
    /// whole answer is there, so this is the time the model may take.
    static let requestTimeout: TimeInterval = 60
    /// The same for a server on this Mac or in the network: a large model on an ordinary
    /// computer takes minutes for a full screen, the first time also to load the model.
    static let localRequestTimeout: TimeInterval = 300
    /// Longest wait in seconds before a request is sent again. When the service asks for more,
    /// the user is told instead.
    static let longestRetryWait: TimeInterval = 5
    /// seconds before a request is sent again when the service names no time
    static let retryWait: TimeInterval = 1
    /// Seconds until the next request after a request that failed; doubled with every further
    /// failure in a row up to `longestBackOff`, so that a service that is down or an address
    /// that leads nowhere is not asked every few seconds for as long as translating is on
    static let firstBackOff: TimeInterval = 5
    static let longestBackOff: TimeInterval = 120
    /// longest wait a service may ask for (Retry-After); a day's quota is not sat out
    static let longestServiceWait: TimeInterval = 900
    /// Answers that could not be used after which a model that has never given a usable one is
    /// given up. Finding the one text a model stumbles over among forty takes seven of them.
    static let patience = 12

    private let connection: LLMConnection
    private let transport: LLMTransport

    /// protects everything below
    private let lock = NSLock()
    private var notice: ((String) -> Void)?
    /// the session behind `transport` when the engine made it itself
    private var session: URLSession?
    private var cancelled = false
    /// the requests that wait for their answer
    private var running: [UUID: Task<LLMHTTPReply, Error>] = [:]
    /// the extra fields the service takes; nil = not found out yet
    private var options: LLMRequestOptions?
    private var hadUsableAnswer = false
    private var unusableAnswers = 0
    /// requests in a row whose texts all stayed untranslated
    private var failuresInARow = 0
    /// no request before this time (`now`)
    private var notBefore: TimeInterval = 0
    /// the wait the service asked for in its last reply that failed
    private var serviceWait: TimeInterval?
    /// notices shown already
    private var noticed: Set<String> = []

    /// - Parameter transport: nil = over the network, with a session of the engine's own
    init(connection: LLMConnection, transport: LLMTransport? = nil) {
        self.connection = connection
        name = Self.name(for: connection)
        // the address decides, not the service: Ollama may run on a computer far away, and a
        // server of one's own on this Mac
        isRemote = !connection.isLocal
        if let transport {
            self.transport = transport
        } else {
            let session = Self.makeSession(timeout: Self.timeout(for: connection))
            self.session = session
            self.transport = session
        }
    }

    deinit {
        // never cancelled: without this the session would stay for as long as the app runs
        session?.invalidateAndCancel()
    }

    /// What a service is called in notices: its name; a server of the user's own by its host
    static func name(for connection: LLMConnection) -> String {
        let host = LLMConnection.host(of: connection.baseURL)
        if connection.provider.id == LLMProvider.custom.id, !host.isEmpty { return host }
        return connection.provider.localizedName
    }

    /// Seconds a request over `connection` waits for its answer
    static func timeout(for connection: LLMConnection) -> TimeInterval {
        connection.isLocal ? localRequestTimeout : requestTimeout
    }

    /// Nothing of a request is kept on this Mac: no cookies, no cache. A redirect is not
    /// followed (`RedirectRefusal`).
    /// - Parameters:
    ///   - timeout: seconds a request waits for its answer
    ///   - configure: changes the configuration before the session is made (for the tests)
    static func makeSession(timeout: TimeInterval = requestTimeout,
                            configure: (URLSessionConfiguration) -> Void = { _ in }) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configure(configuration)
        return URLSession(configuration: configuration, delegate: RedirectRefusal(), delegateQueue: nil)
    }

    static func urlRequest(for request: LLMHTTPRequest) throws -> URLRequest {
        guard let url = URL(string: request.url) else { throw URLError(.badURL) }
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = request.method
        for header in request.headers {
            urlRequest.setValue(header.value, forHTTPHeaderField: header.name)
        }
        urlRequest.httpBody = request.body
        return urlRequest
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    private static var clock: TimeInterval { ProcessInfo.processInfo.systemUptime }

    // MARK: Translating

    func translate(_ texts: [String], into target: Locale.Language) async throws -> [String?] {
        guard !texts.isEmpty else { return [] }
        // a failure a moment ago, or the service asked for a pause: "not now", without a request
        if locked({ now() < notBefore }) { return [String?](repeating: nil, count: texts.count) }
        let system = Self.instruction(for: target)
        var results: [String?] = []
        for batch in TranslationPrompt.batches(texts) {
            do {
                var portion = Portion(budget: Self.requestBudget(for: batch.count))
                results += try await translate(batch, system: system, portion: &portion)
                locked { failuresInARow = 0 }
            } catch {
                // translating was turned off meanwhile: "not now" for what is left
                if isCancellation(error) { break }
                var failure = self.failure(for: error)
                if !failure.isPermanent { failure.retryAfter = backOff() }
                // the request as a whole failed only if nothing came of it
                guard !results.isEmpty else { throw failure }
                note(failure.message)
                break
            }
        }
        return results + [String?](repeating: nil, count: texts.count - results.count)
    }

    /// Seconds until the next request is worth it after one that failed, from now on: what the
    /// service asked for, but at least a pause that grows with every failure in a row
    private func backOff() -> TimeInterval {
        locked {
            failuresInARow += 1
            let steps = Double(min(failuresInARow - 1, 16))
            var wait = min(Self.firstBackOff * pow(2, steps), Self.longestBackOff)
            if let asked = serviceWait { wait = max(wait, min(asked, Self.longestServiceWait)) }
            serviceWait = nil
            notBefore = now() + wait
            return wait
        }
    }

    /// Translates one text and takes no answer but a usable one: for "Test" in the settings,
    /// where `translate` would hide a model that does not do what it is asked.
    func test(_ text: String, into target: Locale.Language) async throws -> String {
        do {
            let answer = try await ask([text], system: Self.instruction(for: target))
            let translations = try TranslationPrompt.parse(answer, count: 1)
            return TranslationPrompt.usable(translations, for: [text])[0]
        } catch {
            throw failure(for: error)
        }
    }

    /// The models the service offers for translating, for the settings
    func models() async throws -> [String] {
        do {
            let reply = try await send(LLMWire.modelsRequest(connection))
            return try LLMWire.modelIDs(provider: connection.provider, status: reply.status, headers: reply.headers,
                                        body: reply.body)
        } catch {
            throw failure(for: error)
        }
    }

    func cancel() {
        let (waiting, idle): ([Task<LLMHTTPReply, Error>], URLSession?) = locked {
            cancelled = true
            return (Array(running.values), sessionToGiveUp())
        }
        waiting.forEach { $0.cancel() }
        idle?.invalidateAndCancel()
    }

    /// What the model is told: the language by its English name and its code
    static func instruction(for target: Locale.Language) -> String {
        let code = target.minimalIdentifier
        let name = Locale(identifier: "en").localizedString(forIdentifier: code) ?? ""
        return TranslationPrompt.system(targetName: name, targetCode: code)
    }

    /// Requests one portion of `count` texts may take when its answers cannot be used: enough
    /// to find one troublesome text by halving (two requests per halving), not one per text.
    /// A model that declines a whole screen would otherwise be asked 79 times for 40 texts.
    static func requestBudget(for count: Int) -> Int {
        var halvings = 0
        while (1 << halvings) < count { halvings += 1 }
        return 2 * halvings + 2
    }

    /// Requests in a row that time out, with no answer between them in the same portion, after
    /// which the server is taken for one that does not answer at all: the whole portion, a half
    /// and a quarter
    static let timeoutsBeforeGivingUp = 3

    /// What the requests for one portion of texts have shown so far
    private struct Portion {
        /// requests left (`requestBudget`)
        var budget: Int
        /// a request of this portion was answered: the server is there
        var answered = false
        /// a request of this portion timed out
        var timedOut = false
        /// requests in a row that timed out
        var timeoutsInARow = 0
    }

    /// The translations of one portion of texts, in their order; nil = not now, ask again later.
    ///
    /// An answer that cannot be used (another number of items than texts, cut off, declined)
    /// is asked for again in two halves, so that one troublesome text does not keep the others
    /// from being translated. A single text is left as it is then, and so are the texts that
    /// are left when the portion has used up its `budget` of requests.
    ///
    /// A request that times out is asked for in two halves as well. Once the server has answered
    /// a request of the portion, a text that still times out on its own is put off; before that,
    /// `timeoutsBeforeGivingUp` time-outs in a row fail the portion.
    private func translate(_ texts: [String], system: String, portion: inout Portion) async throws -> [String?] {
        guard portion.budget > 0 else {
            // after a time-out the model may be quicker the next time: not left as they are
            let later = portion.timedOut
            Log.info("Translation: \(name): \(texts.count) texts " + (later ? "are asked for later" : "stay as they are")
                     + " (no more requests for this portion)")
            return later ? [String?](repeating: nil, count: texts.count) : texts
        }
        portion.budget -= 1
        do {
            let answer = try await ask(texts, system: system)
            portion.answered = true
            portion.timeoutsInARow = 0
            let translations = try TranslationPrompt.parse(answer, count: texts.count)
            locked {
                hadUsableAnswer = true
                unusableAnswers = 0
            }
            return TranslationPrompt.usable(translations, for: texts)
        } catch let error as LLMError where Self.isAboutTheAnswer(error) {
            portion.answered = true
            portion.timeoutsInARow = 0
            let isHopeless: Bool = locked {
                unusableAnswers += 1
                return !hadUsableAnswer && unusableAnswers >= Self.patience
            }
            let declined = error == .refused
            if isHopeless {
                // Asking on would cost the user request after request for nothing.
                let words = Self.words(for: declined ? .refused : .malformedReply(""), model: connection.model)
                throw TranslationFailure(message: name + ": " + words, isPermanent: true)
            }
            guard texts.count > 1 else {
                Log.info("Translation: \(name): one text stays as it is (\(Self.kind(of: error)))")
                if declined { note(name + ": " + Self.words(for: error, model: connection.model)) }
                return texts
            }
            Log.info("Translation: \(name): asking again for \(texts.count) texts in two halves (\(Self.kind(of: error)))")
            return try await halves(of: texts, system: system, portion: &portion)
        } catch let error as URLError where error.code == .timedOut && !isCancellation(error) {
            // The model did not finish in time. Sent again whole, it would not finish the next
            // time either; half as many texts take about half as long. Says nothing about
            // whether the model can be used, so it does not count against its patience.
            portion.timedOut = true
            portion.timeoutsInARow += 1
            note(name + ": " + String(localized: "the model takes longer than \(Int(Self.timeout(for: connection))) s to answer – MirrorAct asks for fewer texts at a time"))
            if portion.answered {
                // the server answers, only not this text in time
                guard texts.count > 1 else {
                    Log.info("Translation: \(name): one text is asked for later (timed out)")
                    return [nil]
                }
            } else if texts.count == 1 || portion.timeoutsInARow >= Self.timeoutsBeforeGivingUp {
                // Nothing has come back: a server that does not answer at all is not asked on
                // and on. The caller tells the user and waits before the next request.
                throw error
            }
            Log.info("Translation: \(name): asking again for \(texts.count) texts in two halves (timed out)")
            return try await halves(of: texts, system: system, portion: &portion)
        }
    }

    /// The translations of `texts` asked for in two halves. A half that times out before any
    /// request of the portion was answered does not cost the other half: when that one is
    /// answered, the first is put off.
    private func halves(of texts: [String], system: String, portion: inout Portion) async throws -> [String?] {
        let half = (texts.count + 1) / 2
        let first: [String?]
        do {
            first = try await translate(Array(texts[..<half]), system: system, portion: &portion)
        } catch let error as URLError where error.code == .timedOut && !isCancellation(error) {
            guard portion.timeoutsInARow < Self.timeoutsBeforeGivingUp else { throw error }
            let second = try await translate(Array(texts[half...]), system: system, portion: &portion)
            return [String?](repeating: nil, count: half) + second
        }
        return first + (try await translate(Array(texts[half...]), system: system, portion: &portion))
    }

    /// Says nothing against the service or the key, only against this very request: with fewer
    /// texts at once it can work
    private static func isAboutTheAnswer(_ error: LLMError) -> Bool {
        switch error {
        case .malformedReply, .truncated, .refused: return true
        default: return false
        }
    }

    // MARK: One request

    /// The answer of the model to one portion of texts, as text. Throws `LLMError`, or what the
    /// transport threw.
    private func ask(_ texts: [String], system: String) async throws -> String {
        let start = Self.clock
        do {
            let answer = try await exchange(system: system, user: TranslationPrompt.user(texts))
            Log.info("Translation: \(name) \(connection.model): \(texts.count) texts in \(Self.milliseconds(since: start)) ms")
            return answer
        } catch {
            if !isCancellation(error) {
                Log.error("Translation: \(name) \(connection.model): \(texts.count) texts failed after "
                          + "\(Self.milliseconds(since: start)) ms (\(Self.kind(of: error)))")
            }
            throw error
        }
    }

    /// Sends the request, and sends it again where that can help: without the extra fields when
    /// the service rejects the request with them, and once after a short wait when the service
    /// is busy.
    private func exchange(system: String, user: String) async throws -> String {
        var options = try await requestOptions()
        var hasWaited = false
        while true {
            let reply = try await send(LLMWire.chatRequest(connection, system: system, user: user, options: options))
            do {
                let answer = try LLMWire.reply(format: connection.provider.format, status: reply.status,
                                               headers: reply.headers, body: reply.body)
                if options.refusalFallback { noteFallback(in: reply.body) }
                return answer
            } catch let error as LLMError {
                if case .badRequest = error, options != LLMRequestOptions() {
                    options = withoutRejectedExtras(options)
                    continue
                }
                if error.isRetryable {
                    let wait = Self.wait(before: error, headers: reply.headers)
                    if wait <= Self.longestRetryWait && !hasWaited {
                        hasWaited = true
                        Log.info("Translation: \(name): trying again in \(wait) s (\(Self.kind(of: error)))")
                        try await pause(wait)
                        continue
                    }
                    // the next turn of the caller is not to come sooner than that
                    locked { serviceWait = wait }
                }
                throw error
            }
        }
    }

    /// Seconds to wait before a request that failed with `error` is worth another try
    private static func wait(before error: LLMError, headers: [LLMHeader]) -> TimeInterval {
        if case .rateLimited(let seconds) = error, let seconds { return seconds }
        return LLMError.retryAfter(headers) ?? retryWait
    }

    /// The extra fields to send. Those of Anthropic depend on the model, which is asked once.
    private func requestOptions() async throws -> LLMRequestOptions {
        if let known = locked({ options }) { return known }
        var found = LLMRequestOptions(for: connection.provider)
        if connection.provider.format == .anthropic {
            do {
                let capabilities = try await capabilities()
                found = LLMRequestOptions(for: connection.provider, capabilities: capabilities)
            } catch let error as LLMError where error.isPermanent {
                // a wrong key, an unknown model: the translation would fail the same way
                throw error
            } catch let failure as TranslationFailure where failure.isPermanent {
                // a redirect: the translation would be redirected as well
                throw failure
            } catch {
                // Not to be had right now: this request goes without extras, the next one asks again.
                if !isCancellation(error) {
                    Log.info("Translation: \(name): what \(connection.model) can do is not known yet (\(Self.kind(of: error)))")
                }
                return found
            }
        }
        locked {
            if options == nil { options = found }
        }
        return found
    }

    /// What the model of the connection says about itself (Anthropic)
    private func capabilities() async throws -> LLMModelCapabilities {
        do {
            return try await capabilities(fallbackBeta: true)
        } catch LLMError.badRequest {
            // an organization that may not use the beta is not told about fallback models either
            return try await capabilities(fallbackBeta: false)
        }
    }

    private func capabilities(fallbackBeta: Bool) async throws -> LLMModelCapabilities {
        let reply = try await send(LLMWire.capabilitiesRequest(connection, fallbackBeta: fallbackBeta))
        return try LLMWire.capabilities(status: reply.status, headers: reply.headers, body: reply.body)
    }

    /// The service rejected a request that carried extra fields: the next one goes without, and
    /// so do all that follow. Anthropic's change of model on a refusal goes first, because an
    /// organization that may not use it is the likeliest reason; the rest follows if that was
    /// not it.
    private func withoutRejectedExtras(_ sent: LLMRequestOptions) -> LLMRequestOptions {
        var fewer = LLMRequestOptions()
        if sent.refusalFallback, sent.effortLow { fewer.effortLow = true }
        locked { options = fewer }
        Log.info("Translation: \(name) \(connection.model) rejects extra fields of the request; sending fewer from now on")
        return fewer
    }

    /// Anthropic let another model answer because the chosen one declined. The user pays for
    /// that model, so it is said once.
    private func noteFallback(in body: Data) {
        guard let reply = LLMJSON.object(LLMJSON.parse(body)) else { return }
        let blocks = LLMJSON.array(reply["content"]) ?? []
        guard blocks.contains(where: { LLMJSON.string(LLMJSON.object($0)?["type"]) == "fallback" }),
              let model = LLMJSON.string(reply["model"]), !model.isEmpty else { return }
        Log.info("Translation: \(name): \(model) answered because \(connection.model) declined")
        note(name + ": " + String(localized: "\(model) answered instead, because the chosen model declined"))
    }

    // MARK: Requests on their way

    /// Sends one request. It runs in a task of its own that `cancel` knows, so that turning
    /// translating off ends a request that waits for its answer.
    private func send(_ request: LLMHTTPRequest) async throws -> LLMHTTPReply {
        let id = UUID()
        let transport = self.transport
        let started: Task<LLMHTTPReply, Error>? = locked {
            guard !cancelled else { return nil }
            let task = Task { try await transport.send(request) }
            running[id] = task
            return task
        }
        guard let task = started else { throw CancellationError() }
        defer { finished(id) }
        let reply = try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
        if let failure = redirectFailure(reply, of: request) { throw failure }
        return reply
    }

    /// The reply is a redirect, which the session does not follow (`RedirectRefusal`). The
    /// service answers every request the same way, so trying again is pointless.
    private func redirectFailure(_ reply: LLMHTTPReply, of request: LLMHTTPRequest) -> TranslationFailure? {
        guard reply.status >= 300 && reply.status < 400,
              let location = LLMHeader.value(of: "location", in: reply.headers) else { return nil }
        // a Location may be relative to the address that was asked
        let target = URL(string: location, relativeTo: URL(string: request.url))?.absoluteString ?? location
        let host = LLMConnection.host(of: target)
        let shown = host.isEmpty ? Self.short(location) : host
        Log.error("Translation: \(name): the request was redirected to \(host.isEmpty ? "another address" : host)")
        return TranslationFailure(message: name + ": "
                                  + String(localized: "the service forwards the request to \(shown), which MirrorAct does not follow – check the address in the settings"),
                                  isPermanent: true)
    }

    private func finished(_ id: UUID) {
        let idle: URLSession? = locked {
            running[id] = nil
            return sessionToGiveUp()
        }
        idle?.invalidateAndCancel()
    }

    /// The session, once, when it is no longer needed: translating is off and no request is on
    /// its way. A session that was given up must never be asked for another request (URLSession
    /// raises an exception), which is why it waits for the last one. Call with the lock held.
    private func sessionToGiveUp() -> URLSession? {
        guard cancelled, running.isEmpty, let session else { return nil }
        self.session = nil
        return session
    }

    private func isCancellation(_ error: Error) -> Bool {
        Task.isCancelled || error is CancellationError || locked { cancelled }
    }

    // MARK: Notices and failures

    /// Shows a notice once for as long as this engine is used
    private func note(_ message: String) {
        let handler: ((String) -> Void)? = locked {
            guard noticed.insert(message).inserted else { return nil }
            return notice
        }
        handler?(message)
    }

    /// Why a request failed, in words for the user that name the service
    private func failure(for error: Error) -> TranslationFailure {
        if let failure = error as? TranslationFailure { return failure }
        if let error = error as? LLMError {
            // A page that is not there, and no word about a model: the address the user entered
            // leads to a server, but not to the service ("/v1" missing …). Nothing changes by itself.
            if case .server(status: 404, _) = error, connection.provider.baseURLRule != .fixed {
                return TranslationFailure(message: name + ": "
                                          + String(localized: "the address \(connection.shownAddress) cannot be used – check it in the settings"),
                                          isPermanent: true)
            }
            return TranslationFailure(message: name + ": " + Self.words(for: error, model: connection.model),
                                      isPermanent: error.isPermanent)
        }
        if let error = error as? URLError, let failure = failure(for: error) { return failure }
        return TranslationFailure(message: name + ": " + error.localizedDescription)
    }

    /// The failures of the connection itself that the user can do something about
    private func failure(for error: URLError) -> TranslationFailure? {
        let host = LLMConnection.host(of: connection.baseURL)
        switch error.code {
        case .appTransportSecurityRequiresSecureConnection:
            // App Transport Security lets plain HTTP through only to this Mac, private and
            // link-local IP addresses, .local names and names without a dot (project.yml).
            // "*.localhost" is this Mac as well, but not to ATS.
            let words = host.hasSuffix(".localhost")
                ? String(localized: "plain HTTP to \(host) is not allowed – use localhost or 127.0.0.1 instead")
                : String(localized: "plain HTTP to \(host) is not allowed – use a private IP address, a .local name or https")
            return TranslationFailure(message: name + ": " + words, isPermanent: true)
        case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate,
             .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid, .clientCertificateRejected,
             .clientCertificateRequired:
            // Most often a local server that speaks plain HTTP behind an address with https
            // (or without a scheme, which gets https for a name with a dot)
            return TranslationFailure(message: name + ": "
                                      + String(localized: "no secure connection to \(host) – for a server without https, enter its address with http:// and a private IP address or a .local name"),
                                      isPermanent: true)
        case .badURL, .unsupportedURL:
            return TranslationFailure(message: name + ": "
                                      + String(localized: "the address \(connection.shownAddress) cannot be used – check it in the settings"),
                                      isPermanent: true)
        case .notConnectedToInternet:
            // What macOS reports for a computer in the local network when MirrorAct may not
            // reach it (Privacy & Security > Local Network); this Mac itself needs no permission.
            let isThisMac = host == "localhost" || host == "::1" || host.hasPrefix("127.") || host.hasSuffix(".localhost")
            guard connection.isLocal, !isThisMac else { return nil }
            return TranslationFailure(message: name + ": "
                                      + String(localized: "cannot be reached at \(connection.shownAddress) – allow MirrorAct under System Settings > Privacy & Security > Local Network"))
        case .cannotConnectToHost, .cannotFindHost, .networkConnectionLost:
            // a server on this Mac or in the network that does not answer is most often not running
            guard connection.isLocal else { return nil }
            return TranslationFailure(message: name + ": "
                                      + String(localized: "cannot be reached at \(connection.shownAddress) – is it running?"))
        default:
            return nil
        }
    }

    /// What follows the name of the service in a notice about `error`
    private static func words(for error: LLMError, model: String) -> String {
        switch error {
        case .invalidKey:
            return String(localized: "the API key was not accepted")
        case .noAccess:
            return String(localized: "access was denied – check what the API key may be used for")
        case .unknownModel:
            return String(localized: "the model \(model) is not available – choose another one in the settings")
        case .outOfCredit:
            return String(localized: "no credit left, or the spending limit is reached")
        case .rateLimited:
            return String(localized: "too many requests right now")
        case .overloaded:
            return String(localized: "the service is busy right now")
        case .badRequest(let message):
            // the service's own words say which part of the request it did not take
            let detail = short(message)
            return detail.isEmpty ? String(localized: "the request was rejected")
                : String(localized: "the request was rejected (\(detail))")
        case .refused:
            return String(localized: "the model declined to translate this text")
        case .truncated, .malformedReply:
            return String(localized: "the model’s answer cannot be used – choose another model in the settings")
        case .server(let status, let message):
            let words = short(message)
            let detail = words.isEmpty ? String(status) : String(status) + ": " + words
            return String(localized: "the service reported an error (\(detail))")
        }
    }

    /// A message of a service, short enough for a notice in the mirror window
    private static func short(_ message: String) -> String {
        message.count > 100 ? String(message.prefix(99)) + "…" : message
    }

    /// The kind of a failure for the log, without the words of the service
    private static func kind(of error: Error) -> String {
        if let error = error as? LLMError {
            switch error {
            case .invalidKey: return "invalid key"
            case .noAccess: return "no access"
            case .unknownModel: return "unknown model"
            case .outOfCredit: return "out of credit"
            case .rateLimited: return "rate limited"
            case .overloaded: return "overloaded"
            case .badRequest: return "bad request"
            case .refused: return "refused"
            case .truncated: return "truncated"
            case .server(let status, _): return "server error \(status)"
            // the reason is one of this app's own notes ("3 items instead of 2")
            case .malformedReply(let reason): return "malformed reply: \(reason)"
            }
        }
        if let error = error as? URLError { return "URLError \(error.code.rawValue)" }
        if error is CancellationError { return "cancelled" }
        return String(describing: type(of: error))
    }

    private static func milliseconds(since start: TimeInterval) -> Int {
        Int(((clock - start) * 1000).rounded())
    }
}
