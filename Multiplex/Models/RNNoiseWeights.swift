import Foundation

/// RNNoise's model is fetched on demand rather than shipped: upstream
/// publishes its weights only as generated C source inside a tarball (the
/// regular model alone is 78 MB of text), and the app builds the library with
/// `USE_WEIGHTS_FILE`, loading the binary weights blob at runtime. The
/// conversion below turns the tarball's `rnnoise_data.c` into exactly the
/// bytes upstream's own `dump_weights_blob` writes, so both ends are pinned:
/// the archive by upstream's published checksum (`model_version`, the hash
/// `download_model.sh` checks), the blob by the hash of that tool's output.
/// A conversion that disagrees with upstream by one bit fails the second pin.
enum RNNoiseModelSource {
    // swiftlint:disable:next force_unwrapping
    static let archiveURL = URL(string: "https://media.xiph.org/rnnoise/models/rnnoise_data-0a8755f8e2d834eff6a54714ecc7d75f9932e845df35f8b59bc52a7cfe6e8b37.tar.gz")!
    static let archiveSHA256 = "0a8755f8e2d834eff6a54714ecc7d75f9932e845df35f8b59bc52a7cfe6e8b37"
    static let archiveByteCount = 58_603_099
    /// The regular model's source. The tarball also carries the "little"
    /// model and the PyTorch checkpoints; only this entry is read.
    static let sourceEntry = "src/rnnoise_data.c"
    static let weightsSHA256 = "1b99898350e75656c77d068162fea402afe51eff15dc751989b1e9f53b98bf91"
    static let weightsByteCount = 14_751_424
}

enum RNNoiseWeightsError: Error {
    case download
    case archiveChecksum
    /// The source did not read as upstream's generated weights file; the
    /// detail is for the log, never the UI.
    case malformed(String)
    case weightsChecksum
    case disk

    var message: String {
        switch self {
        case .download:
            String(localized: "The noise reduction model couldn't be downloaded")
        case .archiveChecksum:
            String(localized: "The download didn't match the model's published checksum")
        case .malformed, .weightsChecksum:
            String(localized: "The noise reduction model couldn't be prepared")
        case .disk:
            String(localized: "The noise reduction model couldn't be saved")
        }
    }
}

// MARK: - The blob format

/// `write_weights.c`'s format: per array, a 64-byte `WeightHead` (`"DNNw"`,
/// version, type, byte size, block size, a 44-byte name), the array's bytes,
/// then zeros to the next 64-byte boundary. Integers are machine-endian —
/// little-endian on every Apple target this runs on.
enum RNNoiseWeightBlob {
    static let blockSize = 64
    static let nameCapacity = 44

    enum ElementType: Int32 {
        case float = 0
        case int = 1
        case int8 = 3

        var byteWidth: Int {
            switch self {
            case .float, .int: 4
            case .int8: 1
            }
        }

        /// The C spelling in the generated source.
        init?(cName: String) {
            switch cName {
            case "float": self = .float
            case "int": self = .int
            case "opus_int8": self = .int8
            default: return nil
            }
        }
    }

    static func blockSize(for byteCount: Int) -> Int {
        (byteCount + blockSize - 1) / blockSize * blockSize
    }

    /// The header for one array. The name is copied `strncpy`-style into its
    /// 44 bytes and the last byte forced to NUL, so a 44-byte name loses its
    /// final character — upstream's own truncation.
    static func header(name: String, type: ElementType, byteCount: Int) -> [UInt8] {
        var header = [UInt8](repeating: 0, count: blockSize)
        header.replaceSubrange(0..<4, with: Array("DNNw".utf8))
        func put(_ value: Int32, at offset: Int) {
            withUnsafeBytes(of: value.littleEndian) { header.replaceSubrange(offset..<offset + 4, with: $0) }
        }
        put(0, at: 4)
        put(type.rawValue, at: 8)
        put(Int32(byteCount), at: 12)
        put(Int32(blockSize(for: byteCount)), at: 16)
        let name = Array(name.utf8.prefix(nameCapacity))
        header.replaceSubrange(20..<20 + name.count, with: name)
        header[blockSize - 1] = 0
        return header
    }
}

// MARK: - The C source

