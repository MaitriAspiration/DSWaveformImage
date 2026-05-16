import AVFoundation
import XCTest
@testable import DSWaveformImage

final class WaveformAnalyzerTests: XCTestCase {
    /// Defensive: `extract` previously called `startReading()` unconditionally, which throws an
    /// uncatchable ObjC exception when the reader isn't in `.unknown`. Normal callers always pass
    /// a fresh reader, but the guard prevents a future caller from triggering a hard crash.
    func testExtractDoesNotCrashOnCancelledReader() async throws {
        let url = try makeSilentAudioFile(durationSeconds: 1)
        defer { try? FileManager.default.removeItem(at: url) }

        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        let track = try XCTUnwrap(tracks.first)
        let reader = try AVAssetReader(asset: asset)
        let trackOutput = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ])
        reader.add(trackOutput)
        reader.cancelReading()

        let analysis = WaveformAnalyzer().extract(44_100, downsampledTo: 100, from: reader, channelSelection: .merged, fftBands: nil)
        XCTAssertEqual(analysis.amplitudes, [], "extract on a non-fresh reader should bail with empty amplitudes")
    }

    /// Sanity check: a short file analyzes cleanly via the public surface.
    func testShortFileAnalyzesCleanly() async throws {
        let url = try makeSilentAudioFile(durationSeconds: 2)
        defer { try? FileManager.default.removeItem(at: url) }

        let samples = try await WaveformAnalyzer().samples(fromAudioAt: url, count: 100)
        XCTAssertEqual(samples.count, 100)
    }

    /// Reproduces issue #93: when the read loop produces far fewer output samples than the target
    /// (e.g. the reader fails or is cancelled mid-way after backgrounding), the analyzer's
    /// end-of-loop backfill path padded the *input* buffer with
    /// `(targetSampleCount - leftSamples.count) * samplesPerPixel * 2` bytes of zeros — easily
    /// gigabytes for long files when `samplesPerPixel` is large.
    ///
    /// We simulate the condition without needing a long file or a cancelled reader: pass a
    /// deliberately inflated `totalSamples` to `extract` while reading from a short file. That
    /// makes `samplesPerPixel` huge (`totalSamples / targetSampleCount`), and the actual read
    /// only produces a handful of output samples — exactly the bug's preconditions.
    ///
    /// Post-fix expectation: backfill pads the *output* with silence-equivalent floats and
    /// doesn't allocate anywhere near the input-byte-equivalent footprint.
    func testBackfillDoesNotAllocateInputBufferWhenReadProducesFewSamples() async throws {
        let url = try makeSilentAudioFile(durationSeconds: 2) // 88_200 real samples
        defer { try? FileManager.default.removeItem(at: url) }

        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        let track = try XCTUnwrap(tracks.first)
        let reader = try AVAssetReader(asset: asset)
        let trackOutput = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ])
        reader.add(trackOutput)

        let targetSampleCount = 400
        // Lie about totalSamples to inflate samplesPerPixel. With samplesPerPixel = 25_000 and
        // only 88_200 real samples to consume, the read produces ~3 leftSamples — well under the
        // 400 target. The buggy backfill then allocates ~(397 × 25_000 × 2) = 19.85 MB of zeros
        // and a 39.7 MB Float copy. The fixed backfill allocates target-count Floats (~1.6 KB).
        let fakeTotalSamples = 10_000_000
        let buggyAllocBytes: Int64 = 19_850_000 + 39_700_000

        let (analysis, _, peakDelta) = try await measurePeakMemoryDelta {
            WaveformAnalyzer().extract(
                fakeTotalSamples,
                downsampledTo: targetSampleCount,
                from: reader,
                channelSelection: .merged,
                fftBands: nil
            )
        }

        XCTAssertNotNil(analysis)
        XCTAssertEqual(analysis?.amplitudes.count, targetSampleCount, "backfill should bring count to target")

        // Threshold at 25 % of the buggy footprint — well above any noise but well below the bug.
        let threshold = buggyAllocBytes / 4
        XCTAssertLessThan(
            peakDelta, threshold,
            "Peak alloc delta \(peakDelta / 1_000_000) MB exceeds threshold \(threshold / 1_000_000) MB — backfill is still padding the input buffer"
        )
    }
}
