// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import Combine
import SwiftUI
import XCTest
@testable import MirrorAct

/// The Text page of the settings, typed into like the user does
@MainActor
final class TextSettingsViewTests: XCTestCase {
    private var settings: AppSettings { AppSettings.shared }
    private var saved: (engine: String, provider: String, models: [String: String], addresses: [String: String])!
    private var changes = 0
    private var subscription: AnyCancellable?
    private var window: NSWindow?
    /// the model of the page shown, whose buttons the tests press
    private var page: TextSettingsView.Page!
    /// what the page stored as keys, by service; nil = removed
    private var storedKeys: [(key: String?, provider: String)] = []
    /// the services the page's key store says have a key, and what it hands out for them
    private var keysThere: [String: String?] = [:]
    /// what the service answers Test and Load the list; nil = the request fails
    private var serviceAnswer: LLMHTTPReply?

    override func setUp() {
        super.setUp()
        saved = (settings.translationEngine, settings.llmProvider, settings.llmModels, settings.llmBaseURLs)
        settings.translationEngine = "llm"
        settings.llmProvider = LLMProvider.ollama.id
        settings.llmModels = [:]
        settings.llmBaseURLs = [:]
        changes = 0
        storedKeys = []
        keysThere = [:]
        serviceAnswer = nil
        subscription = settings.translationSettingsChanged.sink { [weak self] in self?.changes += 1 }
    }

    override func tearDown() {
        subscription = nil
        window?.contentView = nil
        window?.close()
        window = nil
        page = nil
        settings.translationEngine = saved.engine
        settings.llmProvider = saved.provider
        settings.llmModels = saved.models
        settings.llmBaseURLs = saved.addresses
        super.tearDown()
    }

    // MARK: Address and model

    /// A half-typed address must not reach the settings: translating would start over with it
    /// and send the screen's text there
    func testTheAddressIsAppliedOnlyOnReturn() throws {
        let page = try showPage()
        let address = try field(at: 0, in: page)
        type("http://192.168.1.2", into: address)
        XCTAssertNil(settings.llmBaseURLs[LLMProvider.ollama.id])
        XCTAssertEqual(changes, 0)

        type("5:11434", into: address)
        pressReturn(in: address)
        XCTAssertTrue(waitUntil { self.settings.llmBaseURLs[LLMProvider.ollama.id] == "http://192.168.1.25:11434" })
        XCTAssertEqual(changes, 1)
    }

    func testTheModelIsAppliedWhenTheFieldIsLeft() throws {
        let page = try showPage()
        let model = try field(at: 1, in: page)
        type("gemma", into: model)
        XCTAssertNil(settings.llmModels[LLMProvider.ollama.id])

        type("4", into: model)
        // to the address field
        window?.makeFirstResponder(try field(at: 0, in: page))
        XCTAssertTrue(waitUntil { self.settings.llmModels[LLMProvider.ollama.id] == "gemma4" })
        XCTAssertEqual(changes, 1)
    }

    /// Going into a field and out again without changing it does not make translating start over
    func testLeavingAFieldUnchangedChangesNothing() throws {
        settings.llmModels = [LLMProvider.ollama.id: "gemma4"]
        changes = 0
        let page = try showPage()
        let model = try field(at: 1, in: page)
        window?.makeFirstResponder(model)
        spin()
        pressReturn(in: model)
        window?.makeFirstResponder(try field(at: 0, in: page))
        spin()
        XCTAssertEqual(changes, 0)
    }

    /// What is typed when the page goes away (the window closes, another tab) is kept
    func testWhatIsTypedIsAppliedWhenThePageCloses() throws {
        let page = try showPage()
        type("http://studio.local:11434", into: try field(at: 0, in: page))
        XCTAssertNil(settings.llmBaseURLs[LLMProvider.ollama.id])
        closePage()
        XCTAssertTrue(waitUntil { self.settings.llmBaseURLs[LLMProvider.ollama.id] == "http://studio.local:11434" })
    }

    // MARK: The key

