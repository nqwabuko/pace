// DialsClient: the one Swift client for dials (04-design, "Swift and Lua clients").
// It shells out to ~/.local/bin/dials and decodes its JSON. Apps carry an unmodified
// copy, kept identical by dials' scripts/sync-clients.sh: change it here, never in a copy.
//
// The decisions (argv building, the folder to watch, whether to self-exec) are small pure
// functions in `DialsArgs`, so a test can check them without starting a process.
import Foundation

/// Any JSON value. Whole numbers encode without a fraction ("3600", not "3600.0"), so a
/// value read from dials goes back to it as the same JSON.
enum JSONValue: Codable, Equatable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([JSONValue].self) { self = .array(a) }
        else if let o = try? c.decode([String: JSONValue].self) { self = .object(o) }
        else { throw DecodingError.dataCorruptedError(in: c, debugDescription: "not a JSON value") }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .number(let n):
            if n.rounded() == n, abs(n) < 9.0e15 { try c.encode(Int64(n)) } else { try c.encode(n) }
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }
}

/// `dials get <tool> --json`: the rev and every value, defaults filled.
struct DialsSnapshot: Decodable, Equatable {
    let rev: Int
    let values: [String: JSONValue]
}

enum DialsError: Error, Equatable {
    /// ~/.local/bin/dials is not there: the app uses its built-in behaviour.
    case notInstalled
    /// dials exited non-zero; the message is its stderr (exit 2 is a refused value).
    case failed(code: Int32, message: String)
    /// dials printed something that is not the JSON this client expects.
    case undecodable(String)
}

/// The pure part: what to run, and what to watch. No process, clock or environment read here.
enum DialsArgs {
    static func get(_ tool: String) -> [String] { ["get", tool, "--json"] }
    static func isOff(_ tool: String) -> [String] { ["is-off", tool] }
    static func set(_ tool: String, _ key: String, _ json: String) -> [String] { ["set", tool, key, json] }
    static func setOff(_ tool: String, _ off: Bool) -> [String] { ["set-off", tool, off ? "1" : "0"] }

    static func report(_ tool: String, _ source: String, ok: Bool, summary: String,
                       rev: Int?, using: [String: JSONValue], runningSince: Date?) -> [String] {
        var a = ["report", tool, source, ok ? "--ok" : "--fail", "--summary", summary]
        if let rev { a += ["--rev", String(rev)] }
        if !using.isEmpty { a += ["--using-json", json(.object(using))] }
        if let runningSince { a += ["--running-since", iso8601(runningSince)] }
        return a
    }

    /// Compact JSON with sorted keys, so the same values always give the same text.
    static func json(_ v: JSONValue) -> String {
        let e = JSONEncoder(); e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: (try? e.encode(v)) ?? Data("null".utf8), as: UTF8.self)
    }

    static func iso8601(_ d: Date) -> String {
        let f = ISO8601DateFormatter(); f.timeZone = TimeZone(identifier: "UTC")
        return f.string(from: d)
    }

    /// The tool's folder in dials' store: `$DIALS_HOME/<tool>`, else
    /// `~/.local/state/dials/<tool>` (the same rule as dials-core's `Root`).
    static func folder(_ tool: String, env: [String: String], home: String) -> String {
        if let h = env["DIALS_HOME"], !h.isEmpty { return "\(h)/\(tool)" }
        return "\(home)/.local/state/dials/\(tool)"
    }

    /// The argv to execv into, or nil to carry on as ourselves: already under `dials run`
    /// (DIALS_REV set), or dials not installed.
    static func selfExec(tool: String, source: String, env: [String: String], installed: Bool,
                         dials: String, argv: [String]) -> [String]? {
        guard env["DIALS_REV"] == nil, installed else { return nil }
        return [dials, "run", tool, source, "--"] + argv
    }
}

enum DialsClient {
    static var path: String { NSHomeDirectory() + "/.local/bin/dials" }
    static var installed: Bool { FileManager.default.isExecutableFile(atPath: path) }

    static func get(_ tool: String) throws -> DialsSnapshot {
        let out = try checked(DialsArgs.get(tool))
        do { return try JSONDecoder().decode(DialsSnapshot.self, from: Data(out.utf8)) }
        catch { throw DialsError.undecodable("\(error)") }
    }

