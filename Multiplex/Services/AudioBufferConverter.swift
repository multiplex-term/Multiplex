import AVFoundation

/// Converts capture-tap buffers to one fixed format, buffer by buffer. The
/// microphone runs at whatever the route gives it — 48 kHz on the built-in
/// mic, 16 or 24 kHz over a Bluetooth headset — and a route change (AirPods
/// arriving) hands the tap a new format mid-take, so the converter is
/// re-derived from each buffer's own format: one built for the old format
/// would turn speech into noise.
///
/// Not thread-safe: the tap is its only caller, so calls are serial.
final class AudioBufferConverter {
    let outputFormat: AVAudioFormat
    private var inputFormat: AVAudioFormat?
    private var converter: AVAudioConverter?

    init(outputFormat: AVAudioFormat) {
        self.outputFormat = outputFormat
    }

    /// Primed for the input the caller expects, or nil when that input cannot
    /// be converted at all — for a caller with a fallback, rather than
    /// discovering it as silence.
    convenience init?(from input: AVAudioFormat, to output: AVAudioFormat) {
        self.init(outputFormat: output)
        adopt(input)
        guard input == output || converter != nil else { return nil }
    }

    func convert(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        adopt(buffer.format)
        if buffer.format == outputFormat { return buffer }
        // A format no converter exists for is dropped, never passed through
        // mislabelled.
        guard let converter else { return nil }
        let ratio = outputFormat.sampleRate / max(buffer.format.sampleRate, 1)
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 32
        guard let output = AVAudioPCMBuffer(
            pcmFormat: outputFormat,
            frameCapacity: capacity
        ) else { return nil }
        var consumed = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            // The block is asked for input until it says there is none; this
            // buffer is all there is for this call. The converter keeps its
            // resampler state between calls, so the stream stays continuous.
            if consumed {
                inputStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            inputStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, output.frameLength > 0 else { return nil }
        return output
    }

    private func adopt(_ format: AVAudioFormat) {
        guard format != inputFormat else { return }
        inputFormat = format
        guard format != outputFormat else {
            converter = nil
            return
        }
        let converter = AVAudioConverter(from: format, to: outputFormat)
        // A stereo or multi-mic input folds into a mono output rather than
        // keeping only its first channel.
        converter?.downmix = true
        self.converter = converter
    }
}
