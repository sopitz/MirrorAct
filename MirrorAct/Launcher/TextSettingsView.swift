// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI
import Translation

/// Settings for “Text” and “Translate” in the mirror window: the language, and what translates
/// (this Mac, or a language model service with the user's own API key).
///
/// The API key goes straight into the keychain (`KeychainStore`); the field is emptied after
/// saving and the key is never shown again. A typed key is saved with Save, on Return, and when
/// the service or the page changes, so that one Test worked with is not lost.
struct TextSettingsView: View {
    @ObservedObject private var settings = AppSettings.shared

    /// Where the page keeps the API keys: the keychain; the tests give it one of their own, so
    /// that they never touch the user's keys
    struct KeyStore {
        var hasKey: (_ providerID: String) -> Bool
        var set: (_ key: String?, _ providerID: String) -> Bool

        static let keychain = KeyStore(hasKey: { KeychainStore.hasKey(for: $0) },
                                       set: { KeychainStore.set($0, for: $1) })
    }

    private let keys: KeyStore

    init(keys: KeyStore = .keychain) {
        self.keys = keys
    }

    /// languages the Mac can translate into (loaded when the page appears)
    @State private var translationLanguages: [Locale.Language] = []

    /// a key that is being typed and is not stored yet
    @State private var enteredKey = ""
    @State private var hasStoredKey = false
    /// what became of the last Save or Remove, when it did not work
    @State private var keyProblem: String?

    @State private var loadedModels: [String] = []
    @State private var modelsProblem: String?
    @State private var isLoadingModels = false

    /// What is typed into Address and Model. It goes into the settings on Return, when the
    /// field is left and when the page goes away: every change there makes a running translation
    /// start over, and a half-typed address would get the screen's text and the key.
    @State private var addressDraft = ""
    @State private var modelDraft = ""
    @FocusState private var focusedField: Field?

    private enum Field: Hashable {
        case address, model
    }

    @State private var testOutcome: Outcome?
    @State private var isTesting = false

    /// the request of “Load the list” or “Test” that is on its way
    @State private var work: Task<Void, Never>?

    private struct Outcome: Equatable {
        let text: String
        let failed: Bool
    }

    /// the language the app shows its own texts in
    private static var appLocale: Locale {
        Locale(identifier: Bundle.main.preferredLocalizations.first ?? "en")
    }

    private var provider: LLMProvider {
        TranslationEngines.llmProvider(id: settings.llmProvider)
    }

    /// The service as it is set up, without asking the keychain (that may make macOS ask the
    /// user); for what the page shows
    private var shownConnection: LLMConnection {
        LLMConnection(provider: provider, baseURL: addressDraft, model: modelDraft)
    }

