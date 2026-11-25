import AppKit
import PocketKit
import SwiftUI

/// The player: the FM-1 faceplate, drawn the way FM-1 Pocket Player draws it (src/style.css), scaled to the window.
/// Encoders and MASTER on the left, the screen in the middle, the four knobs and twelve buttons on the right, the
/// 27 keys (F to G) below.
struct PlayerView: View {
    @EnvironmentObject var player: PlayerModel

    var body: some View {
        VStack(spacing: 0) {
            if let key = player.otherBuildSettings { SettingsOffer(key: key) }
            GeometryReader { geo in
                let s = max(0.3, min(geo.size.width / Face.width, geo.size.height / Face.height))
                Faceplate()
                    .environment(\.faceScale, s)
                    .frame(width: Face.width * s, height: Face.height * s)
                    .position(x: geo.size.width / 2, y: geo.size.height / 2)
            }
            .padding(14)
            Footer()
        }
        .background(Face.bg)
        .foregroundStyle(Face.text)
    }
}

// MARK: - measurements and colours (Pocket's style.css)

enum Face {
    static let width: CGFloat = 1180
    static let height: CGFloat = 726
    static let pad: CGFloat = 22
    static let leftW: CGFloat = 236
    static let rightW: CGFloat = 320
    static let gap: CGFloat = 24
    static let glass: CGFloat = 532          // 480 screen + 26 padding each side
    static let keysH: CGFloat = 132

    static let bg = hex(0x0c0c0e)
    static let panel = hex(0x18181b)
    static let line = hex(0x2e2e33)
    static let text = hex(0xe9e9ec)
    static let dim = hex(0x8f8f98)
    static let key = hex(0xecece6)
    static let keyBlack = hex(0x111113)
    static let bodyTop = hex(0x1c1c20)
    static let body = hex(0x151518)
    static let playGreen = hex(0x4dff7a)

    static func hex(_ v: UInt32) -> Color { PlayerModel.color(rgb: v) }
    static func mono(_ size: CGFloat, _ weight: Font.Weight = .semibold, _ s: CGFloat) -> Font {
        .system(size: size * s, weight: weight, design: .monospaced)
    }
}

private struct FaceScaleKey: EnvironmentKey { static let defaultValue: CGFloat = 1 }
extension EnvironmentValues {
    /// the faceplate's scale: every size on it is multiplied by this, so it stays sharp at any window size
    var faceScale: CGFloat {
        get { self[FaceScaleKey.self] }
        set { self[FaceScaleKey.self] = newValue }
    }
}

// MARK: - the faceplate

private struct Faceplate: View {
    @EnvironmentObject var player: PlayerModel
    @Environment(\.faceScale) private var s

    var body: some View {
        VStack(spacing: Face.pad * s) {
            HStack(alignment: .center, spacing: Face.gap * s) {
                LeftColumn().frame(width: Face.leftW * s)
                Glass()
                RightColumn().frame(width: Face.rightW * s)
            }
            .frame(height: Face.glass * s)
            Keybed().frame(height: Face.keysH * s)
        }
        .padding(.horizontal, Face.pad * s)
        .padding(.top, Face.pad * s)
        .padding(.bottom, 18 * s)
        .background(plate(shape: RoundedRectangle(cornerRadius: 22 * s)))
    }

    private func plate(shape: RoundedRectangle) -> some View {
        ZStack {
            LinearGradient(colors: [Face.bodyTop, Face.body], startPoint: .top, endPoint: .bottom)
            if let img = player.skinImage {                     // the firmware's own skin, dimmed for the labels
                Image(nsImage: img).resizable().aspectRatio(contentMode: .fill)
                Face.body.opacity(player.skinDim)
            }
        }
        .clipShape(shape)
        .overlay(shape.stroke(Face.line, lineWidth: 1))
        .shadow(color: .black.opacity(0.8), radius: 30 * s, y: 30 * s)
    }
}

private struct LeftColumn: View {
    @EnvironmentObject var player: PlayerModel
    @Environment(\.faceScale) private var s

