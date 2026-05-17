//
// see
// * http://www.davidstarke.com/2015/04/waveforms.html
// * http://stackoverflow.com/questions/28626914
// for very good explanations of the asset reading and processing path
//
// FFT done using: https://github.com/jscalo/tempi-fft
//

import Foundation
import Accelerate
import AVFoundation

struct WaveformAnalysis {
    let amplitudes: [Float]
    let fft: [TempiFFT]?
}

public extension Waveform {
    /// Spectrum-aware result returned by `WaveformAnalyzer.analyze(...)`. `amplitudes` is the normal
    /// envelope (one value per requested sample slot, normalized so `0` is loud and `1` is silence,
    /// matching the rest of the rendering pipeline). `spectralCentroids` is parallel to `amplitudes`:
    /// one centroid per slot, normalized to `[0, 1]` on a logarithmic frequency scale — `0` ≈ the
    /// configured `minFrequency`, `1` ≈ Nyquist. Silent / sub-noise-floor slots fall back to `0.5`
    /// so they don't drag a spectral-tint visualization to either color extreme.
    struct SpectralAnalysis: Sendable {
        public let amplitudes: [Float]
        public let spectralCentroids: [Float]

        public init(amplitudes: [Float], spectralCentroids: [Float]) {
            self.amplitudes = amplitudes
            self.spectralCentroids = spectralCentroids
        }
    }
}

/// Calculates the waveform of the initialized asset URL.
public struct WaveformAnalyzer: Sendable {
    public enum AnalyzeError: Error {
        case generic
        case userError
        case emptyTracks
        case readerError(AVAssetReader.Status)
        /// The `channelSelection: .specific(index)` requested a channel that doesn't exist on the audio track.
        /// `available` is the actual channel count of the track.
        case invalidChannelIndex(requested: Int, available: Int)
    }

    /// Everything below this noise floor cutoff will be clipped and interpreted as silence. Default is `-50.0`.
    public var noiseFloorDecibelCutoff: Float = -50.0

    public init() {}

