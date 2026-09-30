import SwiftUI

// The window: the app name and three tabs (Play, Settings, Info) over a white panel, in bold
// black and white (the same in light and dark mode), after the comps in /comps.

private let ink = Color.black
private let paper = Color.white
private let faint = Color.black.opacity(0.25)

private func heavy(_ size: CGFloat) -> Font { .system(size: size, weight: .black, design: .rounded) }
private func textFont(_ size: CGFloat, _ weight: Font.Weight = .semibold) -> Font {
    .system(size: size, weight: weight, design: .rounded)
}

enum Tab: CaseIterable {
    case play, settings, info

    var symbol: String {
        switch self {
        case .play: return "play.fill"
        case .settings: return "gearshape.fill"
        case .info: return "questionmark"
        }
    }

    var help: String {
        switch self {
        case .play: return "Play"
        case .settings: return "Settings"
        case .info: return "About Omidi"
        }
    }
}

struct ContentView: View {
    @ObservedObject var c: Controller
    @ObservedObject var p: Pairing
    @State private var tab = Tab.play

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .bottom, spacing: 8) {
                Text("OMIDI")
                    .font(heavy(24))
                    .foregroundStyle(paper)
                    .padding(.bottom, 12)
                Spacer(minLength: 12)
                ForEach(Tab.allCases, id: \.self) { t in
                    TabButton(tab: t, active: tab == t && !p.active) { tab = t }
                        .disabled(p.active)  // pairing has the panel until it's done or cancelled
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 30)  // room for the window's close/minimize buttons

            Group {
                if p.active {
                    PairingView(p: p)
                } else {
                    switch tab {
                    case .play: PlayView(c: c, onPair: startPairing)
                    case .settings: SettingsView(c: c, onPair: startPairing)
                    case .info: InfoView()
                    }
                }
            }
            .frame(width: 368, height: 470)
            .background(RoundedRectangle(cornerRadius: 16).fill(paper))
            .padding(.horizontal, 16)
            .padding(.bottom, 16)
        }
        .background(ink)
        .onChange(of: p.active) { if !p.active { tab = .play } }
        .fixedSize()  // the window is exactly this size: no dragging it wider or taller
        .ignoresSafeArea()
    }
}

extension ContentView {
    private func startPairing() { p.begin() }
}

/// A folder tab: the active one is white and joins the panel below; the others are outlined.
struct TabButton: View {
    let tab: Tab
    let active: Bool
    let action: () -> Void

    var body: some View {
        let shape = UnevenRoundedRectangle(topLeadingRadius: 12, bottomLeadingRadius: active ? 0 : 6,
                                           bottomTrailingRadius: active ? 0 : 6, topTrailingRadius: 12)
        Button(action: action) {
            Image(systemName: tab.symbol)
                .font(.system(size: 22, weight: .black))
                .foregroundStyle(active ? ink : paper)
                .frame(width: 58, height: active ? 52 : 44)
                .background(shape.fill(active ? paper : ink))
                .overlay(shape.stroke(paper, lineWidth: active ? 0 : 3))
                .padding(.bottom, active ? 0 : 6)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(tab.help)
    }
}

// MARK: - Play

struct PlayView: View {
    @ObservedObject var c: Controller
    let onPair: () -> Void
    @State private var pulse = false

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            Title("MODE")
            ModeDots(count: c.modes, current: c.mode, pulse: pulse)
                .padding(.top, 10)
            Title("TILT", muted: $c.tiltMuted).padding(.top, 34)
            LevelBar(position: c.position(c.pitch, in: c.tiltRange), live: c.pitchCC != nil && !c.tiltMuted)
                .padding(.top, 8)
            Title("ROLL", muted: $c.rollMuted).padding(.top, 26)
            LevelBar(position: c.position(c.roll, in: c.rollRange), live: c.rollCC != nil && !c.rollMuted)
                .padding(.top, 8)
            PillButton(title: "RESET", filled: false) { c.zeroHere() }
                .keyboardShortcut(.space, modifiers: [])
                .help("Make the current pose the middle of both bars (Space)")
                .padding(.top, 40)
            Spacer(minLength: 0)
            StatusLine(c: c, onPair: onPair)
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 20)
        .onChange(of: c.taps) {
            pulse = true
            withAnimation(.easeOut(duration: 0.35).delay(0.08)) { pulse = false }
        }
    }
}

