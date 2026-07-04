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

/// Calculates the waveform of the initialized asset URL.
public class WaveformAnalyzer {
    public enum AnalyzeError: Error {
        case generic
        /// The requested sample count was <= 0.
        case invalidSampleCount
        /// The asset's `duration` could not be loaded.
        case durationLoadFailed(Error?)
        /// The `AVAssetReader` did not finish reading (e.g. failed under memory pressure).
        /// Carries `assetReader.error` when available.
        case readingFailed(status: AVAssetReader.Status, underlying: Error?)
    }

    /// Everything below this noise floor cutoff will be clipped and interpreted as silence. Default is `-50.0`.
    public var noiseFloorDecibelCutoff: Float = -50.0

    /// Sample rate (Hz) the audio is decoded at for analysis. Lower values dramatically reduce
    /// memory/CPU for long files with no visible impact on the amplitude envelope. Default is `8000`.
    public var analysisSampleRate: Double = 8000

    private let assetReader: AVAssetReader
    private let audioAssetTrack: AVAssetTrack

    public init?(audioAssetURL: URL) {
        let audioAsset = AVURLAsset(url: audioAssetURL, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])

        do {
            let assetReader = try AVAssetReader(asset: audioAsset)
            guard let assetTrack = audioAsset.tracks(withMediaType: .audio).first else {
                print("ERROR loading asset track")
                return nil
            }

            self.assetReader = assetReader
            self.audioAssetTrack = assetTrack
        } catch {
            print("ERROR loading asset \(error)")
            return nil
        }
    }

#if compiler(>=5.5) && canImport(_Concurrency)
    /// Calculates the amplitude envelope of the initialized audio asset URL, downsampled to the required `count` amount of samples.
    /// Calls the completionHandler on a background thread.
    /// - Parameter count: amount of samples to be calculated. Downsamples.
    /// - Parameter qos: QoS of the DispatchQueue the calculations are performed (and returned) on.
    ///
    /// Returns sampled result or nil in edge-error cases.
    public func samples(count: Int, qos: DispatchQoS.QoSClass = .userInitiated) async throws -> [Float] {
        try await withCheckedThrowingContinuation { continuation in
            waveformSamples(count: count, qos: qos, fftBands: nil) { result in
                continuation.resume(with: result.map { $0.amplitudes })
            }
        }
    }
#endif

    /// Calculates the amplitude envelope of the initialized audio asset URL, downsampled to the required `count` amount of samples.
    /// Calls the completionHandler on a background thread.
    /// - Parameter count: amount of samples to be calculated. Downsamples.
    /// - Parameter qos: QoS of the DispatchQueue the calculations are performed (and returned) on.
    /// - Parameter completionHandler: called from a background thread. Returns the sampled result or nil in edge-error cases.
    public func samples(count: Int, qos: DispatchQoS.QoSClass = .userInitiated, completionHandler: @escaping (_ amplitudes: [Float]?) -> ()) {
        waveformSamples(count: count, qos: qos, fftBands: nil) { result in
            switch result {
            case .success(let analysis):
                completionHandler(analysis.amplitudes)
            case .failure(let error):
                print("ERROR: waveform analysis failed: \(error)")
                completionHandler(nil)
            }
        }
    }
}

// MARK: - Private

