import Compression
import CryptoKit
import Foundation
import Observation
import os
#if DEBUG
import notify
#endif

private let logger = Logger(subsystem: "app.multiplexterm.multiplex", category: "rnnoise")

/// The on-demand RNNoise model: fetched from upstream when the user asks
/// for noise reduction in Settings, never shipped in the app. Download →
/// archive SHA-256 → convert → blob SHA-256 → install, all off the main
/// actor; see `RNNoiseModelSource` for why both ends are pinned. The
/// installed blob is re-downloadable, so it is excluded from backup.
@MainActor
@Observable
final class RNNoiseModelStore {
    static let shared = RNNoiseModelStore()

    enum State: Equatable {
        case absent
        case downloading(fraction: Double)
        case installing
        case ready
        case failed(String)
    }

    private(set) var state: State
    @ObservationIgnored private var job: Task<Void, Never>?
    /// Bumped by every start, cancel and delete: a job that finishes after
    /// being superseded must not write its outcome over the newer state.
    @ObservationIgnored private var generation = 0

    init() {
        // Verified once, at install; a size check is enough to tell an
        // installed blob from a missing or partial one.
        let size = (try? FileManager.default.attributesOfItem(
            atPath: RNNoiseWeightsInstaller.weightsURL.path
        )[.size] as? NSNumber)?.intValue
        state = size == RNNoiseModelSource.weightsByteCount ? .ready : .absent
    }

    func download() {
        switch state {
        case .absent, .failed: break
        case .downloading, .installing, .ready: return
        }
        let generation = supersedeJob()
        state = .downloading(fraction: 0)
        logger.debug("rnnoise-download-start")
        let advance: @MainActor @Sendable (Double) -> Void = { [weak self] fraction in
            self?.advance(to: fraction, generation: generation)
        }
        job = Task { [weak self] in
            do {
                let archive = try await Self.fetchArchive { fraction in
                    Task { @MainActor in advance(fraction) }
                }
                defer { try? FileManager.default.removeItem(at: archive) }
                guard self?.generation == generation else { return }
                self?.state = .installing
                try await Self.install(archive)
                self?.conclude(.ready, generation: generation)
            } catch {
                if !(error is CancellationError) {
                    logger.error("rnnoise-install-failed \(String(describing: error), privacy: .public)")
                }
                let message = ((error as? RNNoiseWeightsError) ?? .download).message
                self?.conclude(.failed(message), generation: generation)
            }
        }
    }

    /// Stop a download or install in flight; nothing is left on disk.
    func cancel() {
        switch state {
        case .downloading, .installing: break
        case .absent, .ready, .failed: return
        }
        supersedeJob()
        state = .absent
    }

    /// Remove the installed model (and any partial a crash left behind).
    func delete() {
        supersedeJob()
        try? FileManager.default.removeItem(at: RNNoiseWeightsInstaller.directory)
        state = .absent
    }

    /// Retire whatever job is running; returns the new generation.
    @discardableResult
    private func supersedeJob() -> Int {
        generation &+= 1
        job?.cancel()
        job = nil
        return generation
    }

    private func advance(to fraction: Double, generation: Int) {
        guard generation == self.generation, case .downloading = state else { return }
        state = .downloading(fraction: fraction)
    }

    private func conclude(_ outcome: State, generation: Int) {
        guard generation == self.generation else { return }
        job = nil
        state = outcome
        if outcome == .ready { logger.debug("rnnoise-installed") }
    }

    /// Nonisolated so the conversion runs off the main actor while still
    /// inside the job's task — a detached task would not see `cancel()`, and
    /// a cancelled install must never move the blob into place.
    nonisolated private static func install(_ archive: URL) async throws {
        try RNNoiseWeightsInstaller.install(archiveAt: archive) { Task.isCancelled }
        try Task.checkCancellation()
    }

    /// The archive, downloaded to a temporary file the caller removes.
    /// Progress is reported in whole-percent steps against the pinned size,
    /// so it reads right even without a Content-Length.
    nonisolated private static func fetchArchive(
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> URL {
        let session = URLSession(configuration: .ephemeral)
        defer { session.finishTasksAndInvalidate() }
        let location: URL
        let response: URLResponse
        do {
            (location, response) = try await session.download(
                from: RNNoiseModelSource.archiveURL,
                delegate: DownloadProgress(report: progress)
            )
        } catch {
            try Task.checkCancellation()
            throw RNNoiseWeightsError.download
        }
        let archive = FileManager.default.temporaryDirectory
            .appendingPathComponent("rnnoise-\(UUID().uuidString).tar.gz")
        do {
            try FileManager.default.moveItem(at: location, to: archive)
        } catch {
            try? FileManager.default.removeItem(at: location)
            throw RNNoiseWeightsError.disk
        }
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            try? FileManager.default.removeItem(at: archive)
            throw RNNoiseWeightsError.download
        }
        return archive
    }
}

