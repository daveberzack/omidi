import Foundation
import simd

typealias Vec = SIMD3<Double>

/// Orientation from the ring's accelerometer.
///
/// Ring axes, worn as a finger gun (index finger pointing, thumb up): gravity lies along +x,
/// aiming up or down swings it along y, and banking right swings it toward -z.
enum Motion {
    static let countsPerG = 1024.0  // measured: a resting ring reads |a| ≈ 1030 counts

    static func deg(_ r: Double) -> Double { r * 180 / .pi }

    static func unit(_ v: Vec) -> Vec {
        let n = simd_length(v)
        return n > 0 ? v / n : v
    }

    static func angle(_ a: Vec, _ b: Vec) -> Double {
        deg(acos(max(-1, min(1, simd_dot(unit(a), unit(b))))))
    }

    /// Pitch and roll (degrees) of a gravity vector in ring axes.
    static func tilt(_ g: Vec) -> (pitch: Double, roll: Double) {
        (deg(atan2(g.y, hypot(g.x, g.z))), deg(atan2(-g.z, g.x)))
    }

    /// Wrap an angle into -180..<180.
    static func wrap(_ d: Double) -> Double {
        var r = (d + 180).truncatingRemainder(dividingBy: 360)
        if r < 0 { r += 360 }
        return r - 180
    }
}

/// Finds thumb taps: a jolt at least as big as the sensitivity threshold that stands out a
/// little from the movement around it.
///
/// At 50 samples/s a tap's impact (~10 ms) falls between samples, so the same tap can measure
/// anywhere from ~1,000 to ~30,000, and taps happen while the hand moves and tilts. So the
/// threshold does the real work, and the other rules only screen out smooth hand motion and the
/// echo of the thumb lifting off. (Real taps, logged: a hard tap knocks the smoothed direction
/// 30–45° for a moment, so a "the finger mustn't turn" rule threw out the hardest taps.)
struct TapDetector {
    static let floor = 250.0  // jolts smaller than this are ordinary hand motion, never judged
    static let post = 6  // judge 120 ms after the jolt starts, at its peak
    static let pre = 10  // the finger's direction 200 ms before the jolt, for the log's turn figure
    static let sampleRate = 50.0  // the ring's accelerometer samples per second
    /// Debounce: after a tap, no new tap can start for this long. One tap often jolts the ring
    /// twice, 0.24–0.35 s apart and about equally hard (from the tap log); this leaves a margin past that.
    static let debounce = 0.5
    static let gap = Int((debounce * sampleRate).rounded())  // the debounce in samples, counted in ring time
    static let sharp = 2.0  // the jolt is at least this many times the background shake (last 500 ms);
                            // smooth hand motion measures ~1–2×, taps ~5× to several hundred ×
    static let echoWindow = 20  // for 400 ms after a tap...
    static let echoRatio = 0.35  // ...a jolt under this share of it is the thumb lifting off, not a tap
    static let contextLength = 25

    enum Verdict: String {
        case tap
        case soft  // below the sensitivity threshold
        case shaky  // no sharper than the movement around it: a hand movement
        case echo  // the thumb lifting off after a tap
    }

    struct Judgement {
        let size: Double
        let turn: Double
        let sharpness: Double
        let verdict: Verdict
    }

    enum Event {
        /// A jolt started; `likely` when it's already big and sharp enough to probably be a tap.
        case spike(likely: Bool)
        case judged(Judgement)
    }

    var threshold: Double
    /// The latest jolt size (second difference of the raw samples), for the meter.
    private(set) var jolt = 0.0

    private struct Pending {
        let n: Int
        let pre: Vec
        var size: Double
        let shake: Double
    }

    private var raw: [Vec] = []
    private var hist: [Vec] = []
    private var shake: [Double] = []
    private var n = 0
    private var lastTapN = -1_000_000
    private var lastTapSize = 0.0
    private var pending: Pending?

    init(threshold: Double) { self.threshold = threshold }

    /// Feed one raw sample and the smoothed gravity direction.
    mutating func feed(_ v: Vec, g: Vec) -> Event? {
        n += 1
        push(&raw, v, max: 3)
        push(&hist, g, max: Self.pre + 1)
        jolt = raw.count == 3 ? simd_length(raw[0] - 2 * raw[1] + raw[2]) : 0
        defer { push(&shake, jolt, max: Self.contextLength) }

        if var p = pending {
            p.size = max(p.size, jolt)  // a bigger jolt while judging is the same tap's peak
            pending = p
            guard n - p.n >= Self.post else { return nil }
            pending = nil
            let turn = Motion.angle(p.pre, g)
            let sharpness = p.size / max(p.shake, 1)
            let echo = p.n - lastTapN <= Self.echoWindow && p.size < Self.echoRatio * lastTapSize
            let verdict: Verdict = p.size < threshold ? .soft
                : sharpness < Self.sharp ? .shaky
                : echo ? .echo
                : .tap
            if verdict == .tap {
                lastTapN = p.n
                lastTapSize = p.size
            }
            return .judged(Judgement(size: p.size, turn: turn, sharpness: sharpness, verdict: verdict))
        }
        guard jolt > Self.floor, n - lastTapN > Self.gap, let pre = hist.first else { return nil }
        // The background leaves out the jolt's own rise (the last two samples).
        let background = median(Array(shake.dropLast(2)))
        pending = Pending(n: n, pre: pre, size: jolt, shake: background)
        let echo = n - lastTapN <= Self.echoWindow && jolt < Self.echoRatio * lastTapSize
        return .spike(likely: jolt >= threshold && jolt / max(background, 1) >= Self.sharp && !echo)
    }

    private func push<T>(_ a: inout [T], _ v: T, max: Int) {
        a.append(v)
        if a.count > max { a.removeFirst(a.count - max) }
    }

    private func median(_ xs: [Double]) -> Double {
        guard !xs.isEmpty else { return 0 }
        let s = xs.sorted()
        let m = s.count / 2
        return s.count % 2 == 1 ? s[m] : (s[m - 1] + s[m]) / 2
    }
}
