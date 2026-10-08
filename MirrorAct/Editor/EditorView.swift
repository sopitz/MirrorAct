// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import AVKit
import SwiftUI

/// Editor für Screenshots (auch Duo) und Bildschirmaufnahmen
struct EditorView: View {
    @ObservedObject var document: EditorDocument
    @State private var trimRequest = 0

    var body: some View {
        HStack(spacing: 0) {
            previewArea
                .frame(minWidth: 480, maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            sidebar
                .frame(width: 340)
        }
        .frame(minHeight: 620)
    }

    // MARK: Vorschau

    @ViewBuilder
    private var previewArea: some View {
        VStack(spacing: 0) {
            ZStack {
                if document.isVideo {
                    PlayerView(player: document.player, trimRequest: trimRequest)
                } else {
                    Checkerboard()
                    if let image = document.preview {
                        Image(decorative: image, scale: 1)
                            .resizable()
                            .interpolation(.high)
                            .scaledToFit()
                            .padding(24)
                            .onDrag { dragProvider() }
                    }
                }
            }
            Divider()
            bottomBar
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
        }
    }

    private var bottomBar: some View {
        HStack(spacing: 10) {
            if let progress = document.exportProgress {
                ProgressView(value: progress)
                    .frame(width: 160)
                Text("Exporting …").foregroundStyle(.secondary)
            } else if let message = document.message {
                Text(message).foregroundStyle(.secondary).lineLimit(1)
            } else {
                Text(document.isVideo
                     ? String(localized: "Trim with “Trim …”; the preview shows half resolution.")
                     : String(localized: "Drag the image out to share it, or save/copy it."))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            if !document.isVideo {
                Button("Copy") { document.copy() }
            }
            ShareButton(document: document)
                .frame(width: 34, height: 24)
            Button(document.isVideo ? String(localized: "Save Video …") : String(localized: "Save …")) { document.save() }
                .keyboardShortcut("s")
                .buttonStyle(.borderedProminent)
                .disabled(document.exportProgress != nil)
        }
        .font(.system(size: 12))
    }

    private func dragProvider() -> NSItemProvider {
        let provider = NSItemProvider()
        provider.registerFileRepresentation(forTypeIdentifier: "public.png", fileOptions: [], visibility: .all) { completion in
            Task { @MainActor in
                let url = await document.temporaryExport()
                completion(url, false, url == nil ? CocoaError(.fileWriteUnknown) : nil)
            }
            return nil
        }
        return provider
    }

    // MARK: Seitenleiste

    private var sidebar: some View {
        Form {
            if document.isDuo {
                Section("Duo") {
                    Picker("Pose", selection: $document.pose) {
                        ForEach(DuoPose.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                }
            }
            Section("Model") {
                Picker("Device", selection: $document.modelSelection) {
                    Text("Automatic (by resolution)").tag("auto")
                    Divider()
                    ForEach(DeviceProfile.selectableModels, id: \.id) { model in
                        Text(model.name).tag(model.id)
                    }
                }
            }
            StyleControls(style: $document.style, showFrame: $document.showFrame)
            if document.isVideo {
                Section("Video") {
                    Button("Trim …") { trimRequest += 1 }
                    if let source = document.videoSource {
                        LabeledContent("Source", value: "\(Int(source.size.width)) × \(Int(source.size.height)), \(Self.duration(source.duration))")
                    }
                    Text(VideoFramer.needsAlpha(style: document.style, showFrame: document.showFrame)
                         ? String(localized: "Export: HEVC with transparency (.mov)")
                         : String(localized: "Export: H.264 (.mov), up to 4K"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Section {
                Button("Use as Default") { document.adoptAsDefault() }
            }
        }
        .formStyle(.grouped)
    }

    private static func duration(_ time: CMTime) -> String {
        let seconds = Int(time.seconds.rounded())
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

/// AVPlayerView mit eingebauter Kürzen-Funktion
struct PlayerView: NSViewRepresentable {
    let player: AVPlayer
    let trimRequest: Int

    final class Coordinator { var handledTrim = 0 }
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.player = player
        view.controlsStyle = .inline
        view.showsFullScreenToggleButton = false
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        if trimRequest != context.coordinator.handledTrim {
            context.coordinator.handledTrim = trimRequest
            if view.canBeginTrimming { view.beginTrimming(completionHandler: nil) }
        }
    }
}

/// Teilen-Menü von macOS (exportiert vorher in eine temporäre Datei)
struct ShareButton: NSViewRepresentable {
    let document: EditorDocument

    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(image: NSImage(systemSymbolName: "square.and.arrow.up", accessibilityDescription: String(localized: "Share"))!,
                              target: context.coordinator, action: #selector(Coordinator.share(_:)))
        button.bezelStyle = .rounded
        button.toolTip = String(localized: "Share")
        return button
    }

    func updateNSView(_ nsView: NSButton, context: Context) {
        context.coordinator.document = document
    }

    func makeCoordinator() -> Coordinator { Coordinator(document: document) }

    final class Coordinator: NSObject {
        var document: EditorDocument
        init(document: EditorDocument) { self.document = document }

        @objc func share(_ sender: NSButton) {
            Task { @MainActor in
                guard let url = await document.temporaryExport() else { return }
                NSSharingServicePicker(items: [url]).show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
            }
        }
    }
}

/// Fenster für einen Editor
@MainActor
final class EditorWindowController: NSWindowController, NSWindowDelegate {
    let editorDocument: EditorDocument
    var onClose: (() -> Void)?

    init(document: EditorDocument) {
        self.editorDocument = document
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1120, height: 740),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = String(localized: "Edit – \(document.title)")
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: EditorView(document: document))
        window.setContentSize(NSSize(width: 1120, height: 740))
        super.init(window: window)
        window.delegate = self
        window.center()
    }

    required init?(coder: NSCoder) { fatalError() }

    func windowWillClose(_ notification: Notification) {
        editorDocument.player.pause()
        onClose?()
    }
}
