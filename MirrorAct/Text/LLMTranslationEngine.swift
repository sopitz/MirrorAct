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

    /// seconds a request waits for its answer
    static let requestTimeout: TimeInterval = 60
    /// Longest wait in seconds before a request is sent again. When the service asks for more,
    /// the user is told instead.
    static let longestRetryWait: TimeInterval = 5
    /// seconds before a request is sent again when the service names no time
    static let retryWait: TimeInterval = 1
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
            let session = Self.makeSession()
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

    /// Nothing of a request is kept on this Mac: no cookies, no cache. A redirect is not
    /// followed (`RedirectRefusal`).
    /// - Parameter configure: changes the configuration before the session is made (for the tests)
    static func makeSession(configure: (URLSessionConfiguration) -> Void = { _ in }) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = requestTimeout
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
        let system = Self.instruction(for: target)
        var results: [String?] = []
        for batch in TranslationPrompt.batches(texts) {
            do {
                let translations = try await translate(batch, system: system)
                results += translations.map { Optional($0) }
            } catch {
                // translating was turned off meanwhile: "not now" for what is left
                if isCancellation(error) { break }
                let failure = self.failure(for: error)
                // the request as a whole failed only if nothing came of it
                guard !results.isEmpty else { throw failure }
                note(failure.message)
                break
            }
        }
        return results + [String?](repeating: nil, count: texts.count - results.count)
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

    /// The translations of one portion of texts, in their order.
    ///
    /// An answer that cannot be used (another number of items than texts, cut off, declined)
    /// is asked for again in two halves, so that one troublesome text does not keep the others
    /// from being translated. A single text is left as it is then.
    private func translate(_ texts: [String], system: String) async throws -> [String] {
        do {
            let answer = try await ask(texts, system: system)
            let translations = try TranslationPrompt.parse(answer, count: texts.count)
            locked {
                hadUsableAnswer = true
                unusableAnswers = 0
            }
            return TranslationPrompt.usable(translations, for: texts)
        } catch let error as LLMError where Self.isAboutTheAnswer(error) {
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
            let half = (texts.count + 1) / 2
            let first = try await translate(Array(texts[..<half]), system: system)
            let second = try await translate(Array(texts[half...]), system: system)
            return first + second
        }
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
                if error.isRetryable, !hasWaited {
                    let wait = Self.wait(before: error, headers: reply.headers)
                    if wait <= Self.longestRetryWait {
                        hasWaited = true
                        Log.info("Translation: \(name): trying again in \(wait) s (\(Self.kind(of: error)))")
                        try await pause(wait)
                        continue
                    }
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
                                      + String(localized: "the address \(connection.baseURL) cannot be used – check it in the settings"),
                                      isPermanent: true)
        case .cannotConnectToHost, .cannotFindHost, .networkConnectionLost:
            // a server on this Mac or in the network that does not answer is most often not running
            guard connection.isLocal else { return nil }
            return TranslationFailure(message: name + ": "
                                      + String(localized: "cannot be reached at \(connection.baseURL) – is it running?"))
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