private struct Title: View {
    let text: String
    let muted: Binding<Bool>?
    init(_ text: String, muted: Binding<Bool>? = nil) {
        self.text = text
        self.muted = muted
    }

    var body: some View {
        Text(text).font(heavy(24)).foregroundStyle(ink)
            // An overlay doesn't take part in layout, so the title stays where it was.
            .overlay(alignment: .trailing) {
                if let muted { PauseButton(active: muted).offset(x: 40) }
            }
    }
}

/// Pauses one MIDI signal: an empty circle with a pause icon; filled black while paused.
private struct PauseButton: View {
    @Binding var active: Bool

    var body: some View {
        Button { active.toggle() } label: {
            Image(systemName: "pause.fill")
                .font(.system(size: 12, weight: .black))
                .foregroundStyle(active ? paper : ink)
                .frame(width: 30, height: 30)
                .background(Circle().fill(active ? ink : paper))
                .overlay(Circle().stroke(ink, lineWidth: 3))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(active ? "Paused: sending no MIDI for this. Click to resume." : "Pause this MIDI signal")
    }
}

/// The modes as dots on a line, the current one filled; it pulses on each tap.
struct ModeDots: View {
    let count: Int
    let current: Int
    let pulse: Bool

    var body: some View {
        HStack(spacing: 0) {
            ForEach(1...max(count, 1), id: \.self) { m in
                if m > 1 { Rectangle().fill(ink).frame(height: 4) }
                Circle()
                    .fill(m == current ? ink : paper)
                    .overlay(Circle().stroke(ink, lineWidth: 4))
                    .frame(width: 30, height: 30)
                    .scaleEffect(m == current && pulse ? 1.3 : 1)
            }
        }
        .frame(maxWidth: count == 1 ? 30 : .infinity)
        .frame(height: 40)
        .animation(.spring(duration: 0.25), value: current)
    }
}

/// Where the hand is within its range. The node is outlined gray while the CC isn't sending
/// (after a mode change or reset, until the hand moves, and while paused).
struct LevelBar: View {
    let position: Double?
    let live: Bool

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width - 34
            ZStack(alignment: .leading) {
                Capsule().fill(ink).frame(height: 5).padding(.horizontal, 4)
                Circle()
                    .fill(paper)
                    .overlay(Circle().stroke(live ? ink : faint, lineWidth: 4))
                    .frame(width: 34, height: 34)
                    .offset(x: (position ?? 0.5) * w)
                    .opacity(position == nil ? 0.3 : 1)
            }
            .frame(maxHeight: .infinity)
        }
        .frame(height: 38)
    }
}

struct PillButton: View {
    let title: String
    let filled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(heavy(20))
                .foregroundStyle(filled ? paper : ink)
                .padding(.horizontal, 18)
                .frame(minWidth: 128, minHeight: 44)
                .background(Capsule().fill(filled ? ink : paper))
                .overlay(Capsule().stroke(ink, lineWidth: 3))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

/// Shown only when the ring isn't streaming: what's happening, and a way to reconnect.
struct StatusLine: View {
    @ObservedObject var c: Controller
    let onPair: () -> Void

    var body: some View {
        if !c.isPaired && c.state == .stopped {
            HStack(spacing: 10) {
                Text("No ring paired yet.").font(textFont(12)).foregroundStyle(ink.opacity(0.7))
                Spacer(minLength: 0)
                SmallButton(title: "Pair a ring", action: onPair)
            }
        } else if c.state != .streaming {
            HStack(spacing: 10) {
                Text(text)
                    .font(textFont(12))
                    .foregroundStyle(ink.opacity(0.7))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                if c.state == .stopped {
                    SmallButton(title: "Reconnect") { c.start() }
                }
            }
        }
    }

    private var text: String {
        if !c.message.isEmpty { return c.message }
        if !c.isPaired { return "No ring paired yet." }
        switch c.state {
        case .connecting: return "Connecting to the ring…"
        case .stopping: return "Stopping the ring…"
        default: return "Not connected to the ring."
        }
    }
}

// MARK: - Settings

struct SettingsView: View {
    @ObservedObject var c: Controller
    let onPair: () -> Void

