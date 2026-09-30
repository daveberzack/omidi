import Foundation

/// Pairs a factory-reset ring, the way FunOura's pair.sh does: scan for Oura rings, let the user
/// pick theirs, install a fresh auth key on it (`oura pair`), and save it as the paired ring.
@MainActor
final class Pairing: ObservableObject {
    struct Found: Identifiable, Equatable {
        let id: String  // the ring's Bluetooth address on this Mac
        let name: String
        let rssi: Int

        /// Signal strength in words; the ring being paired is usually the closest.
        var distance: String {
            rssi >= -60 ? "very close" : rssi >= -75 ? "nearby" : "far away"
        }
    }

    enum Step: Equatable {
        case intro
        case scanning
        case results([Found])
        case pairing(Found)
        case done(Found)
        case failed(String)
    }

    @Published private(set) var active = false
    @Published private(set) var step = Step.intro

    private let controller: Controller
    private var process: Process?
    private var cancelled = false

    init(controller: Controller) {
        self.controller = controller
    }

    /// Open the pairing panel. The ring can do one thing at a time, so streaming stops first.
    func begin() {
        active = true
        step = .intro
        controller.stop()
    }

    func scan() {
        step = .scanning
        cancelled = false
        // Wait for the stream to finish stopping before using Bluetooth for something else.
        controller.stop { [weak self] in
            MainActor.assumeIsolated { self?.runScan() }
        }
    }

    func pair(_ ring: Found) {
        step = .pairing(ring)
        cancelled = false
        let pending = RingConfig.folder.appendingPathComponent("ring.key.pending")
        try? FileManager.default.removeItem(at: pending)  // oura reuses an existing key file; this must be fresh
        OuraTool.run(["--name", "", "--address", ring.id, "--key-file", pending.path, "pair"],
                     started: { [weak self] p in MainActor.assumeIsolated { self?.process = p } }) { [weak self] out in
            MainActor.assumeIsolated { self?.paired(ring, out, pending) }
        }
    }

    /// Leave pairing. Streaming picks up again if a ring is (still) paired.
    func cancel() {
        cancelled = true
        if case .pairing = step { return }  // never interrupt a key being installed
        if let p = process, p.isRunning {
            p.terminate()
            DispatchQueue.global().async { OuraTool.finish(p.processIdentifier, after: 5) }
        }
        process = nil
        active = false
        controller.start()
    }

    /// After success: close the panel and start streaming from the new ring.
    func finish() {
        active = false
        controller.start()
    }

    private func runScan() {
        guard !cancelled else { return }
        OuraTool.run(["scan"], started: { [weak self] p in MainActor.assumeIsolated { self?.process = p } }) { [weak self] out in
            MainActor.assumeIsolated { self?.scanned(out) }
        }
    }

    private func scanned(_ out: OuraTool.Output) {
        process = nil
        guard !cancelled else { return }
        if out.bluetoothDenied {
            step = .failed(Self.bluetoothDenied)
            return
        }
        let found = Self.parseScan(out.out)
        if out.status != 0 && found.isEmpty {
            step = .failed("Scanning didn't work: \(Self.lastLine(out.err))")
            return
        }
        step = .results(found.sorted { $0.rssi > $1.rssi })
    }

    private func paired(_ ring: Found, _ out: OuraTool.Output, _ pending: URL) {
        process = nil
        let keyWritten = (try? Data(contentsOf: pending)).map { !$0.isEmpty } ?? false
        if out.status == 0 && keyWritten {
            do {
                try RingConfig.save(address: ring.id, name: ring.name, pendingKey: pending)
                step = .done(ring)
            } catch {
                step = .failed("The ring was paired, but its key couldn't be saved: \(error.localizedDescription)")
            }
            return
        }
        try? FileManager.default.removeItem(at: pending)
        if out.bluetoothDenied {
            step = .failed(Self.bluetoothDenied)
        } else if out.err.contains("set_auth_key") {
            step = .failed("\(ring.name) didn't accept a new key, so it probably isn't factory-reset "
                           + "(or it's still set up in the Oura app). Reset it and try again.")
        } else {
            step = .failed("Couldn't pair with \(ring.name). Keep it on its charger right next to this Mac "
                           + "and try again. (\(Self.lastLine(out.err)))")
        }
    }

    private static let bluetoothDenied =
        "macOS didn't let Omidi use Bluetooth. Turn Omidi on in System Settings › Privacy & Security "
        + "› Bluetooth, then try again."

    private static func lastLine(_ s: String) -> String {
        s.split(separator: "\n").last.map(String.init) ?? "no details"
    }

    /// `oura scan` prints one ring per line: `  -58 dBm  Oura 2A3F…  (UUID)`.
    private static let scanLine = try! NSRegularExpression(
        pattern: #"^\s*(-?\d+) dBm\s+(.*?)\s+\(([0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12})\)\s*$"#,
        options: [.anchorsMatchLines])

    static func parseScan(_ text: String) -> [Found] {
        var seen = Set<String>()
        var out: [Found] = []
        let range = NSRange(text.startIndex..., in: text)
        for m in scanLine.matches(in: text, range: range) {
            guard let rssi = Range(m.range(at: 1), in: text).flatMap({ Int(text[$0]) }),
                  let name = Range(m.range(at: 2), in: text).map({ RingConfig.friendly(String(text[$0])) }),
                  let id = Range(m.range(at: 3), in: text).map({ String(text[$0]) }),
                  seen.insert(id).inserted
            else { continue }
            out.append(Found(id: id, name: name, rssi: rssi))
        }
        return out
    }
}