    var body: some View {
        VStack(spacing: 8 * s) {
            // as on the FM-1: MASTER and SELECT on top, PRESETS and ALGORITHM below, OCT− and OCT+ under them
            if player.style == .knobs {
                Grid(horizontalSpacing: 10 * s, verticalSpacing: 12 * s) {
                    GridRow { ControlView(role: 7); ControlView(role: 0) }
                    GridRow { ControlView(role: 2); ControlView(role: 1) }
                }
            } else {
                ForEach([7, 0, 2, 1], id: \.self) { ControlView(role: $0) }
            }
            HStack(spacing: 10 * s) {
                PanelButton(button: .octDown)
                PanelButton(button: .octUp)
            }
            .padding(.top, 6 * s)
        }
    }
}

private struct RightColumn: View {
    @EnvironmentObject var player: PlayerModel
    @Environment(\.faceScale) private var s

    var body: some View {
        VStack(spacing: 16 * s) {
            if player.style == .knobs {
                HStack(spacing: 10 * s) { ForEach(3...6, id: \.self) { ControlView(role: $0) } }
            } else {
                VStack(spacing: 8 * s) { ForEach(3...6, id: \.self) { ControlView(role: $0) } }
            }
            Grid(horizontalSpacing: 8 * s, verticalSpacing: 8 * s) {
                GridRow { ForEach(FM1Button.allCases.prefix(6)) { PanelButton(button: $0) } }
                GridRow { ForEach(FM1Button.allCases.dropFirst(6).prefix(6)) { PanelButton(button: $0) } }
            }
        }
    }
}

// MARK: - the screen

private struct Glass: View {
    @EnvironmentObject var player: PlayerModel
    @Environment(\.faceScale) private var s

    var body: some View {
        ZStack {
            if let img = player.screen {
                Image(decorative: img, scale: 1).resizable().interpolation(.none)
            } else {
                Color.black
            }
            if let msg = player.haltMessage {
                VStack(spacing: 12 * s) {
                    Text(msg).multilineTextAlignment(.center)
                    Button("Power On Again") { player.powerCycle() }
                }
                .font(Face.mono(13, .regular, s))
                .padding(16 * s)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.black.opacity(0.85))
            }
        }
        .frame(width: 480 * s, height: 480 * s)
        .padding(26 * s)
        .background(RoundedRectangle(cornerRadius: 14 * s).fill(Color.black))
        .overlay(RoundedRectangle(cornerRadius: 14 * s).stroke(Face.hex(0x26262b), lineWidth: 1))
        .accessibilityLabel("FM-1 screen")
    }
}

// MARK: - encoders and MASTER

/// One control: its printed name, the firmware's name for it now, its value, and a knob or a slider.
private struct ControlView: View {
    @EnvironmentObject var player: PlayerModel
    @Environment(\.faceScale) private var s
    let role: Int

    private var printed: String { role == 7 ? "MASTER" : (FM1Encoder(rawValue: Int32(role))?.label ?? "") }

    var body: some View {
        let c = player.controls[role]
        let name = c.name.isEmpty || c.name == printed ? "" : c.name
        Group {
            if player.style == .knobs {
                VStack(spacing: 2 * s) {
                    Text(printed).font(Face.mono(10, .regular, s)).foregroundStyle(Face.dim).lineLimit(1)
                    Text(name.isEmpty ? " " : name).font(Face.mono(12, .semibold, s)).lineLimit(1)
                    Text(c.text.isEmpty ? " " : c.text).font(Face.mono(12, .semibold, s)).foregroundStyle(player.ink).lineLimit(1)
                    Dial(role: role, state: c)
                }
                .frame(maxWidth: .infinity)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(alignment: .firstTextBaseline, spacing: 8 * s) {
                        Text(printed).font(Face.mono(10, .regular, s)).foregroundStyle(Face.dim)
                        Text(name).font(Face.mono(12, .semibold, s))
                        Spacer(minLength: 0)
                        Text(c.text).font(Face.mono(12, .semibold, s)).foregroundStyle(player.ink)
                    }
                    .lineLimit(1)
                    HStack(spacing: 6 * s) {
                        if role < 7 { Nudge(role: role, step: -1, glyph: "‹") }
                        ControlSlider(role: role, state: c)
                        if role < 7 { Nudge(role: role, step: 1, glyph: "›") }
                    }
                }
            }
        }
        .modifier(ScrollToTurn(role: role))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(printed + (name.isEmpty ? "" : ", \(name)"))
        .accessibilityValue(c.text)
        .accessibilityAdjustableAction { dir in
            let d = dir == .increment ? 1 : -1
            if c.absolute { player.setValue(role, c.value + d * (role == 7 ? 32 : 1)) } else { player.turn(role, d) }
        }
    }
}

