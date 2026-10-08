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
        #if DEBUG
        if let index = CommandLine.arguments.firstIndex(of: "--showcase") {
            let dir = CommandLine.arguments.count > index + 1 ? CommandLine.arguments[index + 1] : NSTemporaryDirectory()
            MainActor.assumeIsolated { Showcase.export(to: URL(fileURLWithPath: dir)) }
            exit(0)
        }
        MainActor.assumeIsolated { Showcase.install() }
        #endif
        Log.info("MirrorAct starting")
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
            Button("Mirror iPhone or iPad …") { AppModel.shared.mirrorFirstAvailable() }
                .keyboardShortcut("n")
            Button("Edit Screenshot or Video …") { AppModel.shared.openEditorPanel() }
                .keyboardShortcut("e")
        }
        CommandMenu("Device") {
            Button("Save Screenshot") { mirror?.session.saveScreenshot(withFrame: settings.showFrame) }
                .keyboardShortcut("s")
            Button("Copy Screenshot") { mirror?.session.copyScreenshot(withFrame: settings.showFrame) }
                .keyboardShortcut("c", modifiers: [.command, .shift])
            Button("Start / Stop Recording") {
                mirror?.session.toggleRecording()
            }
            .keyboardShortcut("r")
            Toggle("Record with Device Frame", isOn: $settings.recordWithFrame)
            Divider()
            Button("Larger") { mirror?.zoomIn() }
                .keyboardShortcut("+")
            Button("Smaller") { mirror?.zoomOut() }
                .keyboardShortcut("-")
            Button("Point-Perfect (as on the iPhone)") { mirror?.actualSize() }
                .keyboardShortcut("0")
            Button("Life-Size") { mirror?.lifeSize() }
                .keyboardShortcut("1")
            Button("Pixel-Perfect") { mirror?.pixelPerfect() }
                .keyboardShortcut("2")
            Button("Fit to Screen") { mirror?.fitToScreen() }
                .keyboardShortcut("9")
            Divider()
            Button("Present") { mirror?.togglePresentation() }
                .keyboardShortcut("f", modifiers: [.command, .control])
            Button("Style …") { mirror?.showStylePanel() }
                .keyboardShortcut("k")
            Toggle("Always Show Tools", isOn: $settings.alwaysShowTools)
            Toggle("Keep on Top", isOn: $settings.alwaysOnTop)
                .keyboardShortcut("t")
            Toggle("Show Device Frame", isOn: $settings.showFrame)
                .keyboardShortcut("f", modifiers: [.command, .shift])
            Toggle("Play Sound", isOn: Binding(
                get: { settings.playAudio },
                set: { value in
                    settings.playAudio = value
                    MainActor.assumeIsolated { AppModel.shared.keyMirror?.session.muted = !value }
                }))
        }
    }
}
