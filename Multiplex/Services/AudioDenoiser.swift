import Accelerate
import AVFoundation
import CRNNoise

/// RNNoise between the microphone and the recognizer: the capture tap's
/// buffers go in at whatever format the route runs (a Bluetooth headset's
/// 16 or 24 kHz, the built-in mic's 48 kHz) and come out as 48 kHz mono with
/// the steady background — fans, traffic, a headset's own hiss — suppressed.
/// The recognizers then always see one format, whatever the route did.
///
/// One instance per dictation take: RNNoise's recurrent state is the take's
/// recent audio. Built only from a verified weights blob
/// (`RNNoiseModelStore`); nil when that cannot load, and the take runs on
/// the raw microphone instead. Touched only from the tap's thread after
/// construction.
final class AudioDenoiser: @unchecked Sendable {
    /// RNNoise's own rate; its frame is 10 ms of it.
    static let sampleRate: Double = 48_000
    /// RNNoise is trained on 16-bit PCM magnitudes; the engine hands over
    /// floats in ±1.
    private static let pcmScale: Float = 32_768

    let outputFormat: AVAudioFormat
    /// The memory-mapped blob. RNNoise's layers point straight into these
    /// bytes, so they must outlive the state — they are released together.
    private let weights: NSData
    private let model: OpaquePointer
    private let state: OpaquePointer
    private let converter: AudioBufferConverter
    private var assembler: AudioFrameAssembler
    private var scaledIn: [Float]
    private var denoisedOut: [Float]

    init?(weightsURL: URL) {
        guard let format = AVAudioFormat(standardFormatWithSampleRate: Self.sampleRate, channels: 1),
              let weights = try? NSData(contentsOf: weightsURL, options: .alwaysMapped),
              weights.length == RNNoiseModelSource.weightsByteCount,
              let model = rnnoise_model_from_buffer(weights.bytes, Int32(weights.length))
        else { return nil }
        // A blob that parses but does not describe this network's layers
        // fails here, not mid-take.
        guard let state = rnnoise_create(model) else {
            rnnoise_model_free(model)
            return nil
        }
        let frameSize = Int(rnnoise_get_frame_size())
        outputFormat = format
        self.weights = weights
        self.model = model
        self.state = state
        converter = AudioBufferConverter(outputFormat: format)
        assembler = AudioFrameAssembler(frameSize: frameSize)
        scaledIn = [Float](repeating: 0, count: frameSize)
        denoisedOut = [Float](repeating: 0, count: frameSize)
    }

    deinit {
        rnnoise_destroy(state)
        rnnoise_model_free(model)
    }

    /// One tap buffer in; the whole frames it completed out, denoised — or
    /// nil while a frame is still filling. Adds at most one frame (10 ms) of
    /// latency.
    func process(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let mono = converter.convert(buffer),
              let channel = mono.floatChannelData?[0]
        else { return nil }
        assembler.append(UnsafeBufferPointer(start: channel, count: Int(mono.frameLength)))
        let ready = assembler.readyCount
        guard ready > 0,
              let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: AVAudioFrameCount(ready)),
              let outputChannel = output.floatChannelData?[0]
        else { return nil }
        output.frameLength = AVAudioFrameCount(assembler.drain(into: outputChannel) { frameIn, frameOut in
            denoise(frameIn, into: frameOut)
        })
        return output
    }

    private func denoise(_ frameIn: UnsafePointer<Float>, into frameOut: UnsafeMutablePointer<Float>) {
        let length = vDSP_Length(scaledIn.count)
        var up = Self.pcmScale
        var down = 1 / Self.pcmScale
        scaledIn.withUnsafeMutableBufferPointer { scaled in
            denoisedOut.withUnsafeMutableBufferPointer { denoised in
                guard let scaledBase = scaled.baseAddress,
                      let denoisedBase = denoised.baseAddress
                else { return }
                vDSP_vsmul(frameIn, 1, &up, scaledBase, 1, length)
                _ = rnnoise_process_frame(state, denoisedBase, scaledBase)
                vDSP_vsmul(denoisedBase, 1, &down, frameOut, 1, length)
            }
        }
    }
}
