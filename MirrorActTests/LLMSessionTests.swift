// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import XCTest
@testable import MirrorAct

/// A service inside the URL loading system of the test, so that the session of the engine is
/// used as it is in the app, without the network: "service.test" redirects every request to
/// "elsewhere.test", which answers like a model would.
private final class RedirectingService: URLProtocol {
    private static let lock = NSLock()
    private static var seen: [URLRequest] = []

    /// the requests that reached the service, in their order
    static var requests: [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return seen
    }

    static func forget() {
        lock.lock()
        seen = []
        lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        Self.seen.append(request)
        Self.lock.unlock()
        guard let url = request.url else { return }
        if url.host == "service.test" {
            let moved = HTTPURLResponse(url: url, statusCode: 307, httpVersion: "HTTP/1.1",
                                        headerFields: ["Location": "https://elsewhere.test/v1/chat/completions"])!
            var next = request
            next.url = URL(string: "https://elsewhere.test/v1/chat/completions")
            client?.urlProtocol(self, wasRedirectedTo: next, redirectResponse: moved)
            // what the system's own loader does when the redirect is refused: the reply is the redirect
            client?.urlProtocol(self, didReceive: moved, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data("Moved".utf8))
        } else {
            let answer = #"{"choices":[{"index":0,"message":{"role":"assistant","content":"[\"Einstellungen\"]"},"finish_reason":"stop"}],"data":[{"id":"m"}]}"#
            let ok = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                                     headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: ok, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(answer.utf8))
        }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// The session the engine sends its requests with
final class LLMSessionTests: XCTestCase {
    private let german = Locale.Language(identifier: "de")

    override func setUp() {
        super.setUp()
        RedirectingService.forget()
    }

    private func engine(_ provider: LLMProvider, session: URLSession) -> LLMTranslationEngine {
        let connection = LLMConnection(provider: provider, baseURL: "https://service.test/v1", model: "m",
                                       apiKey: "sk-secret")
        let engine = LLMTranslationEngine(connection: connection, transport: session)
        engine.pause = { _ in }
        return engine
    }

    func testARedirectIsNotFollowedWithTheKeyAndTheTexts() async throws {
        let session = LLMTranslationEngine.makeSession { $0.protocolClasses = [RedirectingService.self] }
        defer { session.invalidateAndCancel() }
        // Azure: the key travels in "api-key", which URLSession would take along to another host
        let engine = engine(.azure, session: session)

        do {
            let translations = try await engine.translate(["Settings"], into: german)
            XCTFail("no failure, but \(translations)")
        } catch let failure as TranslationFailure {
            // the same address redirects every request: no use asking again
            XCTAssertTrue(failure.isPermanent)
            XCTAssertEqual(failure.message, "Azure OpenAI: " + String(localized: "the service forwards the request to \("elsewhere.test"), which MirrorAct does not follow – check the address in the settings"))
        }
        XCTAssertEqual(RedirectingService.requests.map { $0.url?.host }, ["service.test"])
    }

    func testTheListOfModelsAndTheTestOfTheSettingsDoNotFollowARedirectEither() async throws {
        let session = LLMTranslationEngine.makeSession { $0.protocolClasses = [RedirectingService.self] }
        defer { session.invalidateAndCancel() }
        let engine = engine(.custom, session: session)

        do {
            let models = try await engine.models()
            XCTFail("no failure, but \(models)")
        } catch let failure as TranslationFailure {
            XCTAssertTrue(failure.isPermanent)
        }
        do {
            let translation = try await engine.test("Hello", into: german)
            XCTFail("no failure, but \(translation)")
        } catch let failure as TranslationFailure {
            XCTAssertTrue(failure.isPermanent)
        }
        XCTAssertEqual(RedirectingService.requests.map { $0.url?.host }, ["service.test", "service.test"])
    }

    func testAnAddressThatAnswersItselfIsUsed() async throws {
        let session = LLMTranslationEngine.makeSession { $0.protocolClasses = [RedirectingService.self] }
        defer { session.invalidateAndCancel() }
        let connection = LLMConnection(provider: .custom, baseURL: "https://elsewhere.test/v1", model: "m")
        let engine = LLMTranslationEngine(connection: connection, transport: session)
        let translations = try await engine.translate(["Settings"], into: german)
        XCTAssertEqual(translations, ["Einstellungen"])
    }
}
