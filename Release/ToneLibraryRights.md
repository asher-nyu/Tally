# Reminder sound provenance and distribution review

Updated September 29, 2026.

## Current audio

Tally bundles five original synthesized reminder sounds: **Ripple**, **Pebble**,
**Glow**, **Lift**, and **Signal**. **Ripple** is the default; **None** delivers a
silent notification. The four alternatives to Ripple were redesigned for this
palette. The audio comes from `Original Sound Previews/generate_tones.py`, which
specifies the pitches, timing, waveforms, and envelopes and uses Python’s standard
library. The system `afconvert` utility packages the resulting PCM audio into CAF
files; it supplies no sound content.

The original synthesized audio replaced all copied system recordings before
build 18 was submitted. The unchanged build 17 and 18 verification reports are preserved beside the
Xcode archives in `~/Library/Developer/Xcode/Archives/2026-09-27/Tally Build Verification/`.
They record the filenames and hashes in the submitted builds. [Design/SoundSources.md](../Design/SoundSources.md) documents the current
names, resources, generation process, and validation.

## Earlier recordings

An early development version copied or converted nine recordings from the Mac’s
installed ToneLibrary resources. The September 27 review did not establish
permission to redistribute those recordings, so they were replaced with original
audio. Availability on a development Mac and successful playback are not evidence
of redistribution permission. Renaming a copied recording would not resolve its
rights status.

## Apple documentation reviewed

Apple supports custom notification sound files through the public
[User Notifications API](https://developer.apple.com/documentation/usernotifications/unnotificationsound).
The API’s format and playback requirements do not establish a license to
redistribute a particular system recording.

[App Review Guidelines 5.2–5.2.1](https://developer.apple.com/app-store/review/guidelines/#intellectual-property)
require appropriate rights to content included in an app. The earlier review
also consulted the
[Apple Developer Program License Agreement](https://developer.apple.com/support/terms/apple-developer-program-license-agreement/).
No specific permission to redistribute the copied ToneLibrary recordings was
identified. The current audio is independently synthesized and uses no recordings,
samples, soundfonts, or downloaded audio assets.

Copyright © 2026 Asher Bloom. All rights reserved.
