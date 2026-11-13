// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import SwiftUI
import Translation

/// Settings for “Text” and “Translate” in the mirror window: the language, and what translates
/// (this Mac, or a language model service with the user's own API key).
///
/// The API key goes straight into the keychain (`KeychainStore`); the field is emptied after
/// saving and the key is never shown again. A typed key is saved with Save, on Return, and as soon
/// as Test worked with it. When the list of models loaded, the service or the page changes, it is
/// saved too, but only for a service that has no key yet: a key that is stored is never replaced
/// without the user's doing.
struct TextSettingsView: View {
    @ObservedObject private var settings = AppSettings.shared

    /// Where the page keeps the API keys: the keychain; the tests give it one of their own, so
    /// that they never touch the user's keys
    struct KeyStore {
        var hasKey: (_ providerID: String) -> Bool
        /// the key itself; nil when there is none or macOS did not hand it out
        var key: (_ providerID: String) -> String?
        var set: (_ key: String?, _ providerID: String) -> Bool

        static let keychain = KeyStore(hasKey: { KeychainStore.hasKey(for: $0) },
                                       key: { KeychainStore.key(for: $0) },
                                       set: { KeychainStore.set($0, for: $1) })
    }

    /// what is typed, loaded and tested on the page, and what its buttons do
    @StateObject private var page: Page

    init(keys: KeyStore = .keychain) {
        _page = StateObject(wrappedValue: Page(keys: keys))
    }

    /// The page with a model the caller keeps, so that the tests can press its buttons
    init(page: Page) {
        _page = StateObject(wrappedValue: page)
    }

    /// the rows of the languages the Mac can translate into (loaded when the page appears)
    @State private var translationLanguages: [LanguageRow] = []

    @FocusState private var focusedField: Field?

    private enum Field: Hashable {
        case address, model
    }

    /// the language the app shows its own texts in
    private static var appLocale: Locale {
        Locale(identifier: Bundle.main.preferredLocalizations.first ?? "en")
    }

