import AppKit
import SwiftUI
import UniformTypeIdentifiers

@main
struct FM1PocketApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var library = LibraryModel()
    @StateObject private var player = PlayerModel()

    init() {
        if let i = CommandLine.arguments.firstIndex(of: "--selftest-fwsc"), i + 1 < CommandLine.arguments.count {
            let out = i + 2 < CommandLine.arguments.count ? CommandLine.arguments[i + 2] : nil
            exit(SelfTest.runPackage(CommandLine.arguments[i + 1], writingTo: out))
        }
        if let i = CommandLine.arguments.firstIndex(of: "--integration"), i + 1 < CommandLine.arguments.count {
            let out = i + 2 < CommandLine.arguments.count ? CommandLine.arguments[i + 2] : nil
            exit(IntegrationTest.run(CommandLine.arguments[i + 1], writingTo: out))
        }
        if let i = CommandLine.arguments.firstIndex(of: "--selftest") {
            let out = i + 1 < CommandLine.arguments.count ? CommandLine.arguments[i + 1] : nil
            exit(SelfTest.run(writingTo: out))
        }
    }

    var body: some Scene {
        Window("FM-1 Pocket", id: "library") {
            ContentView()
                .environmentObject(library)
                .environmentObject(player)
                .frame(minWidth: 900, minHeight: 560)
                .onAppear { library.start() }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
                    player.stop()
                }
        }
        .defaultSize(width: 1180, height: 760)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .appInfo) {
                Button("Check for Firmware Updates…") { library.refresh() }
                Button("Clean Up Old Downloads") { library.cleanUp() }
            }
            SidebarCommands()
            ShowWindowCommands()
            CommandGroup(before: .sidebar) {
                Button("as Icons") { library.viewMode = .icons }.keyboardShortcut("1", modifiers: .command)
                Button("as List") { library.viewMode = .list }.keyboardShortcut("2", modifiers: .command)
                Divider()
            }
            CommandMenu("Firmware") {
                // an author's original update package on the emulator engine (fm1-emu)
                Button("Open Firmware Package (.fwsc)…") {
                    let panel = NSOpenPanel()
                    panel.allowedContentTypes = [.init(filenameExtension: "fwsc") ?? .data]
                    panel.allowsMultipleSelection = false
                    panel.message = "Choose an FM-1 update package (.fwsc) to play on the emulator engine."
                    if panel.runModal() == .OK, let url = panel.url { player.play(.package(url), library: library) }
                }
                .keyboardShortcut("o", modifiers: [.command, .shift])
                Divider()
                Button("Play") {
                    if let item = library.item(library.selection) { player.play(item, library: library) }
                }
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(!(library.item(library.selection)?.canPlay ?? false))
                Button("Stop") { player.stop() }
                    .keyboardShortcut(".", modifiers: .command)
                    .disabled(player.playingID == nil)
                Button("Power Cycle") { player.powerCycle() }
                    .keyboardShortcut("r", modifiers: .command)
                    .disabled(player.playingID == nil)
                Toggle("Mute", isOn: $player.muted)
                    .keyboardShortcut("m", modifiers: [.command, .option])
                Toggle("MIDI In", isOn: $player.midiEnabled)
                Picker("Controls", selection: $player.style) {
                    Text("Knobs").tag(ControlStyle.knobs)
                    Text("Sliders").tag(ControlStyle.sliders)
                }
                Button("Firmware Info") { NotificationCenter.default.post(name: .showFirmwareInfo, object: nil) }
                    .keyboardShortcut("i", modifiers: .command)
                    .disabled(player.playingID == nil)
                Divider()
                Button(library.item(library.selection).map { library.isFavourite($0) } == true ? "Remove from Favourites" : "Add to Favourites") {
                    if let item = library.item(library.selection) { library.toggleFavourite(item) }
                }
                .keyboardShortcut("d", modifiers: .command)
                .disabled(library.selection == nil)
                Button("Download Now") {
                    if let item = library.item(library.selection) { library.download(item) }
                }
                .disabled(library.item(library.selection).map { $0.isBuiltin || $0.isListedOnly || $0.download == .installed || $0.downloading } ?? true)
                Divider()
                Button("Show All Firmware") { library.section = .all }.keyboardShortcut("a", modifiers: [.command, .shift])
                Button("Show Favourites") { library.section = .favourites }.keyboardShortcut("f", modifiers: [.command, .shift])
                Button("Show Recently Played") { library.section = .recent }.keyboardShortcut("r", modifiers: [.command, .shift])
                Button("Show More Firmware") { library.section = .more }
                    .disabled(library.moreItems.isEmpty)
            }
        }

        // the player: its own window, so the library stays a library (the FM-1 faceplate is Milestone 3)
        Window("Player", id: "player") {
            PlayerWindow()
                .environmentObject(library)
                .environmentObject(player)
        }
        .windowResizability(.contentMinSize)
        .defaultSize(width: 1240, height: 860)
        .defaultPosition(.center)
    }
}

