import AVFoundation
import XCTest
@testable import DSWaveformImage

final class WaveformAnalyzerTests: XCTestCase {

    // MARK: - Spectral analysis

    /// `analyze(...)` must return centroids parallel to amplitudes. Mismatched counts would silently
    /// break any per-column visualization that zips them together.
    func testAnalyzeReturnsCentroidsMatchingAmplitudeCount() async throws {
        let url = try makeSineToneAudioFile(durationSeconds: 1, frequency: 1_000)
        defer { try? FileManager.default.removeItem(at: url) }

        let analysis = try await WaveformAnalyzer().analyze(fromAudioAt: url, count: 200)
        XCTAssertEqual(analysis.amplitudes.count, 200)
        XCTAssertEqual(analysis.spectralCentroids.count, 200)
    }

    /// Silent input has no spectral content to weight; centroids should fall back to the neutral 0.5
    /// rather than collapsing to either endpoint of a 2-color gradient.
    func testAnalyzeCentroidsForSilenceFallBackToMidpoint() async throws {
        let url = try makeSilentAudioFile(durationSeconds: 1)
        defer { try? FileManager.default.removeItem(at: url) }

        let analysis = try await WaveformAnalyzer().analyze(fromAudioAt: url, count: 100)
        XCTAssertEqual(analysis.spectralCentroids.count, 100)
        for c in analysis.spectralCentroids {
            XCTAssertEqual(c, 0.5, accuracy: 0.001)
        }
    }

    /// A pure 200 Hz tone (near the bass end of the default 50 Hz–Nyquist log range) should produce
    /// centroids well below the midpoint; a pure 8 kHz tone should produce centroids well above it.
    /// This is the load-bearing assertion for the whole spectral-tint feature — if it fails, color
    /// mapping won't match what the listener hears.
    func testAnalyzeCentroidsTrackInputToneFrequency() async throws {
        let lowURL = try makeSineToneAudioFile(durationSeconds: 1, frequency: 200)
        defer { try? FileManager.default.removeItem(at: lowURL) }
        let highURL = try makeSineToneAudioFile(durationSeconds: 1, frequency: 8_000)
        defer { try? FileManager.default.removeItem(at: highURL) }

        let lowAnalysis = try await WaveformAnalyzer().analyze(fromAudioAt: lowURL, count: 50)
        let highAnalysis = try await WaveformAnalyzer().analyze(fromAudioAt: highURL, count: 50)

        // Drop the first/last slot — FFT windowing can make edge frames noisy.
        let lowMid = Array(lowAnalysis.spectralCentroids.dropFirst().dropLast())
        let highMid = Array(highAnalysis.spectralCentroids.dropFirst().dropLast())
        let lowAvg = lowMid.reduce(0, +) / Float(lowMid.count)
        let highAvg = highMid.reduce(0, +) / Float(highMid.count)

        XCTAssertLessThan(lowAvg, 0.4, "200 Hz tone should sit in the lower portion of the centroid range, got \(lowAvg)")
        XCTAssertGreaterThan(highAvg, 0.6, "8 kHz tone should sit in the upper portion of the centroid range, got \(highAvg)")
        XCTAssertLessThan(lowAvg, highAvg, "low-tone centroid must be below high-tone centroid")
    }

    /// End-to-end smoke test: a `.spectralTint`-styled waveform image renders without errors and
    /// produces a non-empty bitmap. Doesn't assert exact pixel colors (that's brittle) — just that
    /// the spectral pipeline goes all the way from audio file to image.
    func testSpectralTintRendersImage() async throws {
        let url = try makeSineToneAudioFile(durationSeconds: 1, frequency: 1_000)
        defer { try? FileManager.default.removeItem(at: url) }

        let config = Waveform.Configuration(
            size: CGSize(width: 200, height: 50),
            style: .spectralTint(low: .red, high: .blue),
            scale: 1
        )
        let image = try await WaveformImageDrawer().waveformImage(fromAudioAt: url, with: config)
        XCTAssertGreaterThan(image.size.width, 0)
        XCTAssertGreaterThan(image.size.height, 0)
    }

    // MARK: - Existing
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

        let analysis = WaveformAnalyzer().extract(44_100, downsampledTo: 100, from: reader, channelSelection: .merged, fftConfig: nil)
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
                fftConfig: nil
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
