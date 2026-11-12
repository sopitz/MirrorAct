// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

// Translating with a language model service, without the network: what is sent to a service and
// how its replies are read. Values and pure functions only, so that the same code (and the same
// tests) describes every MirrorAct app that translates this way.
//
// A translation is one round trip: `LLMWire.chatRequest` for an `LLMConnection` with the texts
// of `TranslationPrompt`, then `LLMWire.reply` for whatever came back, then
// `TranslationPrompt.parse`. Everything that can go wrong on the way is an `LLMError`.

/// A header of a request or of a reply
struct LLMHeader: Equatable, CustomStringConvertible {
    var name: String
    var value: String

    init(_ name: String, _ value: String) {
        self.name = name
        self.value = value
    }

    /// For the log: the header without the key it may carry
    var description: String {
        let isSecret = ["authorization", "x-api-key", "api-key"].contains(name.lowercased())
        return name + ": " + (isSecret ? "…" : value)
    }

    /// Value of the header `name`, nil when there is none; upper and lower case do not matter
    static func value(of name: String, in headers: [LLMHeader]) -> String? {
        let wanted = name.lowercased()
        return headers.first { $0.name.lowercased() == wanted }?.value
    }

    /// The headers of a reply the way `HTTPURLResponse.allHeaderFields` has them, sorted by name
    static func list(_ fields: [AnyHashable: Any]) -> [LLMHeader] {
        var headers: [LLMHeader] = []
        for (key, value) in fields {
            let name = (key.base as? String) ?? String(describing: key.base)
            headers.append(LLMHeader(name, (value as? String) ?? String(describing: value)))
        }
        return headers.sorted { $0.name.lowercased() < $1.name.lowercased() }
    }
}

/// A request, ready to be handed to whatever sends HTTP on the platform
struct LLMHTTPRequest: Equatable {
    /// "GET" or "POST"
    var method: String
    var url: String
    /// in the order they are sent
    var headers: [LLMHeader]
    var body: Data?
}

/// What the user still has to enter before a service can be asked
enum LLMMissingSetting: Equatable {
    case address
    case apiKey
    case model
}

/// A service as the user has set it up
struct LLMConnection: Equatable, CustomStringConvertible {
    let provider: LLMProvider
    /// where requests go, without a slash at the end
    let baseURL: String
    let model: String
    let apiKey: String

    /// For the log: without the key
    var description: String {
        provider.name + " " + (model.isEmpty ? "(no model)" : model) + " at " + (baseURL.isEmpty ? "(no address)" : baseURL)
    }