/// Reports a download's bytes as whole-percent steps — the task updates its
/// count per received packet, and only a new percent is worth a hop to the
/// main actor.
private final class DownloadProgress: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let report: @Sendable (Double) -> Void
    private let lock = NSLock()
    private var observation: NSKeyValueObservation?
    private var reportedPercent = -1

    init(report: @escaping @Sendable (Double) -> Void) {
        self.report = report
    }

    func urlSession(_ session: URLSession, didCreateTask task: URLSessionTask) {
        let observation = task.observe(\.countOfBytesReceived) { [weak self] task, _ in
            self?.received(task.countOfBytesReceived)
        }
        lock.lock()
        self.observation = observation
        lock.unlock()
    }

    private func received(_ bytes: Int64) {
        let percent = Int(min(100, bytes * 100 / Int64(RNNoiseModelSource.archiveByteCount)))
        lock.lock()
        let changed = percent != reportedPercent
        reportedPercent = percent
        lock.unlock()
        if changed { report(Double(percent) / 100) }
    }

    deinit { observation?.invalidate() }
}

// MARK: - Install

/// The synchronous conversion core, callable from any thread. `isCancelled`
/// is polled once per megabyte read.
enum RNNoiseWeightsInstaller {
    private static let readChunk = 1 << 20

    static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("RNNoise", isDirectory: true)
    }

    static var weightsURL: URL {
        directory.appendingPathComponent(
            "rnnoise-weights-\(RNNoiseModelSource.weightsSHA256.prefix(12)).bin"
        )
    }

    /// Verify the archive, convert it beside the destination, verify the
    /// blob, and move it into place.
    static func install(archiveAt archive: URL, isCancelled: () -> Bool) throws {
        let start = ContinuousClock.now
        var archiveHasher = SHA256()
        try forEachChunk(of: archive, isCancelled: isCancelled) { chunk in
            archiveHasher.update(data: chunk)
            return true
        }
        guard hex(archiveHasher.finalize()) == RNNoiseModelSource.archiveSHA256 else {
            throw RNNoiseWeightsError.archiveChecksum
        }
        let destination = weightsURL
        let partial = directory.appendingPathComponent(".partial-\(UUID().uuidString)")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw RNNoiseWeightsError.disk
        }
        defer { try? FileManager.default.removeItem(at: partial) }
        // The SHA-256 pins the size too.
        guard try convert(archiveAt: archive, to: partial, isCancelled: isCancelled)
            == RNNoiseModelSource.weightsSHA256
        else { throw RNNoiseWeightsError.weightsChecksum }
        do {
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.moveItem(at: partial, to: destination)
            var installed = destination
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try installed.setResourceValues(values)
        } catch {
            throw RNNoiseWeightsError.disk
        }
        logger.debug("rnnoise-converted in \(String(describing: ContinuousClock.now - start), privacy: .public)")
    }

    /// gunzip → tar → `rnnoise_data.c` → blob, streamed end to end; reading
    /// stops once the source entry has been consumed (the rest of the
    /// tarball is the little model and the checkpoints). Returns the blob's
    /// SHA-256.
    static func convert(
        archiveAt archive: URL,
        to blob: URL,
        isCancelled: () -> Bool
    ) throws -> String {
        guard FileManager.default.createFile(atPath: blob.path, contents: nil),
              let output = try? FileHandle(forWritingTo: blob)
        else { throw RNNoiseWeightsError.disk }
        defer { try? output.close() }

        var hasher = SHA256()
        var writeFailed = false
        func write(_ bytes: UnsafeRawBufferPointer) {
            hasher.update(bufferPointer: bytes)
            do { try output.write(contentsOf: bytes) } catch { writeFailed = true }
        }

        let inflater = try GzipInflater()
        var tar = TarStreamReader()
        var parser = RNNoiseWeightsSourceParser()
        var inSource = false
        var sourceDone = false
        try forEachChunk(of: archive, isCancelled: isCancelled) { chunk in
            try chunk.withUnsafeBytes { compressed in
                try inflater.inflate(compressed) { text in
                    try tar.feed(text) { event in
                        switch event {
                        case .begin(let path):
                            inSource = !sourceDone && path == RNNoiseModelSource.sourceEntry
                        case .content(let bytes):
                            guard inSource else { return }
                            try parser.feed(bytes)
                            parser.drain(write)
                        case .end:
                            if inSource { sourceDone = true }
                            inSource = false
                        }
                    }
                }
            }
            guard !writeFailed else { throw RNNoiseWeightsError.disk }
            return !(sourceDone || inflater.isFinished || tar.isFinished)
        }
        guard sourceDone else { throw RNNoiseWeightsError.malformed("\(RNNoiseModelSource.sourceEntry) not found") }
        try parser.finish()
        parser.drain(write)
        guard !writeFailed else { throw RNNoiseWeightsError.disk }
        logger.debug("rnnoise-blob arrays=\(parser.arrayCount, privacy: .public)")
        return hex(hasher.finalize())
    }

    static func hex(_ digest: SHA256.Digest) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Hand `body` the file a megabyte at a time until it returns false or
    /// the file ends. Each read is an autoreleased buffer; without a pool per
    /// chunk a background thread holds the whole file until the loop ends.
    private static func forEachChunk(
        of url: URL,
        isCancelled: () -> Bool,
        _ body: (Data) throws -> Bool
    ) throws {
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: url)
        } catch {
            throw RNNoiseWeightsError.disk
        }
        defer { try? handle.close() }
        var reading = true
        while reading {
            reading = try autoreleasepool {
                let chunk: Data?
                do {
                    chunk = try handle.read(upToCount: readChunk)
                } catch {
                    throw RNNoiseWeightsError.disk
                }
                guard let chunk, !chunk.isEmpty else { return false }
                guard !isCancelled() else { throw CancellationError() }
                return try body(chunk)
            }
        }
    }
}