/// Streams upstream's generated `rnnoise_data.c` into the weights blob.
///
/// Every `static const <float|int|opus_int8> name[N] = { … };` becomes one
/// block, in file order — which is the order of the file's own
/// `rnnoise_arrays[]` table, the order `write_weights.c` emits. Preprocessor
/// lines are ignored: `write_weights.c` undefines `USE_WEIGHTS_FILE` and does
/// not define `DISABLE_DEBUG_FLOAT`, so every array is in. Floats are parsed
/// as `double` and then narrowed, because that is what the C compiler does
/// with an unsuffixed literal; `strtof` would round some of them differently.
/// Fewer initializers than declared zero-fill (C semantics); more is an error.
struct RNNoiseWeightsSourceParser {
    private enum Mode {
        case scanning
        case values
    }

    private struct OpenArray {
        var type: RNNoiseWeightBlob.ElementType
        var count: Int
        var written = 0
    }

    private(set) var arrayCount = 0
    private var mode = Mode.scanning
    private var output: [UInt8] = []
    /// Everything since the last newline or brace, while scanning for a
    /// declaration. Lines outside arrays are short; past the cap the line
    /// cannot be a declaration and is skipped to its end.
    private var line: [UInt8] = []
    private var lineOverflowed = false
    private static let lineCapacity = 512
    /// The current value token, NUL-terminated in place for `strtod`.
    private var token = [CChar](repeating: 0, count: 64)
    private var tokenLength = 0
    private var open: OpenArray?

    init() {
        output.reserveCapacity(1 << 20)
        line.reserveCapacity(Self.lineCapacity)
    }

    mutating func feed(_ bytes: UnsafeRawBufferPointer) throws {
        for byte in bytes {
            switch mode {
            case .scanning: try scan(byte)
            case .values: try value(byte)
            }
        }
    }

    /// The end of the source: an array still open means it was cut short.
    mutating func finish() throws {
        guard mode == .scanning else { throw RNNoiseWeightsError.malformed("source ends inside an array") }
        guard arrayCount > 0 else { throw RNNoiseWeightsError.malformed("no weight arrays") }
    }

    /// Hand over the blob bytes produced so far and forget them.
    mutating func drain(_ body: (UnsafeRawBufferPointer) throws -> Void) rethrows {
        guard !output.isEmpty else { return }
        try output.withUnsafeBytes(body)
        output.removeAll(keepingCapacity: true)
    }

    // MARK: Scanning

    private mutating func scan(_ byte: UInt8) throws {
        switch byte {
        case UInt8(ascii: "\n"):
            line.removeAll(keepingCapacity: true)
            lineOverflowed = false
        case UInt8(ascii: "{"):
            if !lineOverflowed, let declaration = try Self.declaration(line) {
                begin(declaration)
            }
            line.removeAll(keepingCapacity: true)
        default:
            guard !lineOverflowed else { return }
            if line.count < Self.lineCapacity {
                line.append(byte)
            } else {
                lineOverflowed = true
            }
        }
    }

    /// `static const <type> <name>[<count>] =` — the text before an array's
    /// opening brace. Nil for any other brace (the table, the init
    /// function); a `static const` this parser cannot read throws, because
    /// skipping a weights array would build a wrong blob.
    static func declaration(
        _ line: [UInt8]
    ) throws -> (name: String, type: RNNoiseWeightBlob.ElementType, count: Int)? {
        let text = String(decoding: line, as: UTF8.self).trimmingCharacters(in: .whitespaces)
        guard text.hasPrefix("static const ") else { return nil }
        let words = text.dropFirst("static const ".count).split(separator: " ", omittingEmptySubsequences: true)
        guard words.count >= 3,
              words.last == "=",
              let type = RNNoiseWeightBlob.ElementType(cName: String(words[0]))
        else { throw RNNoiseWeightsError.malformed("unreadable declaration: \(text)") }
        let declarator = words[1...].dropLast().joined()
        guard let open = declarator.firstIndex(of: "["),
              declarator.last == "]",
              let count = Int(declarator[declarator.index(after: open)...].dropLast()),
              count > 0
        else { throw RNNoiseWeightsError.malformed("unreadable declarator: \(text)") }
        let name = String(declarator[..<open])
        guard !name.isEmpty else { throw RNNoiseWeightsError.malformed("unnamed array: \(text)") }
        return (name, type, count)
    }

