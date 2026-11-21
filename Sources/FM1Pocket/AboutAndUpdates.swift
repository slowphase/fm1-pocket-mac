import AppKit
import PocketKit
import SwiftUI

// MARK: - About (credits and licences)

/// The standard About window, with the credits: who made the app, The Firmware Hub's credit as its terms ask (credit
/// line linked, licence linked), the engines and their licences, and the independence statement.
enum AboutPanel {
    static func show(attribution: CatalogueV2.Attribution?) {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits(attribution)])
    }

    static func credits(_ hub: CatalogueV2.Attribution?) -> NSAttributedString {
        let out = NSMutableAttributedString()
        let centred = NSMutableParagraphStyle()
        centred.alignment = .center
        centred.paragraphSpacing = 6
        let base: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.labelColor,
                                                   .paragraphStyle: centred]
        func text(_ s: String) { out.append(NSAttributedString(string: s, attributes: base)) }
        func bold(_ s: String) {
            var a = base; a[.font] = NSFont.boldSystemFont(ofSize: 11)
            out.append(NSAttributedString(string: s, attributes: a))
        }
        func link(_ s: String, _ url: String?) {
            guard let url, let u = URL(string: url) else { return text(s) }
            var a = base; a[.link] = u
            out.append(NSAttributedString(string: s, attributes: a))
        }

        text("Made by slowphase · "); link("suprlab.net", "https://www.suprlab.net/"); text("\n\n")

        bold("Firmware\n")
        text("Every firmware is the work of its makers and keeps its own licence. Each firmware's details link to its maker and source.\n")
        link(hub?.text ?? "Firmware list: The Firmware Hub – thefirmwarehub.com", hub?.url ?? "https://thefirmwarehub.com/")
        text(", licensed ")
        link(hub?.license ?? "CC BY 4.0", hub?.licenseUrl ?? "https://creativecommons.org/licenses/by/4.0/")
        text(".")
        if let c = hub?.changes, !c.isEmpty { text(" " + c) }
        text("\n\n")

        bold("Engines\n")
        text("Original packages run on "); link("fm1-emu", "https://github.com/joakimeriksson/fm1-emu")
        text(" by Joakim Eriksson (MIT).\n")
        link(".rfm1", "https://github.com/Quixotic7/RemoteFM1FW"); text(" builds come from RemoteFM1FW by Michael P Jones (Quixotic7).\n")
        text("The .rfm1 engine is a port of Jake Handy's "); link("FM-1 Browser Simulator", "https://github.com/jakehandy/fm1-browser-simulator")
        text(" (MIT), with his "); link("h1", "https://github.com/jakehandy/h1"); text(" built in (MIT), running on ")
        link("wasm3", "https://github.com/wasm3/wasm3"); text(" (MIT).\n\n")

        text("FM-1 Pocket is an independent community project, not affiliated with or endorsed by M-VAVE. Its own code is MIT licensed. ")
        link("Third-party notices", Bundle.main.url(forResource: "THIRD-PARTY-NOTICES", withExtension: "md")?.absoluteString
             ?? "https://github.com/slowphase/fm1-pocket-mac/blob/main/THIRD-PARTY-NOTICES.md")
        text(".")
        return out
    }
}

// MARK: - Check for Firmware Updates

/// FM-1 Pocket › Check for Firmware Updates…: starts a check and opens the small update window.
struct CheckForUpdatesButton: View {
    @ObservedObject var library: LibraryModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Check for Firmware Updates…") {
            library.refresh()
            openWindow(id: UpdateCheckView.windowID)
        }
    }
}

/// A small window in the style of an app's "You're up to date" check: the icon, what happened, and OK.
struct UpdateCheckView: View {
    static let windowID = "update-check"
    @EnvironmentObject var library: LibraryModel
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        let m = message
        VStack(alignment: .leading, spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 64, height: 64)
            Text(m.title).font(.headline)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                if library.isRefreshing { ProgressView().controlSize(.small) }
                Text(m.body).fixedSize(horizontal: false, vertical: true)
            }
            .help(m.detail ?? "")
            Button { dismissWindow(id: Self.windowID) } label: { Text("OK").frame(maxWidth: .infinity) }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
                .padding(.top, 6)
        }
        .padding(20)
        .frame(width: 280)
    }

    private var message: (title: String, body: String, detail: String?) {
        let offline = library.counts.map { " \($0.readyOffline) firmware\($0.readyOffline == 1 ? " is" : "s are") available offline." } ?? ""
        switch library.updateCheck {
        case .idle, .checking:
            return ("Checking for updates…", "Looking for new and updated firmware.", nil)
        case .upToDate:
            return ("You're up to date!", "Your library has the newest firmware." + offline, nil)
        case .updated(let d, let f, let w):
            var parts: [String] = []
            if d > 0 { parts.append("\(d) new or updated firmware \(d == 1 ? "is" : "are") ready to play.") }
            if f > 0 { parts.append("\(f) couldn't be downloaded. FM-1 Pocket will try again next time.") }
            if w > 0 { parts.append("\(w) no longer listed. Your copies still play.") }
            return (f > 0 && d == 0 ? "Some firmware didn't download" : "Library updated", parts.joined(separator: " "), nil)
        case .offline(let e):
            return ("Couldn't check for updates",
                    "FM-1 Pocket can't reach the firmware library right now. Your downloaded firmware still plays.", e)
        }
    }
}

// MARK: - Sidebar footer

/// The library sidebar's footer: the library's state, and how much is available offline. Long forms give way to
/// short or stacked ones in a narrow sidebar, so nothing is cut off.
struct LibraryFooter: View {
    @EnvironmentObject var library: LibraryModel

    var body: some View {
        let s = library.footerStatus
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 5) {
                if library.isRefreshing { ProgressView().controlSize(.mini) }
                ViewThatFits(in: .horizontal) {
                    Text(s.text)
                    Text(s.short)
                }
            }
            .help(s.detail ?? "")
            if let c = library.counts {
                ViewThatFits(in: .horizontal) {
                    Text(c.footerLine)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(c.offlineText)
                        if let m = c.moreText { Text(m) }
                    }
                }
            }
        }
        .lineLimit(1)
        .font(.caption)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

/// The Firmware Hub's credit, as its terms ask: the credit line linked to the Hub, the licence linked, and what
/// FM-1 Pocket changed (shown under a firmware the Hub lists).
struct HubCredit: View {
    let attribution: CatalogueV2.Attribution

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            if let u = URL(string: attribution.url) { Link(attribution.text, destination: u) } else { Text(attribution.text) }
            HStack(spacing: 3) {
                Text("Licence:")
                if let l = attribution.licenseUrl, let u = URL(string: l) { Link(attribution.license, destination: u) }
                else { Text(attribution.license) }
            }
        }
        .help(attribution.changes ?? "")
    }
}