/// A knob: drag up or down (or scroll) to turn it. With a value (sim1 or MASTER) the arc shows where it is and a drag
/// sets it; otherwise it is an endless encoder and every few points of drag is one click.
private struct Dial: View {
    @EnvironmentObject var player: PlayerModel
    @Environment(\.faceScale) private var s
    let role: Int
    let state: ControlState
    @State private var startValue = 0
    @State private var acc: CGFloat = 0
    @State private var dragging = false
    @State private var angle: Double = 0                     // for endless encoders: turns with each click

    private let sweep = Double.pi * 0.75

    /// where the mark points, in radians from straight up
    private var angleNow: Double {
        guard state.absolute else { return angle }
        let span = Double(state.hi - state.lo)
        let t: Double = span > 0 ? Double(state.value - state.lo) / span : 0
        return -sweep + t * 2 * sweep
    }

    var body: some View {
        let a = angleNow
        let ink = player.ink
        let absolute = state.absolute
        let active = dragging
        let sw = sweep
        return Canvas { ctx, size in
            Self.draw(ctx, size: size, angle: a, sweep: sw, absolute: absolute, active: active, ink: ink)
        }
        .frame(width: 64 * s, height: 64 * s)
        .contentShape(Circle())
        .gesture(drag)
        .onHover { inside in if inside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() } }
    }

    private var drag: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { g in
                if !dragging { dragging = true; startValue = state.value; acc = 0 }
                let dy: CGFloat = -g.translation.height / s
                if state.absolute {
                    let span = Double(state.hi - state.lo)
                    let raw: Double = Double(startValue) + Double(dy) * span / 180
                    let nv = max(state.lo, min(state.hi, Int(raw.rounded())))
                    if nv != state.value { player.setValue(role, nv) }
                } else {
                    let steps = Int((dy - acc) / 8)
                    if steps != 0 {
                        acc += CGFloat(steps) * 8
                        player.turn(role, steps)
                        angle += Double(steps) * Double.pi / 12
                    }
                }
            }
            .onEnded { _ in dragging = false }
    }

    /// the knob as Pocket's SVG draws it, in a 64-unit box
    private static func draw(_ ctx: GraphicsContext, size: CGSize, angle a: Double, sweep: Double, absolute: Bool,
                             active: Bool, ink: Color) {
        let u: CGFloat = size.width / 64
        let c = CGPoint(x: size.width / 2, y: size.height / 2)
        func arc(_ from: Double, _ to: Double) -> Path {
            var p = Path()
            p.addArc(center: c, radius: 27 * u, startAngle: .radians(from - Double.pi / 2),
                     endAngle: .radians(to - Double.pi / 2), clockwise: false)
            return p
        }
        func point(_ r: CGFloat) -> CGPoint {
            CGPoint(x: c.x + CGFloat(sin(a)) * r * u, y: c.y - CGFloat(cos(a)) * r * u)
        }
        let line = StrokeStyle(lineWidth: 5 * u, lineCap: .round)
        if absolute {
            ctx.stroke(arc(-sweep, sweep), with: .color(Face.hex(0x0a0a0b)), style: line)
            if a > -sweep + 0.001 { ctx.stroke(arc(-sweep, a), with: .color(ink), style: line) }
        }
        let rect = CGRect(x: c.x - 21 * u, y: c.y - 21 * u, width: 42 * u, height: 42 * u)
        let knob = Path(ellipseIn: rect)
        let shade = Gradient(colors: [Face.hex(0x5a5a62), Face.hex(0x26262b)])
        ctx.fill(knob, with: .radialGradient(shade, center: CGPoint(x: c.x - 7 * u, y: c.y - 9 * u), startRadius: 0, endRadius: 33 * u))
        ctx.stroke(knob, with: .color(active ? ink : Color.black), lineWidth: 1.5 * u)
        var mark = Path()
        mark.move(to: point(8))
        mark.addLine(to: point(18))
        ctx.stroke(mark, with: .color(ink), style: StrokeStyle(lineWidth: 3 * u, lineCap: .round))
    }
}