    /// Return in the key field stores the key, like Save
    func testTheKeyIsStoredOnReturn() throws {
        settings.llmProvider = LLMProvider.custom.id
        let page = try showPage()
        let key = try field(at: 2, in: page)
        XCTAssertTrue(key is NSSecureTextField)
        type("sk-test", into: key)
        XCTAssertTrue(storedKeys.isEmpty)
        pressReturn(in: key)
        XCTAssertTrue(waitUntil { !self.storedKeys.isEmpty })
        XCTAssertEqual(storedKeys.first?.key, "sk-test")
        XCTAssertEqual(storedKeys.first?.provider, LLMProvider.custom.id)
    }

    /// A key that was typed and not saved is not lost when the window closes: Test may have
    /// worked with it, and translating would then ask for a key
    func testATypedKeyIsStoredWhenThePageCloses() throws {
        settings.llmProvider = LLMProvider.custom.id
        let page = try showPage()
        type("sk-test", into: try field(at: 2, in: page))
        closePage()
        XCTAssertTrue(waitUntil { !self.storedKeys.isEmpty })
        XCTAssertEqual(storedKeys.map(\.key), ["sk-test"])
        XCTAssertEqual(storedKeys.first?.provider, LLMProvider.custom.id)
    }

    /// Nothing typed, nothing stored: closing the page must not remove a key that is there
    func testClosingThePageWithoutAKeyStoresNothing() throws {
        settings.llmProvider = LLMProvider.custom.id
        _ = try showPage()
        closePage()
        XCTAssertTrue(storedKeys.isEmpty)
    }

    /// A key typed for a service that has none yet is kept when the user picks another one
    func testATypedKeyIsStoredWhenTheServiceChangesAndNoneIsStoredYet() throws {
        settings.llmProvider = LLMProvider.custom.id
        let view = try showPage()
        type("sk-new", into: try field(at: 2, in: view))
        page.selectProvider(LLMProvider.openAI.id)
        XCTAssertEqual(settings.llmProvider, LLMProvider.openAI.id)
        XCTAssertEqual(storedKeys.map(\.key), ["sk-new"])
        XCTAssertEqual(storedKeys.map(\.provider), [LLMProvider.custom.id])
    }

    /// A stored key is replaced only by Save, Return, or a Test that worked with the typed one:
    /// a key pasted while the wrong service was shown must not overwrite it
    func testATypedKeyDoesNotReplaceAStoredKeyWhenTheServiceChanges() throws {
        settings.llmProvider = LLMProvider.openAI.id
        keysThere = [LLMProvider.openAI.id: "sk-working"]
        let view = try showPage()
        type("sk-other", into: try field(at: 1, in: view))
        // the page says that the typed key is not stored, so that dropping it is no surprise
        XCTAssertTrue(page.typedKeyIsPending)
        page.selectProvider(LLMProvider.anthropic.id)
        XCTAssertEqual(settings.llmProvider, LLMProvider.anthropic.id)
        XCTAssertTrue(storedKeys.isEmpty, "\(storedKeys)")
        XCTAssertEqual(page.enteredKey, "")
    }

    func testATypedKeyDoesNotReplaceAStoredKeyWhenThePageCloses() throws {
        settings.llmProvider = LLMProvider.openAI.id
        keysThere = [LLMProvider.openAI.id: "sk-working"]
        let view = try showPage()
        type("sk-other", into: try field(at: 1, in: view))
        closePage()
        XCTAssertTrue(storedKeys.isEmpty, "\(storedKeys)")
    }

    /// Return still replaces a stored key: the user asked for it
    func testReturnReplacesAStoredKey() throws {
        settings.llmProvider = LLMProvider.openAI.id
        keysThere = [LLMProvider.openAI.id: "sk-working"]
        let view = try showPage()
        let key = try field(at: 1, in: view)
        type("sk-other", into: key)
        pressReturn(in: key)
        XCTAssertTrue(waitUntil { !self.storedKeys.isEmpty })
        XCTAssertEqual(storedKeys.map(\.key), ["sk-other"])
        XCTAssertFalse(page.typedKeyIsPending)
    }