fileprivate extension WaveformAnalyzer {
    func waveformSamples(
            count requiredNumberOfSamples: Int,
            qos: DispatchQoS.QoSClass,
            fftBands: Int?,
            completionHandler: @escaping (_ result: Result<WaveformAnalysis, AnalyzeError>) -> ()) {
        guard requiredNumberOfSamples > 0 else {
            completionHandler(.failure(.invalidSampleCount))
            return
        }

        let trackOutput = AVAssetReaderTrackOutput(track: audioAssetTrack, outputSettings: outputSettings())
        assetReader.add(trackOutput)

        assetReader.asset.loadValuesAsynchronously(forKeys: ["duration"]) {
            var error: NSError?
            let status = self.assetReader.asset.statusOfValue(forKey: "duration", error: &error)
            switch status {
            case .loaded:
                let totalSamples = self.totalSamplesOfTrack()
                DispatchQueue.global(qos: qos).async {
                    let analysis = self.extract(totalSamples: totalSamples, downsampledTo: requiredNumberOfSamples, fftBands: fftBands)

                    switch self.assetReader.status {
                    case .completed:
                        completionHandler(.success(analysis))
                    default:
                        // Surface the actual reader error (e.g. a failure under memory pressure on a
                        // long file) instead of silently returning nil, so callers can diagnose it.
                        completionHandler(.failure(.readingFailed(status: self.assetReader.status, underlying: self.assetReader.error)))
                    }
                }

            case .failed, .cancelled, .loading, .unknown:
                completionHandler(.failure(.durationLoadFailed(error)))
            @unknown default:
                completionHandler(.failure(.durationLoadFailed(error)))
            }
        }
    }

    func extract(totalSamples: Int,
                 downsampledTo targetSampleCount: Int,
                 fftBands: Int?) -> WaveformAnalysis {
        var outputSamples = [Float]()
        var outputFFT = fftBands == nil ? nil : [TempiFFT]()
        var sampleBuffer = Data()
        var sampleBufferFFT = Data()

        // Guard against invalid inputs that would otherwise crash below:
        // - targetSampleCount == 0 -> integer division by zero at samplesPerPixel
        // - totalSamples <= 0 -> nothing to process
        guard targetSampleCount > 0, totalSamples > 0 else {
            return WaveformAnalysis(amplitudes: [], fft: outputFFT)
        }

        // read upfront to avoid frequent re-calculation (and memory bloat from C-bridging)
        let samplesPerPixel = max(1, totalSamples / targetSampleCount)
        let samplesPerFFT = 4096 // ~100ms at 44.1kHz, rounded to closest pow(2) for FFT

        // Build the averaging filter once. It is `samplesPerPixel` elements long and was
        // previously re-allocated on every emitted pixel inside `process(...)`, which for long
        // audio (large `samplesPerPixel`) meant repeated multi-MB allocations and heavy churn.
        let averagingFilter = [Float](repeating: 1.0 / Float(samplesPerPixel), count: samplesPerPixel)

        // Bail out explicitly if the reader can't start, so callers see a failed status
        // instead of silently receiving an empty waveform.
        guard assetReader.startReading() else {
            return WaveformAnalysis(amplitudes: [], fft: outputFFT)
        }

        outputSamples.reserveCapacity(targetSampleCount)

        while assetReader.status == .reading {
            // CRITICAL: each `copyNextSampleBuffer()` makes AVFoundation's decoder produce a
            // fresh buffer plus autoreleased internal allocations. `CMSampleBufferInvalidate`
            // frees the buffer's data but NOT that autoreleased memory, which is only drained
            // when the enclosing scope returns. Since `extract(...)` runs as one long block on a
            // global queue, without a per-iteration pool the undrained memory grows linearly with
            // duration (~100k buffers on a 1h45m file), spiking until the OS jetsam-kills the app
            // before the read reaches `.completed`. Draining every iteration keeps peak memory
            // flat regardless of audio length, so files longer than 2 hours complete reliably.
            let reachedEnd: Bool = autoreleasepool {
                guard let trackOutput = assetReader.outputs.first,
                      let nextSampleBuffer = trackOutput.copyNextSampleBuffer(),
                      let blockBuffer = CMSampleBufferGetDataBuffer(nextSampleBuffer) else {
                    return true
                }

                var readBufferLength = 0
                var readBufferPointer: UnsafeMutablePointer<Int8>? = nil
                CMBlockBufferGetDataPointer(blockBuffer, atOffset: 0, lengthAtOffsetOut: &readBufferLength, totalLengthOut: nil, dataPointerOut: &readBufferPointer)
                sampleBuffer.append(UnsafeBufferPointer(start: readBufferPointer, count: readBufferLength))
                if fftBands != nil {
                    // don't append data to this buffer unless we're going to use it.
                    sampleBufferFFT.append(UnsafeBufferPointer(start: readBufferPointer, count: readBufferLength))
                }
                CMSampleBufferInvalidate(nextSampleBuffer)

                let processedSamples = process(sampleBuffer, from: assetReader, downsampleTo: samplesPerPixel, filter: averagingFilter)
                outputSamples += processedSamples

                if processedSamples.count > 0 {
                    // vDSP_desamp uses strides of samplesPerPixel; remove only the processed ones
                    sampleBuffer.removeFirst(processedSamples.count * samplesPerPixel * MemoryLayout<Int16>.size)

                    // this takes care of a memory leak where Memory continues to increase even though it should clear after calling .removeFirst(…) above.
                    sampleBuffer = Data(sampleBuffer)
                }

                if let fftBands = fftBands, sampleBufferFFT.count / MemoryLayout<Int16>.size >= samplesPerFFT {
                    let processedFFTs = process(sampleBufferFFT, samplesPerFFT: samplesPerFFT, fftBands: fftBands)
                    sampleBufferFFT.removeFirst(processedFFTs.count * samplesPerFFT * MemoryLayout<Int16>.size)
                    outputFFT? += processedFFTs
                }

                return false
            }

            if reachedEnd { break }
        }

        // if we don't have enough pixels yet,
        // process leftover samples with padding (to reach multiple of samplesPerPixel for vDSP_desamp)
        //
        // Only backfill after a *successful* read. On a partial/failed read of a long file
        // `outputSamples.count` stays small, so `missingSampleCount` (≈ targetSampleCount *
        // samplesPerPixel ≈ totalSamples) would allocate a zero buffer roughly the size of the
        // entire decoded file (potentially gigabytes) and OOM-crash. Gating on `.completed`
        // guarantees `sampleBuffer` holds at most one leftover `samplesPerPixel` window.
        if outputSamples.count < targetSampleCount, assetReader.status == .completed {
            let missingSampleCount = (targetSampleCount - outputSamples.count) * samplesPerPixel
            let existingSampleCount = sampleBuffer.count / MemoryLayout<Int16>.size
            // Clamp to zero: leftover samples in `sampleBuffer` can exceed `missingSampleCount`,
            // which would otherwise make the count negative and crash Array/Data with
            // "Can't construct Array with negative count".
            let backfillPaddingSampleCount = max(0, missingSampleCount - existingSampleCount)
            let backfillPaddingSampleCount16 = backfillPaddingSampleCount * MemoryLayout<Int16>.size
            if backfillPaddingSampleCount16 > 0 {
                let backfillPaddingSamples = [UInt8](repeating: 0, count: backfillPaddingSampleCount16)
                sampleBuffer.append(backfillPaddingSamples, count: backfillPaddingSampleCount16)
            }
            let processedSamples = process(sampleBuffer, from: assetReader, downsampleTo: samplesPerPixel, filter: averagingFilter)
            outputSamples += processedSamples
        }

        // Clamp instead of forcing a fixed width: after a short/failed read `outputSamples`
        // can still be smaller than `targetSampleCount`, which would crash the slice with
        // "Array slice index is out of range".
        let safeCount = min(outputSamples.count, targetSampleCount)
        let targetSamples = Array(outputSamples[0..<safeCount])
        return WaveformAnalysis(amplitudes: normalize(targetSamples), fft: outputFFT)
    }

    private func process(_ sampleBuffer: Data,
                         from assetReader: AVAssetReader,
                         downsampleTo samplesPerPixel: Int,
                         filter: [Float]) -> [Float] {
        var downSampledData = [Float]()
        let sampleLength = sampleBuffer.count / MemoryLayout<Int16>.size

        // guard for crash in very long audio files, empty buffers (nil baseAddress),
        // and division by zero when samplesPerPixel <= 0
        guard samplesPerPixel > 0, sampleLength / samplesPerPixel > 0, filter.count == samplesPerPixel else { return downSampledData }

        sampleBuffer.withUnsafeBytes { (samplesRawPointer: UnsafeRawBufferPointer) in
            let unsafeSamplesBufferPointer = samplesRawPointer.bindMemory(to: Int16.self)
            guard let unsafeSamplesPointer = unsafeSamplesBufferPointer.baseAddress else { return }
            var loudestClipValue: Float = 0.0
            var quietestClipValue = noiseFloorDecibelCutoff
            var zeroDbEquivalent: Float = Float(Int16.max) // maximum amplitude storable in Int16 = 0 Db (loudest)
            let samplesToProcess = vDSP_Length(sampleLength)

            var processingBuffer = [Float](repeating: 0.0, count: Int(samplesToProcess))
            vDSP_vflt16(unsafeSamplesPointer, 1, &processingBuffer, 1, samplesToProcess) // convert 16bit int to float (
            vDSP_vabs(processingBuffer, 1, &processingBuffer, 1, samplesToProcess) // absolute amplitude value
            vDSP_vdbcon(processingBuffer, 1, &zeroDbEquivalent, &processingBuffer, 1, samplesToProcess, 1) // convert to DB
            vDSP_vclip(processingBuffer, 1, &quietestClipValue, &loudestClipValue, &processingBuffer, 1, samplesToProcess)

            let downSampledLength = sampleLength / samplesPerPixel
            downSampledData = [Float](repeating: 0.0, count: downSampledLength)

            vDSP_desamp(processingBuffer,
                        vDSP_Stride(samplesPerPixel),
                        filter,
                        &downSampledData,
                        vDSP_Length(downSampledLength),
                        vDSP_Length(samplesPerPixel))
        }

        return downSampledData
    }

    private func process(_ sampleBuffer: Data,
                         samplesPerFFT: Int,
                         fftBands: Int) -> [TempiFFT] {
        var ffts = [TempiFFT]()
        let sampleLength = sampleBuffer.count / MemoryLayout<Int16>.size
        // Need at least one full FFT window; also guards against a nil baseAddress.
        guard samplesPerFFT > 0, fftBands > 0, sampleLength >= samplesPerFFT else { return ffts }
        sampleBuffer.withUnsafeBytes { (samplesRawPointer: UnsafeRawBufferPointer) in
            let unsafeSamplesBufferPointer = samplesRawPointer.bindMemory(to: Int16.self)
            guard let unsafeSamplesPointer = unsafeSamplesBufferPointer.baseAddress else { return }
            let samplesToProcess = vDSP_Length(sampleLength)

            var processingBuffer = [Float](repeating: 0.0, count: Int(samplesToProcess))
            vDSP_vflt16(unsafeSamplesPointer, 1, &processingBuffer, 1, samplesToProcess) // convert 16bit int to float

            repeat {
                let fftBuffer = processingBuffer[0..<samplesPerFFT]
                let fft = TempiFFT(withSize: samplesPerFFT, sampleRate: 44100.0)
                fft.windowType = TempiFFTWindowType.hanning
                fft.fftForward(Array(fftBuffer))
                fft.calculateLinearBands(minFrequency: 0, maxFrequency: fft.nyquistFrequency, numberOfBands: fftBands)
                ffts.append(fft)

                processingBuffer.removeFirst(samplesPerFFT)
            } while processingBuffer.count >= samplesPerFFT
        }
        return ffts
    }

    func normalize(_ samples: [Float]) -> [Float] {
        return samples.map { $0 / noiseFloorDecibelCutoff }
    }

    // swiftlint:disable force_cast
    private func totalSamplesOfTrack() -> Int {
        var totalSamples = 0

        autoreleasepool {
            let descriptions = audioAssetTrack.formatDescriptions as! [CMFormatDescription]
            descriptions.forEach { formatDescription in
                guard let basicDescription = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription) else { return }
                let channelCount = Int(basicDescription.pointee.mChannelsPerFrame)
                let sampleRate = basicDescription.pointee.mSampleRate
                let rawTimescale = assetReader.asset.duration.timescale
                // Malformed / streaming assets can report an invalid (zero) timescale or a
                // non-finite duration, which would make Int(...) below trap with
                // "Double value cannot be converted to Int because it is either infinite or NaN".
                guard rawTimescale != 0, channelCount > 0, sampleRate.isFinite, sampleRate > 0 else { return }
                let duration = Double(assetReader.asset.duration.value)
                let totalDuration = duration / Double(rawTimescale)
                guard totalDuration.isFinite, totalDuration >= 0 else { return }
                // The track output decodes at `analysisSampleRate` (see `outputSettings()`), so the
                // number of samples actually delivered by the reader is based on that rate, not the
                // source rate. Using the source rate here would over-estimate `totalSamples` and thus
                // inflate `samplesPerPixel`, leaving the waveform padded with trailing silence.
                let effectiveSampleRate = min(sampleRate, analysisSampleRate)
                let computedSamples = effectiveSampleRate * totalDuration * Double(channelCount)
                guard computedSamples.isFinite, computedSamples >= 0, computedSamples < Double(Int.max) else { return }
                totalSamples = Int(computedSamples)
            }
        }

        return totalSamples
    }
    // swiftlint:enable force_cast
}

// MARK: - Configuration

private extension WaveformAnalyzer {
    func outputSettings() -> [String: Any] {
        return [
            AVFormatIDKey: kAudioFormatLinearPCM,
            // Decode at a reduced analysis sample rate. The amplitude envelope needs
            // very little frequency resolution, so 8 kHz is plenty while cutting the
            // decoded sample count (and therefore CPU time, `samplesPerPixel`, and every
            // downstream allocation) by ~5.5x for 44.1 kHz sources. This is the single
            // biggest safeguard against hangs/OOM on very long audio files.
            AVSampleRateKey: analysisSampleRate,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]
    }
}