    private mutating func begin(_ declaration: (name: String, type: RNNoiseWeightBlob.ElementType, count: Int)) {
        let byteCount = declaration.count * declaration.type.byteWidth
        output.append(contentsOf: RNNoiseWeightBlob.header(
            name: declaration.name,
            type: declaration.type,
            byteCount: byteCount
        ))
        open = OpenArray(type: declaration.type, count: declaration.count)
        mode = .values
    }

    // MARK: Values

    private mutating func value(_ byte: UInt8) throws {
        switch byte {
        case UInt8(ascii: ","), UInt8(ascii: " "), UInt8(ascii: "\n"), UInt8(ascii: "\t"), UInt8(ascii: "\r"):
            try commitToken()
        case UInt8(ascii: "}"):
            try commitToken()
            end()
        case UInt8(ascii: "0")...UInt8(ascii: "9"), UInt8(ascii: "-"), UInt8(ascii: "+"),
             UInt8(ascii: "."), UInt8(ascii: "e"), UInt8(ascii: "E"):
            guard tokenLength < token.count - 1 else { throw RNNoiseWeightsError.malformed("overlong value") }
            token[tokenLength] = CChar(bitPattern: byte)
            tokenLength += 1
        default:
            throw RNNoiseWeightsError.malformed("unexpected byte \(byte) in an array")
        }
    }

    private mutating func commitToken() throws {
        guard tokenLength > 0, var array = open else { return }
        defer { tokenLength = 0 }
        guard array.written < array.count else { throw RNNoiseWeightsError.malformed("more values than declared") }
        switch array.type {
        case .float:
            token[tokenLength] = 0
            let length = tokenLength
            let parsed: Double? = token.withUnsafeBufferPointer { buffer in
                guard let start = buffer.baseAddress else { return nil }
                var end: UnsafeMutablePointer<CChar>?
                let value = strtod(start, &end)
                guard let end, end - UnsafeMutablePointer(mutating: start) == length else { return nil }
                return value
            }
            guard let parsed else { throw RNNoiseWeightsError.malformed("bad float") }
            append(Float(parsed).bitPattern.littleEndian)
        case .int:
            guard let parsed = parseInteger(), let value = Int32(exactly: parsed) else {
                throw RNNoiseWeightsError.malformed("bad int")
            }
            append(value.littleEndian)
        case .int8:
            guard let parsed = parseInteger(), let value = Int8(exactly: parsed) else {
                throw RNNoiseWeightsError.malformed("bad int8")
            }
            output.append(UInt8(bitPattern: value))
        }
        array.written += 1
        open = array
    }

    /// A decimal integer, optionally signed — all the generated file writes.
    private func parseInteger() -> Int? {
        var index = 0
        var negative = false
        if token[0] == CChar(bitPattern: UInt8(ascii: "-")) || token[0] == CChar(bitPattern: UInt8(ascii: "+")) {
            negative = token[0] == CChar(bitPattern: UInt8(ascii: "-"))
            index = 1
        }
        guard index < tokenLength, tokenLength - index <= 18 else { return nil }
        var value = 0
        while index < tokenLength {
            let digit = Int(token[index]) - Int(UInt8(ascii: "0"))
            guard (0...9).contains(digit) else { return nil }
            value = value * 10 + digit
            index += 1
        }
        return negative ? -value : value
    }

    private mutating func append<T: FixedWidthInteger>(_ value: T) {
        withUnsafeBytes(of: value) { output.append(contentsOf: $0) }
    }

    private mutating func end() {
        guard let array = open else { return }
        let byteCount = array.count * array.type.byteWidth
        let missing = (array.count - array.written) * array.type.byteWidth
        let padding = RNNoiseWeightBlob.blockSize(for: byteCount) - byteCount
        output.append(contentsOf: repeatElement(0, count: missing + padding))
        open = nil
        arrayCount += 1
        mode = .scanning
    }
}

// MARK: - The tarball

