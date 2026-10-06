import Foundation

/// Re-blocks a stream of samples into the fixed frames a frame-based filter
/// needs. The capture tap hands over whatever the hardware and the sample-rate
/// converter produced — 1024, 341, 1366 samples — while RNNoise takes exactly
/// one 480-sample frame per call; the remainder waits for the next append
/// rather than being padded, so nothing is invented and nothing is dropped.
///
/// Pure and clock-free: identical input yields identical frames however it
/// was chunked, which is what the tests pin.
struct AudioFrameAssembler {
    let frameSize: Int
    private var waiting: [Float] = []

    init(frameSize: Int) {
        precondition(frameSize > 0)
        self.frameSize = frameSize
    }

    /// Samples in whole frames, ready for `drain`.
    var readyCount: Int { waiting.count / frameSize * frameSize }

    mutating func append(_ samples: UnsafeBufferPointer<Float>) {
        waiting.append(contentsOf: samples)
    }

    /// Run `process` (input frame, output frame — both `frameSize` long) over
    /// every whole frame, writing into `output` in order, and keep the
    /// remainder. `output` must hold `readyCount` samples. Returns how many
    /// were written.
    @discardableResult
    mutating func drain(
        into output: UnsafeMutablePointer<Float>,
        process: (UnsafePointer<Float>, UnsafeMutablePointer<Float>) -> Void
    ) -> Int {
        let ready = readyCount
        waiting.withUnsafeBufferPointer { input in
            guard let base = input.baseAddress else { return }
            for offset in stride(from: 0, to: ready, by: frameSize) {
                process(base + offset, output + offset)
            }
        }
        waiting.removeFirst(ready)
        return ready
    }
}