    var body: some View {
        VStack(spacing: 6) {
            SettingRow(title: "Tilt\nRange", value: spanText(c.tiltSpan)) {
                SpanSlider(span: $c.tiltSpan, bounds: Controller.spans)
            }
            SettingRow(title: "Roll\nRange", value: spanText(c.rollSpan)) {
                SpanSlider(span: $c.rollSpan, bounds: Controller.spans)
            }
            SettingRow(title: "CC\nModes", value: "\(c.modes)") {
                StepSlider(value: $c.modes, steps: 1...Controller.maxModes)
            }
            SettingRow(title: "MIDI\nChannel", value: "\(c.channel)") {
                StepSlider(value: $c.channel, steps: 1...16)
            }
            SettingRow(title: "Send Tap\nas MIDI?", value: c.tapMIDI.label) {
                StepSlider(value: Binding(get: { c.tapMIDI.rawValue },
                                          set: { c.tapMIDI = Controller.TapMIDI(rawValue: $0) ?? .off }),
                           steps: 0...2)
            }
            SettingRow(title: "Tap\nSensitivity", value: c.tapLevelName) {
                SensitivitySlider(level: $c.tapLevel, jolt: c.jolt)
            }
            .help("How easily a tap registers. The bar under the dots shows each jolt; one that reaches "
                  + "past the selected dot counts as a tap. Move toward Max if taps are missed.")
            SettingRow(title: "Oura\nRing", value: c.ringName ?? "Not paired") {
                HStack {
                    Spacer()
                    SmallButton(title: c.isPaired ? "Pair a different ring" : "Pair a ring", action: onPair)
                }
            }
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 16).fill(ink))
        .padding(6)
    }

    private func spanText(_ span: Double) -> String {
        "\(Int(span))°"
    }
}

/// One white card: a two-line label on the left, a control, and its value underneath on the right.
struct SettingRow<Control: View>: View {
    let title: String
    let value: String
    @ViewBuilder let control: Control

    var body: some View {
        HStack(spacing: 14) {
            Text(title)
                .font(heavy(17))
                .multilineTextAlignment(.center)
                .lineSpacing(-2)
                .frame(width: 96)
            VStack(alignment: .trailing, spacing: 2) {
                control.frame(height: 32)
                Text(value).font(heavy(14))
            }
        }
        .foregroundStyle(ink)
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: 10).fill(paper))
    }
}

private let thumbSize: CGFloat = 26

private struct Thumb: View {
    var body: some View {
        Circle().fill(paper)
            .overlay(Circle().stroke(ink, lineWidth: 3.5))
            .frame(width: thumbSize, height: thumbSize)
    }
}

/// One symmetric range: the line is -90° to +90°, and the thick span between the two handles is the
/// range. The handles move together, mirrored around the middle; drag either one, or anywhere.
struct SpanSlider: View {
    @Binding var span: Double
    let bounds: ClosedRange<Double>

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width - thumbSize
            let mid = w / 2
            let half = CGFloat(span / 2 / 90) * (w / 2)  // 90° either side fills the line
            ZStack(alignment: .leading) {
                Capsule().fill(ink).frame(height: 4).padding(.horizontal, thumbSize / 2)
                Rectangle().fill(ink).frame(width: 2, height: 18).offset(x: mid + thumbSize / 2 - 1)
                Capsule().fill(ink)
                    .frame(width: 2 * half, height: 12)
                    .offset(x: mid - half + thumbSize / 2)
                Thumb().offset(x: mid - half)
                Thumb().offset(x: mid + half)
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged {
                let fromMid = abs($0.location.x - thumbSize / 2 - mid) / (w / 2)  // 0 at the middle, 1 at an end
                span = min(max(Double(fromMid) * 180, bounds.lowerBound), bounds.upperBound)
            })
        }
    }
}

/// Whole-number steps as small dots on a line; the chosen one is a big handle. Click or drag.
struct StepSlider: View {
    @Binding var value: Int
    let steps: ClosedRange<Int>

