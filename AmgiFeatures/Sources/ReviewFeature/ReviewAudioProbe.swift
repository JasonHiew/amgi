//
//  ReviewAudioProbe.swift
//  ReviewFeature
//
//  Debug-only measurement hook. Not compiled into Release.
//

#if DEBUG
import AVFoundation
import AppCore
import Foundation

/// Thread-safe collector for interruption events raised while a mode is measured.
private final class InterruptionLog: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String] = []

    func append(_ value: String) {
        lock.lock()
        items.append(value)
        lock.unlock()
    }

    func snapshot() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return items
    }
}

/// What one mode observed while a tone played through the real review audio path.
package struct AudioProbeResult: Identifiable, Sendable {
    package let mode: String
    package let otherAudioBefore: Bool
    package let otherAudioDuring: [Bool]
    package let otherAudioAfter: Bool
    package let interruptions: [String]
    package let playedSeconds: Double

    package var id: String { mode }

    package var verdict: String {
        guard !otherAudioDuring.isEmpty else { return "no samples — tone never played" }
        let stillPlaying = otherAudioDuring.filter { $0 }.count
        let samples = otherAudioDuring.count
        switch mode {
        case "interrupt":
            // Taking a non-mixable session makes the other app's audio disappear.
            return stillPlaying == 0
                ? "took the session — background audio stopped"
                : "did NOT interrupt (\(stillPlaying)/\(samples) samples still playing)"
        case "duck":
            // Ducking leaves the other app playing, only quieter. This API cannot
            // see volume, so "kept playing" is the correct expectation here and a
            // stop would mean it interrupted instead.
            return stillPlaying == samples
                ? "background kept playing (volume not exposed to this API)"
                : "background stopped — that is interruption, not ducking"
        default:
            return stillPlaying == samples
                ? "mixed — background unaffected"
                : "background stopped while mixing"
        }
    }
}

