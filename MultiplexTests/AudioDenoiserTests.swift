import AVFoundation
import XCTest
@testable import Multiplex

/// The denoiser end to end — format conversion, framing, RNNoise itself —
/// against the real model. The model is a download, never in the repo, so
/// this runs only when a verified blob is handed in:
/// `TEST_RUNNER_RNNOISE_WEIGHTS=/path/to/rnnoise-weights.bin xcodebuild test …`
/// (the blob `RNNoiseModelStore` installs, or upstream `dump_weights_blob`
/// output for the pinned model).
final class AudioDenoiserTests: XCTestCase {
    private func weightsURL() throws -> URL {
        guard let path = ProcessInfo.processInfo.environment["RNNOISE_WEIGHTS"] else {
            throw XCTSkip("set TEST_RUNNER_RNNOISE_WEIGHTS to a weights blob to run")
        }
        return URL(fileURLWithPath: path)
    }

    func testAHeadsetRateInputComesOutAt48kWithTheNoiseSuppressed() throws {
        let denoiser = try XCTUnwrap(AudioDenoiser(weightsURL: weightsURL()))
        XCTAssertEqual(denoiser.outputFormat.sampleRate, 48_000)
        XCTAssertEqual(denoiser.outputFormat.channelCount, 1)

        // Two seconds of white noise at a Bluetooth headset's 16 kHz, fed in
        // the tap's 1024-frame buffers.
        let input = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        var generator = SystemRandomNumberGenerator()
        var inEnergy: Double = 0
        var outEnergy: Double = 0
        var outFrames = 0
        for index in 0..<32 {
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: input, frameCapacity: 1024))
            buffer.frameLength = 1024
            let samples = try XCTUnwrap(buffer.floatChannelData?[0])
            for frame in 0..<1024 {
                samples[frame] = Float.random(in: -0.1...0.1, using: &generator)
                // The first half-second is RNNoise settling on the noise
                // floor; measure after it.
                if index >= 8 { inEnergy += Double(samples[frame] * samples[frame]) }
            }
            guard let output = denoiser.process(buffer) else { continue }
            XCTAssertEqual(output.format, denoiser.outputFormat)
            XCTAssertEqual(Int(output.frameLength) % 480, 0, "whole RNNoise frames only")
            outFrames += Int(output.frameLength)
            guard index >= 8, let denoised = output.floatChannelData?[0] else { continue }
            for frame in 0..<Int(output.frameLength) {
                outEnergy += Double(denoised[frame] * denoised[frame])
            }
        }
        // 32 × 1024 samples at 16 kHz is 98 304 at 48 kHz, less the frame
        // still filling and the resampler's own priming.
        XCTAssertGreaterThan(outFrames, 98_304 - 2 * 480 - 256)
        XCTAssertLessThanOrEqual(outFrames, 98_304)
        // Per-sample energy, normalized for the 3× rate change.
        let reduction = 10 * log10((outEnergy / 3) / inEnergy)
        XCTAssertLessThan(reduction, -10, "steady noise loses at least 10 dB (got \(reduction))")
    }

    func testABlobOfTheWrongSizeIsRefused() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("rnnoise-truncated-\(UUID().uuidString).bin")
        try Data(repeating: 0, count: 4096).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertNil(AudioDenoiser(weightsURL: url))
    }
}