/// A streaming reader for the model tarball: fed chunks of any size, it
/// reports each regular file's start, its content in pieces, and its end.
/// Handles POSIX ustar (with the prefix field), GNU `L` long names and pax
/// `path` records; directories, links and global headers are skipped. Header
/// checksums are verified — a misframed stream fails here rather than
/// feeding garbage onward.
struct TarStreamReader {
    enum Event {
        case begin(path: String)
        /// Valid only for the duration of the handler call.
        case content(UnsafeRawBufferPointer)
        case end
    }

    private enum MetaKind {
        case longName
        case pax
    }

    private enum State {
        case header
        case content(remaining: Int, padding: Int)
        case meta(MetaKind, remaining: Int, padding: Int)
        case skip(remaining: Int)
        case finished
    }

    private static let blockSize = 512
    /// Long names and pax records are a few hundred bytes; anything bigger is
    /// not a header this archive would carry.
    private static let metaCapacity = 1 << 16

    private var state = State.header
    private var header: [UInt8] = []
    private var meta: [UInt8] = []
    private var pendingLongName: String?
    private var pendingPaxPath: String?

    /// The end-of-archive block was read; later bytes are ignored.
    var isFinished: Bool {
        if case .finished = state { return true }
        return false
    }

    mutating func feed(_ bytes: UnsafeRawBufferPointer, _ handle: (Event) throws -> Void) throws {
        var index = 0
        while index < bytes.count {
            let available = bytes.count - index
            switch state {
            case .finished:
                return
            case .header:
                let take = min(Self.blockSize - header.count, available)
                header.append(contentsOf: UnsafeRawBufferPointer(rebasing: bytes[index..<index + take]))
                index += take
                if header.count == Self.blockSize {
                    try readHeader(handle)
                    header.removeAll(keepingCapacity: true)
                }
            case .content(let remaining, let padding):
                let take = min(remaining, available)
                try handle(.content(UnsafeRawBufferPointer(rebasing: bytes[index..<index + take])))
                index += take
                if take == remaining {
                    try handle(.end)
                    state = padding > 0 ? .skip(remaining: padding) : .header
                } else {
                    state = .content(remaining: remaining - take, padding: padding)
                }
            case .meta(let kind, let remaining, let padding):
                let take = min(remaining, available)
                meta.append(contentsOf: UnsafeRawBufferPointer(rebasing: bytes[index..<index + take]))
                index += take
                if take == remaining {
                    try finishMeta(kind)
                    state = padding > 0 ? .skip(remaining: padding) : .header
                } else {
                    state = .meta(kind, remaining: remaining - take, padding: padding)
                }
            case .skip(let remaining):
                let take = min(remaining, available)
                index += take
                state = take == remaining ? .header : .skip(remaining: remaining - take)
            }
        }
    }

    private mutating func readHeader(_ handle: (Event) throws -> Void) throws {
        if header.allSatisfy({ $0 == 0 }) {
            state = .finished
            return
        }
        guard let stored = Self.octal(header[148..<156]) else {
            throw RNNoiseWeightsError.malformed("tar checksum field")
        }
        let computed = header.enumerated().reduce(0) { sum, item in
            sum + ((148..<156).contains(item.offset) ? 0x20 : Int(item.element))
        }
        guard stored == computed else { throw RNNoiseWeightsError.malformed("tar header checksum") }
        guard let size = Self.octal(header[124..<136]) else { throw RNNoiseWeightsError.malformed("tar size") }
        let padding = (Self.blockSize - size % Self.blockSize) % Self.blockSize
        switch header[156] {
        case UInt8(ascii: "L"), UInt8(ascii: "x"):
            guard size <= Self.metaCapacity else { throw RNNoiseWeightsError.malformed("tar metadata too large") }
            let kind: MetaKind = header[156] == UInt8(ascii: "L") ? .longName : .pax
            meta.removeAll(keepingCapacity: true)
            state = size > 0 ? .meta(kind, remaining: size, padding: padding) : .header
        case UInt8(ascii: "0"), 0:
            let path = pendingLongName ?? pendingPaxPath ?? headerPath()
            pendingLongName = nil
            pendingPaxPath = nil
            try handle(.begin(path: path))
            if size > 0 {
                state = .content(remaining: size, padding: padding)
            } else {
                try handle(.end)
                state = .header
            }
        default:
            // Directories, links, global pax headers: nothing to read, and a
            // pending name belonged to this entry.
            pendingLongName = nil
            pendingPaxPath = nil
            state = size + padding > 0 ? .skip(remaining: size + padding) : .header
        }
    }