/// Plays a tone through the genuine review audio path and reports what iOS did to
/// other apps' audio.
///
/// The simulator cannot answer any of this: its session daemon reports
/// `isOtherAudioPlaying == false` even while another app is audibly playing, and
/// delivers no interruption notifications. On device the same numbers are real.
package enum ReviewAudioProbe {
    /// Snapshot of the session as the app finds it, before the probe touches it.
    /// Shows whether something already changed the category at launch.
    package static func preflight() -> String {
        let session = AVAudioSession.sharedInstance()
        return "start: category=\(session.category.rawValue) options=\(session.categoryOptions.rawValue) otherAudio=\(session.isOtherAudioPlaying)"
    }

    /// Waits for another app's audio to be audible. Without this the whole run is
    /// vacuous: `otherAudio=no` before the first mode means there was nothing to
    /// duck or interrupt, so every "background stopped" line is a false negative.
    package static func waitForOtherAudio(seconds: Double = 25) async -> Bool {
        let session = AVAudioSession.sharedInstance()
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if session.isOtherAudioPlaying { return true }
            try? await Task.sleep(for: .milliseconds(500))
        }
        return false
    }

    /// Runs every mode in order and returns what each observed.
    package static func runAll() async -> [AudioProbeResult] {
        var results: [AudioProbeResult] = []
        for mode in [ReviewAudioPlaybackMode.mix, .duck, .interrupt] {
            results.append(await measure(mode: mode))
        }
        return results
    }

    /// Simulator entry point: `-AmgiAudioProbe mix|duck|interrupt`.
    package static func runIfRequested() {
        guard let raw = UserDefaults.standard.string(forKey: "AmgiAudioProbe") else { return }
        let mode = ReviewAudioPlaybackMode.resolved(raw)
        Task { @MainActor in
            _ = await measure(mode: mode)
        }
    }

    @MainActor
    private static func measure(mode: ReviewAudioPlaybackMode) async -> AudioProbeResult {
        let session = AVAudioSession.sharedInstance()
        let otherBefore = session.isOtherAudioPlaying
        let log = InterruptionLog()
        let observer = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: session,
            queue: .main
        ) { note in
            let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt ?? 0
            let kind = AVAudioSession.InterruptionType(rawValue: raw) == .began ? "began" : "ended"
            log.append("\(mode.rawValue): \(kind)")
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        ReviewAudioSession.apply(playInSilent: true, mode: mode)
        note("applied mode=\(mode.rawValue) options=\(session.categoryOptions.rawValue) otherAudio=\(otherBefore)")

        var during: [Bool] = []
        var played = 0.0
        if let url = writeTone(seconds: 1.5), let player = try? AVAudioPlayer(contentsOf: url) {
            player.play()
            for _ in 0..<6 {
                try? await Task.sleep(for: .milliseconds(200))
                during.append(session.isOtherAudioPlaying)
            }
            played = player.currentTime
            player.stop()
        }

        ReviewAudioSession.restoreIfNeeded(mode: mode)
        try? await Task.sleep(for: .milliseconds(900))
        let otherAfter = session.isOtherAudioPlaying
        note("done mode=\(mode.rawValue) during=\(during) after=\(otherAfter) played=\(String(format: "%.2f", played))")

        return AudioProbeResult(
            mode: mode.rawValue,
            otherAudioBefore: otherBefore,
            otherAudioDuring: during,
            otherAudioAfter: otherAfter,
            interruptions: log.snapshot(),
            playedSeconds: played
        )
    }

    private static func writeTone(seconds: Double) -> URL? {
        let rate = 44_100.0
        let total = Int(rate * seconds)
        var samples = [Int16](repeating: 0, count: total)
        for index in 0..<total {
            let value = 0.35 * sin(2.0 * Double.pi * 1_000.0 * Double(index) / rate)
            samples[index] = Int16(value * Double(Int16.max))
        }
        var data = Data()
        data.append(contentsOf: Array("RIFF".utf8))
        var chunkSize = UInt32(36 + total * 2).littleEndian
        data.append(withUnsafeBytes(of: &chunkSize) { Data($0) })
        data.append(contentsOf: Array("WAVEfmt ".utf8))
        var subchunk1 = UInt32(16).littleEndian
        data.append(withUnsafeBytes(of: &subchunk1) { Data($0) })
        var audioFormat = UInt16(1).littleEndian
        data.append(withUnsafeBytes(of: &audioFormat) { Data($0) })
        var channels = UInt16(1).littleEndian
        data.append(withUnsafeBytes(of: &channels) { Data($0) })
        var sampleRate = UInt32(rate).littleEndian
        data.append(withUnsafeBytes(of: &sampleRate) { Data($0) })
        var byteRate = UInt32(rate * 2).littleEndian
        data.append(withUnsafeBytes(of: &byteRate) { Data($0) })
        var blockAlign = UInt16(2).littleEndian
        data.append(withUnsafeBytes(of: &blockAlign) { Data($0) })
        var bitsPerSample = UInt16(16).littleEndian
        data.append(withUnsafeBytes(of: &bitsPerSample) { Data($0) })
        data.append(contentsOf: Array("data".utf8))
        var dataSize = UInt32(total * 2).littleEndian
        data.append(withUnsafeBytes(of: &dataSize) { Data($0) })
        samples.withUnsafeBufferPointer { data.append(Data(buffer: $0)) }

        let url = FileManager.default.temporaryDirectory.appendingPathComponent("amgi-probe-tone.wav")
        return (try? data.write(to: url)) != nil ? url : nil
    }

    private static func note(_ message: String) {
        NSLog("AMGI_AUDIO_PROBE %@", message)
    }
}

/// Plain-text report: keeps the type out of the module boundary, so the caller can
/// render it with whatever UI it already has. DEBUG only.
package extension ReviewAudioProbe {
    static func report(_ results: [AudioProbeResult], preflight: String? = nil) -> String {
        var lines = ["AUDIO DIAGNOSTICS"]
        if let preflight { lines.append(preflight) }
        for result in results {
            lines.append("")
            lines.append("\(result.mode.uppercased())")
            lines.append("before  otherAudio=\(result.otherAudioBefore ? "yes" : "no")")
            lines.append("during  \(result.otherAudioDuring.map { $0 ? "playing" : "stopped" }.joined(separator: ", "))")
            lines.append("after   otherAudio=\(result.otherAudioAfter ? "yes" : "no")")
            lines.append(result.verdict)
            if !result.interruptions.isEmpty {
                lines.append("interruptions: \(result.interruptions.joined(separator: "; "))")
            }
        }
        return lines.joined(separator: "\n")
    }
}
#endif
