import Foundation
import simd

/// Turns the ring's samples into MIDI: tilt (pitch) → CC 10·M+1, roll → CC 10·M+2, and each tap
/// moves to the next mode M (1…modes), optionally sending CC 10 (momentary 127 then 0, or a toggle).
@MainActor
final class Controller: ObservableObject {
    static let tapCC = 10
    static let maxModes = 7
    static let spans = 10.0...180.0  // a range's total width in degrees, split evenly either side of zero
    static let smooth = 0.2  // low-pass per sample (~100 ms); lower is steadier but lags more
    static let movingG = 0.15  // |a| this far from 1 g: the hand is accelerating, angles are rough
    // The ring stops streaming on its own after this, so a stream that's somehow left behind can't
    // run for long; Omidi reconnects by itself when it ends (a few seconds' gap, once an hour).
    static let streamSeconds = 3600
    static let settleSamples = 10  // 200 ms after a tap before the CCs (and a new mode's start) resume
    /// Tap sensitivity: five levels of the jolt size a tap needs, most sensitive first.
    static let tapLevels: [(threshold: Double, name: String)] = [
        (1000, "Max"), (2000, "High"), (3000, "Medium"), (4000, "Low"), (5000, "Min"),
    ]
    static let tapThresholds = 1000.0...5000.0
    static let defaultTapThreshold = 3000.0
    /// Every judged jolt goes here, so taps can be tuned from real data.
    static let tapLog = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/Omidi/taps.jsonl")

    enum State { case stopped, connecting, streaming, stopping }

    /// What a tap sends on CC 10, besides moving to the next mode.
    enum TapMIDI: Int, CaseIterable {
        case off, momentary, toggle

        var label: String {
            switch self {
            case .off: return "Off"
            case .momentary: return "Momentary"
            case .toggle: return "Toggle"
            }
        }
    }

    /// The angles that span CC 0…127, in degrees from the zeroed pose (symmetric: ±span/2).
    struct AngleRange: Equatable {
        var low: Double
        var high: Double
    }

    /// One continuous controller. After a mode, channel or zero change it sends nothing until
    /// the hand moves, so the new CC doesn't jump to wherever the hand happens to be.
    struct Axis {
        // CC steps of movement that count as "the hand moved". A thumb tap itself tilts the finger
        // by 5–12° and it often stays a little tilted, so this sits above that wobble (~6° pitch, ~7.5° roll).
        static let startMoving = 8.0
        static let hysteresis = 0.75  // CC steps; stops a value flickering on a step boundary

        var baseline: Double?
        var waiting = true
        var sent: Int?

        mutating func arm() { self = Axis() }

        /// The value to send for a continuous position `cc` (0…127), or nil to send nothing.
        mutating func output(_ cc: Double) -> Int? {
            if waiting {
                guard let b = baseline else { baseline = cc; return nil }
                guard abs(cc - b) >= Self.startMoving else { return nil }
                waiting = false
            }
            if let s = sent, abs(cc - Double(s)) < Self.hysteresis { return nil }
            let v = Int(cc.rounded())
            guard v != sent else { return nil }
            sent = v
            return v
        }
    }

