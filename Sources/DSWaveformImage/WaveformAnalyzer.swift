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
public struct WaveformAnalyzer: Sendable {
    public enum AnalyzeError: Error { case generic, userError, emptyTracks, readerError(AVAssetReader.Status) }

    /// Everything below this noise floor cutoff will be clipped and interpreted as silence. Default is `-50.0`.
    public var noiseFloorDecibelCutoff: Float = -50.0

    public init() {}

    /// Calculates the amplitude envelope of the initialized audio asset URL, downsampled to the required `count` amount of samples.
    /// - Parameter fromAudioAt: local filesystem URL of the audio file to process.
    /// - Parameter count: amount of samples to be calculated. Downsamples.
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
    /// - Parameter count: amount of samples to be calculated. Downsamples.
    /// - Parameter channelSelection: which channel(s) to extract. Default is `.merged` (all channels combined).
    /// - Parameter qos: QoS of the DispatchQueue the calculations are performed (and returned) on.
    public func samples(fromAsset audioAsset: AVAsset, count: Int, channelSelection: Waveform.ChannelSelection = .merged, qos: DispatchQoS.QoSClass = .userInitiated) async throws -> [Float] {
        try await Task(priority: taskPriority(qos: qos)) {
            let assetReader = try AVAssetReader(asset: audioAsset)

            guard let assetTrack = try await audioAsset.loadTracks(withMediaType: .audio).first else {
                throw AnalyzeError.emptyTracks
            }

            return try await waveformSamples(track: assetTrack, reader: assetReader, count: count, channelSelection: channelSelection, fftBands: nil).amplitudes
        }.value
    }

    /// Calculates the amplitude envelope of the initialized audio asset URL, downsampled to the required `count` amount of samples.
    /// - Parameter fromAudioAt: local filesystem URL of the audio file to process.
    /// - Parameter count: amount of samples to be calculated. Downsamples.
    /// - Parameter qos: QoS of the DispatchQueue the calculations are performed (and returned) on.
    public func samples(fromAudioAt audioAssetURL: URL, count: Int, qos: DispatchQoS.QoSClass = .userInitiated) async throws -> [Float] {
        try await samples(fromAudioAt: audioAssetURL, count: count, channelSelection: .merged, qos: qos)
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

fileprivate extension WaveformAnalyzer {
    func waveformSamples(
            track audioAssetTrack: AVAssetTrack,
            reader assetReader: AVAssetReader,
            count requiredNumberOfSamples: Int,
            channelSelection: Waveform.ChannelSelection = .merged,
            fftBands: Int?
    ) async throws -> WaveformAnalysis {
        guard requiredNumberOfSamples > 0 else {
            throw AnalyzeError.userError
        }

        let trackOutput = AVAssetReaderTrackOutput(track: audioAssetTrack, outputSettings: outputSettings(channelSelection: channelSelection))
        assetReader.add(trackOutput)

        let totalSamples = try await totalSamples(of: audioAssetTrack, channelSelection: channelSelection)
        let analysis = extract(totalSamples, downsampledTo: requiredNumberOfSamples, from: assetReader, channelSelection: channelSelection, fftBands: fftBands)

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
        fftBands: Int?
    ) -> WaveformAnalysis {
        let isStereo = (channelSelection == .stereo)
        var leftSamples = [Float]()
        var rightSamples = [Float]()
        var outputFFT = fftBands == nil ? nil : [TempiFFT]()
        var sampleBuffer = Data()
        var sampleBufferFFT = Data()

        // read upfront to avoid frequent re-calculation (and memory bloat from C-bridging)
        let samplesPerPixel = max(1, totalSamples / targetSampleCount)
        let samplesPerFFT = 4096 // ~100ms at 44.1kHz, rounded to closest pow(2) for FFT

        assetReader.startReading()
        while assetReader.status == .reading {
            let trackOutput = assetReader.outputs.first!

            guard let nextSampleBuffer = trackOutput.copyNextSampleBuffer(),
                let blockBuffer = CMSampleBufferGetDataBuffer(nextSampleBuffer) else {
                    break
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

            let result = process(sampleBuffer, from: assetReader, downsampleTo: samplesPerPixel, channelSelection: channelSelection)
            leftSamples += result.left
            rightSamples += result.right

            if result.bytesConsumed > 0 {
                sampleBuffer.removeFirst(result.bytesConsumed)

                // this takes care of a memory leak where Memory continues to increase even though it should clear after calling .removeFirst(…) above.
                sampleBuffer = Data(sampleBuffer)
            }

            if let fftBands = fftBands, sampleBufferFFT.count / MemoryLayout<Int16>.size >= samplesPerFFT {
                let processedFFTs = process(sampleBufferFFT, samplesPerFFT: samplesPerFFT, fftBands: fftBands)
                sampleBufferFFT.removeFirst(processedFFTs.count * samplesPerFFT * MemoryLayout<Int16>.size)
                outputFFT? += processedFFTs
            }
        }

        // if we don't have enough pixels yet,
        // process leftover samples with padding (to reach multiple of samplesPerPixel for vDSP_desamp)
        if leftSamples.count < targetSampleCount {
            // each output sample for a single rendered "channel" consumes `samplesPerPixel * inputUnitsPerOutputSample`
            // Int16s from the interleaved buffer.
            let channelCount = channelInfo(from: assetReader)?.channelCount ?? 1
            let inputUnitsPerOutputSample = (channelSelection == .merged) ? 1 : channelCount
            let missingSampleCount = (targetSampleCount - leftSamples.count) * samplesPerPixel * inputUnitsPerOutputSample
            let backfillPaddingSampleCount = max(0, missingSampleCount - (sampleBuffer.count / MemoryLayout<Int16>.size))
            let backfillPaddingByteCount = backfillPaddingSampleCount * MemoryLayout<Int16>.size
            let backfillPaddingSamples = [UInt8](repeating: 0, count: backfillPaddingByteCount)
            sampleBuffer.append(backfillPaddingSamples, count: backfillPaddingByteCount)
            let result = process(sampleBuffer, from: assetReader, downsampleTo: samplesPerPixel, channelSelection: channelSelection)
            leftSamples += result.left
            rightSamples += result.right
        }

        let amplitudes: [Float]
        if isStereo {
            // StereoWaveformRenderer expects samples laid out as [allLeft..., allRight...]
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
                    // Mono input: mirror the single channel into both top and bottom halves so
                    // StereoWaveformRenderer still produces something sensible.
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

    private func process(_ sampleBuffer: Data, samplesPerFFT: Int, fftBands: Int) -> [TempiFFT] {
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
