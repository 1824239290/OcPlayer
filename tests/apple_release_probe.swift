import Darwin
import Foundation
import OcPlayerCore

@main
struct AppleReleaseProbe {
    static func require(_ condition: Bool, _ message: String) {
        if !condition {
            FileHandle.standardError.write(Data((message + "\n").utf8))
            exit(1)
        }
    }
    static func main() throws {
        // The verification executable exports no Core symbols. A loader-only
        // binding would fail here after the release linker strips unused code.
        let image = dlopen(nil, RTLD_NOW)!
        defer { dlclose(image) }
        require(dlsym(image, "ocp_core_create") == nil, "Probe must hide dynamic ABI exports")
        require(ProcessInfo.processInfo.environment["OCP_CORE_LIBRARY_PATH"] == nil, "Unexpected dynamic library override")
        require(OcpCoreClient.abiVersion == 1, "Static ABI version mismatch")
        let client = try OcpCoreClient()
        let ping = try client.call("ping")
        let event = try client.pollEvent()
        require(ping.ok && event?.kind == "core.ready", "Ping or ready event mismatch: \(String(describing: event?.kind))")
        let session = OcpPlaybackSession(client: client)!
        try session.open(uri: "release-fixture.mp4")
        try session.setRate(1.5)
        try session.setVolume(0.4)
        try session.play()
        try session.seek(seconds: 30)
        try session.pause()
        require(session.snapshot?.rate == 1.5 && session.snapshot?.volume == 0.4, "Playback rate/volume mismatch")
        require(session.snapshot?.positionSeconds == 30 && session.snapshot?.state == "paused", "Playback timeline mismatch: \(String(describing: session.snapshot))")
        let settings = try client.call("settings.backup.capabilities")
        require(settings.ok, "Backup capabilities unavailable")
        let exporter = OcpDiagnosticExport(client: client)!
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let logs = root.appendingPathComponent("logs")
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        // Native log sinks redact before writing; imported trace tails are
        // redacted by export. Exercise that actual ownership boundary here.
        try Data("record\n".utf8).write(to: logs.appendingPathComponent("diagnostics.jsonl"))
        let trace = root.appendingPathComponent("trace.txt")
        try Data("password=secret\n".utf8).write(to: trace)
        let output = root.appendingPathComponent("diagnostic.txt")
        let report = try exporter.export(logDirectory: logs, to: output, headerLines: ["release"],
                                         bodyByteBudget: nil,
                                         traces: [.init(url: trace, name: "trace", maxBytes: 1024)], username: "fixture")
        let text = try String(contentsOf: output, encoding: .utf8)
        require(!text.contains("secret") && text.contains("<redacted>"), "Diagnostic redaction mismatch")
        require(report.bytes == UInt64(text.utf8.count), "Diagnostic byte count mismatch")
#if arch(arm64)
        let architecture = "arm64"
#else
        let architecture = "x86_64"
#endif
        print("{\"architecture\":\"\(architecture)\",\"staticOnly\":true,\"abiVersion\":1,\"ping\":true,\"events\":true,\"playback\":true,\"settingsBackup\":true,\"diagnostics\":true}")
    }
}