/// A slider. With a value it jumps straight to it; otherwise it turns the encoder as far as it is dragged and springs
/// back to the middle, as in Pocket.
private struct ControlSlider: View {
    @EnvironmentObject var player: PlayerModel
    @Environment(\.faceScale) private var s
    let role: Int
    let state: ControlState
    @State private var jog: Double = 0                       // -12...12 while a relative slider is held
    @State private var sent = 0

    /// 0...1 along the track
    private var position: Double {
        if !state.absolute { return (jog + 12) / 24 }
        let span = Double(state.hi - state.lo)
        return span > 0 ? Double(state.value - state.lo) / span : 0
    }

    var body: some View {
        GeometryReader { geo in
            let w: CGFloat = geo.size.width
            let thumb: CGFloat = 26 * s
            let x: CGFloat = thumb / 2 + CGFloat(position) * (w - thumb)
            ZStack(alignment: .leading) {
                Capsule().fill(Face.hex(0x0a0a0b)).frame(height: 10 * s)
                    .overlay(Capsule().stroke(Color.black, lineWidth: 1))
                let from: CGFloat = state.absolute ? thumb / 2 : min(x, w / 2)
                let to: CGFloat = state.absolute ? x : max(x, w / 2)
                Capsule().fill(player.ink).frame(width: max(0, to - from), height: 10 * s).offset(x: from)
                if !state.absolute {
                    // an endless knob: a mark at the middle, where it rests between turns
                    Rectangle().fill(Face.dim).frame(width: 2 * s, height: 18 * s).offset(x: w / 2 - s)
                }
                Circle()
                    .fill(RadialGradient(colors: [Face.hex(0x5a5a62), Face.hex(0x26262b)], center: UnitPoint(x: 0.35, y: 0.3), startRadius: 0, endRadius: thumb * 0.7))
                    .overlay(Circle().stroke(Color.black, lineWidth: 1))
                    .frame(width: thumb, height: thumb)
                    .offset(x: x - thumb / 2)
                    .shadow(color: .black.opacity(0.6), radius: 3 * s, y: 3 * s)
            }
            .frame(height: geo.size.height)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        let along: CGFloat = (g.location.x - thumb / 2) / max(1, w - thumb)
                        let p = Double(max(0, min(1, along)))
                        if state.absolute {
                            let span = Double(state.hi - state.lo)
                            let nv = state.lo + Int((p * span).rounded())
                            if nv != state.value { player.setValue(role, nv) }
                        } else {
                            jog = (p * 24 - 12).rounded()
                            let target = Int(jog)
                            if target != sent { player.turn(role, target - sent); sent = target }
                        }
                    }
                    .onEnded { _ in jog = 0; sent = 0 }
            )
        }
        .frame(height: 36 * s)
        .help(state.absolute ? "Drag to set it" : "Endless knob: drag left or right to turn it; it springs back to the middle. The firmware keeps the setting.")
    }
}

/// ‹ › : one click each, repeating while held.
private struct Nudge: View {
    @EnvironmentObject var player: PlayerModel
    @Environment(\.faceScale) private var s
    let role: Int
    let step: Int
    let glyph: String
    @State private var timer: Timer?

    var body: some View {
        Text(glyph)
            .font(Face.mono(15, .semibold, s))
            .foregroundStyle(timer != nil ? player.ink : Face.dim)
            .frame(width: 30 * s, height: 32 * s)
            .background(RoundedRectangle(cornerRadius: 8 * s).fill(LinearGradient(colors: [Face.hex(0x303035), Face.hex(0x232327)], startPoint: .top, endPoint: .bottom)))
            .overlay(RoundedRectangle(cornerRadius: 8 * s).stroke(Color.black, lineWidth: 1))
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        guard timer == nil else { return }
                        player.turn(role, step)
                        let r = role, st = step, p = player
                        let t = Timer(timeInterval: 0.38, repeats: false) { _ in
                            MainActor.assumeIsolated {
                                let rep = Timer(timeInterval: 0.1, repeats: true) { _ in MainActor.assumeIsolated { p.turn(r, st) } }
                                RunLoop.main.add(rep, forMode: .common)
                                self.timer = rep
                            }
                        }
                        RunLoop.main.add(t, forMode: .common)
                        timer = t
                    }
                    .onEnded { _ in timer?.invalidate(); timer = nil }
            )
            .onDisappear { timer?.invalidate() }
    }
}