    /// Calculates the amplitude envelope of the initialized audio asset URL, downsampled to the required `count` amount of samples.
    /// - Parameter fromAudioAt: local filesystem URL of the audio file to process.
    /// - Parameter count: amount of samples to be calculated **per rendered channel slot**. For `.merged`
    ///   and `.specific` this is the total length of the returned array; for `.stereo` the result is
    ///   `count * 2` (left samples followed by right samples).
    /// - Parameter channelSelection: which channel(s) to extract. Default is `.merged` (all channels combined).
    /// - Parameter qos: QoS of the DispatchQueue the calculations are performed (and returned) on.
    public func samples(fromAudioAt audioAssetURL: URL, count: Int, channelSelection: Waveform.ChannelSelection = .merged, qos: DispatchQoS.QoSClass = .userInitiated) async throws -> [Float] {
        try await Task(priority: taskPriority(qos: qos)) {
            let audioAsset = AVURLAsset(url: audioAssetURL, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
            return try await samples(fromAsset: audioAsset, count: count, channelSelection: channelSelection, qos: qos)
        }.value
    }

    /// Calculates the amplitude envelope of the initialized audio asset, downsampled to the required `count` amount of samples.
    /// - Parameter audioAsset: asset of the audio file to process.
    /// - Parameter count: amount of samples to be calculated **per rendered channel slot**. For `.merged`
    ///   and `.specific` this is the total length of the returned array; for `.stereo` the result is
    ///   `count * 2` (left samples followed by right samples).
    /// - Parameter channelSelection: which channel(s) to extract. Default is `.merged` (all channels combined).
    /// - Parameter qos: QoS of the DispatchQueue the calculations are performed (and returned) on.
    public func samples(fromAsset audioAsset: AVAsset, count: Int, channelSelection: Waveform.ChannelSelection = .merged, qos: DispatchQoS.QoSClass = .userInitiated) async throws -> [Float] {
        try await Task(priority: taskPriority(qos: qos)) {
            let assetReader = try AVAssetReader(asset: audioAsset)

            guard let assetTrack = try await audioAsset.loadTracks(withMediaType: .audio).first else {
                throw AnalyzeError.emptyTracks
            }

            return try await waveformSamples(track: assetTrack, reader: assetReader, count: count, channelSelection: channelSelection, fftConfig: nil).amplitudes
        }.value
    }

    /// Calculates the amplitude envelope of the initialized audio asset URL, downsampled to the required `count` amount of samples.
    /// - Parameter fromAudioAt: local filesystem URL of the audio file to process.
    /// - Parameter count: amount of samples to be calculated. Downsamples.
    /// - Parameter qos: QoS of the DispatchQueue the calculations are performed (and returned) on.
    public func samples(fromAudioAt audioAssetURL: URL, count: Int, qos: DispatchQoS.QoSClass = .userInitiated) async throws -> [Float] {
        try await samples(fromAudioAt: audioAssetURL, count: count, channelSelection: .merged, qos: qos)
    }

    /// Calculates both the amplitude envelope and a parallel array of normalized spectral centroids.
    /// Use this when you want to drive a spectrum-aware visualization (e.g. `Waveform.Style.spectralTint`).
    ///
    /// - Parameter fromAudioAt: local filesystem URL of the audio file to process.
    /// - Parameter count: number of output amplitude slots; centroid count matches.
    /// - Parameter bandsPerOctave: log-spaced spectrum resolution. Default `4` (quarter-octave) is
    ///   musically meaningful and cheap.
    /// - Parameter minFrequency: lower edge of the log-frequency mapping. Default `50 Hz` brushes the
    ///   bottom of the bass range without picking up rumble.
    /// - Parameter channelSelection: which channel(s) to extract. Default `.merged`.
    /// - Parameter qos: QoS of the DispatchQueue the calculations are performed (and returned) on.
    public func analyze(
        fromAudioAt audioAssetURL: URL,
        count: Int,
        bandsPerOctave: Int = 4,
        minFrequency: Float = 50,
        channelSelection: Waveform.ChannelSelection = .merged,
        qos: DispatchQoS.QoSClass = .userInitiated
    ) async throws -> Waveform.SpectralAnalysis {
        try await Task(priority: taskPriority(qos: qos)) {
            let audioAsset = AVURLAsset(url: audioAssetURL, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
            let assetReader = try AVAssetReader(asset: audioAsset)
            guard let assetTrack = try await audioAsset.loadTracks(withMediaType: .audio).first else {
                throw AnalyzeError.emptyTracks
            }
            let analysis = try await waveformSamples(
                track: assetTrack,
                reader: assetReader,
                count: count,
                channelSelection: channelSelection,
                fftConfig: FFTConfig(bandsPerOctave: bandsPerOctave, minFrequency: minFrequency)
            )
            let centroids = WaveformAnalyzer.spectralCentroids(
                from: analysis.fft ?? [],
                amplitudeCount: analysis.amplitudes.count,
                minFrequency: minFrequency
            )
            return Waveform.SpectralAnalysis(amplitudes: analysis.amplitudes, spectralCentroids: centroids)
        }.value
    }

    /// Calculates the amplitude envelope of the initialized audio asset URL, downsampled to the required `count` amount of samples.
    /// - Parameter fromAudioAt: local filesystem URL of the audio file to process.
    /// - Parameter count: amount of samples to be calculated. Downsamples.
    /// - Parameter qos: QoS of the DispatchQueue the calculations are performed (and returned) on.
    /// - Parameter completionHandler: called from a background thread. Returns the sampled result `[Float]` or `Error`.
    ///
    /// Calls the completionHandler on a background thread.
    @available(*, deprecated, renamed: "samples(fromAudioAt:count:qos:)")
    public func samples(fromAudioAt audioAssetURL: URL, count: Int, qos: DispatchQoS.QoSClass = .userInitiated, completionHandler: @escaping (Result<[Float], Error>) -> ()) {
        Task {
            do {
                let samples = try await samples(fromAudioAt: audioAssetURL, count: count, qos: qos)
                completionHandler(.success(samples))
            } catch {
                completionHandler(.failure(error))
            }
        }
    }
}

// MARK: - Private

/// Parameters that drive log-spaced FFT banding. `nil` everywhere it appears means "skip FFT entirely"
/// — the cheap path used by callers that only want the amplitude envelope.
struct FFTConfig: Sendable {
    let bandsPerOctave: Int
    let minFrequency: Float
}

internal extension WaveformAnalyzer {
    func waveformSamples(
            track audioAssetTrack: AVAssetTrack,
            reader assetReader: AVAssetReader,
            count requiredNumberOfSamples: Int,
            channelSelection: Waveform.ChannelSelection = .merged,
            fftConfig: FFTConfig?
    ) async throws -> WaveformAnalysis {
        guard requiredNumberOfSamples > 0 else {
            throw AnalyzeError.userError
        }

        let trackOutput = AVAssetReaderTrackOutput(track: audioAssetTrack, outputSettings: outputSettings(channelSelection: channelSelection))
        assetReader.add(trackOutput)

        if case .specific(let channelIndex) = channelSelection,
           let info = channelInfo(from: assetReader),
           channelIndex < 0 || channelIndex >= info.channelCount {
            throw AnalyzeError.invalidChannelIndex(requested: channelIndex, available: info.channelCount)
        }

        let totalSamples = try await totalSamples(of: audioAssetTrack, channelSelection: channelSelection)
        let analysis = extract(totalSamples, downsampledTo: requiredNumberOfSamples, from: assetReader, channelSelection: channelSelection, fftConfig: fftConfig)

        switch assetReader.status {
        case .completed:
            return analysis
        default:
            print("ERROR: reading waveform audio data has failed \(assetReader.status)")
            throw AnalyzeError.readerError(assetReader.status)
        }
    }

    func extract(
        _ totalSamples: Int,
        downsampledTo targetSampleCount: Int,
        from assetReader: AVAssetReader,
        channelSelection: Waveform.ChannelSelection = .merged,
        fftConfig: FFTConfig?
    ) -> WaveformAnalysis {
        let isStereo = (channelSelection == .stereo)
        var leftSamples = [Float]()
        var rightSamples = [Float]()
        var outputFFT = fftConfig == nil ? nil : [TempiFFT]()
        var sampleBuffer = Data()
        var sampleBufferFFT = Data()

        // read upfront to avoid frequent re-calculation (and memory bloat from C-bridging)
        let samplesPerPixel = max(1, totalSamples / targetSampleCount)
        let samplesPerFFT = 4096 // ~100ms at 44.1kHz, rounded to closest pow(2) for FFT

        // Use the track's real sample rate so FFT band frequencies (and any derived centroid) are
        // accurate. Default to 44.1 kHz only if the format description is unavailable for some reason
        // — that's the same constant the code used to hardcode, so this path is no worse than before.
        let sampleRate: Float = channelInfo(from: assetReader).map { Float($0.basicDescription.mSampleRate) } ?? 44_100

        // `startReading()` throws an uncatchable ObjC exception if the reader isn't in `.unknown`
        // (e.g. already cancelled or failed). Normal callers always pass a fresh reader, but bail
        // gracefully if that contract is violated so we surface as `readerError` rather than crash.
        guard assetReader.status == .unknown else {
            return WaveformAnalysis(amplitudes: [], fft: outputFFT)
        }
        assetReader.startReading()
        while assetReader.status == .reading {
            // CMSampleBuffer is a Core Foundation type that lives in the autorelease pool.
            // Without an explicit drain per iteration, long files iterate thousands of times and
            // can keep gigabytes of buffer memory pinned until the loop exits.
            let continueReading = autoreleasepool { () -> Bool in
                let trackOutput = assetReader.outputs.first!

                guard let nextSampleBuffer = trackOutput.copyNextSampleBuffer(),
                    let blockBuffer = CMSampleBufferGetDataBuffer(nextSampleBuffer) else {
                        return false
                }

                var readBufferLength = 0
                var readBufferPointer: UnsafeMutablePointer<Int8>? = nil
                CMBlockBufferGetDataPointer(blockBuffer, atOffset: 0, lengthAtOffsetOut: &readBufferLength, totalLengthOut: nil, dataPointerOut: &readBufferPointer)
                sampleBuffer.append(UnsafeBufferPointer(start: readBufferPointer, count: readBufferLength))
                if fftConfig != nil {
                    // don't append data to this buffer unless we're going to use it.
                    sampleBufferFFT.append(UnsafeBufferPointer(start: readBufferPointer, count: readBufferLength))
                }
                CMSampleBufferInvalidate(nextSampleBuffer)

                let result = process(sampleBuffer, from: assetReader, downsampleTo: samplesPerPixel, channelSelection: channelSelection)
                leftSamples += result.left
                rightSamples += result.right

                if result.bytesConsumed > 0 {
                    sampleBuffer.removeFirst(result.bytesConsumed)

                    // this takes care of a memory leak where Memory continues to increase even though it should clear after calling .removeFirst(…) above.
                    sampleBuffer = Data(sampleBuffer)
                }

                if let fftConfig = fftConfig, sampleBufferFFT.count / MemoryLayout<Int16>.size >= samplesPerFFT {
                    let processedFFTs = process(sampleBufferFFT, samplesPerFFT: samplesPerFFT, sampleRate: sampleRate, fftConfig: fftConfig)
                    sampleBufferFFT.removeFirst(processedFFTs.count * samplesPerFFT * MemoryLayout<Int16>.size)
                    outputFFT? += processedFFTs
                }
                return true
            }
            if !continueReading { break }
        }

        // Pad the *output* with silence-equivalent dB values when the read produced fewer samples
        // than the target — e.g. a short tail or a reader that ended early (failed/cancelled after
        // backgrounding). These become 1.0 (silence) after `normalize`. Allocation is
        // O(targetSampleCount), independent of audio duration — the previous implementation padded
        // the *input* buffer with up to `target × samplesPerPixel × 2` bytes of zeros, which
        // crashed on multi-hour files (issue #93). We only pad on a clean read; a non-`.completed`
        // status means `waveformSamples` will throw and the result is discarded anyway, so skip the
        // wasted work.
        if assetReader.status == .completed {
            if leftSamples.count < targetSampleCount {
                let missing = targetSampleCount - leftSamples.count
                leftSamples.append(contentsOf: repeatElement(noiseFloorDecibelCutoff, count: missing))
            }
            if isStereo, rightSamples.count < targetSampleCount {
                let missing = targetSampleCount - rightSamples.count
                rightSamples.append(contentsOf: repeatElement(noiseFloorDecibelCutoff, count: missing))
            }
        }

        let amplitudes: [Float]
        if isStereo {
            // Renderers in `.stereo` mode expect samples laid out as [allLeft..., allRight...]
            amplitudes = Array(leftSamples.prefix(targetSampleCount)) + Array(rightSamples.prefix(targetSampleCount))
        } else {
            amplitudes = Array(leftSamples.prefix(targetSampleCount))
        }
        return WaveformAnalysis(amplitudes: normalize(amplitudes), fft: outputFFT)
    }

    /// Result of processing one buffer chunk. `right` is populated only for `.stereo`. `bytesConsumed`
    /// is how many bytes of the interleaved input buffer the caller should drop, since it varies with
    /// channel count and which channels we actually consumed.
    private struct ProcessResult {
        let left: [Float]
        let right: [Float]
        let bytesConsumed: Int

        static let empty = ProcessResult(left: [], right: [], bytesConsumed: 0)
    }

    private func process(_ sampleBuffer: Data, from assetReader: AVAssetReader, downsampleTo samplesPerPixel: Int, channelSelection: Waveform.ChannelSelection) -> ProcessResult {
        let sampleLength = sampleBuffer.count / MemoryLayout<Int16>.size

        // guard for crash in very long audio files
        guard sampleLength / samplesPerPixel > 0 else { return .empty }

        var result: ProcessResult = .empty

        sampleBuffer.withUnsafeBytes { (samplesRawPointer: UnsafeRawBufferPointer) in
            let basePointer = samplesRawPointer.bindMemory(to: Int16.self).baseAddress!

            switch channelSelection {
            case .merged:
                // Treat the interleaved buffer as a single stream — matches the original behavior.
                let left = downsample(from: basePointer, count: sampleLength, stride: 1, samplesPerPixel: samplesPerPixel)
                result = ProcessResult(left: left, right: [], bytesConsumed: left.count * samplesPerPixel * MemoryLayout<Int16>.size)

            case .specific(let channelIndex):
                guard let info = channelInfo(from: assetReader),
                      channelIndex >= 0 && channelIndex < info.channelCount else { return }
                let perChannelLength = sampleLength / info.channelCount
                let left = downsample(
                    from: basePointer.advanced(by: channelIndex),
                    count: perChannelLength,
                    stride: info.channelCount,
                    samplesPerPixel: samplesPerPixel
                )
                result = ProcessResult(left: left, right: [], bytesConsumed: left.count * samplesPerPixel * info.channelCount * MemoryLayout<Int16>.size)

            case .stereo:
                guard let info = channelInfo(from: assetReader) else { return }
                if info.channelCount < 2 {
                    // Mono input: mirror the single channel into both top and bottom halves so a
                    // stereo renderer still produces something sensible.
                    let samples = downsample(from: basePointer, count: sampleLength, stride: 1, samplesPerPixel: samplesPerPixel)
                    result = ProcessResult(left: samples, right: samples, bytesConsumed: samples.count * samplesPerPixel * MemoryLayout<Int16>.size)
                } else {
                    // For >2 channels we only visualize the first two as left/right; the rest are dropped.
                    let perChannelLength = sampleLength / info.channelCount
                    let left = downsample(from: basePointer, count: perChannelLength, stride: info.channelCount, samplesPerPixel: samplesPerPixel)
                    let right = downsample(from: basePointer.advanced(by: 1), count: perChannelLength, stride: info.channelCount, samplesPerPixel: samplesPerPixel)
                    result = ProcessResult(left: left, right: right, bytesConsumed: left.count * samplesPerPixel * info.channelCount * MemoryLayout<Int16>.size)
                }
            }
        }

        return result
    }

    /// abs → dB → clip → desamp pipeline shared across all channel-selection modes.
    private func downsample(from pointer: UnsafePointer<Int16>, count: Int, stride: Int, samplesPerPixel: Int) -> [Float] {
        var loudestClipValue: Float = 0.0
        var quietestClipValue = noiseFloorDecibelCutoff
        var zeroDbEquivalent: Float = Float(Int16.max)
        let samplesToProcess = vDSP_Length(count)

        var buffer = [Float](repeating: 0.0, count: count)
        vDSP_vflt16(pointer, vDSP_Stride(stride), &buffer, 1, samplesToProcess)
        vDSP_vabs(buffer, 1, &buffer, 1, samplesToProcess)
        vDSP_vdbcon(buffer, 1, &zeroDbEquivalent, &buffer, 1, samplesToProcess, 1)
        vDSP_vclip(buffer, 1, &quietestClipValue, &loudestClipValue, &buffer, 1, samplesToProcess)

        let filter = [Float](repeating: 1.0 / Float(samplesPerPixel), count: samplesPerPixel)
        let downSampledLength = count / samplesPerPixel
        var downSampled = [Float](repeating: 0.0, count: downSampledLength)
        vDSP_desamp(buffer, vDSP_Stride(samplesPerPixel), filter, &downSampled, vDSP_Length(downSampledLength), vDSP_Length(samplesPerPixel))
        return downSampled
    }

    private func process(_ sampleBuffer: Data, samplesPerFFT: Int, sampleRate: Float, fftConfig: FFTConfig) -> [TempiFFT] {
        var ffts = [TempiFFT]()
        let sampleLength = sampleBuffer.count / MemoryLayout<Int16>.size
        sampleBuffer.withUnsafeBytes { (samplesRawPointer: UnsafeRawBufferPointer) in
            let unsafeSamplesBufferPointer = samplesRawPointer.bindMemory(to: Int16.self)
            let unsafeSamplesPointer = unsafeSamplesBufferPointer.baseAddress!
            let samplesToProcess = vDSP_Length(sampleLength)

            var processingBuffer = [Float](repeating: 0.0, count: Int(samplesToProcess))
            vDSP_vflt16(unsafeSamplesPointer, 1, &processingBuffer, 1, samplesToProcess) // convert 16bit int to float

            repeat {
                let fftBuffer = processingBuffer[0..<samplesPerFFT]
                let fft = TempiFFT(withSize: samplesPerFFT, sampleRate: sampleRate)
                fft.windowType = TempiFFTWindowType.hanning
                fft.fftForward(Array(fftBuffer))
                fft.calculateLogarithmicBands(
                    minFrequency: fftConfig.minFrequency,
                    maxFrequency: fft.nyquistFrequency,
                    bandsPerOctave: fftConfig.bandsPerOctave
                )
                ffts.append(fft)

                processingBuffer.removeFirst(samplesPerFFT)
            } while processingBuffer.count >= samplesPerFFT
        }
        return ffts
    }

    /// Collapses an array of per-frame FFT results into a single centroid per amplitude slot, normalized
    /// to `[0, 1]` on a log-frequency scale. Centroid is computed in log-frequency space (weighted by
    /// band magnitudes), which is what reads "musically" when used to color a waveform.
    ///
    /// When `fftFrames.count > amplitudeCount` (typical: a multi-second file at ~10 FFT frames/sec vs.
    /// hundreds of output pixels), we average the centroids of frames mapped to each slot. When it's
    /// the other way (very short files), each slot picks the single closest frame. Silent slots
    /// (sum-of-magnitudes ≈ 0) get `0.5` so they don't pull a 2-color gradient toward either extreme.
    static func spectralCentroids(from fftFrames: [TempiFFT], amplitudeCount: Int, minFrequency: Float) -> [Float] {
        guard amplitudeCount > 0 else { return [] }
        guard !fftFrames.isEmpty else {
            return Array(repeating: 0.5, count: amplitudeCount)
        }

        // Compute a per-frame log-centroid in [0, 1].
        let frameCount = fftFrames.count
        let nyquist = fftFrames[0].nyquistFrequency
        let logMin = logf(max(minFrequency, 1))
        let logMax = logf(max(nyquist, minFrequency + 1))
        let logSpan = max(logMax - logMin, .leastNormalMagnitude)

        var perFrame = [Float](repeating: 0.5, count: frameCount)
        for (idx, fft) in fftFrames.enumerated() {
            let bandCount = fft.numberOfBands
            guard bandCount > 0 else { continue }
            var weightedLog: Float = 0
            var totalMag: Float = 0
            for b in 0..<bandCount {
                let mag = fft.bandMagnitudes[b]
                let freq = fft.bandFrequencies[b]
                if mag > 0, freq > 0 {
                    weightedLog += logf(freq) * mag
                    totalMag += mag
                }
            }
            if totalMag > 0 {
                let logCentroid = weightedLog / totalMag
                perFrame[idx] = min(1, max(0, (logCentroid - logMin) / logSpan))
            } // else stays 0.5 — silence
        }

        // Re-bin to amplitudeCount slots. Both directions handled by the same math:
        // map slot i to the frame range [i * frameCount / N, (i+1) * frameCount / N).
        var out = [Float](repeating: 0.5, count: amplitudeCount)
        for i in 0..<amplitudeCount {
            let start = (i * frameCount) / amplitudeCount
            let end = max(start + 1, ((i + 1) * frameCount) / amplitudeCount)
            let clampedEnd = min(end, frameCount)
            if clampedEnd <= start {
                out[i] = perFrame[min(start, frameCount - 1)]
            } else {
                var sum: Float = 0
                for j in start..<clampedEnd { sum += perFrame[j] }
                out[i] = sum / Float(clampedEnd - start)
            }
        }
        return out
    }

    func normalize(_ samples: [Float]) -> [Float] {
        samples.map { $0 / noiseFloorDecibelCutoff }
    }
    
    private func channelInfo(from assetReader: AVAssetReader) -> (channelCount: Int, basicDescription: AudioStreamBasicDescription)? {
        guard let trackOutput = assetReader.outputs.first as? AVAssetReaderTrackOutput,
              let formatDescription = (trackOutput.track.formatDescriptions as? [CMFormatDescription])?.first,
              let basicDescription = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription) else {
            return nil
        }
        return (Int(basicDescription.pointee.mChannelsPerFrame), basicDescription.pointee)
    }

    private func totalSamples(of audioAssetTrack: AVAssetTrack, channelSelection: Waveform.ChannelSelection) async throws -> Int {
        var totalSamples = 0
        let (descriptions, timeRange) = try await audioAssetTrack.load(.formatDescriptions, .timeRange)

        descriptions.forEach { formatDescription in
            guard let basicDescription = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription) else { return }
            let channelCount = Int(basicDescription.pointee.mChannelsPerFrame)
            let sampleRate = basicDescription.pointee.mSampleRate
            let oneChannelSamples = Int(sampleRate * timeRange.duration.seconds)

            switch channelSelection {
            case .merged:
                // The interleaved buffer is treated as a single stream — count every Int16.
                totalSamples = oneChannelSamples * channelCount
            case .specific, .stereo:
                // We process per-channel, so `samplesPerPixel` is derived from one channel's count.
                totalSamples = oneChannelSamples
            }
        }
        return totalSamples
    }
}

// MARK: - Configuration

private extension WaveformAnalyzer {
    func outputSettings(channelSelection: Waveform.ChannelSelection) -> [String: Any] {
        // Always use interleaved format - it's simpler to work with
        return [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]
    }

    func taskPriority(qos: DispatchQoS.QoSClass) -> TaskPriority {
        switch qos {
        case .background: return .background
        case .utility: return .utility
        case .default: return .medium
        case .userInitiated: return .userInitiated
        case .userInteractive: return .high
        case .unspecified: return .medium
        @unknown default: return .medium
        }
    }
}