    /// True only when dials says the tool is off (exit 0). Not installed reads as on.
    static func isOff(_ tool: String) -> Bool {
        guard installed else { return false }
        return launch(DialsArgs.isOff(tool)).code == 0
    }

    static func set(_ tool: String, _ key: String, _ json: String) throws {
        _ = try checked(DialsArgs.set(tool, key, json))
    }

    /// The tool's switch (`dials set-off`), for an app that is its tool's own switch (MicWatch).
    static func setOff(_ tool: String, _ off: Bool) throws {
        _ = try checked(DialsArgs.setOff(tool, off))
    }

    /// Record how the app is doing. Not installed: nothing to report to. A failed report is
    /// written to stderr, since the caller has nothing better to do with it.
    static func report(_ tool: String, _ source: String, ok: Bool, summary: String,
                       rev: Int?, using: [String: JSONValue], runningSince: Date?) {
        guard installed else { return }
        do {
            _ = try checked(DialsArgs.report(tool, source, ok: ok, summary: summary,
                                             rev: rev, using: using, runningSince: runningSince))
        } catch {
            FileHandle.standardError.write(Data("dials report \(tool) \(source): \(error)\n".utf8))
        }
    }

    /// Call `onChange` on the main queue whenever anything under the tool's folder changes.
    /// The folder is made if missing, since FSEvents needs a path to watch. Keep the returned
    /// object: the watch stops when it is released.
    static func watch(_ tool: String, _ onChange: @escaping () -> Void) -> AnyObject {
        let dir = DialsArgs.folder(tool, env: ProcessInfo.processInfo.environment, home: NSHomeDirectory())
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return FolderWatch(dir, onChange)
    }

    /// Replace this process with `dials run <tool> <source> -- <argv>`, unless already under
    /// dials or dials is not installed. Returns only when it did not exec.
    static func selfExec(tool: String, source: String) {
        let me = Bundle.main.executablePath ?? CommandLine.arguments[0]
        guard let argv = DialsArgs.selfExec(tool: tool, source: source,
                                            env: ProcessInfo.processInfo.environment,
                                            installed: installed, dials: path,
                                            argv: [me] + CommandLine.arguments.dropFirst()) else { return }
        var cargs: [UnsafeMutablePointer<CChar>?] = argv.map { strdup($0) } + [nil]
        execv(path, &cargs)
        // Only reached when execv failed: say so and carry on as ourselves.
        FileHandle.standardError.write(Data("dials: execv failed (\(errno)), running without dials\n".utf8))
        for p in cargs { free(p) }
    }

    /// stdout of a dials call that must succeed.
    private static func checked(_ args: [String]) throws -> String {
        guard installed else { throw DialsError.notInstalled }
        let r = launch(args)
        guard r.code == 0 else {
            throw DialsError.failed(code: r.code, message: r.err.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return r.out
    }

    /// The one place a dials process starts. Both pipes are drained before waitUntilExit,
    /// stderr on a second queue, so a full pipe can never hold the child up.
    private static func launch(_ args: [String]) -> (code: Int32, out: String, err: String) {
        let p = Process(), out = Pipe(), err = Pipe()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = out
        p.standardError = err
        do { try p.run() } catch { return (-1, "", "could not start dials: \(error)") }
        var errData = Data()
        let drained = DispatchGroup()
        DispatchQueue.global().async(group: drained) { errData = err.fileHandleForReading.readDataToEndOfFile() }
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        drained.wait()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: outData, as: UTF8.self), String(decoding: errData, as: UTF8.self))
    }
}

/// An FSEvents stream on one folder, stopped when released.
private final class FolderWatch {
    private var stream: FSEventStreamRef?
    private let onChange: () -> Void

    init(_ dir: String, _ onChange: @escaping () -> Void) {
        self.onChange = onChange
        var ctx = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                       retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            Unmanaged<FolderWatch>.fromOpaque(info).takeUnretainedValue().onChange()
        }
        stream = FSEventStreamCreate(nil, callback, &ctx, [dir] as CFArray,
                                     FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.3,
                                     FSEventStreamCreateFlags(kFSEventStreamCreateFlagNoDefer))
        if let stream {
            FSEventStreamSetDispatchQueue(stream, DispatchQueue.main)
            FSEventStreamStart(stream)
        }
    }

    deinit {
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
    }
}