/// Scrolling over a control turns it (one click per notch, or per few points on a trackpad).
private struct ScrollToTurn: ViewModifier {
    @EnvironmentObject var player: PlayerModel
    let role: Int

    func body(content: Content) -> some View {
        content.onHover { inside in
            if inside { ScrollRouter.shared.target = (role, player) } else if ScrollRouter.shared.target?.0 == role { ScrollRouter.shared.target = nil }
        }
    }
}

/// Sends scroll-wheel events in the player window to the control under the pointer.
@MainActor
final class ScrollRouter {
    static let shared = ScrollRouter()
    var target: (Int, PlayerModel)?
    private var monitor: Any?
    private var acc: CGFloat = 0

    private init() {
        monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] ev in
            MainActor.assumeIsolated {
                guard let self, let (role, player) = self.target, ev.window === player.playerWindow else { return ev }
                let dy = ev.scrollingDeltaY
                if ev.hasPreciseScrollingDeltas {
                    self.acc += dy
                    let steps = Int(self.acc / 6)
                    if steps != 0 { self.acc -= CGFloat(steps) * 6; self.turn(player, role, steps) }
                } else if dy != 0 {
                    self.turn(player, role, dy > 0 ? 1 : -1)
                }
                return nil
            }
        }
    }

    private func turn(_ player: PlayerModel, _ role: Int, _ steps: Int) {
        let c = player.controls[role]
        if c.absolute { player.setValue(role, c.value + steps * (role == 7 ? 16 : 1)) } else { player.turn(role, steps) }
    }

}

// MARK: - buttons

/// A button: hold it as long as you like; Shift-click latches it down until the next click. The little bar is its LED.
private struct PanelButton: View {
    @EnvironmentObject var player: PlayerModel
    @Environment(\.faceScale) private var s
    let button: FM1Button
    @State private var pressed = false

    var body: some View {
        let i = Int(button.rawValue)
        let down = player.downButtons.contains(button.rawValue)
        let latched = player.latchedButtons.contains(button.rawValue)
        let lit: UInt8 = player.leds?.buttons[i] ?? 0
        let greenLit: UInt8 = button == .play ? (player.leds?.playGreen ?? 0) : 0
        let green = greenLit > lit
        let level = Double(green ? greenLit : lit) / 255
        let led = green ? Face.playGreen : player.ink
        let name = player.buttonNames[i]
        VStack(spacing: 5 * s) {
            ZStack {
                RoundedRectangle(cornerRadius: 2 * s).fill(Face.hex(0x0b0b0c))
                RoundedRectangle(cornerRadius: 2 * s).fill(led).opacity(level)
                    .shadow(color: led.opacity(level), radius: 4 * s)
            }
            .frame(width: 14 * s, height: 4 * s)
            Text(name)
                .font(Face.mono(10, .regular, s))
                .foregroundStyle(Face.dim)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
        .padding(.top, 5 * s)
        .padding(.bottom, 6 * s)
        .padding(.horizontal, 2 * s)
        .frame(maxWidth: .infinity, minHeight: 40 * s)
        .background(RoundedRectangle(cornerRadius: 8 * s).fill(face(down)))
        .overlay(RoundedRectangle(cornerRadius: 8 * s).stroke(Color.black, lineWidth: 1))
        .overlay(RoundedRectangle(cornerRadius: 10 * s).stroke(latched ? player.ink : .clear, lineWidth: 2).padding(-3 * s))
        .shadow(color: .black.opacity(0.7), radius: 3 * s, y: 3 * s)
        .offset(y: down ? 1 : 0)
        .opacity(player.buttonIdle[i] ? 0.55 : 1)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    guard !pressed else { return }
                    pressed = true
                    player.buttonPressed(button, shift: NSEvent.modifierFlags.contains(.shift))
                }
                .onEnded { _ in
                    pressed = false
                    player.buttonReleased(button)
                }
        )
        .help(helpText(name))
        .accessibilityLabel(name)
        .accessibilityAddTraits(.isButton)
    }
}

