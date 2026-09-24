import AVFoundation
import Foundation
import Observation
import UniformTypeIdentifiers

/// One sound file the viewer has read whole over SFTP, decoded by
/// `AVAudioPlayer`. Owned by the `Document` that named it, not by the screen
/// showing it: the screen is a remote (PLAY/PAUSE, scrub, clock), so a tab
/// moving between windows on merge/split keeps its position, a quiet watch
/// reload can hand the position to the replacement, and closing the tab
/// releases the player — the audio stops with the document, never later.
///
/// Playback is deliberately whole-file: streaming would need a resource
/// loader over SFTP, and every file the size cap admits fits in memory.
/// Nothing here is observable — the position moves several times a second,
/// and repainting the pane's rail and header at that rate would be waste.
/// The screen polls while the clip plays. The one thing the clip follows is
/// the listener's volume store, so every clip is at the chosen level whether
/// or not a panel is currently looking at it.
@MainActor
final class FileViewerAudioClip: Equatable {
    /// Transport skips ride the same ±15 s the system players use.
    static let skipInterval: TimeInterval = 15

    private let player: AVAudioPlayer
    private let volumeStore: FileViewerAudioVolumeStore
    private let finishBridge = FinishBridge()

    var duration: TimeInterval { player.duration }
    var currentTime: TimeInterval { player.currentTime }
    var isPlaying: Bool { player.isPlaying }
    /// The gain under the device volume, 0…1 — always the store's reading.
    var volume: Float { player.volume }

    /// Throws when Core Audio can't read the bytes — an Ogg Vorbis file, a
    /// text file wearing `.mp3`, or a truncated header all land here, and
    /// the screen says CAN'T PLAY. The extension is offered as a hint only
    /// when it names a known audio type: a `dyn.` UTI for a stray extension
    /// would steer the decoder wrong where no hint lets it sniff the bytes.
    /// ⚠ Built ON the main actor on purpose: the same call from
    /// `Task.detached` measured 100–400× slower on the visionOS sim (and
    /// ~9 s for a mismatched hint) — Core Audio's open path wants a run
    /// loop; here it is sub-millisecond, header-deep, whatever the file size.
    init(data: Data, fileName: String, volumeStore: FileViewerAudioVolumeStore) throws {
        let hint = fileName.split(separator: ".").dropFirst().last
            .flatMap { UTType(filenameExtension: String($0)) }
            .flatMap { $0.conforms(to: .audio) ? $0.identifier : nil }
        player = try AVAudioPlayer(data: data, fileTypeHint: hint)
        self.volumeStore = volumeStore
        player.delegate = finishBridge
        finishBridge.clip = self
        followVolume()
    }

    deinit {
        // A released clip may have been mid-play (the tab closed): hand the
        // session back so audio interrupted elsewhere resumes.
        if player.isPlaying {
            player.stop()
            Self.releaseSession()
        }
    }

    nonisolated static func == (lhs: FileViewerAudioClip, rhs: FileViewerAudioClip) -> Bool {
        lhs === rhs
    }

    // MARK: Transport

    func play() {
        guard !player.isPlaying else { return }
        // Playback category so a muted iPad still plays what the person
        // pressed PLAY on; claimed only now, never at load, so opening a
        // sound file in the tree does not interrupt music.
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default)
        try? session.setActive(true)
        player.play()
    }

    func pause() {
        guard player.isPlaying else { return }
        player.pause()
        Self.releaseSession()
    }

    /// Stop and rewind — the tab is closing or the document is being
    /// replaced; a paused clip at position zero is what a fresh screen shows.
    func stop() {
        let wasPlaying = player.isPlaying
        player.stop()
        player.currentTime = 0
        if wasPlaying { Self.releaseSession() }
    }

    func togglePlayback() {
        if player.isPlaying { pause() } else { play() }
    }

    func seek(to time: TimeInterval) {
        // A seek at the very end makes AVAudioPlayer stop on the next tick;
        // hold a hair short so PLAY from a full scrub still plays.
        let ceiling = max(0, player.duration - 0.05)
        player.currentTime = min(max(0, time), ceiling)
    }

    func skip(by delta: TimeInterval) {
        seek(to: player.currentTime + delta)
    }

    /// A quiet watch reload swapped the bytes underneath a listener: carry
    /// the position and the playing state over so the screen does not jump
    /// to zero, and silence the clip being replaced.
    func adoptPosition(from previous: FileViewerAudioClip) {
        let wasPlaying = previous.isPlaying
        let time = previous.currentTime
        previous.stop()
        seek(to: time)
        if wasPlaying { play() }
    }

    // MARK: Volume

    /// Observation's change hook fires BEFORE the store's write lands, so
    /// the re-read happens one main-actor hop later; the panel's slider only
    /// ever writes the store.
    private func followVolume() {
        withObservationTracking {
            player.volume = volumeStore.volume
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in self?.followVolume() }
        }
    }

    // MARK: Session + finish

    /// Handing the session back can block briefly, so it happens off the main
    /// actor. A play that begins meanwhile keeps its own I/O running, and a
    /// deactivate under a running player is refused by the system — never a
    /// stop.
    nonisolated private static func releaseSession() {
        Task.detached {
            try? AVAudioSession.sharedInstance().setActive(
                false, options: .notifyOthersOnDeactivation
            )
        }
    }

    private func playbackFinished() {
        // AVAudioPlayer has already stopped and rewound itself; the session
        // is what still needs handing back.
        Self.releaseSession()
    }

    /// The delegate lives on a retained NSObject so the clip stays a plain
    /// class; AVAudioPlayer holds its delegate weakly.
    private final class FinishBridge: NSObject, AVAudioPlayerDelegate {
        weak var clip: FileViewerAudioClip?

        nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
            Task { @MainActor [weak self] in self?.clip?.playbackFinished() }
        }
    }
}
