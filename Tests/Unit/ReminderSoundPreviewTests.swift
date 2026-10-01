import Foundation
import Testing
@testable import Tally

@MainActor
struct ReminderSoundPreviewTests {
    @Test func selectingTheSameSoundAgainStopsTheOldPlayerAndStartsAFreshPlayer() {
        let system = FakeSoundPreviewSystem()
        let preview = system.preview()

        preview.play(.ripple)
        preview.play(.ripple)

        #expect(preview.playbackRequestCount == 2)
        #expect(system.players.count == 2)
        #expect(system.players[0].playCount == 1)
        #expect(system.players[0].stopCount == 1)
        #expect(system.players[1].playCount == 1)
        #expect(system.players[1].stopCount == 0)
        #expect(system.events == ["create:Rebound.caf", "play:0", "stop:0", "create:Rebound.caf", "play:1"])
    }

    @Test func choosingNoneStopsTheCurrentPreviewWithoutCreatingAnotherPlayer() {
        let system = FakeSoundPreviewSystem()
        let preview = system.preview()
        preview.play(.glow)

        preview.play(.none)
        preview.play(.none)

        #expect(preview.playbackRequestCount == 1)
        #expect(system.players.count == 1)
        #expect(system.players[0].stopCount == 1)
        #expect(system.resolvedFilenames == ["Chord.caf"])
    }

    @Test func stoppingOnDismissalIsIdempotentAndTheNextSelectionStartsFresh() {
        let system = FakeSoundPreviewSystem()
        let preview = system.preview()
        preview.play(.pebble)

        preview.stop()
        preview.stop()

        #expect(system.players[0].stopCount == 1)
        #expect(preview.playbackRequestCount == 1)
        preview.play(.pebble)
        #expect(system.players.count == 2)
        #expect(system.players[1].playCount == 1)
        #expect(preview.playbackRequestCount == 2)
    }

    @Test func changingSoundsStopsPlaybackBeforeCreatingTheNextPlayer() {
        let system = FakeSoundPreviewSystem()
        let preview = system.preview()

        preview.play(.lift)
        preview.play(.signal)

        #expect(system.events == ["create:Chime.caf", "play:0", "stop:0", "create:Bell.caf", "play:1"])
        #expect(preview.playbackRequestCount == 2)
    }

    @Test func suppressedPlaybackStillRecordsRepeatedSelectionRequestsWithoutMakingPlayers() {
        let system = FakeSoundPreviewSystem()
        let preview = system.preview(playbackSuppressed: true)

        preview.play(.ripple)
        preview.play(.ripple)
        preview.play(.none)

        #expect(preview.playbackRequestCount == 2)
        #expect(system.players.isEmpty)
        #expect(system.events.isEmpty)
    }

    @Test func missingResourcesStopThePreviousSoundAndFailSilently() {
        let system = FakeSoundPreviewSystem()
        let preview = system.preview()
        preview.play(.ripple)
        system.resourceAvailable = false

        preview.play(.glow)

        #expect(preview.playbackRequestCount == 1)
        #expect(system.players.count == 1)
        #expect(system.players[0].stopCount == 1)
    }

    @Test func unusableAudioStopsThePreviousSoundAndFailsSilently() {
        let system = FakeSoundPreviewSystem()
        let preview = system.preview()
        preview.play(.ripple)
        system.failCreation = true

        preview.play(.signal)
        preview.stop()

        #expect(preview.playbackRequestCount == 2)
        #expect(system.players.count == 1)
        #expect(system.players[0].stopCount == 1)
    }
}

@MainActor
private final class FakeSoundPreviewSystem {
    final class FakePlayer {
        var playCount = 0
        var stopCount = 0
    }

    enum TestError: Error { case unusableAudio }

    var players: [FakePlayer] = []
    var events: [String] = []
    var resolvedFilenames: [String] = []
    var resourceAvailable = true
    var failCreation = false

    func preview(playbackSuppressed: Bool = false) -> ReminderSoundPreview {
        ReminderSoundPreview(
            playbackSuppressed: playbackSuppressed,
            resolveResource: { [self] filename in
                resolvedFilenames.append(filename)
                return resourceAvailable ? URL(fileURLWithPath: "/fixture/\(filename)") : nil
            },
            makePlayer: { [self] url in
                if failCreation { throw TestError.unusableAudio }
                let index = players.count
                let player = FakePlayer()
                players.append(player)
                events.append("create:\(url.lastPathComponent)")
                return ReminderSoundPreview.Player(
                    play: { [self] in
                        player.playCount += 1
                        events.append("play:\(index)")
                    },
                    stop: { [self] in
                        player.stopCount += 1
                        events.append("stop:\(index)")
                    }
                )
            }
        )
    }
}
