import PocketKit
import SwiftUI

/// Milestone 1's player: the firmware's own 240x240 screen, its 14 buttons (lit by its LEDs), the seven encoders and
/// the 27 keys. Plain controls on purpose; the FM-1 faceplate is Milestone 3.
struct PlayerView: View {
    @EnvironmentObject var player: PlayerModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 20) {
                Group {
                    if let img = player.screen {
                        Image(decorative: img, scale: 1).resizable().interpolation(.none)
                    } else {
                        Color.black
                    }
                }
                .frame(width: 360, height: 360)
                .background(Color.black)
                .clipShape(RoundedRectangle(cornerRadius: 6))

                VStack(alignment: .leading, spacing: 10) {
                    Text(player.title).font(.headline)
                    Grid(horizontalSpacing: 6, verticalSpacing: 6) {
                        GridRow { ForEach(FM1Button.allCases.prefix(7)) { b in PanelButton(button: b) } }
                        GridRow { ForEach(FM1Button.allCases.suffix(7)) { b in PanelButton(button: b) } }
                    }
                    Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 4) {
                        ForEach(FM1Encoder.allCases) { e in
                            GridRow {
                                Text(e.label).font(.caption).foregroundStyle(.secondary)
                                Button { player.turn(e, -1) } label: { Image(systemName: "chevron.left") }
                                Button { player.turn(e, 1) } label: { Image(systemName: "chevron.right") }
                            }
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
            Keybed()
            Text("Computer keys: A W S E D F … play notes · Z / X octave · ← → presets · ↑ ↓ algorithm · , . select · 1–4 knobs (Shift turns down)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

/// A button that sends press and release separately (the firmware cares how long it is held), tinted by its LED.
private struct PanelButton: View {
    @EnvironmentObject var player: PlayerModel
    let button: FM1Button
    @State private var down = false

    var body: some View {
        let lit = Double(player.leds?.buttons[Int(button.rawValue)] ?? 0) / 255
        Text(player.buttonNames[Int(button.rawValue)])
            .font(.system(size: 10, weight: .semibold, design: .rounded))
            .lineLimit(1)
            .minimumScaleFactor(0.6)
            .frame(width: 52, height: 30)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(down ? Color.accentColor.opacity(0.5) : Color(nsColor: .controlColor))
            )
            .overlay(RoundedRectangle(cornerRadius: 6).fill(Color.orange.opacity(lit * 0.6)))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.4)))
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in if !down { down = true; player.button(button, down: true) } }
                    .onEnded { _ in down = false; player.button(button, down: false) }
            )
            .accessibilityLabel(player.buttonNames[Int(button.rawValue)])
            .accessibilityAddTraits(.isButton)
    }
}

/// 27 keys, chromatic from C (key 0), as the FM-1's keybed.
private struct Keybed: View {
    @EnvironmentObject var player: PlayerModel
    private static let black: Set<Int> = [1, 3, 6, 8, 10]

    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<FirmwareCore.keyCount, id: \.self) { k in
                let isBlack = Self.black.contains(k % 12)
                let held = player.heldKeys.contains(k)
                let lit = Double(player.leds?.keys[k] ?? 0) / 255
                RoundedRectangle(cornerRadius: 3)
                    .fill(held ? Color.accentColor : (isBlack ? Color(white: 0.15) : Color(white: 0.95)))
                    .overlay(RoundedRectangle(cornerRadius: 3).fill(Color.orange.opacity(lit * 0.5)))
                    .overlay(RoundedRectangle(cornerRadius: 3).stroke(Color.secondary.opacity(0.5)))
                    .frame(width: 22, height: isBlack ? 56 : 72, alignment: .top)
                    .frame(height: 72, alignment: .top)
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { _ in player.key(k, down: true) }
                            .onEnded { _ in player.key(k, down: false) }
                    )
            }
        }
    }
}
