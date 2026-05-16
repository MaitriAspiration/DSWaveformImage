import AVFoundation
import Darwin
import Foundation

/// Writes a silent mono 16-bit PCM WAV file to a temporary location and returns the URL.
/// Bytes-on-disk = `durationSeconds * sampleRate * 2`. A 10-minute file is ~53 MB.
func makeSilentAudioFile(durationSeconds: Double, sampleRate: Double = 44_100) throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("dswaveform-test-\(UUID().uuidString).wav")

    let settings: [String: Any] = [
        AVFormatIDKey: kAudioFormatLinearPCM,
        AVSampleRateKey: sampleRate,
        AVNumberOfChannelsKey: 1,
        AVLinearPCMBitDepthKey: 16,
        AVLinearPCMIsBigEndianKey: false,
        AVLinearPCMIsFloatKey: false,
        AVLinearPCMIsNonInterleaved: false,
    ]
    let file = try AVAudioFile(forWriting: url, settings: settings)

    // Write in chunks so we don't allocate the whole audio file as a single PCM buffer.
    let format = file.processingFormat
    let chunkFrames: AVAudioFrameCount = 44_100 // 1 s of audio at 44.1 kHz
    let totalFrames = AVAudioFrameCount(durationSeconds * sampleRate)
    var written: AVAudioFrameCount = 0
    while written < totalFrames {
        let frames = min(chunkFrames, totalFrames - written)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else {
            throw NSError(domain: "TestSupport", code: 1, userInfo: [NSLocalizedDescriptionKey: "buffer alloc failed"])
        }
        buffer.frameLength = frames
        // The buffer is zero-initialized — that's our silence.
        try file.write(from: buffer)
        written += frames
    }
    return url
}

/// Current process physical memory footprint in bytes, via `task_vm_info`.
func currentPhysFootprint() -> Int64 {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
    let kr = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
    }
    return kr == KERN_SUCCESS ? Int64(info.phys_footprint) : 0
}

/// Runs `operation` while polling the process's physical memory footprint, returning the operation's
/// result along with the peak delta over the baseline measured immediately before the call.
func measurePeakMemoryDelta<T>(
    pollIntervalNanos: UInt64 = 5_000_000,
    during operation: () async throws -> T
) async throws -> (result: T?, error: Error?, peakDeltaBytes: Int64) {
    let baseline = currentPhysFootprint()
    let peakBox = PeakBox()
    let monitor = Task { [peakBox] in
        while !Task.isCancelled {
            let delta = currentPhysFootprint() - baseline
            await peakBox.update(delta)
            try? await Task.sleep(nanoseconds: pollIntervalNanos)
        }
    }

    let result: T?
    let caught: Error?
    do {
        result = try await operation()
        caught = nil
    } catch {
        result = nil
        caught = error
    }

    monitor.cancel()
    _ = await monitor.value
    // Pick up any final spike that may have landed between the last poll and cancel.
    await peakBox.update(currentPhysFootprint() - baseline)
    let peak = await peakBox.peak
    return (result, caught, peak)
}

private actor PeakBox {
    private(set) var peak: Int64 = 0
    func update(_ value: Int64) { peak = max(peak, value) }
}
