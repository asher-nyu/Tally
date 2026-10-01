# Notification sounds

**Ripple is the default reminder sound.** The app offers six choices, in order:
**Ripple**, **Pebble**, **Glow**, **Lift**, **Signal**, and **None**. Five choices
play original synthesized audio; None delivers a silent notification. Selecting
an audible sound previews it every time, even when it is already selected.
Selecting None stops any preview in progress.

Ripple retains its original light cascade. The other four sounds are new
compositions: Pebble has two rounded taps, Glow a gently opening interval, Lift
a smooth rising gesture, and Signal two measured pulses.

## Source and generation

The reproducible source is `Release/Original Sound Previews/generate_tones.py`.
It uses Python's standard library to combine mathematical sine waves, specified
pitches and overtone ratios, decays, and smooth envelopes. No recordings, Apple
ToneLibrary files, samples, soundfonts, or third-party audio assets are used.
The system `afconvert` tool packages the generated PCM into CAF containers
without supplying sound content.

Each bundled CAF is a byte-for-byte copy of its corresponding original preview
CAF. The app uses the public User Notifications and AVFAudio APIs for delivery
and previews.

## Bundled sounds and compatibility

The resource filenames and stored identifiers for retained sound slots stay
stable, so previously scheduled notification requests still resolve their sound
file. The user-facing labels and preview filenames use the current names.
Existing selections in these five slots retain their slot; four slots now play
the redesigned audio. A silent selection remains silent.

| Display label | Stored identifier | Bundled resource | Original preview |
| --- | --- | --- | --- |
| Ripple | `rebound` | `Rebound.caf` | `Ripple.caf` |
| Pebble | `bamboo` | `Bamboo.caf` | `Pebble.caf` |
| Glow | `chord` | `Chord.caf` | `Glow.caf` |
| Lift | `chime` | `Chime.caf` | `Lift.caf` |
| Signal | `bell` | `Bell.caf` | `Signal.caf` |
| None | `none` | — | — |

Retired selections and missing sound settings resolve to Ripple when existing
files or reminder caches are decoded. This compatibility conversion does not
require a file-format version change. On launch, the notification coordinator
restores its cache and refreshes pending requests even when their documents are
closed.

## Validation

- Mono, signed 16-bit little-endian PCM at 44,100 Hz.
- All clips last 1.15–2.10 seconds.
- Every sound has smooth attack and release envelopes, headroom, no clipped
  samples, and exact zero first and last samples.
- Each CAF is decoded back to PCM and checked against the generated source.
- `Release/Original Sound Previews/Validation.json` records duration, format,
  peak, RMS, DC offset, edge samples, reproducibility, and SHA-256 hashes.
- `python3 generate_tones.py --check`, run in the preview directory, checks the
  current assets against the synthesis source and bundled resources.

Signal measurements establish file integrity and amplitude; perceived volume
also depends on the device, its speakers, and the user's sound settings.

## Signal measurements

| Sound | Duration | Peak | RMS |
| --- | ---: | ---: | ---: |
| Ripple | 1.80 s | -5.19 dBFS | -20.18 dBFS |
| Pebble | 1.15 s | -5.19 dBFS | -18.92 dBFS |
| Glow | 2.10 s | -5.19 dBFS | -20.04 dBFS |
| Lift | 1.35 s | -5.19 dBFS | -17.25 dBFS |
| Signal | 1.50 s | -5.19 dBFS | -18.50 dBFS |

## Source asset checksums

| Bundled resource | SHA-256 |
| --- | --- |
| `Rebound.caf` | `f228b279d55fe1097b06fc6544148f8a6ae80d8c0a7d2ec0eff7e046b8602381` |
| `Bamboo.caf` | `95de3cc1e63cefda6d75461e4cfec7a53d9bc71ea0c8db371e28fc2019b0ea76` |
| `Chord.caf` | `60de1ffcf17c3850c15a1779897859eae59667f738f0a50c5e22400973c24650` |
| `Chime.caf` | `25133da555bdbebf3eac0e26ff651e04529a11a6505008e17dcd3d2de600478d` |
| `Bell.caf` | `060d483df1604f5bbbe181176e45b8a056bef2b78382d845d70392953d0ba694` |
