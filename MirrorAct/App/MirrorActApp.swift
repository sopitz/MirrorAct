// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import SwiftUI

@main
struct MirrorActApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        Window("MirrorAct", id: "launcher") {
            LauncherView()
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .commands { MirrorCommands() }

        Settings {
            SettingsView()
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        if let index = CommandLine.arguments.firstIndex(of: "--render-test") {
            let dir = CommandLine.arguments.count > index + 1 ? CommandLine.arguments[index + 1] : NSTemporaryDirectory()
            RenderTest.run(into: URL(fileURLWithPath: dir))
            RenderTest.recordTest(into: URL(fileURLWithPath: dir)) { exit(0) }
            return
        }
        Log.info("MirrorAct startet")
        MainActor.assumeIsolated { AppModel.shared.start() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { AppModel.shared.receiver.stop() }
    }
}

struct MirrorCommands: Commands {
    @ObservedObject private var settings = AppSettings.shared

    private var mirror: MirrorWindowController? { MainActor.assumeIsolated { AppModel.shared.keyMirror } }

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("iPhone oder iPad spiegeln …") { AppModel.shared.mirrorFirstAvailable() }
                .keyboardShortcut("n")
            Button("Screenshot oder Video bearbeiten …") { AppModel.shared.openEditorPanel() }
                .keyboardShortcut("e")
        }
        CommandMenu("Gerät") {
            Button("Screenshot sichern") { mirror?.session.saveScreenshot(withFrame: settings.showFrame) }
                .keyboardShortcut("s")
            Button("Screenshot kopieren") { mirror?.session.copyScreenshot(withFrame: settings.showFrame) }
                .keyboardShortcut("c", modifiers: [.command, .shift])
            Button("Video aufnehmen / beenden") {
                mirror?.session.toggleRecording()
            }
            .keyboardShortcut("r")
            Toggle("Aufnahme mit Gerätrahmen", isOn: $settings.recordWithFrame)
            Divider()
            Button("Grösser") { mirror?.zoomIn() }
                .keyboardShortcut("+")
            Button("Kleiner") { mirror?.zoomOut() }
                .keyboardShortcut("-")
            Button("Punktgenau (wie auf dem iPhone)") { mirror?.actualSize() }
                .keyboardShortcut("0")
            Button("Lebensgross") { mirror?.lifeSize() }
                .keyboardShortcut("1")
            Button("Pixelgenau") { mirror?.pixelPerfect() }
                .keyboardShortcut("2")
            Button("An Bildschirm anpassen") { mirror?.fitToScreen() }
                .keyboardShortcut("9")
            Divider()
            Button("Präsentieren") { mirror?.togglePresentation() }
                .keyboardShortcut("f", modifiers: [.command, .control])
            Button("Stil …") { mirror?.showStylePanel() }
                .keyboardShortcut("k")
            Toggle("Werkzeuge immer zeigen", isOn: $settings.alwaysShowTools)
            Toggle("Immer im Vordergrund", isOn: $settings.alwaysOnTop)
                .keyboardShortcut("t")
            Toggle("Gerätrahmen anzeigen", isOn: $settings.showFrame)
                .keyboardShortcut("f", modifiers: [.command, .shift])
            Toggle("Ton wiedergeben", isOn: Binding(
                get: { settings.playAudio },
                set: { value in
                    settings.playAudio = value
                    MainActor.assumeIsolated { AppModel.shared.keyMirror?.session.muted = !value }
                }))
        }
    }
}
