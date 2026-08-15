import Foundation

/// The sound screen's clock: `m:ss`, `h:mm:ss` past an hour — the transport's
/// readouts and the header's length. Fractions floor: a clock that rounds
/// shows 0:01 for a clip half a second in.
enum FileViewerAudioClock {
    static func label(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds > 0 else { return "0:00" }
        let total = Int(seconds)
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        }
        return String(format: "%d:%02d", minutes, secs)
    }
}