    // Settings (remembered between launches). With @Published, assigning inside didSet runs
    // didSet again, so the clamp only reassigns an out-of-range value (once).
    @Published var channel: Int {
        didSet {
            let clamped = min(max(channel, 1), 16)
            if channel != clamped { channel = clamped; return }
            defaults.set(channel, forKey: "channel")
            if channel != oldValue { armAxes() }
        }
    }
    @Published var modes: Int {
        didSet {
            let clamped = min(max(modes, 1), Self.maxModes)
            if modes != clamped { modes = clamped; return }
            defaults.set(modes, forKey: "modes")
            if mode > modes { mode = 1; armAxes() }
        }
    }
    @Published var tapMIDI: TapMIDI {
        didSet {
            defaults.set(tapMIDI.rawValue, forKey: "tapMIDI")
            toggleOn = false
        }
    }
    /// How far the hand tilts, in total, from CC 0 to 127: 90 means -45° to +45° around the reset pose.
    @Published var tiltSpan: Double {
        didSet {
            let clamped = Self.clampSpan(tiltSpan)
            if tiltSpan != clamped { tiltSpan = clamped; return }
            defaults.set(tiltSpan, forKey: "tiltSpan")
        }
    }
    @Published var rollSpan: Double {
        didSet {
            let clamped = Self.clampSpan(rollSpan)
            if rollSpan != clamped { rollSpan = clamped; return }
            defaults.set(rollSpan, forKey: "rollSpan")
        }
    }
    var tiltRange: AngleRange { AngleRange(low: -tiltSpan / 2, high: tiltSpan / 2) }
    var rollRange: AngleRange { AngleRange(low: -rollSpan / 2, high: rollSpan / 2) }
    /// While an axis is muted it sends nothing; the ring keeps streaming and the window keeps moving.
    @Published var tiltMuted = false {
        didSet { if !tiltMuted && oldValue { pitchAxis.arm(); pitchCC = nil } }  // don't jump to wherever the hand went meanwhile
    }
    @Published var rollMuted = false {
        didSet { if !rollMuted && oldValue { rollAxis.arm(); rollCC = nil } }
    }
    /// How big a jolt a tap needs (raw counts); lower is more sensitive.
    @Published var tapThreshold: Double {
        didSet {
            let clamped = Self.nearestLevel(tapThreshold)
            if tapThreshold != clamped { tapThreshold = clamped; return }
            defaults.set(tapThreshold, forKey: "tapThreshold")
            detector.threshold = tapThreshold
        }
    }

    // Live state for the window.
    @Published private(set) var mode = 1
    @Published private(set) var state = State.stopped
    @Published private(set) var message = ""
    @Published private(set) var pitch: Double?
    @Published private(set) var roll: Double?
    @Published private(set) var pitchCC: Int?
    @Published private(set) var rollCC: Int?
    @Published private(set) var raw: Vec?
    @Published private(set) var magnitude = 0.0
    @Published private(set) var taps = 0
    @Published private(set) var jolt = 0.0  // the tap meter: recent jolt size, falling off quickly
    @Published private(set) var lastJudgement: TapDetector.Judgement?
    /// The paired ring's name (as it appeared when paired), or nil when no ring is paired.
    @Published private(set) var ringName: String?

    var isRunning: Bool { ring.isRunning }
    var moving: Bool { abs(magnitude - 1) > Self.movingG }

    private let defaults = UserDefaults.standard
    private let ring = RingStream()
    private let midi = MidiOut(name: "Omidi")
    private var detector: TapDetector
    private var tapLog: FileHandle?
    private var toggleOn = false  // the Toggle tap state: the next tap sends 127 when false, 0 when true
    private var gravity: Vec?
    private var zero = (pitch: 0.0, roll: 0.0)
    private var pitchAxis = Axis()
    private var rollAxis = Axis()
    private var holding = false  // a likely tap is being judged: don't let its jolt move the CCs
    private var settle = 0  // samples to wait after a judged spike while its jolt fades from `gravity`
    private var wantRunning = false
    private var startedAt = Date()
    private var samples = 0
    private var activity: NSObjectProtocol?  // keeps App Nap from throttling us while streaming

    init() {
        channel = defaults.object(forKey: "channel") as? Int ?? 1
        modes = min(max(defaults.object(forKey: "modes") as? Int ?? 1, 1), Self.maxModes)
        tapMIDI = (defaults.object(forKey: "tapMIDI") as? Int).flatMap(TapMIDI.init) ?? .off
        tiltSpan = Self.loadSpan("tiltSpan", legacy: "tiltRange", defaults) ?? 90
        rollSpan = Self.loadSpan("rollSpan", legacy: "rollRange", defaults) ?? 120
        let saved = defaults.object(forKey: "tapThreshold") as? Double ?? Self.defaultTapThreshold
        let threshold = Self.nearestLevel(saved)
        tapThreshold = threshold
        detector = TapDetector(threshold: threshold)
        ring.onSamples = { [weak self] batch in
            MainActor.assumeIsolated { batch.forEach { self?.handle($0) } }
        }
        ring.onMessage = { [weak self] text in
            MainActor.assumeIsolated { self?.ringSaid(text) }
        }
        ring.onExit = { [weak self] status in
            MainActor.assumeIsolated { self?.ringExited(status) }
        }
        if midi == nil { message = "Couldn't create the MIDI port." }
    }

