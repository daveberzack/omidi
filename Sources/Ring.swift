import Foundation

/// The paired ring: its Bluetooth address on this Mac and the auth key Precious installed on it,
/// kept in ~/Library/Application Support/Precious (ring.json and ring.key).
///
/// The address is the id macOS gives the ring on this Mac, so a ring is paired per Mac. A
/// developer build also knows the FunOura folder's ring.json (stamped into Info.plist as
/// RingConfig by build.sh) and copies it in on first use, so an already-paired ring keeps working.
struct RingConfig {
    let address: String
    let keyPath: String
    let name: String?

    static let folder = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Precious")
    static let file = folder.appendingPathComponent("ring.json")
    static let keyFile = folder.appendingPathComponent("ring.key")

    static func load() -> RingConfig? {
        if let c = read(file) { return c }
        importDeveloperRing()
        return read(file)
    }

    /// Record a newly paired ring. `pendingKey` is the key file `oura pair` just wrote; it replaces
    /// ring.key (the previous key is kept as ring.key.old).
    static func save(address: String, name: String, pendingKey: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let old = folder.appendingPathComponent("ring.key.old")
        if fm.fileExists(atPath: keyFile.path) {
            try? fm.removeItem(at: old)
            try fm.moveItem(at: keyFile, to: old)
        }
        try fm.moveItem(at: pendingKey, to: keyFile)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: keyFile.path)
        let json: [String: Any] = ["address": address, "key_file": "ring.key", "name": name]
        try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
            .write(to: file, options: .atomic)
    }

    private static func read(_ url: URL) -> RingConfig? {
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let address = json["address"] as? String,
              let keyFile = json["key_file"] as? String
        else { return nil }
        let key = keyFile.hasPrefix("/")
            ? keyFile
            : url.deletingLastPathComponent().appendingPathComponent(keyFile).path
        guard FileManager.default.fileExists(atPath: key) else { return nil }
        return RingConfig(address: address, keyPath: key, name: json["name"] as? String)
    }

    private static func importDeveloperRing() {
        guard let path = Bundle.main.object(forInfoDictionaryKey: "RingConfig") as? String,
              let c = read(URL(fileURLWithPath: path)) else { return }
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            try fm.copyItem(at: URL(fileURLWithPath: c.keyPath), to: keyFile)
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: keyFile.path)
            let json: [String: Any] = ["address": c.address, "key_file": "ring.key"]
            try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
                .write(to: file, options: .atomic)
        } catch {
            try? fm.removeItem(at: keyFile)
        }
    }
}

/// The ring client (open_oura's `oura`), bundled inside the app next to its own program.
enum OuraTool {
    struct Output {
        let status: Int32
        let out: String
        let err: String

        /// oura aborts (SIGABRT, status 134) when macOS refuses it Bluetooth.
        var bluetoothDenied: Bool { status == 134 }
    }

    static var url: URL? {
        guard let u = Bundle.main.url(forAuxiliaryExecutable: "oura"),
              FileManager.default.isExecutableFile(atPath: u.path) else { return nil }
        return u
    }

    /// A process for `oura` with these arguments, run from the app's own data folder (oura
    /// writes files relative to where it runs).
    static func process(_ args: [String]) -> Process? {
        guard let url else { return nil }
        try? FileManager.default.createDirectory(at: RingConfig.folder, withIntermediateDirectories: true)
        let p = Process()
        p.executableURL = url
        p.arguments = args
        p.currentDirectoryURL = RingConfig.folder
        p.standardInput = FileHandle.nullDevice
        return p
    }

    /// Run a one-off command (scan, pair) to the end. `started` hands back the process so the
    /// caller can cancel it; `done` runs on the main queue.
    static func run(_ args: [String], started: (Process) -> Void = { _ in },
                    done: @escaping (Output) -> Void) {
        guard let p = process(args) else {
            done(Output(status: -1, out: "", err: "The ring client (oura) is missing from the app."))
            return
        }
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        // Read both pipes while it runs, so a chatty command can't fill a pipe and stall.
        var outData = Data(), errData = Data()
        let group = DispatchGroup()
        for (pipe, isOut) in [(out, true), (err, false)] {
            group.enter()
            DispatchQueue.global().async {
                let d = pipe.fileHandleForReading.readDataToEndOfFile()
                if isOut { outData = d } else { errData = d }
                group.leave()
            }
        }
        p.terminationHandler = { proc in
            group.notify(queue: .main) {
                done(Output(status: proc.terminationStatus,
                            out: String(decoding: outData, as: UTF8.self),
                            err: clean(String(decoding: errData, as: UTF8.self))))
            }
        }
        do {
            try p.run()
            started(p)
        } catch {
            done(Output(status: -1, out: "", err: error.localizedDescription))
        }
    }

    /// Wait up to `seconds` for a process that was sent SIGTERM to exit, then force it. oura waits
    /// for the ring to confirm "stream off" with no time limit, so if Bluetooth has dropped it never
    /// exits by itself and would stay behind, holding the ring. Forcing it is safe: the ring stops
    /// streaming by itself when the stream's time limit runs out. Call off the main thread.
    static func finish(_ pid: pid_t, after seconds: Double) {
        let deadline = Date().addingTimeInterval(seconds)
        while kill(pid, 0) == 0 && Date() < deadline { usleep(50_000) }
        if kill(pid, 0) == 0 { kill(pid, SIGKILL) }
    }

