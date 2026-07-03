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
    private let assetReader: AVAssetReader
    private let audioAssetTrack: AVAssetTrack

    public init?(audioAssetURL: URL) {
        let audioAsset = AVURLAsset(url: audioAssetURL, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])

        guard
                let assetReader = try? AVAssetReader(asset: audioAsset),
                let assetTrack = audioAsset.tracks(withMediaType: .audio).first else {
            print("ERROR loading asset / audio track")
            return nil
        }

        self.assetReader = assetReader
        self.audioAssetTrack = assetTrack
    }
    
    /// Returns the calculated waveform of the initialized asset URL.
    public func samples(count: Int, qos: DispatchQoS.QoSClass = .userInitiated, completionHandler: @escaping (_ amplitudes: [Float]?) -> ()) {
        waveformSamples(count: count, qos: qos, fftBands: nil) { analysis in
            completionHandler(analysis?.amplitudes)
        }
    }
}

// MARK: - Private

fileprivate extension WaveformAnalyzer {
    private var silenceDbThreshold: Float { return -50.0 } // everything below -50 dB will be clipped
    
    func waveformSamples(
            count requiredNumberOfSamples: Int,
            qos: DispatchQoS.QoSClass,
            fftBands: Int?,
            completionHandler: @escaping (_ analysis: WaveformAnalysis?) -> ()) {
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
                        completionHandler(analysis)
                    default:
                        print("ERROR: reading waveform audio data has failed \(self.assetReader.status)")
                        completionHandler(nil)
                    }
                }

            case .failed, .cancelled, .loading, .unknown:
                print("failed to load due to: \(error?.localizedDescription ?? "unknown error")")
                completionHandler(nil)
            @unknown default:
                print("failed to load due to: \(error?.localizedDescription ?? "unknown error")")
                completionHandler(nil)
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

        self.assetReader.startReading()
        while self.assetReader.status == .reading {
            guard let trackOutput = assetReader.outputs.first else { break }

            guard let nextSampleBuffer = trackOutput.copyNextSampleBuffer(),
                let blockBuffer = CMSampleBufferGetDataBuffer(nextSampleBuffer) else {
                    break
            }

            var readBufferLength = 0
            var readBufferPointer: UnsafeMutablePointer<Int8>? = nil
            CMBlockBufferGetDataPointer(blockBuffer, atOffset: 0, lengthAtOffsetOut: &readBufferLength, totalLengthOut: nil, dataPointerOut: &readBufferPointer)
            sampleBuffer.append(UnsafeBufferPointer(start: readBufferPointer, count: readBufferLength))
            if fftBands != nil {
                // Only retain a second full copy of the audio when FFT output is requested.
                sampleBufferFFT.append(UnsafeBufferPointer(start: readBufferPointer, count: readBufferLength))
            }
            CMSampleBufferInvalidate(nextSampleBuffer)

            let processedSamples = process(sampleBuffer, from: assetReader, downsampleTo: samplesPerPixel)
            outputSamples += processedSamples

            if processedSamples.count > 0 {
                // vDSP_desamp uses strides of samplesPerPixel; remove only the processed ones
                sampleBuffer.removeFirst(processedSamples.count * samplesPerPixel * MemoryLayout<Int16>.size)
            }

            if let fftBands = fftBands, sampleBufferFFT.count / MemoryLayout<Int16>.size >= samplesPerFFT {
                let processedFFTs = process(sampleBufferFFT, samplesPerFFT: samplesPerFFT, fftBands: fftBands)
                sampleBufferFFT.removeFirst(processedFFTs.count * samplesPerFFT * MemoryLayout<Int16>.size)
                outputFFT? += processedFFTs
            }
        }

        // if we don't have enough pixels yet,
        // process leftover samples with padding (to reach multiple of samplesPerPixel for vDSP_desamp)
        if outputSamples.count < targetSampleCount {
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
            let processedSamples = process(sampleBuffer, from: assetReader, downsampleTo: samplesPerPixel)
            outputSamples += processedSamples
        }

        return WaveformAnalysis(amplitudes: normalize(outputSamples), fft: outputFFT)
    }

    private func process(_ sampleBuffer: Data,
                         from assetReader: AVAssetReader,
                         downsampleTo samplesPerPixel: Int) -> [Float] {
        var downSampledData = [Float]()
        let sampleLength = sampleBuffer.count / MemoryLayout<Int16>.size
        // Nothing to process (and baseAddress would be nil for an empty buffer).
        guard sampleLength > 0, samplesPerPixel > 0 else { return downSampledData }
        sampleBuffer.withUnsafeBytes { (samplesRawPointer: UnsafeRawBufferPointer) in
            let unsafeSamplesBufferPointer = samplesRawPointer.bindMemory(to: Int16.self)
            guard let unsafeSamplesPointer = unsafeSamplesBufferPointer.baseAddress else { return }
            var loudestClipValue: Float = 0.0
            var quietestClipValue = silenceDbThreshold
            var zeroDbEquivalent: Float = Float(Int16.max) // maximum amplitude storable in Int16 = 0 Db (loudest)
            let samplesToProcess = vDSP_Length(sampleLength)

            var processingBuffer = [Float](repeating: 0.0, count: Int(samplesToProcess))
            vDSP_vflt16(unsafeSamplesPointer, 1, &processingBuffer, 1, samplesToProcess) // convert 16bit int to float (
            vDSP_vabs(processingBuffer, 1, &processingBuffer, 1, samplesToProcess) // absolute amplitude value
            vDSP_vdbcon(processingBuffer, 1, &zeroDbEquivalent, &processingBuffer, 1, samplesToProcess, 1) // convert to DB
            vDSP_vclip(processingBuffer, 1, &quietestClipValue, &loudestClipValue, &processingBuffer, 1, samplesToProcess)

            let filter = [Float](repeating: 1.0 / Float(samplesPerPixel), count: samplesPerPixel)
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
        return samples.map { $0 / silenceDbThreshold }
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
                let computedSamples = sampleRate * totalDuration * Double(channelCount)
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
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]
    }
}