/// The player window: the FM-1 faceplate. Closing it stops the sound.
struct PlayerWindow: View {
    @EnvironmentObject var player: PlayerModel
    @State private var showInfo = false

    var body: some View {
        Group {
            if player.playingID != nil {
                PlayerView()
            } else if player.loadingID != nil {
                ProgressView("Starting…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView("Nothing Playing", systemImage: "pianokeys",
                                       description: Text("Choose a firmware in the library and press Play."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 640, minHeight: 440)
        .navigationTitle(player.playingID == nil ? "Player" : player.title)
        .toolbar {
            ToolbarItemGroup {
                Picker("Controls", selection: $player.style) {
                    Text("Knobs").tag(ControlStyle.knobs)
                    Text("Sliders").tag(ControlStyle.sliders)
                }
                .pickerStyle(.segmented)
                .help("Show the encoders as knobs or as sliders")
                Toggle(isOn: $player.midiEnabled) { Label("MIDI In", systemImage: "pianokeys") }
                    .help(player.midiEnabled ? "MIDI in is on: any connected MIDI keyboard plays the firmware" : "MIDI in is off")
                Toggle(isOn: $player.muted) { Label("Mute", systemImage: player.muted ? "speaker.slash.fill" : "speaker.wave.2.fill") }
                    .help(player.muted ? "Sound is muted" : "Mute the sound")
                Button { player.powerCycle() } label: { Label("Power Cycle", systemImage: "power") }
                    .help("Save, then switch the firmware off and on again")
                    .disabled(player.playingID == nil)
                Toggle(isOn: $showInfo) { Label("Firmware Info", systemImage: "info.circle") }
                    .help("About this firmware, its saved settings and its log")
            }
        }
        .inspector(isPresented: $showInfo) {
            FirmwareInfoPanel().inspectorColumnWidth(min: 260, ideal: 320, max: 440)
        }
        .background(WindowFrameKeeper(name: "FM1Pocket.Player") { player.playerWindow = $0 })
        .onReceive(NotificationCenter.default.publisher(for: .showFirmwareInfo)) { _ in showInfo.toggle() }
        .onDisappear { player.stop() }
    }
}

extension Notification.Name {
    static let showFirmwareInfo = Notification.Name("FM1Pocket.showFirmwareInfo")
}

/// About this firmware: its facts, credits and licences, its saved settings, and what it printed.
struct FirmwareInfoPanel: View {
    @EnvironmentObject var player: PlayerModel
    @State private var confirmErase = false

    var body: some View {
        let i = player.info
        Form {
            Section("About") {
                LabeledContent("Name", value: "\(i.name) \(i.version)")
                if !i.authors.isEmpty { LabeledContent("By", value: i.authors.joined(separator: ", ")) }
                LabeledContent("Licence", value: i.license)
                if let u = URL(string: Self.link(i.sourceURL)), !i.sourceURL.isEmpty {
                    LabeledContent("Source") { Link(i.sourceURL, destination: u).lineLimit(1).truncationMode(.middle) }
                }
                if let g = i.glueURL, let u = URL(string: Self.link(g)) {
                    LabeledContent("Build glue") { Link(g, destination: u).lineLimit(1).truncationMode(.middle) }
                }
                if let b = i.builtBy { LabeledContent("Built by", value: b) }
                LabeledContent("Core", value: i.core)
            }
            Section("Saved Settings") {
                Text("Saved for this exact build (\(i.buildKey)). Other versions keep their own.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("Export…") { export() }
                    Button("Import…") { importFile() }
                    Spacer()
                    Button("Erase…", role: .destructive) { confirmErase = true }
                }
            }
            if !i.credits.isEmpty {
                Section("Credits") {
                    ScrollView { Text(i.credits).font(.system(size: 11, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                        .frame(maxHeight: 220)
                }
            }
            if !i.licenses.isEmpty {
                Section("Licences") {
                    ForEach(Array(i.licenses.enumerated()), id: \.offset) { _, l in
                        DisclosureGroup(l.name) {
                            ScrollView { Text(l.text).font(.system(size: 11, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                                .frame(maxHeight: 220)
                        }
                    }
                }
            }
            Section("Log") {
                Text(player.log.isEmpty ? "Nothing yet." : player.log)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("Erase this firmware's saved settings?", isPresented: $confirmErase) {
            Button("Erase and Restart", role: .destructive) { player.eraseSavedSettings() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This deletes the settings saved for \(i.name) \(i.version) and starts it fresh. Settings saved by other versions are not touched. Export them first if you might want them back.")
        }
    }

    /// "https://github.com/a/b@<commit>" -> the GitHub page for that commit, as Pocket links it
    static func link(_ s: String) -> String {
        guard let at = s.lastIndex(of: "@"), s.hasPrefix("https://github.com/") else { return s }
        let commit = s[s.index(after: at)...]
        guard commit.count >= 7, commit.allSatisfy(\.isHexDigit) else { return s }
        return String(s[..<at]) + "/tree/" + commit
    }

    private func export() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(player.info.name) \(player.info.version) settings.flash"
        panel.message = "Save a copy of this firmware's settings"
        if panel.runModal() == .OK, let u = panel.url { player.exportSettings(to: u) }
    }

    private func importFile() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "Choose a settings file exported from \(player.info.name). The current settings are kept as a backup."
        if panel.runModal() == .OK, let u = panel.url { player.importSettings(from: u) }
    }
}

/// View › Show Library (⌘0) and Show Player (⌥⌘P): either window can be closed and brought back.
struct ShowWindowCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(before: .sidebar) {
            Button("Show Library") { openWindow(id: "library") }
                .keyboardShortcut("0", modifiers: .command)
            Button("Show Player") { openWindow(id: "player") }
                .keyboardShortcut("p", modifiers: [.command, .option])
            Divider()
        }
    }
}

/// Keeps the app running when its windows are closed, and brings the library back when the Dock icon is clicked.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { Self.perform(menuItem: "Show Library", in: NSApp.mainMenu) }
        return true
    }

    /// runs a menu command by its title (SwiftUI's menu items are ordinary AppKit menu items)
    @discardableResult
    static func perform(menuItem title: String, in menu: NSMenu?) -> Bool {
        guard let menu else { return false }
        for (i, item) in menu.items.enumerated() {
            if item.title == title, item.isEnabled {
                menu.performActionForItem(at: i)
                return true
            }
            if perform(menuItem: title, in: item.submenu) { return true }
        }
        return false
    }
}

/// Makes a window remember its position and size (on whichever screen it was left), via AppKit's frame autosave.
/// A remembered position that is no longer on any screen (a monitor was unplugged) is ignored. Also hands back the
/// window, for code that needs it.
struct WindowFrameKeeper: NSViewRepresentable {
    let name: String
    var found: ((NSWindow?) -> Void)?

    init(name: String, found: ((NSWindow?) -> Void)? = nil) {
        self.name = name
        self.found = found
    }

    func makeNSView(context: Context) -> KeeperView {
        let v = KeeperView()
        v.name = name
        v.found = found
        return v
    }
    func updateNSView(_ v: KeeperView, context: Context) { v.found = found }

    final class KeeperView: NSView {
        var name = ""
        var found: ((NSWindow?) -> Void)?
        private weak var configured: NSWindow?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            found?(window)
            guard let w = window, w !== configured else { return }
            configured = w
            let name = self.name
            // after SwiftUI has given the window its first size and place, put it back where it was left
            DispatchQueue.main.async {
                if w.setFrameUsingName(name) {
                    let onScreen = NSScreen.screens.contains { $0.visibleFrame.intersects(w.frame) }
                    if !onScreen { w.center() }
                }
                w.setFrameAutosaveName(name)
            }
        }
    }
}
