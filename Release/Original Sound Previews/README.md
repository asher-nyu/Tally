# Original notification sound previews

Five original synthesized sounds for Tally. **Ripple is the default reminder
sound.** The app offers Ripple, Pebble, Glow, Lift, Signal, and None, in that
order. In the app, selecting an audible sound plays its preview every time,
including when that sound is already selected. Choosing None stops playback and
delivers a silent notification.

Ripple keeps its existing audio. Pebble, Glow, Lift, and Signal are new
compositions for the current palette. Each audible option includes a `.wav` file
for listening and a `.caf` file containing the same PCM samples for native
notifications. Listen in Finder with Quick Look, or open [Sound Previews](Preview.html)
in a browser.

| Sound | Character | Duration |
| --- | --- | ---: |
| Ripple | Four light notes that gently settle | 1.80 s |
| Pebble | Two rounded taps with a soft resonance | 1.15 s |
| Glow | A warm interval that opens and gently fades | 2.10 s |
| Lift | A smooth rise that settles into a quiet finish | 1.35 s |
| Signal | Two measured pulses with a clear, warm tone | 1.50 s |

See [Sound sources](../../Design/SoundSources.md) for bundled resource mappings,
compatibility with earlier reminder choices, measurements, and checksums.

## Provenance

All waveforms originate in `generate_tones.py`. The script uses Python's standard
library to combine mathematical sine waves, exponential decays, and shaped attack
and release envelopes. Pitches, timing, overtone ratios, and amplitudes are
specified in that source file. No sound recordings, Apple ToneLibrary files,
samples, soundfonts, downloaded assets, or third-party audio libraries are used.

The system `afconvert` utility packages the generated PCM into CAF containers;
it does not supply any sound content. The generation script is included so the
assets can be reviewed and reproduced.

## Technical validation

- Mono, signed 16-bit little-endian PCM at 44,100 Hz.
- All clips are 1.15–2.10 seconds long.
- Every clip has headroom and no clipped samples, with smooth attacks and releases
  and exact zero first and last samples.
- Each CAF is decoded back to PCM and checked against its source WAV.
- `Validation.json` records duration, RMS, peak level, residual DC offset, edge
  samples, reproducibility checks, and SHA-256 hashes.

These checks verify files and signal properties. They do not establish perceived
loudness on every device. Listening on actual iPhone and iPad speakers remains
separate from simulator playback.

## Regenerate and check

From this directory, run:

```sh
python3 generate_tones.py
python3 generate_tones.py --check
```

The script requires macOS's built-in `/usr/bin/afconvert`. Generation writes the
five preview WAVs, CAFs, and validation record and installs the corresponding CAFs
in the app's sound resources. The check reads the assets and verifies them against
the synthesis source and the app's bundled CAFs.