extension PanelButton {
    func face(_ down: Bool) -> AnyShapeStyle {
        if down { return AnyShapeStyle(Face.hex(0x1d1d20)) }
        return AnyShapeStyle(LinearGradient(colors: [Face.hex(0x303035), Face.hex(0x232327)], startPoint: .top, endPoint: .bottom))
    }

    func helpText(_ name: String) -> String {
        let printed = button.label.replacingOccurrences(of: "-", with: " −").replacingOccurrences(of: "+", with: " +")
        return name == button.label || name == printed ? "Shift-click to hold it down" : "Printed \(button.label). Shift-click to hold it down."
    }
}

// MARK: - keys

/// The 27 keys, F to G. Where a key is hit sets its velocity (near the front is loud), and dragging across the keys
/// plays each in turn. The bar on each key is its LED.
private struct Keybed: View {
    @EnvironmentObject var player: PlayerModel
    @Environment(\.faceScale) private var s
    @State private var mouseKey: Int?

    /// from F: which of the 12 are black
    static let black: Set<Int> = [1, 3, 5, 8, 10]
    static let whites = 16

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            let ww = w / CGFloat(Self.whites)
            ZStack(alignment: .topLeading) {
                ForEach(Self.layout(width: w).filter { !$0.black }, id: \.key) { k in
                    KeyCap(key: k.key, black: false, height: h)
                        .frame(width: ww - 2 * s, height: h)
                        .offset(x: k.x)
                }
                ForEach(Self.layout(width: w).filter { $0.black }, id: \.key) { k in
                    KeyCap(key: k.key, black: true, height: h * 0.6)
                        .frame(width: ww * 0.62, height: h * 0.6)
                        .offset(x: k.x)
                }
            }
            // The keys are placed with .offset, which moves where they are drawn but not the ZStack's own size: on
            // its own the ZStack is one key wide, and contentShape(Rectangle()) would then make only the leftmost key
            // (F) answer the mouse. Sizing it to the whole keybed first makes every key respond.
            .frame(width: w, height: h, alignment: .topLeading)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        let hit = Self.hit(g.location, width: w, height: h)
                        if hit?.key != mouseKey {
                            if let old = mouseKey { player.key(old, down: false) }
                            mouseKey = hit?.key
                            if let n = hit { player.key(n.key, down: true, velocity: n.velocity) }
                        }
                    }
                    .onEnded { _ in
                        if let old = mouseKey { player.key(old, down: false) }
                        mouseKey = nil
                    }
            )
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Keyboard, F to G")
    }

    struct KeyPos { let key: Int; let black: Bool; let x: CGFloat }

    static func layout(width w: CGFloat) -> [KeyPos] {
        let ww = w / CGFloat(whites)
        var wi = 0
        return (0..<FirmwareCore.keyCount).map { k in
            if black.contains(k % 12) { return KeyPos(key: k, black: true, x: ww * (CGFloat(wi) - 0.31)) }
            defer { wi += 1 }
            return KeyPos(key: k, black: false, x: ww * CGFloat(wi))
        }
    }

    /// the key under a point, and the velocity from how far down the key it is (30 at the back, 127 at the front)
    static func hit(_ p: CGPoint, width w: CGFloat, height h: CGFloat) -> (key: Int, velocity: Int)? {
        guard p.x >= 0, p.x < w, p.y >= 0, p.y <= h else { return nil }
        let ww = w / CGFloat(whites)
        let all = layout(width: w)
        if p.y < h * 0.6, let b = all.first(where: { $0.black && p.x >= $0.x && p.x < $0.x + ww * 0.62 }) {
            return (b.key, 30 + Int((max(0, min(1, p.y / (h * 0.6))) * 97).rounded()))
        }
        guard let k = all.last(where: { !$0.black && p.x >= $0.x }) else { return nil }
        return (k.key, 30 + Int((max(0, min(1, p.y / h)) * 97).rounded()))
    }
}

private struct KeyCap: View {
    @EnvironmentObject var player: PlayerModel
    @Environment(\.faceScale) private var s
    let key: Int
    let black: Bool
    let height: CGFloat

    private var ledY: CGFloat { black ? 8.5 * s : height * 0.6 + 11.5 * s }

