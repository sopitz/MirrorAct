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
    /// what the page stored as keys, by service; nil = removed
    private var storedKeys: [(key: String?, provider: String)] = []

    override func setUp() {
        super.setUp()
        saved = (settings.translationEngine, settings.llmProvider, settings.llmModels, settings.llmBaseURLs)
        settings.translationEngine = "llm"
        settings.llmProvider = LLMProvider.ollama.id
        settings.llmModels = [:]
        settings.llmBaseURLs = [:]
        changes = 0
        storedKeys = []
        subscription = settings.translationSettingsChanged.sink { [weak self] in self?.changes += 1 }
    }

    override func tearDown() {
        subscription = nil
        window?.contentView = nil
        window?.close()
        window = nil
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

    // MARK: Helpers

    private func showPage() throws -> NSView {
        let keys = TextSettingsView.KeyStore(hasKey: { _ in false },
                                             set: { [weak self] key, provider in
                                                 self?.storedKeys.append((key, provider))
                                                 return true
                                             })
        let host = NSHostingView(rootView: TextSettingsView(keys: keys).frame(width: SettingsView.width, height: 700))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: SettingsView.width, height: 700),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        self.window = window
        window.makeKeyAndOrderFront(nil)
        XCTAssertTrue(waitUntil { self.textFields(in: host).count >= 2 }, "the fields of the page did not appear")
        return host
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