    private func headerPath() -> String {
        let name = Self.string(header[0..<100])
        // POSIX ustar ("ustar\0") carries a prefix; GNU's "ustar  \0" uses the
        // same bytes for other fields.
        guard Array(header[257..<263]) == Array("ustar\0".utf8) else { return name }
        let prefix = Self.string(header[345..<500])
        return prefix.isEmpty ? name : prefix + "/" + name
    }

    private mutating func finishMeta(_ kind: MetaKind) throws {
        switch kind {
        case .longName:
            pendingLongName = Self.string(meta[...])
        case .pax:
            pendingPaxPath = try Self.paxPath(meta)
        }
    }

    /// Pax records are `"<length> <key>=<value>\n"`, the length counting the
    /// whole record.
    static func paxPath(_ records: [UInt8]) throws -> String? {
        var index = 0
        var path: String?
        while index < records.count {
            guard let space = records[index...].firstIndex(of: UInt8(ascii: " ")),
                  let length = Int(String(decoding: records[index..<space], as: UTF8.self)),
                  length > space - index + 1,
                  index + length <= records.count,
                  records[index + length - 1] == UInt8(ascii: "\n")
            else { throw RNNoiseWeightsError.malformed("pax record") }
            let record = records[(space + 1)..<(index + length - 1)]
            if let equals = record.firstIndex(of: UInt8(ascii: "=")),
               String(decoding: record[..<equals], as: UTF8.self) == "path" {
                path = String(decoding: record[(equals + 1)...], as: UTF8.self)
            }
            index += length
        }
        return path
    }

    private static func string(_ bytes: ArraySlice<UInt8>) -> String {
        let end = bytes.firstIndex(of: 0) ?? bytes.endIndex
        return String(decoding: bytes[..<end], as: UTF8.self)
    }

    /// An octal field: leading spaces, digits, then NUL or space.
    private static func octal(_ bytes: ArraySlice<UInt8>) -> Int? {
        var value = 0
        var sawDigit = false
        for byte in bytes {
            switch byte {
            case UInt8(ascii: "0")...UInt8(ascii: "7"):
                value = value * 8 + Int(byte - UInt8(ascii: "0"))
                sawDigit = true
            case UInt8(ascii: " ") where !sawDigit:
                continue
            case 0, UInt8(ascii: " "):
                return sawDigit ? value : nil
            default:
                return nil
            }
        }
        return sawDigit ? value : nil
    }
}

// MARK: - The gzip wrapper

/// The gzip member header (RFC 1952) in front of the archive's DEFLATE body.
/// The body itself is inflated by the Compression framework, which reads raw
/// DEFLATE and nothing around it; the trailer is never needed, because the
/// whole file's SHA-256 was checked first.
enum GzipHeader {
    /// The header's length, or nil while `bytes` is too short to tell.
    static func length(of bytes: UnsafeRawBufferPointer) throws -> Int? {
        guard bytes.count >= 10 else { return nil }
        guard bytes[0] == 0x1F, bytes[1] == 0x8B else { throw RNNoiseWeightsError.malformed("not gzip") }
        guard bytes[2] == 8 else { throw RNNoiseWeightsError.malformed("gzip method") }
        let flags = bytes[3]
        guard flags & 0xE0 == 0 else { throw RNNoiseWeightsError.malformed("gzip flags") }
        var offset = 10
        if flags & 0x04 != 0 {
            guard bytes.count >= offset + 2 else { return nil }
            offset += 2 + (Int(bytes[offset]) | Int(bytes[offset + 1]) << 8)
        }
        for flag: UInt8 in [0x08, 0x10] where flags & flag != 0 {
            guard offset < bytes.count,
                  let terminator = bytes[offset...].firstIndex(of: 0)
            else { return nil }
            offset = terminator + 1
        }
        if flags & 0x02 != 0 { offset += 2 }
        return bytes.count >= offset ? offset : nil
    }
}
