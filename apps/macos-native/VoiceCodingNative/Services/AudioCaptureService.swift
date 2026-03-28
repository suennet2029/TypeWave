@preconcurrency import AVFoundation
import Foundation

final class AudioCaptureService {
    var onMaxDurationReached: (@Sendable () -> Void)?
    var onLevelUpdate: (@Sendable (Double) -> Void)?

    private let lock = NSLock()
    private var audioEngine: AVAudioEngine?
    private var pcmBuffer = Data()
    private var capturedSamples = 0
    private var maxDurationTask: DispatchWorkItem?
    private var recordingStartedAt: Date?

    var isRecording: Bool {
        audioEngine != nil
    }

    func start(maxDuration: TimeInterval) throws {
        if isRecording {
            return
        }

        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)

        lock.lock()
        pcmBuffer = Data()
        capturedSamples = 0
        lock.unlock()
        recordingStartedAt = Date()

        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1_024, format: inputFormat) { [weak self] buffer, _ in
            self?.append(buffer: buffer)
        }

        engine.prepare()
        try engine.start()

        let callback = onMaxDurationReached
        let workItem = DispatchWorkItem {
            callback?()
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + maxDuration, execute: workItem)

        self.audioEngine = engine
        self.maxDurationTask = workItem
    }

    func stop() -> CapturedAudio? {
        guard let audioEngine else {
            return nil
        }

        maxDurationTask?.cancel()
        maxDurationTask = nil

        audioEngine.inputNode.removeTap(onBus: 0)
        audioEngine.stop()
        self.audioEngine = nil

        let levelResetCallback = onLevelUpdate
        DispatchQueue.main.async {
            levelResetCallback?(0)
        }

        lock.lock()
        let data = pcmBuffer
        let samples = capturedSamples
        pcmBuffer = Data()
        capturedSamples = 0
        lock.unlock()

        let wallClockDuration = recordingStartedAt.map { Date().timeIntervalSince($0) } ?? 0
        recordingStartedAt = nil
        let sampleDuration = Double(samples) / 16_000.0
        let duration = max(wallClockDuration, sampleDuration)
        return CapturedAudio(pcmData: data, duration: duration)
    }

    func snapshot() -> CapturedAudio? {
        guard isRecording else {
            return nil
        }

        lock.lock()
        let data = pcmBuffer
        let samples = capturedSamples
        lock.unlock()

        guard !data.isEmpty else {
            return nil
        }

        let wallClockDuration = recordingStartedAt.map { Date().timeIntervalSince($0) } ?? 0
        let sampleDuration = Double(samples) / 16_000.0
        let duration = max(wallClockDuration, sampleDuration)
        return CapturedAudio(pcmData: data, duration: duration)
    }

    private func append(buffer: AVAudioPCMBuffer) {
        let monoSamples = extractMonoSamples(from: buffer)
        guard !monoSamples.isEmpty else {
            return
        }

        let resampledSamples = resample(samples: monoSamples, sourceSampleRate: buffer.format.sampleRate, targetSampleRate: 16_000)
        guard !resampledSamples.isEmpty else {
            return
        }

        var pcmBytes = Data(count: resampledSamples.count * MemoryLayout<Int16>.stride)
        pcmBytes.withUnsafeMutableBytes { rawBuffer in
            let pcm = rawBuffer.bindMemory(to: Int16.self)
            for (index, sample) in resampledSamples.enumerated() {
                let clipped = max(-1.0, min(1.0, sample))
                pcm[index] = Int16(clipped * Float(Int16.max))
            }
        }

        let level = normalizedLevel(from: resampledSamples)

        lock.lock()
        pcmBuffer.append(pcmBytes)
        capturedSamples += resampledSamples.count
        lock.unlock()

        let levelCallback = onLevelUpdate
        DispatchQueue.main.async {
            levelCallback?(level)
        }
    }

    private func extractMonoSamples(from buffer: AVAudioPCMBuffer) -> [Float] {
        let frameLength = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)
        guard frameLength > 0, channelCount > 0 else {
            return []
        }

        if let channelData = buffer.floatChannelData {
            var samples = Array(repeating: Float(0), count: frameLength)
            for frameIndex in 0 ..< frameLength {
                var mixed: Float = 0
                for channelIndex in 0 ..< channelCount {
                    mixed += channelData[channelIndex][frameIndex]
                }
                samples[frameIndex] = mixed / Float(channelCount)
            }
            return samples
        }

        if let channelData = buffer.int16ChannelData {
            var samples = Array(repeating: Float(0), count: frameLength)
            for frameIndex in 0 ..< frameLength {
                var mixed: Float = 0
                for channelIndex in 0 ..< channelCount {
                    mixed += Float(channelData[channelIndex][frameIndex]) / Float(Int16.max)
                }
                samples[frameIndex] = mixed / Float(channelCount)
            }
            return samples
        }

        if let channelData = buffer.int32ChannelData {
            var samples = Array(repeating: Float(0), count: frameLength)
            for frameIndex in 0 ..< frameLength {
                var mixed: Float = 0
                for channelIndex in 0 ..< channelCount {
                    mixed += Float(channelData[channelIndex][frameIndex]) / Float(Int32.max)
                }
                samples[frameIndex] = mixed / Float(channelCount)
            }
            return samples
        }

        return []
    }

    private func resample(samples: [Float], sourceSampleRate: Double, targetSampleRate: Double) -> [Float] {
        guard !samples.isEmpty else {
            return []
        }

        guard sourceSampleRate > 0, abs(sourceSampleRate - targetSampleRate) > 1 else {
            return samples
        }

        if samples.count == 1 {
            return samples
        }

        let duration = Double(samples.count) / sourceSampleRate
        let targetCount = max(1, Int(round(duration * targetSampleRate)))
        if targetCount == samples.count {
            return samples
        }

        if targetCount == 1 {
            return [samples[0]]
        }

        var resampled = Array(repeating: Float(0), count: targetCount)
        let scale = Double(samples.count - 1) / Double(targetCount - 1)
        for targetIndex in 0 ..< targetCount {
            let position = Double(targetIndex) * scale
            let leftIndex = Int(position)
            let rightIndex = min(leftIndex + 1, samples.count - 1)
            let fraction = Float(position - Double(leftIndex))
            let leftSample = samples[leftIndex]
            let rightSample = samples[rightIndex]
            resampled[targetIndex] = leftSample + (rightSample - leftSample) * fraction
        }

        return resampled
    }

    private func normalizedLevel(from samples: [Float]) -> Double {
        guard !samples.isEmpty else {
            return 0
        }

        var sumSquares = 0.0
        for sample in samples {
            let normalizedSample = Double(sample)
            sumSquares += normalizedSample * normalizedSample
        }

        let rms = sqrt(sumSquares / Double(samples.count))
        guard rms > 0 else {
            return 0
        }

        let decibels = 20 * log10(max(rms, 0.000_015))
        let scaled = min(max((decibels + 52) / 52, 0), 1)
        return pow(scaled, 0.8)
    }
}
