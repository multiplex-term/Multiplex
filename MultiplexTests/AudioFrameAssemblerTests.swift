import XCTest
@testable import Multiplex

final class AudioFrameAssemblerTests: XCTestCase {
    /// A stand-in filter that marks every sample with its frame's index, so
    /// the output shows exactly which samples travelled together.
    private func run(_ samples: [Float], chunks: [Int], frameSize: Int) -> [Float] {
        var assembler = AudioFrameAssembler(frameSize: frameSize)
        var frames = 0
        var output: [Float] = []
        var offset = 0
        for count in chunks {
            samples[offset..<offset + count].withUnsafeBufferPointer { assembler.append($0) }
            offset += count
            var out = [Float](repeating: .nan, count: assembler.readyCount)
            let written = out.withUnsafeMutableBufferPointer { buffer -> Int in
                guard let base = buffer.baseAddress else { return 0 }
                return assembler.drain(into: base) { frameIn, frameOut in
                    for index in 0..<frameSize {
                        frameOut[index] = frameIn[index] + Float(frames) * 1000
                    }
                    frames += 1
                }
            }
            XCTAssertEqual(written, out.count)
            output += out
        }
        return output
    }

    func testFramesAreIdenticalHoweverTheInputWasChunked() {
        let samples = (0..<2000).map(Float.init)
        let whole = run(samples, chunks: [2000], frameSize: 480)
        let ragged = run(samples, chunks: [1, 479, 341, 1024, 155], frameSize: 480)
        XCTAssertEqual(whole.count, 1920, "four whole frames; 80 samples wait")
        XCTAssertEqual(ragged, whole)
        XCTAssertEqual(whole[480], 480 + 1000, "the second frame is the second 480 samples")
    }

    func testAShortAppendWaitsRatherThanBeingDroppedOrPadded() {
        var assembler = AudioFrameAssembler(frameSize: 4)
        [Float]([1, 2, 3]).withUnsafeBufferPointer { assembler.append($0) }
        XCTAssertEqual(assembler.readyCount, 0)
        [Float]([4, 5]).withUnsafeBufferPointer { assembler.append($0) }
        XCTAssertEqual(assembler.readyCount, 4, "the first three complete a frame")
    }
}