    /// Stop any oura left behind by an earlier Precious (its parent gone, so it's now launchd's
    /// child) before connecting, so it can't hold on to the ring. `done` runs on the main queue.
    static func reapLeftovers(done: @escaping () -> Void) {
        DispatchQueue.global().async {
            let ps = Process()
            ps.executableURL = URL(fileURLWithPath: "/bin/ps")
            ps.arguments = ["-Ao", "pid=,ppid=,comm="]
            let pipe = Pipe()
            ps.standardOutput = pipe
            try? ps.run()
            let text = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            ps.waitUntilExit()
            let leftovers: [pid_t] = text.split(separator: "\n").compactMap { line in
                let f = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
                guard f.count == 3, let pid = pid_t(f[0]), f[1] == "1",
                      f[2].hasSuffix(".app/Contents/MacOS/oura") else { return nil }
                return pid
            }
            for pid in leftovers { kill(pid, SIGTERM) }
            for pid in leftovers { finish(pid, after: 3) }
            DispatchQueue.main.async(execute: done)
        }
    }

    private static let ansi = try! NSRegularExpression(pattern: "\u{1B}\\[[0-9;]*[A-Za-z]")

    /// Strip terminal colors and surrounding whitespace.
    static func clean(_ s: String) -> String {
        let range = NSRange(s.startIndex..., in: s)
        return ansi.stringByReplacingMatches(in: s, range: range, withTemplate: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Runs `oura accel --jsonl` for the paired ring and reports each accelerometer sample. The
/// app launches it itself, so macOS credits the app with Bluetooth.
final class RingStream {
    enum Failure: LocalizedError {
        case notPaired
        case missingClient

        var errorDescription: String? {
            switch self {
            case .notPaired:
                return "No ring is paired yet."
            case .missingClient:
                return "The ring client (oura) is missing from the app. Rebuild it with midi/build.sh."
            }
        }
    }

    /// All callbacks arrive on the main queue.
    var onSamples: (([Vec]) -> Void)?
    var onMessage: ((String) -> Void)?
    var onExit: ((Int32) -> Void)?

    private var process: Process?
    private var outBuffer = Data()
    private var errBuffer = Data()

    var isRunning: Bool { process?.isRunning == true }

    func start(seconds: Int) throws {
        guard let ring = RingConfig.load() else { throw Failure.notPaired }
        guard let p = OuraTool.process(["--name", "", "--address", ring.address, "--key-file", ring.keyPath,
                                        "accel", "--seconds", String(seconds), "--jsonl"])
        else { throw Failure.missingClient }
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        outBuffer.removeAll()
        errBuffer.removeAll()

        // Each handler runs on its own background queue, one chunk at a time.
        out.fileHandleForReading.readabilityHandler = { [weak self] h in
            let data = h.availableData
            guard let self, !data.isEmpty else { h.readabilityHandler = nil; return }
            let samples = Self.lines(&self.outBuffer, data).compactMap(Self.sample)
            if !samples.isEmpty {
                DispatchQueue.main.async { self.onSamples?(samples) }
            }
        }
        err.fileHandleForReading.readabilityHandler = { [weak self] h in
            let data = h.availableData
            guard let self, !data.isEmpty else { h.readabilityHandler = nil; return }
            for line in Self.lines(&self.errBuffer, data) {
                let text = OuraTool.clean(String(decoding: line, as: UTF8.self))
                if !text.isEmpty {
                    DispatchQueue.main.async { self.onMessage?(text) }
                }
            }
        }
        p.terminationHandler = { [weak self] proc in
            DispatchQueue.main.async { self?.onExit?(proc.terminationStatus) }
        }
        try p.run()
        process = p
    }

    /// Stop streaming. SIGTERM first: oura switches the ring's stream off on its way out, which
    /// can take a few seconds. `done` runs on the main queue.
    func stop(done: @escaping () -> Void) {
        guard let p = process, p.isRunning else { done(); return }
        p.terminate()
        DispatchQueue.global().async {
            OuraTool.finish(p.processIdentifier, after: 8)
            DispatchQueue.main.async(execute: done)
        }
    }

    /// Append `data` to `buffer` and take out every complete line.
    private static func lines(_ buffer: inout Data, _ data: Data) -> [Data] {
        buffer.append(data)
        var out: [Data] = []
        while let i = buffer.firstIndex(of: 0x0A) {
            out.append(buffer[buffer.startIndex..<i])
            buffer.removeSubrange(buffer.startIndex...i)
        }
        return out
    }

    /// `{"t_ms":…,"x":…,"y":…,"z":…}` → a sample in raw counts.
    private static func sample(_ line: Data) -> Vec? {
        guard let d = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let x = (d["x"] as? NSNumber)?.doubleValue,
              let y = (d["y"] as? NSNumber)?.doubleValue,
              let z = (d["z"] as? NSNumber)?.doubleValue
        else { return nil }
        return Vec(x, y, z)
    }
}