    var body: some View {
        Form {
            Section {
                Picker("Translate into", selection: $settings.translationLanguage) {
                    Text("System language").tag("system")
                    // while the list loads, the language chosen before keeps its row
                    if settings.translationLanguage != "system",
                       !translationLanguages.contains(where: { $0.minimalIdentifier == settings.translationLanguage }) {
                        Text(verbatim: Self.name(of: Locale.Language(identifier: settings.translationLanguage)))
                            .tag(settings.translationLanguage)
                    }
                    ForEach(translationLanguages, id: \.minimalIdentifier) { language in
                        Text(verbatim: Self.name(of: language)).tag(language.minimalIdentifier)
                    }
                }
                Picker("Translate with", selection: engineSelection) {
                    Text("This Mac (Apple)").tag("apple")
                    Text("A language model service, with your own API key").tag("llm")
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
            let languages = await LanguageAvailability().supportedLanguages
            translationLanguages = languages.sorted {
                Self.name(of: $0).localizedCompare(Self.name(of: $1)) == .orderedAscending
            }
        }
        .onAppear {
            loadDrafts()
            refreshKeyState()
        }
        .onDisappear {
            commitDrafts()
            storeEnteredKey()
            stopWork()
        }
        .onChange(of: focusedField) { commitDrafts() }
    }

    // MARK: The service

    @ViewBuilder
    private var serviceSection: some View {
        let provider = self.provider
        let connection = shownConnection
        let service = LLMTranslationEngine.name(for: connection)
        Section("Language model service") {
            Picker("Service", selection: providerSelection) {
                ForEach(LLMProvider.all) { provider in
                    Text(verbatim: provider.localizedName).tag(provider.id)
                }
            }
            Group {
                if connection.isLocal {
                    Text("Runs on this Mac or in your network; nothing is sent to the internet.")
                } else {
                    Text("The text recognized on the screen is sent to \(service) to be translated. Nothing is sent while translating is off.")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            if provider.baseURLRule != .fixed {
                TextField("Address", text: $addressDraft, prompt: Text(verbatim: provider.baseURLExample))
                    .focused($focusedField, equals: .address)
                    .onSubmit { commitDrafts() }
            }

            LabeledContent("Model") {
                HStack {
                    TextField("Model", text: $modelDraft, prompt: Text(verbatim: provider.defaultModel))
                        .labelsHidden()
                        .focused($focusedField, equals: .model)
                        .onSubmit { commitDrafts() }
                    Menu("Models") {
                        ForEach(modelChoices, id: \.self) { model in
                            Button(model) { setModel(model) }
                        }
                    }
                    .disabled(modelChoices.isEmpty)
                    .fixedSize()
                }
            }
            HStack {
                if let modelsProblem {
                    Text(verbatim: modelsProblem)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .help(modelsProblem)
                }
                Spacer()
                if isLoadingModels {
                    ProgressView().controlSize(.small)
                }
                Button("Load the list") { loadModels() }
                    .disabled(isLoadingModels)
            }

            if provider.needsAPIKey || provider.id == LLMProvider.custom.id {
                keyRows(for: provider)
            }

            HStack {
                Button("Test") { runTest() }
                    .disabled(isTesting)
                if isTesting {
                    ProgressView().controlSize(.small)
                }
                if let testOutcome {
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
        SecureField("API key", text: $enteredKey)
            .onSubmit { storeEnteredKey() }
        HStack {
            Group {
                if let keyProblem {
                    Text(verbatim: keyProblem)
                        .foregroundStyle(.red)
                } else if hasStoredKey {
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
            if let page = URL(string: provider.keyPage), !provider.keyPage.isEmpty {
                Link("Get a key", destination: page)
            }
            Button("Remove") { storeKey(nil) }
                .disabled(!hasStoredKey)
            Button("Save") { storeKey(enteredKey) }
                .disabled(enteredKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    // MARK: Bindings

    private var engineSelection: Binding<String> {
        Binding(get: { settings.translationEngine == "llm" ? "llm" : "apple" },
                set: { settings.translationEngine = $0 })
    }

    /// Another service: what was typed, loaded or tested belongs to the one before
    private var providerSelection: Binding<String> {
        Binding(get: { provider.id }, set: { id in
            guard id != provider.id else { return }
            stopWork()
            commitDrafts()
            storeEnteredKey()
            settings.llmProvider = id
            loadDrafts()
            enteredKey = ""
            keyProblem = nil
            loadedModels = []
            modelsProblem = nil
            testOutcome = nil
            refreshKeyState()
        })
    }

    /// A model picked from the menu counts at once
    private func setModel(_ model: String) {
        modelDraft = model
        commitDrafts()
    }

    /// The address and model of the service as they are set up
    private func loadDrafts() {
        addressDraft = settings.llmBaseURLs[provider.id] ?? ""
        modelDraft = settings.llmModels[provider.id] ?? ""
    }

    /// Puts what is typed into the settings; a value that is already there is not written again,
    /// so that leaving a field unchanged does not make translating start over
    private func commitDrafts() {
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

    /// The models the app suggests, then those the service listed
    private var modelChoices: [String] {
        let known = provider.knownModels
        return known + loadedModels.filter { !known.contains($0) }
    }

    // MARK: Actions

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

    /// Saves a key that was typed and not saved yet, for the service shown
    private func storeEnteredKey() {
        guard !enteredKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        storeKey(enteredKey)
    }

    private func stopWork() {
        work?.cancel()
        work = nil
        isLoadingModels = false
        isTesting = false
    }

    /// The service with what is entered on the page; a typed key that is not saved yet counts
    private func enteredConnection() -> LLMConnection {
        TranslationEngines.llmConnection(for: settings, enteredKey: enteredKey)
    }

    private func loadModels() {
        stopWork()
        commitDrafts()
        modelsProblem = nil
        let connection = enteredConnection()
        // the list needs no model; the address and the key it does need
        if let missing = connection.missing, missing != .model {
            modelsProblem = TranslationEngines.failure(for: missing, in: connection).message
            return
        }
        isLoadingModels = true
        work = Task { @MainActor in
            let engine = LLMTranslationEngine(connection: connection)
            defer { engine.cancel() }
            do {
                let models = try await engine.models()
                guard !Task.isCancelled else { return }
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

    private func runTest() {
        stopWork()
        commitDrafts()
        testOutcome = nil
        let connection = enteredConnection()
        if let missing = connection.missing {
            testOutcome = Outcome(text: TranslationEngines.failure(for: missing, in: connection).message, failed: true)
            return
        }
        let target = settings.translationTarget
        isTesting = true
        work = Task { @MainActor in
            let engine = LLMTranslationEngine(connection: connection)
            defer { engine.cancel() }
            do {
                let translation = try await engine.test("Hello", into: target)
                guard !Task.isCancelled else { return }
                testOutcome = Outcome(text: translation, failed: false)
            } catch {
                guard !Task.isCancelled else { return }
                testOutcome = Outcome(text: error.localizedDescription, failed: true)
            }
            isTesting = false
        }
    }

    private static func name(of language: Locale.Language) -> String {
        LanguageMatching.name(of: language, in: appLocale)
    }
}
