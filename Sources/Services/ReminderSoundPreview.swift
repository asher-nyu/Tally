import AVFAudio
import Foundation
import Observation

/// Auditions bundled tones without scheduling a notification or asking permission.
@MainActor
@Observable
final class ReminderSoundPreview {
    struct Player {
        let play: @MainActor () -> Void
        let stop: @MainActor () -> Void
    }

    /// Counts selection requests, including reselection of the current sound.
    /// This remains observable when UI tests suppress actual audio playback.
    private(set) var playbackRequestCount = 0

    @ObservationIgnored private var player: Player?
    @ObservationIgnored private let playbackSuppressed: Bool
    @ObservationIgnored private let resolveResource: @MainActor (String) -> URL?
    @ObservationIgnored private let makePlayer: @MainActor (URL) throws -> Player

    init(
        playbackSuppressed: Bool = ProcessInfo.processInfo.arguments.contains("--ui-testing")
            || ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            || NSClassFromString("XCTestCase") != nil,
        resolveResource: @escaping @MainActor (String) -> URL? = {
            Bundle.main.url(forResource: $0, withExtension: nil)
        },
        makePlayer: @escaping @MainActor (URL) throws -> Player = { url in
            let audioPlayer = try AVAudioPlayer(contentsOf: url)
            #if os(iOS)
            // Previews respect silent mode and mix with audio from other apps.
            try? AVAudioSession.sharedInstance().setCategory(.ambient, mode: .default)
            #endif
            return Player(play: { audioPlayer.play() }, stop: { audioPlayer.stop() })
        }
    ) {
        self.playbackSuppressed = playbackSuppressed
        self.resolveResource = resolveResource
        self.makePlayer = makePlayer
    }

    func play(_ sound: PaymentReminderSound) {
        stop()
        guard let filename = sound.bundledFilename,
              let url = resolveResource(filename) else { return }
        playbackRequestCount += 1
        guard !playbackSuppressed,
              let player = try? makePlayer(url) else { return }
        self.player = player
        player.play()
    }

    func stop() {
        player?.stop()
        player = nil
    }
}
