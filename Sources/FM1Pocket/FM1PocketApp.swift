import AppKit
import SwiftUI

@main
struct FM1PocketApp: App {
    @StateObject private var library = LibraryModel()
    @StateObject private var player = PlayerModel()

    init() {
        if let i = CommandLine.arguments.firstIndex(of: "--selftest") {
            let out = i + 1 < CommandLine.arguments.count ? CommandLine.arguments[i + 1] : nil
            exit(SelfTest.run(writingTo: out))
        }
    }

    var body: some Scene {
        WindowGroup("FM-1 Pocket", id: "library") {
            ContentView()
                .environmentObject(library)
                .environmentObject(player)
                .frame(minWidth: 820, minHeight: 560)
                .onAppear { library.start() }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
                    player.stop()
                }
        }
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Firmware Updates…") { library.refresh() }
                Button("Clean Up Old Downloads") { library.cleanUp() }
            }
            CommandMenu("Player") {
                Button("Play Selected Firmware") {
                    if let item = library.item(library.selection) { player.play(item, library: library) }
                }
                .keyboardShortcut(.return, modifiers: .command)
                Button("Stop") { player.stop() }
                    .keyboardShortcut(".", modifiers: .command)
                    .disabled(player.playingID == nil)
            }
        }
    }
}