    var pitchCCNumber: Int { Self.ccNumbers(mode: mode).tilt }
    var rollCCNumber: Int { Self.ccNumbers(mode: mode).roll }

    static func ccNumbers(mode: Int) -> (tilt: Int, roll: Int) { (10 * mode + 1, 10 * mode + 2) }

    /// Where an angle sits in its range, 0…1 (for the window's bars).
    func position(_ deg: Double?, in range: AngleRange) -> Double? {
        deg.map { min(max(($0 - range.low) / (range.high - range.low), 0), 1) }
    }

    var isPaired: Bool { ringName != nil }

    /// Re-read which ring is paired (after pairing, or at launch).
    func refreshRing() {
        let ring = RingConfig.load()
        ringName = ring.map { $0.name ?? RingConfig.defaultName }
    }

    func start() {
        guard state == .stopped else { return }
        refreshRing()
        do {
            try ring.start(seconds: Self.streamSeconds)
        } catch {
            message = error.localizedDescription
            return
        }
        wantRunning = true
        // The window is usually in the background behind a DAW; without this, App Nap slows the
        // app down and samples (and MIDI) arrive late and in bursts.
        activity = activity ?? ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .latencyCritical], reason: "Streaming the ring as MIDI")
        startedAt = Date()
        samples = 0
        detector = TapDetector(threshold: tapThreshold)
        gravity = nil
        holding = false
        settle = 0
        armAxes()
        state = .connecting
        message = "Connecting to the ring…"
    }

    func stop(done: @escaping () -> Void = {}) {
        wantRunning = false
        guard ring.isRunning else { state = .stopped; endActivity(); done(); return }
        state = .stopping
        message = "Stopping the ring…"
        ring.stop { [weak self] in
            MainActor.assumeIsolated {
                self?.state = .stopped
                self?.message = ""
                self?.endActivity()
            }
            done()
        }
    }

    /// Make the current pose 0° on both bars.
    func zeroHere() {
        guard let g = gravity else { return }
        zero = Motion.tilt(g)
        armAxes()
    }

    private func endActivity() {
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
        activity = nil
    }

    private func armAxes() {
        pitchAxis.arm()
        rollAxis.arm()
        pitchCC = nil
        rollCC = nil
    }

    private func handle(_ v: Vec) {
        samples += 1
        if state == .connecting {
            state = .streaming
            message = ""
        }
        let g = gravity.map { $0 + Self.smooth * (v - $0) } ?? v
        gravity = g
        let event = detector.feed(v, g: Motion.unit(g))

        let t = Motion.tilt(g)
        let p = t.pitch - zero.pitch
        let r = Motion.wrap(t.roll - zero.roll)
        pitch = p
        roll = r
        raw = v
        magnitude = simd_length(v) / Motion.countsPerG

        jolt = max(detector.jolt, jolt * 0.9)
        switch event {
        case .spike(let likely):
            holding = likely
        case .judged(let j):
            if holding || j.verdict == .tap { settle = Self.settleSamples }
            holding = false
            lastJudgement = j
            log(j)
            if j.verdict == .tap { tapped() }
        case nil:
            break
        }
        guard !holding else { return }
        if settle > 0 { settle -= 1; return }
        if !tiltMuted {
            if let out = pitchAxis.output(Self.scale(p, tiltRange)) {
                midi?.cc(channel: channel, number: pitchCCNumber, value: out)
            }
            pitchCC = pitchAxis.sent
        }
        if !rollMuted {
            if let out = rollAxis.output(Self.scale(r, rollRange)) {
                midi?.cc(channel: channel, number: rollCCNumber, value: out)
            }
            rollCC = rollAxis.sent
        }
    }

    private func tapped() {
        taps += 1
        if let midi {
            let ch = channel
            switch tapMIDI {
            case .off:
                break
            case .momentary:
                midi.cc(channel: ch, number: Self.tapCC, value: 127)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    midi.cc(channel: ch, number: Self.tapCC, value: 0)
                }
            case .toggle:
                toggleOn.toggle()
                midi.cc(channel: ch, number: Self.tapCC, value: toggleOn ? 127 : 0)
            }
        }
        if modes > 1 {
            mode = mode % modes + 1
            armAxes()
        }
    }

    private func log(_ j: TapDetector.Judgement) {
        if tapLog == nil {
            let url = Self.tapLog
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: url.path) {
                FileManager.default.createFile(atPath: url.path, contents: nil)
            }
            tapLog = try? FileHandle(forWritingTo: url)
            _ = try? tapLog?.seekToEnd()
        }
        let line = String(format: "{\"time\":%.3f,\"size\":%.0f,\"turn\":%.1f,\"sharpness\":%.1f,"
                          + "\"threshold\":%.0f,\"verdict\":\"%@\"}\n",
                          Date().timeIntervalSince1970, j.size, j.turn, j.sharpness, tapThreshold,
                          j.verdict.rawValue)
        tapLog?.write(Data(line.utf8))
    }

    private func ringSaid(_ text: String) {
        if text.hasPrefix("Streaming accelerometer") { return }
        if state == .connecting || state == .streaming { message = text }
    }

    private func ringExited(_ status: Int32) {
        guard state != .stopping else { return }  // stop() finishes up
        state = .stopped
        // The stream is time-boxed; if it ran its course while wanted, carry on seamlessly.
        if wantRunning && samples > 0 && Date().timeIntervalSince(startedAt) > 60 {
            start()
            return
        }
        wantRunning = false
        endActivity()
        if samples == 0 {
            if message.isEmpty || message.hasPrefix("Connecting") {
                message = "Couldn't reach the ring. Keep it close and charged, then Start."
            }
        } else {
            message = "The ring stopped streaming. Press Start to reconnect."
        }
    }

    /// Degrees within the range → a continuous 0…127.
    private static func scale(_ deg: Double, _ range: AngleRange) -> Double {
        min(max((deg - range.low) / (range.high - range.low), 0), 1) * 127
    }

    /// The sensitivity level (1 = Max … 5 = Min) for the window's selector.
    var tapLevel: Int {
        get { (Self.tapLevels.firstIndex { $0.threshold == tapThreshold } ?? 2) + 1 }
        set { tapThreshold = Self.tapLevels[min(max(newValue, 1), Self.tapLevels.count) - 1].threshold }
    }

    var tapLevelName: String { Self.tapLevels[tapLevel - 1].name }

    /// The level threshold closest to `t` (a saved value from before there were levels, say).
    private static func nearestLevel(_ t: Double) -> Double {
        tapLevels.map(\.threshold).min { abs($0 - t) < abs($1 - t) } ?? defaultTapThreshold
    }

    /// Whole, even degrees (so each side is a whole number) within `spans`.
    private static func clampSpan(_ s: Double) -> Double {
        (min(max(s, spans.lowerBound), spans.upperBound) / 2).rounded() * 2
    }

    /// A saved span, or the width of a range saved by the earlier two-handled slider.
    private static func loadSpan(_ key: String, legacy: String, _ defaults: UserDefaults) -> Double? {
        if let s = defaults.object(forKey: key) as? Double { return clampSpan(s) }
        guard let a = defaults.array(forKey: legacy) as? [Double], a.count == 2 else { return nil }
        return clampSpan(a[1] - a[0])
    }
}