    var body: some View {
        Form {
            Section {
                Picker("Translate into", selection: $settings.translationLanguage) {
                    Text("System language").tag("system")
                    // while the list loads, the language chosen before keeps its row
                    if settings.translationLanguage != "system",
                       !translationLanguages.contains(where: { $0.id == settings.translationLanguage }) {
                        let chosen = Locale.Language(identifier: settings.translationLanguage)
                        Text(verbatim: Self.label(of: chosen, in: Self.appLocale, withRegion: chosen.region != nil))
                            .tag(settings.translationLanguage)
                    }
                    ForEach(translationLanguages) { row in
                        Text(verbatim: row.label).tag(row.id)
                    }
                }
                Picker("Translate with", selection: engineSelection) {
                    Text("This Mac (Apple)").tag("apple")
                    Text("Language model service (own API key)").tag("llm")
                }
            }
            if settings.translationEngine == "llm" {
                serviceSection
            }
            Section {
                Text("“Text” in the mirror window copies the text on the screen, “Translate” shows its translation in place, also while you scroll. With “This Mac”, both run on this Mac; macOS asks once before it downloads a language.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .task {
            let languages = await AppleTranslationAvailability.systemLanguages()
            translationLanguages = Self.languageRows(for: languages.all, onDevice: languages.onDevice,
                                                     in: Self.appLocale)
        }
        .onAppear { page.appear() }
        .onDisappear { page.disappear() }
        .onChange(of: focusedField) { page.commitDrafts() }
        // A field keeps its focus when another window becomes key: without this, Translate in
        // the mirror window would use the address of before while the field shows a new one
        .background(KeyWindowWatcher { page.commitDrafts() })
    }

    // MARK: The service

    @ViewBuilder
    private var serviceSection: some View {
        let provider = page.provider
        let notice = page.serviceNotice
        Section("Language model service") {
            Picker("Service", selection: providerSelection) {
                ForEach(LLMProvider.all) { provider in
                    Text(verbatim: provider.localizedName).tag(provider.id)
                }
            }
            Group {
                switch notice {
                case .local:
                    Text("Runs on this Mac or in your network; nothing is sent to the internet.")
                case .serverToEnter:
                    Text("The text recognized on the screen is sent to the server you enter here to be translated. Nothing is sent while translating is off.")
                        + Text(verbatim: " ") + Self.costNotice
                case .remote(let service):
                    Text("The text recognized on the screen is sent to \(service) to be translated. Nothing is sent while translating is off.")
                        + Text(verbatim: " ") + Self.costNotice
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            if provider.baseURLRule != .fixed {
                TextField("Address", text: $page.addressDraft, prompt: Text(verbatim: provider.baseURLExample))
                    .focused($focusedField, equals: .address)
                    .onSubmit { page.commitDrafts() }
            }

            LabeledContent("Model") {
                HStack {
                    TextField("Model", text: $page.modelDraft, prompt: Text(verbatim: provider.defaultModel))
                        .labelsHidden()
                        .focused($focusedField, equals: .model)
                        .onSubmit { page.commitDrafts() }
                    Menu("Models") {
                        ForEach(page.modelChoices, id: \.self) { model in
                            Button(model) { page.setModel(model) }
                        }
                    }
                    .disabled(page.modelChoices.isEmpty)
                    .fixedSize()
                }
            }
            HStack {
                if let modelsProblem = page.modelsProblem {
                    Text(verbatim: modelsProblem)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .help(modelsProblem)
                }
                Spacer()
                if page.isLoadingModels {
                    ProgressView().controlSize(.small)
                }
                Button("Load the list") { page.loadModels() }
                    .disabled(page.isLoadingModels)
            }

            if provider.needsAPIKey || provider.id == LLMProvider.custom.id {
                keyRows(for: provider)
            }

            HStack {
                Button("Test") { page.runTest() }
                    .disabled(page.isTesting)
                if page.isTesting {
                    ProgressView().controlSize(.small)
                }
                if let testOutcome = page.testOutcome {
                    Group {
                        if testOutcome.failed {
                            Text(verbatim: testOutcome.text)
                                .foregroundStyle(.red)
                        } else {
                            Text("Answer: \(testOutcome.text)")
                        }
                    }
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(testOutcome.text)
                }
                Spacer()
            }
        }
    }

    @ViewBuilder
    private func keyRows(for provider: LLMProvider) -> some View {
        SecureField("API key", text: $page.enteredKey)
            .onSubmit { page.saveEnteredKey() }
        HStack {
            Group {
                if let keyProblem = page.keyProblem {
                    Text(verbatim: keyProblem)
                        .foregroundStyle(.red)
                } else if page.typedKeyIsPending {
                    Text("Not saved yet: Save, Return or a Test that works replaces the stored key.")
                        .foregroundStyle(.secondary)
                } else if page.hasStoredKey {
                    Text("A key is stored in the keychain.")
                        .foregroundStyle(.secondary)
                } else if provider.needsAPIKey {
                    Text("No key is stored yet.")
                        .foregroundStyle(.secondary)
                } else {
                    Text("No key is stored; this service may not need one.")
                        .foregroundStyle(.secondary)
                }
            }
            .font(.caption)
            .lineLimit(2)
            Spacer()
            if let keyPage = URL(string: provider.keyPage), !provider.keyPage.isEmpty {
                Link("Get a key", destination: keyPage)
            }
            Button("Remove") { page.removeKey() }
                .disabled(!page.hasStoredKey)
            Button("Save") { page.saveEnteredKey() }
                .disabled(page.enteredKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    /// Where the page says the recognized text goes
    enum ServiceNotice: Equatable {
        /// to this Mac or the user's network
        case local
        /// to a server of the user's own whose address is not entered yet
        case serverToEnter
        /// to the service or host named
        case remote(String)
    }

    /// Translate sends new text whenever it comes into view, and a service bills each request
    private static let costNotice = Text("The service may charge your account for each request: the more new text comes into view, the more it costs.")

    static func serviceNotice(for connection: LLMConnection) -> ServiceNotice {
        if connection.isLocal { return .local }
        // a server of one's own is named by its host; before there is one, "Custom" would be
        // the name, which tells nothing about where the text goes
        if connection.provider.id == LLMProvider.custom.id, LLMConnection.host(of: connection.baseURL).isEmpty {
            return .serverToEnter
        }
        return .remote(LLMTranslationEngine.name(for: connection))
    }

    // MARK: Bindings

    private var engineSelection: Binding<String> {
        Binding(get: { settings.translationEngine == "llm" ? "llm" : "apple" },
                set: { settings.translationEngine = $0 })
    }

    private var providerSelection: Binding<String> {
        Binding(get: { page.provider.id }, set: { page.selectProvider($0) })
    }

    /// One row of “Translate into”
    struct LanguageRow: Identifiable, Equatable {
        /// the language's minimal identifier, as the settings keep it
        let id: String
        let label: String
        /// only Apple's models that need Apple Intelligence translate into it (macOS 26.4 and later)
        var needsAppleIntelligence = false
    }

    /// The rows for the languages Translation offers, in the order of their labels. Most of them
    /// come in several regions ("en", "en-GB", "en-IN" …): those are told apart by the region, a
    /// language that comes once keeps its plain name. A language that is not in `onDevice`, the
    /// list of the models that work without Apple Intelligence, says that it needs it; nil = one
    /// kind of models (before macOS 26.4).
    static func languageRows(for languages: [Locale.Language], onDevice: [Locale.Language]? = nil,
                             in locale: Locale) -> [LanguageRow] {
        let withoutAppleIntelligence = onDevice.map { Set($0.map(LanguageMatching.key)) }
        var seen = Set<String>()
        let unique = languages.filter { seen.insert($0.minimalIdentifier).inserted }
        var count: [String: Int] = [:]
        for language in unique {
            count[LanguageMatching.name(of: language, in: locale), default: 0] += 1
        }
        return unique
            .map { language in
                let shared = count[LanguageMatching.name(of: language, in: locale), default: 0] > 1
                let label = label(of: language, in: locale, withRegion: shared)
                guard let withoutAppleIntelligence,
                      !withoutAppleIntelligence.contains(LanguageMatching.key(language)) else {
                    return LanguageRow(id: language.minimalIdentifier, label: label)
                }
                return LanguageRow(id: language.minimalIdentifier,
                                   label: String(localized: "\(label) – needs Apple Intelligence"),
                                   needsAppleIntelligence: true)
            }
            .sorted { $0.label.compare($1.label, locale: locale) == .orderedAscending }
    }

    /// "German", or with the region "German (Switzerland)"
    private static func label(of language: Locale.Language, in locale: Locale, withRegion: Bool) -> String {
        let name = LanguageMatching.name(of: language, in: locale)
        guard withRegion, let region = language.region?.identifier,
              let place = locale.localizedString(forRegionCode: region) else { return name }
        return "\(name) (\(place))"
    }
}

extension TextSettingsView {
    /// What the page holds besides the settings themselves: what is typed and not applied yet,
    /// the models loaded and the outcome of Test, and what its buttons do
    @MainActor
    final class Page: ObservableObject {
        private let settings: AppSettings
        private let keys: KeyStore
        /// what Test and Load the list send their requests over; nil = the network
        private let transport: LLMTransport?

        init(settings: AppSettings = .shared, keys: KeyStore = .keychain, transport: LLMTransport? = nil) {
            self.settings = settings
            self.keys = keys
            self.transport = transport
        }

        /// a key that is being typed and is not stored yet
        @Published var enteredKey = ""
        @Published private(set) var hasStoredKey = false
        /// what became of the last Save or Remove, when it did not work
        @Published private(set) var keyProblem: String?

        @Published private(set) var loadedModels: [String] = []
        @Published private(set) var modelsProblem: String?
        @Published private(set) var isLoadingModels = false

        /// What is typed into Address and Model. It goes into the settings on Return, when the
        /// field is left and when the page goes away: every change there makes a running
        /// translation start over, and a half-typed address would get the screen's text and the key.
        @Published var addressDraft = ""
        @Published var modelDraft = ""

        @Published private(set) var testOutcome: Outcome?
        @Published private(set) var isTesting = false

        /// the request of “Load the list” or “Test” that is on its way
        private var work: Task<Void, Never>?

        struct Outcome: Equatable {
            let text: String
            let failed: Bool
        }

        var provider: LLMProvider {
            TranslationEngines.llmProvider(id: settings.llmProvider)
        }

        /// Where the caption says the recognized text goes: where translating sends it now, so
        /// from the settings, not from an address that is being typed and not applied yet. Its
        /// key is not needed, so the keychain (which may make macOS ask the user) is left alone.
        var serviceNotice: ServiceNotice {
            TextSettingsView.serviceNotice(for: LLMConnection(provider: provider,
                                                              baseURL: settings.llmBaseURLs[provider.id],
                                                              model: settings.llmModels[provider.id]))
        }

        /// The models the app suggests, then those the service listed
        var modelChoices: [String] {
            let known = provider.knownModels
            return known + loadedModels.filter { !known.contains($0) }
        }

        func appear() {
            loadDrafts()
            refreshKeyState()
        }

        func disappear() {
            commitDrafts()
            keepTypedKey()
            stopWork()
        }

        /// Another service: what was typed, loaded or tested belongs to the one before
        func selectProvider(_ id: String) {
            guard id != provider.id else { return }
            stopWork()
            commitDrafts()
            keepTypedKey()
            settings.llmProvider = id
            loadDrafts()
            enteredKey = ""
            keyProblem = nil
            loadedModels = []
            modelsProblem = nil
            testOutcome = nil
            refreshKeyState()
        }

        /// A model picked from the menu counts at once
        func setModel(_ model: String) {
            modelDraft = model
            commitDrafts()
        }

        /// The address and model of the service as they are set up
        private func loadDrafts() {
            addressDraft = settings.llmBaseURLs[provider.id] ?? ""
            modelDraft = settings.llmModels[provider.id] ?? ""
        }

        /// Puts what is typed into the settings; a value that is already there is not written
        /// again, so that leaving a field unchanged does not make translating start over
        func commitDrafts() {
            let id = provider.id
            let address = Self.stored(addressDraft), model = Self.stored(modelDraft)
            // assigned only on a change: each assignment publishes, even of the same value
            if provider.baseURLRule != .fixed, settings.llmBaseURLs[id] != address {
                settings.llmBaseURLs[id] = address
            }
            if settings.llmModels[id] != model {
                settings.llmModels[id] = model
            }
        }

        /// what a field's text is stored as; nil for an empty field
        private static func stored(_ text: String) -> String? {
            let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? nil : value
        }

        // MARK: The key

        /// Save, and Return in the key field. An empty field saves nothing, like the disabled Save
        /// button: storing an empty key removes the stored one, which may exist nowhere else.
        func saveEnteredKey() {
            guard !enteredKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            storeKey(enteredKey)
        }

        /// Removes the stored key. A key that is typed and not saved stays in the field: with no
        /// key stored, dropping it would lose it without a word.
        func removeKey() {
            guard hasStoredKey else { return }
            let typed = enteredKey
            storeKey(nil)
            enteredKey = typed
        }

        private func refreshKeyState() {
            hasStoredKey = keys.hasKey(provider.id)
        }

        private func storeKey(_ key: String?) {
            let stored = keys.set(key, provider.id)
            if stored {
                keyProblem = nil
            } else if key == nil {
                keyProblem = String(localized: "The key could not be removed from the keychain.")
            } else {
                keyProblem = String(localized: "The key could not be stored in the keychain. It is used until MirrorAct quits.")
            }
            enteredKey = ""
            testOutcome = nil
            refreshKeyState()
        }

        /// A key is typed while one is stored: it replaces that one only on Save, Return or a
        /// Test that works
        var typedKeyIsPending: Bool {
            hasStoredKey && !enteredKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }

        /// When the page or the service changes, a key typed for a service without one is saved,
        /// so that it is not lost. A key that is stored stays: the typed one may have been pasted
        /// while the wrong service was shown, and the stored one may exist nowhere else.
        private func keepTypedKey() {
            guard !enteredKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !keys.hasKey(provider.id) else { return }
            storeKey(enteredKey)
        }

        /// A typed key that the service just accepted counts at once: the user would otherwise
        /// see Test work and Translate ask for the key. Only while the field still holds that key
        /// and the service is the same.
        private func keepWorkingKey(_ key: String, for providerID: String) {
            guard !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  enteredKey == key, provider.id == providerID else { return }
            storeKey(key)
        }

        // MARK: Requests

        private func stopWork() {
            work?.cancel()
            work = nil
            isLoadingModels = false
            isTesting = false
        }

        /// The service with what is entered on the page; a typed key that is not saved yet
        /// counts. Like `TranslationEngines.llmConnection`, but with the page's key store.
        private func enteredConnection() -> LLMConnection {
            let entered = enteredKey.trimmingCharacters(in: .whitespacesAndNewlines)
            return LLMConnection(provider: provider, baseURL: settings.llmBaseURLs[provider.id],
                                 model: settings.llmModels[provider.id],
                                 apiKey: entered.isEmpty ? keys.key(provider.id) : entered)
        }

        /// What the user still has to enter, as translating would say it. A key that is stored
        /// but that macOS did not hand out is not "missing": the page says it is stored. A typed
        /// key is never such a key.
        private func failureMessage(for missing: LLMMissingSetting, in connection: LLMConnection) -> String {
            let keyIsStored = missing == .apiKey
                && enteredKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && keys.hasKey(provider.id)
            return TranslationEngines.failure(for: missing, in: connection, keyIsStored: keyIsStored).message
        }

        func loadModels() {
            stopWork()
            commitDrafts()
            modelsProblem = nil
            let connection = enteredConnection()
            // the list needs no model; the address and the key it does need
            if let missing = connection.missing, missing != .model {
                modelsProblem = failureMessage(for: missing, in: connection)
                return
            }
            isLoadingModels = true
            let transport = self.transport, typed = enteredKey
            work = Task { @MainActor in
                let engine = LLMTranslationEngine(connection: connection, transport: transport)
                defer { engine.cancel() }
                do {
                    let models = try await engine.models()
                    guard !Task.isCancelled else { return }
                    // The list proves nothing about the key: some services list their models to
                    // anyone, so it takes the place of no stored key. For a service without one
                    // it is kept, as it would be when the page closes.
                    if !keys.hasKey(connection.provider.id) {
                        keepWorkingKey(typed, for: connection.provider.id)
                    }
                    loadedModels = models
                    if models.isEmpty {
                        modelsProblem = String(localized: "The service lists no models for translating.")
                    }
                } catch {
                    guard !Task.isCancelled else { return }
                    modelsProblem = error.localizedDescription
                }
                isLoadingModels = false
            }
        }

        func runTest() {
            stopWork()
            commitDrafts()
            testOutcome = nil
            let connection = enteredConnection()
            if let missing = connection.missing {
                testOutcome = Outcome(text: failureMessage(for: missing, in: connection), failed: true)
                return
            }
            let target = settings.translationTarget
            isTesting = true
            let transport = self.transport, typed = enteredKey
            work = Task { @MainActor in
                let engine = LLMTranslationEngine(connection: connection, transport: transport)
                defer { engine.cancel() }
                do {
                    let translation = try await engine.test("Hello", into: target)
                    guard !Task.isCancelled else { return }
                    // before the outcome: storing the key clears it
                    keepWorkingKey(typed, for: connection.provider.id)
                    testOutcome = Outcome(text: translation, failed: false)
                } catch {
                    guard !Task.isCancelled else { return }
                    testOutcome = Outcome(text: error.localizedDescription, failed: true)
                }
                isTesting = false
            }
        }
    }
}

/// Calls `resigned` when the window it is in is no longer the key window
private struct KeyWindowWatcher: NSViewRepresentable {
    let resigned: () -> Void

    func makeNSView(context: Context) -> WatcherView {
        WatcherView()
    }

    func updateNSView(_ view: WatcherView, context: Context) {
        view.resigned = resigned
    }

    final class WatcherView: NSView {
        var resigned: () -> Void = {}
        private var observer: NSObjectProtocol?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let observer { NotificationCenter.default.removeObserver(observer) }
            observer = nil
            guard let window else { return }
            observer = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification,
                                                              object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.resigned() }
            }
        }

        deinit {
            if let observer { NotificationCenter.default.removeObserver(observer) }
        }
    }
}