    var body: some View {
        GeometryReader { geo in
            let n = steps.count - 1
            let w = geo.size.width - thumbSize
            let x = { (v: Int) in CGFloat(v - steps.lowerBound) / CGFloat(max(n, 1)) * w }
            ZStack(alignment: .leading) {
                Capsule().fill(ink).frame(height: 4).padding(.horizontal, thumbSize / 2)
                ForEach(Array(steps), id: \.self) { v in
                    Circle().fill(ink).frame(width: 11, height: 11)
                        .offset(x: x(v) + (thumbSize - 11) / 2)
                }
                Thumb().offset(x: x(value))
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged {
                let f = min(max(($0.location.x - thumbSize / 2) / w, 0), 1)
                let v = steps.lowerBound + Int((f * CGFloat(n)).rounded())
                if v != value { value = v }
            })
            .animation(.spring(duration: 0.2), value: value)
        }
    }
}

/// Tap sensitivity as five steps (Max … Min), with a live meter of jolts beneath on the same
/// scale: each dot is a threshold (1000 … 5000), so a jolt reaching past the selected dot is a tap.
struct SensitivitySlider: View {
    @Binding var level: Int
    let jolt: Double

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width - thumbSize
            let levels = Controller.tapLevels.map(\.threshold)
            let lo = levels.first!, hi = levels.last!
            let reach = CGFloat(min(max((jolt - lo) / (hi - lo), 0), 1)) * w
            let threshold = levels[level - 1]
            ZStack(alignment: .leading) {
                StepSlider(value: $level, steps: 1...levels.count)
                Capsule().fill(jolt >= threshold ? ink : faint)
                    .frame(width: max(4, reach), height: 6)
                    .offset(x: thumbSize / 2, y: 15)
                    .allowsHitTesting(false)
            }
        }
    }
}

// MARK: - Info

struct InfoView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Omidi is a MIDI device driver that receives input from a paired Oura ring and "
                     + "broadcasts MIDI CC signals that you can map expressively in music or other software.")
                section("Tilt & Roll",
                        "These two movements are sent as two CC values. In Settings, choose the range of "
                        + "movement that maps to 0–127. Reset makes your current pose the middle of both; "
                        + "The pause buttons next to Tilt and Roll stop each one sending MIDI.")
                section("Modes",
                        "Each mode sends on its own pair of CC numbers, so you can map them to different "
                        + "parameters. Tap your finger (a small, quick jolt) to move to the next mode; choose "
                        + "how many modes in Settings.")
                ccTable.frame(maxWidth: .infinity)
                Text("A tap can also send CC \(Controller.tapCC): a momentary 127, a toggle between 127 and 0, "
                     + "or nothing. If taps are missed or appear by themselves, adjust the Tap Sensitivity.")
                Text("Choose the MIDI channel to avoid conflicts with other devices. After a mode change, "
                     + "reset or resume, values wait for your hand to move, so nothing jumps.")
            }
            .font(textFont(12.5))
            .foregroundStyle(ink)
            .fixedSize(horizontal: false, vertical: true)
            .padding(20)
        }
        .scrollIndicators(.never)
    }

    private func section(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(textFont(13, .heavy))
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var ccTable: some View {
        Grid(horizontalSpacing: 0, verticalSpacing: 0) {
            GridRow {
                cell("Mode", bold: true)
                ForEach(1...Controller.maxModes, id: \.self) { cell("\($0)", bold: true) }
            }
            Divider().overlay(ink)
            GridRow {
                cell("Tilt", bold: true)
                ForEach(1...Controller.maxModes, id: \.self) { cell("\(Controller.ccNumbers(mode: $0).tilt)") }
            }
            GridRow {
                cell("Roll", bold: true)
                ForEach(1...Controller.maxModes, id: \.self) { cell("\(Controller.ccNumbers(mode: $0).roll)") }
            }
        }
        .padding(.horizontal, 6)
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(ink, lineWidth: 2))
    }

    private func cell(_ text: String, bold: Bool = false) -> some View {
        Text(text)
            .font(textFont(12, bold ? .heavy : .semibold))
            .frame(minWidth: bold && text.count > 2 ? 44 : 34)
            .padding(.vertical, 4)
    }
}

/// A small outlined button for secondary actions.
struct SmallButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(textFont(12, .bold))
                .foregroundStyle(ink)
                .padding(.horizontal, 12).padding(.vertical, 5)
                .overlay(Capsule().stroke(ink, lineWidth: 2))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Pairing