    /// - Parameters:
    ///   - baseURL: the address the user entered, if any; only used where the service allows another one
    ///   - model: the model the user chose; none = the service's default model
    init(provider: LLMProvider, baseURL: String? = nil, model: String? = nil, apiKey: String? = nil) {
        self.provider = provider
        self.baseURL = LLMConnection.address(for: provider, entered: baseURL ?? "")
        let chosen = (model ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        self.model = chosen.isEmpty ? provider.defaultModel : chosen
        // a key copied from a web page often brings a line break along
        self.apiKey = (apiKey ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// nil = everything a request needs is there
    var missing: LLMMissingSetting? {
        let address = baseURL.lowercased()
        if !(address.hasPrefix("http://") || address.hasPrefix("https://")) || LLMConnection.host(of: baseURL).isEmpty
            || address.contains(where: { $0.isWhitespace }) {
            return .address
        }
        if provider.needsAPIKey && apiKey.isEmpty { return .apiKey }
        if model.isEmpty { return .model }
        return nil
    }

    /// The server is on the user's computer or in the user's network: the text does not leave it.
    /// Decided by the address, because the address of a local server can be changed to one that
    /// is not local, and a server of one's own can be local.
    var isLocal: Bool {
        LLMConnection.isLocalHost(LLMConnection.host(of: baseURL))
    }

    /// The address requests go to: what the user entered where the service allows that, otherwise
    /// the service's own. Tolerates what people type: spaces, a slash at the end, the address of
    /// the chat endpoint instead of its base, no "http://", no path.
    /// A query ("?api-version=…", which older Azure addresses need) stays at the end, behind
    /// every path that is added.
    static func address(for provider: LLMProvider, entered: String) -> String {
        let tidied = provider.baseURLRule == .fixed ? "" : tidy(entered)
        if tidied.isEmpty { return tidy(provider.defaultBaseURL) }
        var (address, query) = splitOffQuery(tidied)
        if address.range(of: "://") == nil {
            // Plain HTTP is what local servers speak. Ollama and LM Studio speak nothing else,
            // also on another computer that is reached by a name such as "gpu-box.lan".
            let plain = provider.isLocal || isLocalHost(host(of: address))
            address = (plain ? "http://" : "https://") + address
        }
        if !provider.pathWhenMissing.isEmpty && !hasPath(address) {
            address += provider.pathWhenMissing
        }
        return address + query
    }

    /// The address of `path` ("/chat/completions", "/models?limit=1000") at this connection:
    /// in front of the query of the address, if it has one
    func url(_ path: String) -> String {
        let (address, query) = LLMConnection.splitOffQuery(baseURL)
        guard !query.isEmpty else { return baseURL + path }
        return address + path + (path.contains("?") ? "&" + query.dropFirst() : query)
    }

    /// The address without its query, and the query with its "?" ("" when there is none)
    private static func splitOffQuery(_ address: String) -> (address: String, query: String) {
        guard let mark = address.firstIndex(of: "?") else { return (address, "") }
        return (String(address[..<mark]), String(address[mark...]))
    }

    private static func tidy(_ entered: String) -> String {
        let (path, query) = splitOffQuery(entered.trimmingCharacters(in: .whitespacesAndNewlines))
        var address = withoutSlashesAtTheEnd(path)
        if let endpoint = address.range(of: "/chat/completions", options: [.caseInsensitive, .backwards, .anchored]) {
            address.removeSubrange(endpoint)
            address = withoutSlashesAtTheEnd(address)
        }
        return address + query
    }

    private static func withoutSlashesAtTheEnd(_ text: String) -> String {
        var text = text
        // the two of "http://" stay
        while text.hasSuffix("/") && !text.hasSuffix("://") { text.removeLast() }
        return text
    }

    private static func hasPath(_ address: String) -> Bool {
        guard let scheme = address.range(of: "://") else { return address.contains("/") }
        return address[scheme.upperBound...].contains("/")
    }

    /// Host of an address in lower case, an IPv6 address without its brackets; "" when there is none
    static func host(of address: String) -> String {
        var rest = address.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let scheme = rest.range(of: "://") { rest = String(rest[scheme.upperBound...]) }
        if let end = rest.firstIndex(where: { $0 == "/" || $0 == "?" || $0 == "#" }) { rest = String(rest[..<end]) }
        if let at = rest.lastIndex(of: "@") { rest = String(rest[rest.index(after: at)...]) }
        if rest.hasPrefix("[") {
            guard let close = rest.firstIndex(of: "]") else { return "" }
            return String(rest[rest.index(after: rest.startIndex)..<close])
        }
        if let port = rest.lastIndex(of: ":") { rest = String(rest[..<port]) }
        return rest
    }

    /// This computer, or a computer that can only be reached inside the local network
    static func isLocalHost(_ host: String) -> Bool {
        if host.isEmpty { return false }
        if host == "localhost" || host.hasSuffix(".localhost") || host.hasSuffix(".local") { return true }
        if host.contains(":") {
            // IPv6: this computer, link-local (fe80::/10) and unique local addresses (fc00::/7)
            return host == "::1" || ["fe8", "fe9", "fea", "feb", "fc", "fd"].contains { host.hasPrefix($0) }
        }
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        let numbers = parts.compactMap { part in
            part.count <= 3 && !part.isEmpty && part.allSatisfy { $0.isASCII && $0.isNumber } ? Int(part) : nil
        }
        if parts.count == 4 && numbers.count == 4 {
            // IPv4: this computer, the private networks and link-local addresses
            let first = numbers[0], second = numbers[1]
            return first == 127 || first == 0 || first == 10 || (first == 192 && second == 168)
                || (first == 172 && second >= 16 && second <= 31) || (first == 169 && second == 254)
        }
        // a name without a dot is only known inside the local network
        return !host.contains(".")
    }
}

/// Extras of a chat request that not every model accepts. Each one is only sent when it is
/// known to be accepted, or is left out again when the server rejects the request.
struct LLMRequestOptions: Equatable {
    /// Anthropic: "output_config": {"effort": "low"}, for a quicker answer. Only for models whose
    /// capabilities allow it (`LLMModelCapabilities.supportsEffortLow`).
    var effortLow = false
    /// Anthropic: when the model declines a request, the service answers it with another model
    /// ("fallbacks": "default" and the beta header that belongs to it).
    var refusalFallback = false
    /// OpenAI format: "reasoning_effort": "low", for a quicker answer. The caller sends the
    /// request once more without it when the server answers 400 or 422.
    var reasoningEffortLow = false

    init(effortLow: Bool = false, refusalFallback: Bool = false, reasoningEffortLow: Bool = false) {
        self.effortLow = effortLow
        self.refusalFallback = refusalFallback
        self.reasoningEffortLow = reasoningEffortLow
    }

    /// The extras that are known to be accepted: from the service's documentation, and for
    /// Anthropic from what the model says about itself (`capabilities`; none = not asked, so
    /// nothing is taken for granted).
    init(for provider: LLMProvider, capabilities: LLMModelCapabilities? = nil) {
        let isAnthropic = provider.format == .anthropic
        self.init(effortLow: isAnthropic && capabilities?.supportsEffortLow == true,
                  refusalFallback: isAnthropic && capabilities?.hasFallbackModels == true,
                  reasoningEffortLow: !isAnthropic && provider.sendsReasoningEffortLow)
    }
}

/// What an Anthropic model can do, as far as the requests depend on it
struct LLMModelCapabilities: Equatable {
    /// "output_config": {"effort": "low"} is accepted
    var supportsEffortLow = false
    /// the service can answer with another model when this one declines
    var hasFallbackModels = false

    init(supportsEffortLow: Bool = false, hasFallbackModels: Bool = false) {
        self.supportsEffortLow = supportsEffortLow
        self.hasFallbackModels = hasFallbackModels
    }
}

/// Why a request to a language model service failed, in cases the caller can act on.
/// The texts inside are the service's own words, or notes for the log; they are not translated.
enum LLMError: Error, Equatable {
    /// the service does not accept the key
    case invalidKey
    /// the key is fine, but not allowed to do this (status 403, model not permitted)
    case noAccess
    /// the service does not know the model, or the key may not use it
    case unknownModel
    /// nothing left to pay with, or a spending limit is reached
    case outOfCredit
    /// too many requests; `retryAfterSeconds` when the service says how long to wait
    case rateLimited(retryAfterSeconds: Double?)
    /// the service is too busy right now
    case overloaded
    /// The service rejected the request (status 400 or 422): possibly an optional field.
    /// With the service's message.
    case badRequest(String)
    /// the model or a filter in front of it declined to answer
    case refused
    /// The answer was cut off at the length limit, or the request was too long: with fewer
    /// texts in a request it can work.
    case truncated
    /// anything else that went wrong on the service's side; with its message, "" if it gave none
    case server(status: Int, message: String)
    /// the reply arrived but cannot be used; with the reason, for the log
    case malformedReply(String)

    /// Trying again is pointless until the user changes something
    var isPermanent: Bool {
        switch self {
        case .invalidKey, .noAccess, .unknownModel, .outOfCredit: return true
        default: return false
        }
    }

    /// The very same request may succeed a little later
    var isRetryable: Bool {
        switch self {
        case .rateLimited, .overloaded: return true
        case .server(let status, _): return status >= 500 || status == 408 || (status >= 200 && status < 300)
        default: return false
        }
    }

    /// What a reply that reports a failure means: from its status, its headers and the body, in
    /// whichever of the shapes the services use.
    static func from(status: Int, headers: [LLMHeader], body: Data) -> LLMError {
        // the beginning is enough to describe the failure, should the body be a long page
        let text = String(decoding: body.prefix(8192), as: UTF8.self)
        return from(status: status, headers: headers, json: LLMJSON.parse(body), text: text)
    }

    /// The same for a body that is parsed already; `text` is the body when it is no JSON
    static func from(status httpStatus: Int, headers: [LLMHeader], json: Any?, text: String) -> LLMError {
        let report = LLMErrorReport(json: json, text: text)
        // an error inside a reply with status 200 brings its own status along (OpenRouter)
        var status = httpStatus
        if httpStatus >= 200 && httpStatus < 300, let inner = report.status, inner >= 400 && inner < 600 {
            status = inner
        }
        let retryAfter = LLMError.retryAfter(headers)
        let message = report.message
        let words = message.lowercased()

        // Gemini and xAI answer a wrong key with status 400, so the body has to be read as well
        if status == 401 || report.names(["invalid_api_key", "api_key_invalid", "authentication", "unauthenticated"])
            || (status == 400 && (words.contains("api key") || words.contains("api_key"))) {
            return .invalidKey
        }
        // declined because of what the text says, not because of the key or the request
        if report.blockedContent
            || report.names(["content_filter", "content_policy", "responsibleaipolicyviolation", "refusal", "moderation"]) {
            return .refused
        }
        // too much for the model or the service at once: fewer texts in a request can work
        if status == 413 || report.names(["context_length_exceeded", "max_tokens_exceeded"]) { return .truncated }
        if status == 402 {
            // OpenRouter: a budget that is only used up for the moment says when to come back
            if let retryAfter { return .rateLimited(retryAfterSeconds: retryAfter) }
            return .outOfCredit
        }
        // these arrive as 429 or 403 and would otherwise be retried or blamed on the key
        if report.names(["insufficient_quota", "credit_balance", "spend_limit", "usage_limit", "billing",
                         "payment_required", "insufficient_balance", "_budget", "key_limit"]) {
            return .outOfCredit
        }
        // Anthropic reports a spend limit the user has set as a plain bad request
        if status == 400 && words.hasPrefix("you have reached your specified") { return .outOfCredit }
        if status == 403 || report.names(["permission"]) { return .noAccess }

        let mentionsModel = words.contains("model") || words.contains("deployment")
        let saysUnknown = ["not found", "does not exist", "not exist", "not a valid model", "invalid model",
                           "unknown model", "no such model"].contains { words.contains($0) }
        if report.names(["model_not_found", "invalid_model", "deploymentnotfound"])
            || (status == 404 && (mentionsModel || report.names(["not_found"])))
            || ((status == 400 || status == 422) && mentionsModel && saysUnknown) {
            return .unknownModel
        }
        if status == 429 || report.names(["rate_limit", "resource_exhausted", "too_many_requests"]) {
            return .rateLimited(retryAfterSeconds: retryAfter)
        }
        // 529 is Anthropic's, 498 Groq's own status for "no capacity"
        if status == 503 || status == 529 || status == 498
            || report.names(["overloaded", "unavailable", "insufficient_system_resource"]) {
            return .overloaded
        }
        if status == 400 || status == 422 { return .badRequest(message) }
        return .server(status: status, message: message)
    }

    /// The service's own description of a failure: one line of at most 200 characters, "" when
    /// the body contains none.
    static func message(in body: Data) -> String {
        let text = String(decoding: body.prefix(8192), as: UTF8.self)
        return LLMErrorReport(json: LLMJSON.parse(body), text: text).message
    }

    /// Seconds to wait before the next attempt, from the header "retry-after-ms" (Azure) or
    /// "retry-after"; nil when the reply names no number.
    static func retryAfter(_ headers: [LLMHeader]) -> Double? {
        if let text = LLMHeader.value(of: "retry-after-ms", in: headers), let milliseconds = plainNumber(text) {
            return milliseconds / 1000
        }
        if let text = LLMHeader.value(of: "retry-after", in: headers), let seconds = plainNumber(text) {
            return seconds
        }
        return nil
    }

    /// A number written with digits and at most one point; everything else (a date, for example) is none
    private static func plainNumber(_ text: String) -> Double? {
        let text = text.trimmingCharacters(in: .whitespaces)
        var digits = 0, points = 0
        for character in text {
            if character.isASCII && character.isNumber {
                digits += 1
            } else if character == "." {
                points += 1
            } else {
                return nil
            }
        }
        guard digits > 0, digits <= 15, points <= 1 else { return nil }
        return Double(text)
    }
}

/// What the body of a failed reply says. The services use six shapes:
/// `{"error": {"message", "type", "code"}}` (OpenAI and most others; Anthropic adds "type": "error"
/// around it, OpenRouter uses a number as the code, Google adds "status" and "details"),
/// `{"error": "…"}` (LM Studio, Ollama; xAI with a "code" beside it), `{"detail": "…"}` or
/// `{"detail": [{"loc", "msg"}]}` (Mistral), any of these inside a list (Gemini), and text that
/// is no JSON at all (the page of a gateway).
private struct LLMErrorReport {
    /// the service's own words in one line, "" when it gave none
    var message = ""
    /// names for the failure found in the body ("invalid_api_key", "resource_exhausted" …),
    /// in lower case and with "_" between the words
    var codes: [String] = []
    /// a status number inside the body
    var status: Int?
    /// the body quotes the text that was objected to (OpenRouter's moderation and guardrails)
    var blockedContent = false

    init(json: Any?, text: String) {
        var root = json
        if let list = LLMJSON.array(root), let first = list.first { root = first }
        guard let object = LLMJSON.object(root) else {
            if let words = LLMJSON.string(root) {
                message = LLMText.oneLine(words)
            } else if json == nil {
                message = LLMText.oneLine(LLMErrorReport.readable(text))
            }
            return
        }
        var words: String?
        note(object["code"])
        note(object["type"])
        note(object["status"])
        if let error = LLMJSON.object(object["error"]) {
            words = LLMJSON.string(error["message"])
            note(error["code"])
            note(error["type"])
            note(error["status"])
            // Google: "details": [{"reason": "API_KEY_INVALID"}]; Anthropic: "details": {"error_code": "…"}
            for detail in LLMJSON.array(error["details"]) ?? [] {
                note(LLMJSON.object(detail)?["reason"])
            }
            note(LLMJSON.object(error["details"])?["error_code"])
            // OpenRouter
            if let metadata = LLMJSON.object(error["metadata"]) {
                note(metadata["error_type"])
                note(metadata["limit_source"])
                blockedContent = metadata["flagged_input"] != nil || metadata["reasons"] != nil || metadata["patterns"] != nil
            }
            // Azure
            note((LLMJSON.object(error["inner_error"]) ?? LLMJSON.object(error["innererror"]))?["code"])
        } else if let error = LLMJSON.string(object["error"]) {
            words = error
        }
        if words == nil, let detail = LLMJSON.string(object["detail"]) {
            words = detail
        }
        if words == nil, let first = LLMJSON.object(LLMJSON.array(object["detail"])?.first) {
            // which field of the request was wrong, and how
            let problem = LLMJSON.string(first["msg"]) ?? ""
            if let field = LLMJSON.string(LLMJSON.array(first["loc"])?.last) {
                words = field + ": " + problem
            } else {
                words = problem
            }
            note(first["type"])
        }
        message = LLMText.oneLine(words ?? LLMJSON.string(object["message"]) ?? "")
    }

    /// One of the names for the failure contains one of `parts`
    func names(_ parts: [String]) -> Bool {
        codes.contains { code in parts.contains { code.contains($0) } }
    }

    private mutating func note(_ value: Any?) {
        if let name = LLMJSON.string(value) {
            let code = name.lowercased().replacingOccurrences(of: "-", with: "_").replacingOccurrences(of: " ", with: "_")
            if !code.isEmpty { codes.append(code) }
        } else if status == nil, let number = LLMJSON.number(value), number >= 100 && number < 1000 {
            status = Int(number)
        }
    }

    /// The readable part of a body that is no JSON: the title of a page, or the text itself
    private static func readable(_ text: String) -> String {
        let lower = text.lowercased()
        guard lower.contains("<html") || lower.contains("<!doctype") || lower.contains("<head") else { return text }
        guard let open = text.range(of: "<title>", options: .caseInsensitive),
              let close = text.range(of: "</title>", options: .caseInsensitive, range: open.upperBound..<text.endIndex) else {
            return ""
        }
        return String(text[open.upperBound..<close.lowerBound])
    }
}

/// Requests to language model services and the reading of their replies
enum LLMWire {
    static let anthropicVersion = "2026-10-21"
    /// lets the service answer with another model when the chosen one declines
    static let anthropicFallbackBeta = "server-side-fallback-2026-07-01"
    /// Anthropic wants a limit. Thinking counts toward it, so it must not be small.
    static let anthropicMaxTokens = 16000

    // MARK: Chat

    /// The request that asks the model: `system` says what to do, `user` is what to do it with.
    ///
    /// The body contains nothing but the model and the two messages, because every other field
    /// is rejected by at least one service or model: no temperature, no limit of tokens (except
    /// where it is required), no response format.
    static func chatRequest(_ connection: LLMConnection, system: String, user: String,
                            options: LLMRequestOptions = LLMRequestOptions()) -> LLMHTTPRequest {
        switch connection.provider.format {
        case .anthropic:
            var headers = keyHeaders(connection)
            headers.append(LLMHeader("content-type", "application/json"))
            var body: [String: Any] = [
                "model": connection.model,
                "max_tokens": anthropicMaxTokens,
                "system": system,
                "messages": [["role": "user", "content": user]],
            ]
            if options.effortLow {
                body["output_config"] = ["effort": "low"]
            }
            if options.refusalFallback {
                headers.append(LLMHeader("anthropic-beta", anthropicFallbackBeta))
                body["fallbacks"] = "default"
            }
            return LLMHTTPRequest(method: "POST", url: connection.url("/messages"), headers: headers,
                                  body: LLMJSON.data(body))
        case .openAICompatible:
            var headers = keyHeaders(connection)
            headers.append(LLMHeader("Content-Type", "application/json"))
            var body: [String: Any] = [
                "model": connection.model,
                "messages": [["role": "system", "content": system], ["role": "user", "content": user]],
            ]
            if options.reasoningEffortLow {
                body["reasoning_effort"] = "low"
            }
            return LLMHTTPRequest(method: "POST", url: connection.url("/chat/completions"), headers: headers,
                                  body: LLMJSON.data(body))
        }
    }

    /// The headers that identify the user. A server that needs no key gets none.
    private static func keyHeaders(_ connection: LLMConnection) -> [LLMHeader] {
        var headers: [LLMHeader] = []
        switch connection.provider.format {
        case .anthropic:
            if !connection.apiKey.isEmpty { headers.append(LLMHeader("x-api-key", connection.apiKey)) }
            headers.append(LLMHeader("anthropic-version", anthropicVersion))
        case .openAICompatible:
            if connection.apiKey.isEmpty { break }
            if connection.provider.keyInAPIKeyHeader {
                headers.append(LLMHeader("api-key", connection.apiKey))
            } else {
                headers.append(LLMHeader("Authorization", "Bearer " + connection.apiKey))
            }
        }
        return headers
    }

    /// The text the model answered with, without its thinking and without white space around it.
    ///
    /// Throws `LLMError`: what the service reported when the status is not 2xx or the body
    /// carries an error; `.refused` or `.truncated` when the model declined or ran into the
    /// length limit; `.malformedReply` when there is no text to be found.
    static func reply(format: LLMWireFormat, status: Int, headers: [LLMHeader] = [], body: Data) throws -> String {
        guard status >= 200 && status < 300 else {
            throw LLMError.from(status: status, headers: headers, body: body)
        }
        var parsed = LLMJSON.parse(body)
        if let list = LLMJSON.array(parsed), let first = list.first { parsed = first }
        guard let root = LLMJSON.object(parsed) else {
            throw LLMError.malformedReply("the reply is not a JSON object")
        }
        // a failure while the model was answering can arrive with status 200 (OpenRouter)
        if isError(root["error"]) || LLMJSON.string(root["type"]) == "error" {
            throw LLMError.from(status: status, headers: headers, json: root, text: "")
        }
        let text: String
        switch format {
        case .anthropic: text = try anthropicText(root)
        case .openAICompatible: text = try openAIText(root, status: status, headers: headers)
        }
        let answer = LLMText.withoutThinking(text)
        guard !answer.isEmpty else { throw LLMError.malformedReply("the reply contains no text") }
        return answer
    }

    private static func anthropicText(_ root: [String: Any]) throws -> String {
        // a declined request has no content, so the reason comes first
        let reason = LLMJSON.string(root["stop_reason"]) ?? ""
        if reason == "refusal" { throw LLMError.refused }
        if reason == "max_tokens" || reason == "model_context_window_exceeded" { throw LLMError.truncated }
        guard let blocks = LLMJSON.array(root["content"]) else {
            throw LLMError.malformedReply("the reply has no content")
        }
        return textParts(blocks)
    }

    private static func openAIText(_ root: [String: Any], status: Int, headers: [LLMHeader]) throws -> String {
        guard let choice = LLMJSON.object(LLMJSON.array(root["choices"])?.first) else {
            throw LLMError.malformedReply("the reply has no choices")
        }
        // OpenRouter: the service behind it failed after it had begun to answer
        if let error = choice["error"], isError(error) {
            throw LLMError.from(status: status, headers: headers, json: ["error": error], text: "")
        }
        let message = LLMJSON.object(choice["message"]) ?? [:]
        let reason = (LLMJSON.string(choice["finish_reason"]) ?? "").lowercased()
        if isRefusal(message["refusal"]) || reason == "content_filter" { throw LLMError.refused }
        // also when there is some text: a list that was cut off cannot be used
        if reason == "length" || reason == "model_length" || reason == "max_tokens" { throw LLMError.truncated }
        if reason == "insufficient_system_resource" { throw LLMError.overloaded }
        if reason == "error" { throw LLMError.server(status: status, message: "") }
        if let text = LLMJSON.string(message["content"]) { return text }
        // Mistral with reasoning: [{"type": "thinking", …}, {"type": "text", "text": "…"}]
        if let parts = LLMJSON.array(message["content"]) { return textParts(parts) }
        return ""
    }

    /// The text of a reply that comes in parts: what is text, not the thinking and not the
    /// notes about a change of model
    private static func textParts(_ parts: [Any]) -> String {
        var text = ""
        for part in parts {
            guard let part = LLMJSON.object(part), let piece = LLMJSON.string(part["text"]) else { continue }
            let type = LLMJSON.string(part["type"])
            if type == nil || type == "text" { text += piece }
        }
        return text
    }

    /// "error": null, "" and {} are no errors
    private static func isError(_ value: Any?) -> Bool {
        if let text = LLMJSON.string(value) { return !text.isEmpty }
        if let object = LLMJSON.object(value) { return !object.isEmpty }
        return false
    }

    /// OpenAI: "refusal" is null unless the model declined
    private static func isRefusal(_ value: Any?) -> Bool {
        if LLMJSON.isNull(value) { return false }
        if let text = LLMJSON.string(value) { return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        return true
    }

    // MARK: Models

    /// The request for the models the key can use
    static func modelsRequest(_ connection: LLMConnection) -> LLMHTTPRequest {
        // Anthropic sends 20 models unless asked for more
        let path = connection.provider.format == .anthropic ? "/models?limit=1000" : "/models"
        return LLMHTTPRequest(method: "GET", url: connection.url(path), headers: keyHeaders(connection), body: nil)
    }

    /// The ids of the models in the reply to `modelsRequest` that can be used to translate: the
    /// ones the catalogue names first, the others by name. Models that evidently do something
    /// else (embeddings, speech, pictures, moderation) are left out; when in doubt a model stays.
    ///
    /// Throws `LLMError` like `reply`.
    static func modelIDs(provider: LLMProvider, status: Int, headers: [LLMHeader] = [], body: Data) throws -> [String] {
        guard status >= 200 && status < 300 else {
            throw LLMError.from(status: status, headers: headers, body: body)
        }
        let root = LLMJSON.parse(body)
        let entries: [Any]
        if let list = LLMJSON.array(root) {
            entries = list
        } else if let object = LLMJSON.object(root) {
            if isError(object["error"]) {
                throw LLMError.from(status: status, headers: headers, json: object, text: "")
            }
            guard let list = LLMJSON.array(object["data"]) ?? LLMJSON.array(object["models"]) else {
                throw LLMError.malformedReply("the reply contains no list of models")
            }
            entries = list
        } else {
            throw LLMError.malformedReply("the reply contains no list of models")
        }

        var ids: [String] = []
        var seen = Set<String>()
        for entry in entries {
            let model = LLMJSON.object(entry) ?? [:]
            guard var id = LLMJSON.string(entry) ?? LLMJSON.string(model["id"]) ?? LLMJSON.string(model["name"]) else { continue }
            id = id.trimmingCharacters(in: .whitespacesAndNewlines)
            // Gemini lists "models/gemini-…" and accepts the name without the prefix
            if !provider.listedModelPrefix.isEmpty && id.hasPrefix(provider.listedModelPrefix) {
                id.removeFirst(provider.listedModelPrefix.count)
            }
            guard !id.isEmpty, canChat(model, id: id), seen.insert(id).inserted else { continue }
            ids.append(id)
        }

        // the models the catalogue names come first, in its order; Ollama lists them with a tag ("gemma4:12b")
        let known = provider.knownModels
        var sortable: [(rank: Int, name: String, id: String)] = []
        for id in ids {
            let rank = known.firstIndex { id == $0 || id.hasPrefix($0 + ":") } ?? known.count
            sortable.append((rank, id.lowercased(), id))
        }
        sortable.sort { first, second in
            if first.rank != second.rank { return first.rank < second.rank }
            return first.name != second.name ? first.name < second.name : first.id < second.id
        }
        return sortable.map { $0.id }
    }

    /// false only where the entry or the name says that the model is not one to chat with
    private static func canChat(_ model: [String: Any], id: String) -> Bool {
        // what the services say themselves
        if isFalse(LLMJSON.object(model["capabilities"])?["completion_chat"]) { return false }    // Mistral
        if isFalse(model["active"]) { return false }                                              // Groq
        if LLMJSON.string(model["lifecycle"]) == "retired" { return false }                       // Anthropic
        if let type = LLMJSON.string(model["type"]), type.lowercased().hasPrefix("embed") { return false }    // LM Studio
        if let methods = LLMJSON.array(model["supportedGenerationMethods"]),
           !methods.contains(where: { LLMJSON.string($0) == "generateContent" }) {
            return false                                                                          // Gemini
        }
        let outputs = LLMJSON.array(model["output_modalities"])
            ?? LLMJSON.array(LLMJSON.object(model["architecture"])?["output_modalities"])
        if let outputs, !outputs.isEmpty, !outputs.contains(where: { LLMJSON.string($0)?.lowercased() == "text" }) {
            return false                                                                          // DeepSeek, OpenRouter
        }
        if !LLMJSON.isNull(model["image_price"]) && LLMJSON.isNull(model["completion_text_token_price"]) {
            return false                                                                          // xAI: draws pictures
        }
        // OpenAI, Groq, Ollama and LM Studio tell nothing but the name
        let name = id.lowercased()
        let otherPurposes = ["embed", "whisper", "tts", "transcribe", "dall-e", "image", "audio", "realtime",
                             "moderation", "rerank", "guard", "orpheus"]
        if otherPurposes.contains(where: { name.contains($0) }) { return false }
        // models of OpenAI that only complete text, and models that make videos
        let lastPart = name.split(separator: "/").last.map { String($0) } ?? name
        if ["babbage", "davinci", "sora", "veo-"].contains(where: { lastPart.hasPrefix($0) }) { return false }
        return true
    }

    private static func isFalse(_ value: Any?) -> Bool {
        (value as? Bool) == false
    }

    // MARK: What an Anthropic model can do

    /// The request for the description of the connection's model.
    /// `fallbackBeta`: with the beta header that makes the service list the model's fallback
    /// models; an organization that may not use the beta gets status 400 and asks again without.
    static func capabilitiesRequest(_ connection: LLMConnection, fallbackBeta: Bool = true) -> LLMHTTPRequest {
        var headers = keyHeaders(connection)
        if fallbackBeta && connection.provider.format == .anthropic {
            headers.append(LLMHeader("anthropic-beta", anthropicFallbackBeta))
        }
        return LLMHTTPRequest(method: "GET", url: connection.url("/models/" + pathEscaped(connection.model)),
                              headers: headers, body: nil)
    }

    /// What the reply to `capabilitiesRequest` says. Whatever is missing in it counts as "no".
    /// Throws `LLMError` when the status is not 2xx (an unknown model, a wrong key).
    static func capabilities(status: Int, headers: [LLMHeader] = [], body: Data) throws -> LLMModelCapabilities {
        guard status >= 200 && status < 300 else {
            throw LLMError.from(status: status, headers: headers, body: body)
        }
        let model = LLMJSON.object(LLMJSON.parse(body)) ?? [:]
        let effort = LLMJSON.object(LLMJSON.object(model["capabilities"])?["effort"])
        let low = LLMJSON.object(effort?["low"])
        // an empty list means that the model has no fallback
        let fallbacks = LLMJSON.array(model["allowed_fallback_models"]) ?? []
        return LLMModelCapabilities(supportsEffortLow: (low?["supported"] as? Bool) == true,
                                    hasFallbackModels: !fallbacks.isEmpty)
    }

    /// A name as part of the path of an address
    private static func pathEscaped(_ text: String) -> String {
        var allowed = CharacterSet()
        allowed.insert(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        return text.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
    }
}

/// Reading JSON whose shape is not certain: every step answers nil instead of failing
enum LLMJSON {
    /// nil when `data` is no JSON
    static func parse(_ data: Data) -> Any? {
        try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    }

    static func object(_ value: Any?) -> [String: Any]? {
        value as? [String: Any]
    }

    static func array(_ value: Any?) -> [Any]? {
        value as? [Any]
    }

    static func string(_ value: Any?) -> String? {
        value as? String
    }

    static func number(_ value: Any?) -> Double? {
        (value as? NSNumber)?.doubleValue
    }

    /// absent, or JSON's null
    static func isNull(_ value: Any?) -> Bool {
        value == nil || value is NSNull
    }

    /// JSON text of a dictionary or an array; the keys are sorted so that the same content always
    /// gives the same text
    static func data(_ object: Any) -> Data? {
        guard JSONSerialization.isValidJSONObject(object) else { return nil }
        return try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
    }
}

/// Small repairs of text that comes from a model or a service
enum LLMText {
    /// The answer without the model's thinking, which some servers leave in the text between
    /// "<think>" and "</think>", and without white space around it. Only thinking at the
    /// beginning is removed: further down the same characters may be part of the answer.
    static func withoutThinking(_ text: String) -> String {
        let open = "<think>", close = "</think>"
        var rest = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // a model thinks once or twice; the limit keeps a text made of nothing but tags from taking long
        for _ in 0..<8 {
            guard rest.range(of: open, options: [.caseInsensitive, .anchored]) != nil else { break }
            // still thinking when the reply ended: there is no answer
            guard let end = rest.range(of: close, options: .caseInsensitive) else { return "" }
            rest = String(rest[end.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        // Some servers put the opening tag into the prompt, so that the reply only has the closing
        // one. An answer that begins with a bracket is the answer already, whatever it contains.
        if !rest.hasPrefix("["), !rest.hasPrefix("{"),
           let end = rest.range(of: close, options: .caseInsensitive),
           rest.range(of: open, options: .caseInsensitive, range: rest.startIndex..<end.lowerBound) == nil {
            rest = String(rest[end.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return rest
    }

    /// One line of at most 200 characters
    static func oneLine(_ text: String) -> String {
        // a long text is cut first, so that a page of megabytes is not split into words
        let words = text.prefix(2000).split(whereSeparator: { character in
            character.isWhitespace || character.unicodeScalars.contains { $0.value < 0x20 || $0.value == 0x7F }
        })
        let line = words.joined(separator: " ")
        return line.count > 200 ? String(line.prefix(199)) + "…" : line
    }
}