    private var capStyle: AnyShapeStyle {
        if black {
            return AnyShapeStyle(LinearGradient(colors: [Face.hex(0x2a2a2e), Face.keyBlack], startPoint: .top, endPoint: .bottom))
        }
        let stops: [Gradient.Stop] = [.init(color: Face.hex(0xd9d9d2), location: 0), .init(color: Face.key, location: 0.3)]
        return AnyShapeStyle(LinearGradient(stops: stops, startPoint: .top, endPoint: .bottom))
    }

    var body: some View {
        let on = player.heldKeys.contains(key)
        let level = Double(player.leds?.keys[key] ?? 0) / 255
        let r: CGFloat = (black ? 5 : 6) * s
        let shape = UnevenRoundedRectangle(bottomLeadingRadius: r, bottomTrailingRadius: r)
        ZStack(alignment: .top) {
            shape.fill(on ? AnyShapeStyle(player.ink) : capStyle)
            shape.stroke(Color.black, lineWidth: 1)
            // the LED: below the black keys on a white key, near the top of a black one
            GeometryReader { g in
                ZStack {
                    RoundedRectangle(cornerRadius: 3 * s).fill(black ? Color.white.opacity(0.13) : Color.black.opacity(0.13))
                    RoundedRectangle(cornerRadius: 3 * s).fill(on ? Color.black : player.ink).opacity(level)
                        .shadow(color: on ? .clear : player.ink.opacity(level), radius: 5 * s)
                }
                .frame(width: g.size.width * 0.6, height: 5 * s)
                .position(x: g.size.width / 2, y: ledY)
            }
            if let letter = PlayerModel.keyLetters[key] {
                VStack {
                    Spacer()
                    Text(letter).font(Face.mono(10, .semibold, s)).foregroundStyle(black ? Face.hex(0x6d6d75) : Face.hex(0x77776f))
                        .padding(.bottom, (black ? 5 : 6) * s)
                }
            }
        }
    }
}

// MARK: - around the faceplate

/// Offered when this build has no saved settings but another build of the same firmware does. Nothing is copied
/// unless asked, and the other build's save is kept either way.
private struct SettingsOffer: View {
    @EnvironmentObject var player: PlayerModel
    let key: String
    @State private var confirm = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "clock.arrow.circlepath")
            Text("This version started with fresh settings. Settings you saved with version \(PlayerModel.version(ofKey: key)) are kept.")
                .lineLimit(2)
            Spacer()
            Button("Try Previous Settings…") { confirm = true }
            Button("Keep Fresh") { player.dismissOtherBuildSettings() }
        }
        .font(.callout)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.bar)
        .confirmationDialog("Try the settings from version \(PlayerModel.version(ofKey: key))?", isPresented: $confirm) {
            Button("Copy and Restart") { player.useOtherBuildSettings() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Different versions can store settings differently, so the firmware may not read them correctly, or may reset them. The original save stays as it is, so nothing is lost.")
        }
    }
}

/// Under the faceplate: MIDI, the screen link and the firmware's CPU figure.
private struct Footer: View {
    @EnvironmentObject var player: PlayerModel

    var body: some View {
        let fps = min(60, 1000 / max(16.67, player.linkMs))
        HStack(spacing: 16) {
            Label(player.midiEnabled ? (player.midiSources == 0 ? "MIDI in: no devices" : "MIDI in: \(player.midiSources) source\(player.midiSources == 1 ? "" : "s")") : "MIDI in: off",
                  systemImage: "pianokeys")
            Spacer()
            HStack(spacing: 8) {
                Text("screen link")
                ProgressView(value: min(1, player.linkMs / 16.67))
                    .frame(width: 90)
                    .tint(player.linkMs > 16.67 ? .red : player.ink)
                Text(String(format: "%.1f ms", player.linkMs)).monospacedDigit().foregroundStyle(Face.text)
                Text("≈ \(Int(fps.rounded())) fps on the device" + (player.cpu.map { $0 > 0 ? " · firmware says \($0)% CPU" : "" } ?? ""))
            }
            .help("How long the part of the screen that changed would take to reach the FM-1's panel over its SPI link. Under 16.7 ms is 60 frames a second.")
        }
        .font(.system(size: 11, design: .monospaced))
        .foregroundStyle(Face.dim)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }
}