// MARK: - gunzip

/// Streaming gunzip: the gzip header is parsed by `GzipHeader`, the DEFLATE
/// body goes through Compression's raw-DEFLATE decoder (`COMPRESSION_ZLIB`
/// reads RFC 1951 with no wrapper), and the trailer is ignored — the caller
/// checks the whole file's SHA-256 instead of the CRC.
final class GzipInflater {
    private let stream: UnsafeMutablePointer<compression_stream>
    private let outputBuffer: UnsafeMutablePointer<UInt8>
    private static let outputCapacity = 1 << 18
    /// Header bytes collected until the header's length is known.
    private var header: [UInt8]? = []
    private(set) var isFinished = false

    init() throws {
        stream = .allocate(capacity: 1)
        outputBuffer = .allocate(capacity: Self.outputCapacity)
        guard compression_stream_init(stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK
        else {
            stream.deallocate()
            outputBuffer.deallocate()
            throw RNNoiseWeightsError.malformed("inflater")
        }
    }

    deinit {
        compression_stream_destroy(stream)
        stream.deallocate()
        outputBuffer.deallocate()
    }

    /// Inflate one chunk of the gzip file, handing decompressed bytes to
    /// `output` as they come (valid only during each call).
    func inflate(
        _ chunk: UnsafeRawBufferPointer,
        _ output: (UnsafeRawBufferPointer) throws -> Void
    ) throws {
        guard !isFinished, !chunk.isEmpty else { return }
        guard var collected = header else {
            try inflateBody(chunk, output)
            return
        }
        collected.append(contentsOf: chunk)
        let length = try collected.withUnsafeBytes { try GzipHeader.length(of: $0) }
        guard let length else {
            header = collected
            return
        }
        header = nil
        try collected.withUnsafeBytes { bytes in
            try inflateBody(UnsafeRawBufferPointer(rebasing: bytes[length...]), output)
        }
    }

    private func inflateBody(
        _ body: UnsafeRawBufferPointer,
        _ output: (UnsafeRawBufferPointer) throws -> Void
    ) throws {
        guard let base = body.baseAddress, !body.isEmpty else { return }
        stream.pointee.src_ptr = base.assumingMemoryBound(to: UInt8.self)
        stream.pointee.src_size = body.count
        while true {
            let unread = stream.pointee.src_size
            stream.pointee.dst_ptr = outputBuffer
            stream.pointee.dst_size = Self.outputCapacity
            let status = compression_stream_process(stream, 0)
            let produced = Self.outputCapacity - stream.pointee.dst_size
            if produced > 0 { try output(UnsafeRawBufferPointer(start: outputBuffer, count: produced)) }
            switch status {
            case COMPRESSION_STATUS_END:
                isFinished = true
                return
            case COMPRESSION_STATUS_OK:
                // A full output buffer may hide more; an empty input with
                // room to spare means this chunk is done.
                if stream.pointee.src_size == 0, stream.pointee.dst_size > 0 { return }
                // The next chunk replaces `src_ptr`, so input the decoder
                // neither consumed nor turned into output would be lost.
                guard produced > 0 || stream.pointee.src_size < unread else {
                    throw RNNoiseWeightsError.malformed("deflate stream stalled")
                }
            default:
                throw RNNoiseWeightsError.malformed("deflate stream")
            }
        }
    }
}

// MARK: - DEBUG hook

#if DEBUG
/// Headless proof of the model install:
/// `notifyutil -p app.multiplexterm.multiplex.debug.rnnoisedownload` starts
/// the download (log category `rnnoise` reports the outcome).
@MainActor
enum RNNoiseDebugHook {
    private static var installed = false

    static func install() {
        guard !installed else { return }
        installed = true
        var token: Int32 = 0
        notify_register_dispatch(
            "app.multiplexterm.multiplex.debug.rnnoisedownload", &token, .main
        ) { _ in
            MainActor.assumeIsolated { RNNoiseModelStore.shared.download() }
        }
    }
}
#endif