    /// A key Test worked with counts at once, also while the settings window stays open and
    /// also in place of the key that is stored
    func testAKeyThatPassedTheTestIsStored() throws {
        settings.llmProvider = LLMProvider.openAI.id
        keysThere = [LLMProvider.openAI.id: "sk-old"]
        serviceAnswer = Self.chatReply("Hallo")
        let view = try showPage()
        type("sk-tested", into: try field(at: 1, in: view))
        page.runTest()
        XCTAssertTrue(waitUntil { !self.page.isTesting })
        XCTAssertEqual(storedKeys.map(\.key), ["sk-tested"])
        XCTAssertEqual(storedKeys.map(\.provider), [LLMProvider.openAI.id])
        // the answer stays in view after the key went into the keychain
        XCTAssertEqual(page.testOutcome, .init(text: "Hallo", failed: false))
        XCTAssertEqual(page.enteredKey, "")
    }

    /// For a service without a key, a typed key the list loaded with is kept at once
    func testAKeyThatLoadedTheListIsStoredWhenNoneIsStoredYet() throws {
        settings.llmProvider = LLMProvider.openAI.id
        serviceAnswer = (200, [LLMHeader("Content-Type", "application/json")],
                         Data(#"{"object":"list","data":[{"id":"gpt-6-luna"},{"id":"gpt-6.1-sol"}]}"#.utf8))
        let view = try showPage()
        type("sk-listed", into: try field(at: 1, in: view))
        page.loadModels()
        XCTAssertTrue(waitUntil { !self.page.isLoadingModels })
        XCTAssertNil(page.modelsProblem)
        XCTAssertEqual(storedKeys.map(\.key), ["sk-listed"])
    }

    /// The list proves nothing about a key: OpenRouter lists its models to anyone, so a key
    /// pasted for another service would get through and overwrite the one that works
    func testAKeyThatLoadedTheListDoesNotReplaceAStoredKey() throws {
        settings.llmProvider = LLMProvider.openRouter.id
        keysThere = [LLMProvider.openRouter.id: "sk-working"]
        serviceAnswer = (200, [LLMHeader("Content-Type", "application/json")],
                         Data(#"{"data":[{"id":"openai/gpt-6-luna"}]}"#.utf8))
        let view = try showPage()
        type("sk-other", into: try field(at: 1, in: view))
        page.loadModels()
        XCTAssertTrue(waitUntil { !self.page.isLoadingModels })
        XCTAssertNil(page.modelsProblem)
        XCTAssertTrue(storedKeys.isEmpty, "\(storedKeys)")
        XCTAssertTrue(page.typedKeyIsPending)
        XCTAssertEqual(page.enteredKey, "sk-other")
    }

    /// A key the service turned down does not take the place of the one that is stored
    func testAKeyThatFailedTheTestIsNotStored() throws {
        settings.llmProvider = LLMProvider.openAI.id
        keysThere = [LLMProvider.openAI.id: "sk-old"]
        serviceAnswer = (401, [LLMHeader("Content-Type", "application/json")],
                         Data(#"{"error":{"message":"Incorrect API key provided"}}"#.utf8))
        let view = try showPage()
        type("sk-wrong", into: try field(at: 1, in: view))
        page.runTest()
        XCTAssertTrue(waitUntil { !self.page.isTesting })
        XCTAssertEqual(page.testOutcome?.failed, true)
        XCTAssertTrue(storedKeys.isEmpty, "\(storedKeys)")
        XCTAssertEqual(page.enteredKey, "sk-wrong")
    }

    /// Test with the stored key stores nothing
    func testATestWithTheStoredKeyStoresNothing() throws {
        settings.llmProvider = LLMProvider.openAI.id
        keysThere = [LLMProvider.openAI.id: "sk-old"]
        serviceAnswer = Self.chatReply("Hallo")
        _ = try showPage()
        page.runTest()
        XCTAssertTrue(waitUntil { !self.page.isTesting })
        XCTAssertEqual(page.testOutcome, .init(text: "Hallo", failed: false))
        XCTAssertTrue(storedKeys.isEmpty, "\(storedKeys)")
    }

    /// A key is stored, but macOS did not hand it out: "enter the key" would contradict
    /// "A key is stored in the keychain" right above it
    func testTestAndTheListSayWhenTheStoredKeyIsNotHandedOut() throws {
        settings.llmProvider = LLMProvider.openAI.id
        keysThere = [LLMProvider.openAI.id: nil as String?]
        _ = try showPage()
        XCTAssertTrue(page.hasStoredKey)
        let refused = TranslationEngines.failure(for: .apiKey, in: LLMConnection(provider: .openAI),
                                                 keyIsStored: true).message
        page.runTest()
        XCTAssertEqual(page.testOutcome, .init(text: refused, failed: true))
        page.loadModels()
        XCTAssertEqual(page.modelsProblem, refused)
    }

    /// Without a stored key the page still asks for one
    func testTestAsksForAKeyWhenNoneIsStored() throws {
        settings.llmProvider = LLMProvider.openAI.id
        _ = try showPage()
        let missing = TranslationEngines.failure(for: .apiKey, in: LLMConnection(provider: .openAI)).message
        page.runTest()
        XCTAssertEqual(page.testOutcome, .init(text: missing, failed: true))
        page.loadModels()
        XCTAssertEqual(page.modelsProblem, missing)
    }

    // MARK: Every way to store or remove a key

    /// What the user can do on the page that may store, replace or remove a key
    private enum KeyAction: String, CaseIterable {
        case save = "Save", pressReturn = "Return", remove = "Remove"
        case testThatWorks = "a Test that works", testThatFails = "a Test that fails"
        case listThatLoads = "Load the list, which works", listThatFails = "Load the list, which fails"
        case otherService = "another service", pageCloses = "the page closing"
        case windowNoLongerKey = "the window no longer key"
    }

    /// What the key field holds before the action
    private enum KeyField: String, CaseIterable {
        case empty, blank, filled

        var text: String {
            switch self {
            case .empty: return ""
            case .blank: return "   "
            case .filled: return "sk-typed"
            }
        }
    }

    /// What the key store must hold for the service after `action`. A stored key changes only
    /// when the user asks for it (Save or Return with a key in the field, Remove) or when a Test,
    /// a real request that needs the key, worked with the typed key. Load the list proves nothing:
    /// some services list their models to anyone. A typed key goes where no key is stored yet
    /// when the page or the service changes or the list loaded, so that it is not lost.
    private static func keyAfter(_ action: KeyAction, stored: String?, content: KeyField) -> String? {
        let typed = content == .filled ? content.text : nil
        switch action {
        case .save, .pressReturn, .testThatWorks: return typed ?? stored
        case .remove: return nil
        case .testThatFails, .listThatFails, .windowNoLongerKey: return stored
        case .listThatLoads, .otherService, .pageCloses: return stored ?? typed
        }
    }

    func testEveryWayToStoreOrRemoveAKey() throws {
        for action in KeyAction.allCases {
            for stored in ["sk-stored", nil] as [String?] {
                for content in KeyField.allCases {
                    try checkKey(after: action, stored: stored, content: content)
                }
            }
        }
    }

    private func checkKey(after action: KeyAction, stored: String?, content: KeyField) throws {
        let openAI = LLMProvider.openAI.id
        let label = "\(action.rawValue) with \(stored == nil ? "no key" : "a key") stored and a field that is \(content)"
        settings.llmProvider = openAI
        keysThere = stored.map { [openAI: $0] } ?? [:]
        storedKeys = []
        switch action {
        case .testThatWorks:
            serviceAnswer = Self.chatReply("Hallo")
        case .listThatLoads:
            serviceAnswer = (200, [LLMHeader("Content-Type", "application/json")],
                             Data(#"{"object":"list","data":[{"id":"gpt-6-luna"}]}"#.utf8))
        case .testThatFails, .listThatFails:
            serviceAnswer = (401, [LLMHeader("Content-Type", "application/json")],
                             Data(#"{"error":{"message":"Incorrect API key provided"}}"#.utf8))
        default:
            serviceAnswer = nil
        }
        let view = try showPage()
        defer {
            window?.contentView = nil
            window?.close()
            window = nil
            spin()
        }
        let keyField = try field(at: 1, in: view)
        XCTAssertTrue(keyField is NSSecureTextField, label)
        if content != .empty {
            type(content.text, into: keyField)
        }
        XCTAssertEqual(page.enteredKey, content.text, label)

        switch action {
        case .save:
            page.saveEnteredKey()
        case .pressReturn:
            window?.makeFirstResponder(keyField)
            spin()
            pressReturn(in: keyField)
        case .remove:
            page.removeKey()
        case .testThatWorks, .testThatFails:
            page.runTest()
            XCTAssertTrue(waitUntil { !self.page.isTesting }, label)
        case .listThatLoads, .listThatFails:
            page.loadModels()
            XCTAssertTrue(waitUntil { !self.page.isLoadingModels }, label)
        case .otherService:
            page.selectProvider(LLMProvider.anthropic.id)
        case .pageCloses:
            closePage()
        case .windowNoLongerKey:
            NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: window)
        }

        let expected = Self.keyAfter(action, stored: stored, content: content)
        let key = { self.keysThere[openAI] ?? nil }
        // Return goes through the field's action; a change shows once it has come through
        _ = waitUntil { key() == expected }
        spin()
        XCTAssertEqual(key(), expected, "\(label); stored: \(storedKeys)")
        XCTAssertEqual(Set(keysThere.keys).subtracting([openAI]), [], "\(label): another service got a key")

        // A typed key is never lost silently while no key is stored: it is stored, or the field
        // still holds it. Only a stored key lets the page drop it, and says so beforehand.
        if content == .filled, key() != content.text {
            if stored == nil || ![.otherService, .pageCloses].contains(action) {
                XCTAssertEqual(page.enteredKey, content.text, "\(label): the typed key was lost")
            }
        }
    }

    // MARK: Leaving the window

    /// Translate in the mirror window uses what the field shows, also when the settings window
    /// stays open: the field keeps its focus when another window becomes key
    func testWhatIsTypedIsAppliedWhenTheWindowIsNoLongerKey() throws {
        let view = try showPage()
        type("http://studio.local:11434", into: try field(at: 0, in: view))
        XCTAssertNil(settings.llmBaseURLs[LLMProvider.ollama.id])
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: window)
        XCTAssertTrue(waitUntil { self.settings.llmBaseURLs[LLMProvider.ollama.id] == "http://studio.local:11434" })
        XCTAssertEqual(changes, 1)
    }

    /// Another window that is no longer key is none of the page's business
    func testAnotherWindowResigningAppliesNothing() throws {
        let view = try showPage()
        type("http://studio.local:11434", into: try field(at: 0, in: view))
        let other = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: true)
        other.isReleasedWhenClosed = false
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: other)
        spin()
        XCTAssertNil(settings.llmBaseURLs[LLMProvider.ollama.id])
    }

    // MARK: Where the text goes

    /// The caption says where translating sends the text now, not where a half-typed address
    /// would send it once it is applied
    func testTheCaptionNamesTheAddressInUseWhileAnotherIsTyped() throws {
        settings.llmProvider = LLMProvider.custom.id
        settings.llmBaseURLs = [LLMProvider.custom.id: "https://api.example.com/v1"]
        let view = try showPage()
        XCTAssertEqual(page.serviceNotice, .remote("api.example.com"))

        let address = try field(at: 0, in: view)
        window?.makeFirstResponder(address)
        spin()
        (address.currentEditor() as? NSTextView)?.selectAll(nil)
        type("http://192.168.1.5:8080", into: address)
        XCTAssertEqual(page.addressDraft, "http://192.168.1.5:8080")
        XCTAssertEqual(page.serviceNotice, .remote("api.example.com"))

        pressReturn(in: address)
        XCTAssertTrue(waitUntil { self.page.serviceNotice == .local })
    }

    // MARK: Helpers

    private func showPage() throws -> NSView {
        let keys = TextSettingsView.KeyStore(hasKey: { [weak self] in self?.keysThere[$0] != nil },
                                             key: { [weak self] in self?.keysThere[$0] ?? nil },
                                             set: { [weak self] key, provider in
                                                 self?.storedKeys.append((key, provider))
                                                 // like the keychain: trimmed, and an empty key removes
                                                 let key = key?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                                                 self?.keysThere[provider] = key.isEmpty ? nil : .some(key)
                                                 return true
                                             })
        let answer = serviceAnswer
        let transport = ScriptedService { _ in
            guard let answer else { throw URLError(.notConnectedToInternet) }
            return answer
        }
        let page = TextSettingsView.Page(keys: keys, transport: transport)
        self.page = page
        let host = NSHostingView(rootView: TextSettingsView(page: page).frame(width: SettingsView.width, height: 700))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: SettingsView.width, height: 700),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        self.window = window
        window.makeKeyAndOrderFront(nil)
        XCTAssertTrue(waitUntil { self.textFields(in: host).count >= 2 }, "the fields of the page did not appear")
        return host
    }

    /// A reply of an OpenAI-style service whose model answers `content`
    private static func chatReply(_ content: String) -> LLMHTTPReply {
        let body: [String: Any] = ["choices": [["index": 0,
                                                "message": ["role": "assistant", "content": TranslationPrompt.user([content])],
                                                "finish_reason": "stop"]]]
        return (200, [LLMHeader("Content-Type", "application/json")],
                (try? JSONSerialization.data(withJSONObject: body)) ?? Data())
    }

    private func closePage() {
        window?.contentView = nil
        spin()
    }

    /// The editable fields of the page, from top to bottom
    private func textFields(in view: NSView) -> [NSTextField] {
        var fields: [NSTextField] = []
        func collect(_ view: NSView) {
            if let field = view as? NSTextField, field.isEditable { fields.append(field) }
            view.subviews.forEach(collect)
        }
        collect(view)
        return fields.sorted {
            $0.convert($0.bounds, to: nil).maxY > $1.convert($1.bounds, to: nil).maxY
        }
    }

    private func field(at index: Int, in view: NSView) throws -> NSTextField {
        let fields = textFields(in: view)
        return try XCTUnwrap(fields.indices.contains(index) ? fields[index] : nil,
                             "the page shows \(fields.count) fields")
    }

    /// Types like the keyboard does, one character at a time
    private func type(_ text: String, into field: NSTextField) {
        if field.currentEditor() == nil { window?.makeFirstResponder(field) }
        spin()
        guard let editor = field.currentEditor() as? NSTextView else {
            XCTFail("the field takes no input")
            return
        }
        for character in text {
            editor.insertText(String(character), replacementRange: editor.selectedRange())
            spin(0.01)
        }
        spin()
    }

    private func pressReturn(in field: NSTextField) {
        (field.currentEditor() as? NSTextView)?.insertNewline(nil)
        spin()
    }

    private func spin(_ seconds: TimeInterval = 0.1) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    private func waitUntil(_ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(5)
        while !condition() {
            if Date() > deadline { return false }
            spin(0.05)
        }
        return true
    }
}

/// Answers the page's requests instead of the network
private struct ScriptedService: LLMTransport {
    let answer: (LLMHTTPRequest) throws -> LLMHTTPReply

    func send(_ request: LLMHTTPRequest) async throws -> LLMHTTPReply {
        try answer(request)
    }
}

/// What the page says about where the text goes
final class TextSettingsServiceNoticeTests: XCTestCase {
    private func notice(_ provider: LLMProvider, address: String? = nil) -> TextSettingsView.ServiceNotice {
        TextSettingsView.serviceNotice(for: LLMConnection(provider: provider, baseURL: address, model: nil))
    }

    /// Without an address there is no server to name: "sent to Custom" says nothing
    func testACustomServerWithoutAnAddressIsNotNamedAfterTheService() {
        XCTAssertEqual(notice(.custom), .serverToEnter)
        XCTAssertEqual(notice(.custom, address: "  "), .serverToEnter)
    }

    func testOtherServicesAreNamed() {
        XCTAssertEqual(notice(.custom, address: "https://llm.example.com/v1"), .remote("llm.example.com"))
        XCTAssertEqual(notice(.openAI), .remote(LLMProvider.openAI.localizedName))
        XCTAssertEqual(notice(.azure), .remote(LLMProvider.azure.localizedName))
        XCTAssertEqual(notice(.ollama), .local)
        XCTAssertEqual(notice(.custom, address: "http://192.168.1.25:8080"), .local)
    }
}
