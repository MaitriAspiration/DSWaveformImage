import XCTest
@testable import DSWaveformImage

final class AmplitudeScalingTests: XCTestCase {

    /// `.absolute` is the no-op path: the analyzer's output is what gets drawn. Whatever the file's
    /// real loudness is, that's what shows up — loud files are tall, quiet files are short.
    func testAbsoluteScalingPassesThrough() {
        let samples: [Float] = [0.0, 0.5, 0.8, 1.0]
        let scaled = WaveformImageDrawer().applyAmplitudeScaling(samples, scaling: .absolute)
        XCTAssertEqual(scaled, samples)
    }

    /// `.normalized` shifts the loudest sample to `0` (the renderer's "loud" end) and stretches the
    /// remainder of the range so silence stays at `1`. A file whose absolute peak is `0.4` ends up
    /// with `0` as its loudest sample after scaling — i.e. it fills the canvas.
    func testNormalizedScalingMapsPeakToZero() {
        let samples: [Float] = [0.4, 0.6, 0.8, 1.0]
        let scaled = WaveformImageDrawer().applyAmplitudeScaling(samples, scaling: .normalized)
        XCTAssertEqual(scaled.first ?? -1, 0, accuracy: 0.0001, "loudest sample must map to 0")
        XCTAssertEqual(scaled.last ?? -1, 1, accuracy: 0.0001, "silence stays at 1")
        // Intermediate samples preserve their relative position in [peak, 1].
        // peak=0.4, range=0.6, so 0.6 → (0.6-0.4)/0.6 = 0.333, 0.8 → 0.666
        XCTAssertEqual(scaled[1], 0.333, accuracy: 0.001)
        XCTAssertEqual(scaled[2], 0.666, accuracy: 0.001)
    }

    /// Defensive: if the file is already at peak (some sample is `0`) there's nothing to stretch.
    /// Passing through unchanged avoids division by zero and a no-op transformation.
    func testNormalizedScalingNoOpAtPeak() {
        let samples: [Float] = [0.0, 0.5, 1.0]
        let scaled = WaveformImageDrawer().applyAmplitudeScaling(samples, scaling: .normalized)
        XCTAssertEqual(scaled, samples)
    }

    /// Defensive: an all-silent file gives `peak == 1`, so there's no range to stretch into and we
    /// pass through. Without this guard we'd divide by zero.
    func testNormalizedScalingNoOpForSilence() {
        let samples: [Float] = [1.0, 1.0, 1.0]
        let scaled = WaveformImageDrawer().applyAmplitudeScaling(samples, scaling: .normalized)
        XCTAssertEqual(scaled, samples)
    }
}