/// Pairing a factory-reset ring, one step at a time. Takes the whole panel while it runs.
struct PairingView: View {
    @ObservedObject var p: Pairing

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(heading).font(heavy(22))
            content
            Spacer(minLength: 0)
            buttons
        }
        .font(textFont(12.5))
        .foregroundStyle(ink)
        .padding(22)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var heading: String {
        switch p.step {
        case .intro: return "PAIR A RING"
        case .scanning: return "LOOKING FOR RINGS"
        case .results: return "WHICH RING?"
        case .pairing: return "PAIRING"
        case .done: return "PAIRED"
        case .failed: return "THAT DIDN'T WORK"
        }
    }

    @ViewBuilder private var content: some View {
        switch p.step {
        case .intro:
            Text("Use a spare ring. Pairing installs Omidi's own key on the ring, so the Oura app and "
                 + "your Oura account stop working with it until you reset it and set it up there again.")
                .font(textFont(12.5, .bold))
                .fixedSize(horizontal: false, vertical: true)
            Text("First, factory-reset the ring on its charging dock (Gen3 / Ring 4):")
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 6) {
                ResetStep(n: 1, text: "Take the ring off the dock, put it back and wait 2 seconds.")
                ResetStep(n: 2, text: "Turn the dock upside down, ring and all. Wait for", light: .blue, name: "blue")
                ResetStep(n: 3, text: "Turn it upright. Wait for", light: .red, name: "red")
                ResetStep(n: 4, text: "Upside down again. Wait for", light: Color(red: 1, green: 0, blue: 1), name: "magenta")
                ResetStep(n: 5, text: "Upright again. Wait for", light: .yellow, name: "yellow")
            }
            Text("Yellow means the reset has started; a few minutes later the light blinks blue. Keep any "
                 + "other Oura ring (and phones paired to it) away while pairing.")
                .fixedSize(horizontal: false, vertical: true)
        case .scanning:
            HStack(spacing: 12) {
                ProgressView().controlSize(.small)
                Text("This takes about 25 seconds. Keep the ring on its charger next to this Mac.")
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .results(let found):
            if found.isEmpty {
                Text("No ring found. Put the ring on its charger for a moment to wake it, then scan again. "
                     + "If macOS asked about Bluetooth, allow it.")
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("A freshly reset ring usually shows up as “Oura” and its serial number. Click yours:")
                    .fixedSize(horizontal: false, vertical: true)
                VStack(spacing: 8) {
                        ForEach(found.prefix(5)) { ring in
                            Button { p.pair(ring) } label: {
                                HStack {
                                    Text(ring.name).font(heavy(15))
                                    Spacer()
                                    Text(ring.distance).font(textFont(12))
                                }
                                .padding(.horizontal, 14).padding(.vertical, 10)
                                .overlay(RoundedRectangle(cornerRadius: 10).stroke(ink, lineWidth: 3))
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                }
                .padding(2)
            }
        case .pairing(let ring):
            HStack(spacing: 12) {
                ProgressView().controlSize(.small)
                Text("Installing Omidi's key on \(ring.name). Keep it close; this can take half a minute.")
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .done(let ring):
            Text("\(ring.name) is paired with this Mac. Omidi will start listening to it now.")
                .fixedSize(horizontal: false, vertical: true)
        case .failed(let message):
            Text(message).fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder private var buttons: some View {
        switch p.step {
        case .intro:
            HStack {
                PillButton(title: "CANCEL", filled: false) { p.cancel() }
                Spacer()
                PillButton(title: "FIND RING", filled: true) { p.scan() }
            }
        case .scanning:
            HStack {
                PillButton(title: "CANCEL", filled: false) { p.cancel() }
                Spacer()
            }
        case .results, .failed:
            HStack {
                PillButton(title: "CANCEL", filled: false) { p.cancel() }
                Spacer()
                PillButton(title: "SCAN AGAIN", filled: true) { p.scan() }
            }
        case .pairing:
            EmptyView()  // installing a key mustn't be interrupted
        case .done:
            HStack {
                Spacer()
                PillButton(title: "DONE", filled: true) { p.finish() }
            }
        }
    }
}

private struct ResetStep: View {
    let n: Int
    let text: String
    var light: Color? = nil
    var name = ""

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(n)").font(textFont(12.5, .heavy)).frame(width: 12)
            // The light's color sits inline, so it wraps with the sentence.
            (Text(text)
             + (light.map { Text("  \(Image(systemName: "circle.fill")) ").foregroundColor($0) } ?? Text(""))
             + Text(name).font(textFont(12.5, .heavy)))
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
