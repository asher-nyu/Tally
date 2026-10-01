#!/usr/bin/env python3
"""Build Tally's five original reminder sounds and validate their bundled PCM.

Uses Python's standard library and macOS afconvert. No recordings, samples,
soundfonts, or third-party assets are used. Run without arguments to regenerate
previews and copy the matching CAFs to Sources; use --check for read-only checks.
Ripple's waveform is intentionally unchanged from the previous sound collection.
"""

from __future__ import annotations

import argparse
import array
import hashlib
import json
import math
from pathlib import Path
import random
import shutil
import struct
import subprocess
import sys
import tempfile
import wave


ROOT = Path(__file__).resolve().parent
SOURCES = ROOT.parents[1] / "Sources"
SAMPLE_RATE = 44_100
PEAK_TARGET = 0.55
TAU = 2.0 * math.pi
RESOURCE_NAMES = {
    "Ripple": "Rebound.caf",
    "Pebble": "Bamboo.caf",
    "Glow": "Chord.caf",
    "Lift": "Chime.caf",
    "Signal": "Bell.caf",
}
DURATIONS = {"Ripple": 1.8, "Pebble": 1.15, "Glow": 2.1, "Lift": 1.35, "Signal": 1.5}
DESCRIPTIONS = {
    "Ripple": "A light cascade of rounded, resonant tones.",
    "Pebble": "Two close, rounded taps with a soft ceramic resonance.",
    "Glow": "A warm, gently blooming interval with a spacious finish.",
    "Lift": "One smooth rising gesture that settles into a quiet resonance.",
    "Signal": "Two clear, measured pulses with a warm, focused tone.",
}
RIPPLE_PCM_SHA256 = "b55217fb3bfc005e3511b44d2254edeef2e2211b6744fd23e6443548b4c1ef6d"
WOOD = ((1.0, 1.0, 1.0), (2.62, 0.20, 0.38), (4.18, 0.065, 0.24))


def midi(note: float) -> float:
    return 440.0 * 2.0 ** ((note - 69.0) / 12.0)


def smoothstep(value: float) -> float:
    value = min(1.0, max(0.0, value))
    return value * value * (3.0 - 2.0 * value)


def add_voice(
    output: list[float], *, onset: float, note: float, duration: float,
    level: float = 1.0, decay: float = 0.32, attack: float = 0.007,
    partials: tuple[tuple[float, float, float], ...] = ((1.0, 1.0, 1.0),),
) -> None:
    """The unchanged modal voice used by Ripple; each mode decays independently."""
    start = round(onset * SAMPLE_RATE)
    count = min(round(duration * SAMPLE_RATE), len(output) - start)
    release = min(0.15, duration * 0.2)
    fundamental = midi(note)
    for frame in range(count):
        t = frame / SAMPLE_RATE
        remaining = (count - 1 - frame) / SAMPLE_RATE
        attack_gain = 0.5 - 0.5 * math.cos(math.pi * min(1.0, t / attack))
        release_gain = 0.5 - 0.5 * math.cos(math.pi * min(1.0, remaining / release))
        signal = sum(
            amplitude * math.exp(-t / (decay * decay_ratio))
            * math.sin(TAU * fundamental * ratio * t)
            for ratio, amplitude, decay_ratio in partials
        )
        output[start + frame] += signal * attack_gain * release_gain * level


def add_resonance(
    output: list[float], *, onset: float, frequency: float, duration: float,
    modes: tuple[tuple[float, float, float], ...], attack: float = 0.008,
    release: float = 0.18, level: float = 1.0, detune: float = 0.0,
) -> None:
    """A damped resonator with independent mode lifetimes and a rounded onset.

    Low-level symmetric detuning supplies gentle width in a mono signal without
    phase cancellation or a synthetic chorus effect. All modes stay below 5 kHz.
    """
    start = round(onset * SAMPLE_RATE)
    count = min(round(duration * SAMPLE_RATE), len(output) - start)
    for frame in range(count):
        t = frame / SAMPLE_RATE
        edge = smoothstep(t / attack) * smoothstep((count - 1 - frame) / SAMPLE_RATE / release)
        signal = 0.0
        for ratio, amplitude, lifetime in modes:
            phase = TAU * frequency * ratio * t
            mode = math.sin(phase)
            if detune:
                mode = 0.82 * mode + 0.09 * math.sin(phase + TAU * detune * t) + 0.09 * math.sin(phase - TAU * detune * t)
            signal += amplitude * math.exp(-t / lifetime) * mode
        output[start + frame] += signal * edge * level


def add_air(output: list[float], *, onset: float, duration: float, level: float, seed: int) -> None:
    """A quiet deterministic filtered-noise attack; never a sampled transient."""
    generator = random.Random(seed)
    start = round(onset * SAMPLE_RATE)
    count = min(round(duration * SAMPLE_RATE), len(output) - start)
    smooth = 0.0
    slower = 0.0
    for frame in range(count):
        t = frame / SAMPLE_RATE
        smooth += 0.15 * (generator.uniform(-1, 1) - smooth)
        slower += 0.025 * (smooth - slower)
        envelope = smoothstep(t / 0.004) * math.exp(-t / 0.017) * smoothstep((count - 1 - frame) / SAMPLE_RATE / 0.015)
        output[start + frame] += (smooth - slower) * envelope * level


def normalize(output: list[float]) -> list[float]:
    # Kept unchanged so Ripple remains sample-exact. Preserve headroom, remove
    # residual DC, and apply a raised-cosine edge without compressing dynamics.
    peak = max(abs(sample) for sample in output)
    output = [sample * PEAK_TARGET / peak for sample in output]
    mean = sum(output) / len(output)
    output = [sample - mean for sample in output]
    edge = round(0.010 * SAMPLE_RATE)
    for i in range(edge):
        fade = 0.5 - 0.5 * math.cos(math.pi * i / (edge - 1))
        output[i] *= fade
        output[-i - 1] *= fade
    peak = max(abs(sample) for sample in output)
    return [sample * PEAK_TARGET / peak for sample in output]


def synthesize(name: str) -> list[float]:
    output = [0.0] * round(DURATIONS[name] * SAMPLE_RATE)
    if name == "Ripple":
        for onset, note, level in ((0.02, 71, 0.80), (0.43, 74, 0.53), (0.73, 78, 0.35), (0.94, 74, 0.23)):
            add_voice(output, onset=onset, note=note, duration=0.76, level=level,
                      decay=0.19, attack=0.008, partials=WOOD)
    elif name == "Pebble":
        # Close taps, not a tune. Short inharmonic modes add rounded ceramic
        # texture while the low fundamental keeps the impact from sounding sharp.
        modes = ((1.0, 1.0, 0.19), (1.47, 0.24, 0.095), (2.38, 0.12, 0.055), (3.73, 0.025, 0.023))
        for onset, frequency, level in ((0.025, 640.0, 0.86), (0.225, 608.0, 0.71)):
            add_resonance(output, onset=onset, frequency=frequency, duration=0.86,
                          modes=modes, attack=0.005, release=0.15, level=level)
            add_air(output, onset=onset, duration=0.11, level=0.13 * level, seed=27)
    elif name == "Glow":
        # Slowly overlapping fifths with modest upper harmonics; the interval
        # blooms as a single object, without an arpeggio or a conspicuous melody.
        modes = ((1.0, 1.0, 0.48), (2.0, 0.13, 0.29), (3.0, 0.018, 0.16))
        add_resonance(output, onset=0.025, frequency=392.0, duration=2.0,
                      modes=modes, attack=0.065, release=0.40, level=0.75, detune=0.8)
        add_resonance(output, onset=0.070, frequency=588.0, duration=1.96,
                      modes=modes, attack=0.095, release=0.40, level=0.42, detune=1.0)
        add_resonance(output, onset=0.095, frequency=784.0, duration=1.92,
                      modes=((1.0, 1.0, 0.37),), attack=0.11, release=0.40, level=0.08)
    elif name == "Lift":
        # One continuous curved pitch motion (not stepped notes). Integration of
        # instantaneous frequency preserves phase continuity throughout the rise.
        phase = 0.0
        start = round(0.025 * SAMPLE_RATE)
        count = round(1.27 * SAMPLE_RATE)
        for frame in range(count):
            t = frame / SAMPLE_RATE
            progress = smoothstep(t / 0.25)
            frequency = 480.0 + 240.0 * progress
            phase += TAU * frequency / SAMPLE_RATE
            edge = smoothstep(t / 0.024) * smoothstep((count - 1 - frame) / SAMPLE_RATE / 0.30)
            envelope = math.exp(-t / 0.29) * edge
            harmonics = math.sin(phase) + 0.16 * math.exp(-t / 0.17) * math.sin(2.0 * phase) + 0.035 * math.exp(-t / 0.08) * math.sin(3.0 * phase)
            output[start + frame] += envelope * harmonics
        add_resonance(output, onset=0.25, frequency=720.0, duration=1.04,
                      modes=((1.0, 1.0, 0.25), (2.0, 0.055, 0.14)), attack=0.11,
                      release=0.30, level=0.20, detune=1.6)
    elif name == "Signal":
        # A measured repeated interval, with a softer first pulse and focused
        # second pulse. Midrange content carries on small speakers without buzz.
        modes = ((1.0, 1.0, 0.26), (1.5, 0.24, 0.19), (2.0, 0.11, 0.11), (3.0, 0.018, 0.06))
        for onset, level in ((0.025, 0.76), (0.405, 0.90)):
            add_resonance(output, onset=onset, frequency=560.0, duration=1.045,
                          modes=modes, attack=0.014, release=0.23, level=level)
    else:
        raise ValueError(f"Unknown sound: {name}")
    return normalize(output)


def pcm_bytes(samples: list[float]) -> bytes:
    pcm = array.array("h", (round(sample * 32_767) for sample in samples))
    if sys.byteorder != "little":
        pcm.byteswap()
    return pcm.tobytes()


def write_wav(path: Path, data: bytes) -> None:
    with wave.open(str(path), "wb") as stream:
        stream.setnchannels(1)
        stream.setsampwidth(2)
        stream.setframerate(SAMPLE_RATE)
        stream.writeframes(data)


def read_wav(path: Path) -> bytes:
    with wave.open(str(path), "rb") as stream:
        assert stream.getnchannels() == 1, path
        assert stream.getsampwidth() == 2, path
        assert stream.getframerate() == SAMPLE_RATE, path
        assert stream.getcomptype() == "NONE", path
        return stream.readframes(stream.getnframes())


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def validate_caf_format(path: Path) -> None:
    """Inspect the source CAF descriptor before any format conversion can mask it."""
    data = path.read_bytes()
    assert data[:8] == b"caff\x00\x01\x00\x00", path
    offset = 8
    while offset + 12 <= len(data):
        kind, length = struct.unpack_from(">4sq", data, offset)
        offset += 12
        if kind == b"desc":
            sample_rate, format_id, flags, packet_bytes, packet_frames, channels, bits = struct.unpack_from(">d4sIIIII", data, offset)
            assert sample_rate == SAMPLE_RATE, path
            assert format_id == b"lpcm", path
            assert not flags & 1, f"CAF is floating point: {path}"
            # CAFFile.h uses a little-endian flag (unlike ASBD flags).
            assert flags & 2, f"CAF is not little endian: {path}"
            assert (packet_bytes, packet_frames, channels, bits) == (2, 1, 1, 16), path
            return
        assert length >= 0, f"Missing CAF descriptor: {path}"
        offset += length
    raise AssertionError(f"Missing CAF descriptor: {path}")


def caf_pcm(path: Path) -> bytes:
    validate_caf_format(path)
    with tempfile.TemporaryDirectory(prefix="tally-audio-check-") as temporary:
        roundtrip = Path(temporary) / "roundtrip.wav"
        subprocess.run(["/usr/bin/afconvert", "-f", "WAVE", "-d", "LEI16", str(path), str(roundtrip)], check=True)
        return read_wav(roundtrip)


def validate(name: str) -> dict:
    wav = ROOT / f"{name}.wav"
    caf = ROOT / f"{name}.caf"
    bundled = SOURCES / RESOURCE_NAMES[name]
    data = read_wav(wav)
    assert data == pcm_bytes(synthesize(name)), f"Preview is not reproducible: {name}"
    assert caf_pcm(caf) == data, f"Preview CAF mismatch: {name}"
    assert caf_pcm(bundled) == data, f"Bundled CAF mismatch: {name}"
    assert caf.read_bytes() == bundled.read_bytes(), f"Bundled container mismatch: {name}"
    pcm = array.array("h", data)
    if sys.byteorder != "little":
        pcm.byteswap()
    peak = max(abs(sample) for sample in pcm) / 32_767
    rms = math.sqrt(sum(sample * sample for sample in pcm) / len(pcm)) / 32_767
    dc = sum(pcm) / len(pcm)
    assert pcm[0] == pcm[-1] == 0, name
    assert 0.5499 <= peak <= 0.5501, (name, peak)
    assert 0.05 <= rms <= 0.20, (name, rms)
    assert 0 < len(pcm) / SAMPLE_RATE < 3.0, name
    assert abs(dc) < 0.1, (name, dc)
    assert not any(abs(sample) >= 32_767 for sample in pcm), name
    # A nonzero middle and energy above -26 dBFS check asset audibility. They do
    # not guarantee device loudness or make any subjective listening judgement.
    assert max(abs(sample) for sample in pcm[len(pcm)//8:len(pcm)//2]) > 2000, name
    pcm_hash = hashlib.sha256(data).hexdigest()
    if name == "Ripple":
        assert pcm_hash == RIPPLE_PCM_SHA256, "Ripple's original waveform changed"
    return {
        "name": name,
        "description": DESCRIPTIONS[name],
        "bundled_resource": RESOURCE_NAMES[name],
        "duration_seconds": round(len(pcm) / SAMPLE_RATE, 6),
        "frames": len(pcm),
        "sample_rate_hz": SAMPLE_RATE,
        "channels": 1,
        "bits_per_sample": 16,
        "peak_linear": round(peak, 6),
        "rms_linear": round(rms, 6),
        "peak_dbfs": round(20 * math.log10(peak), 3),
        "rms_dbfs": round(20 * math.log10(rms), 3),
        "first_sample": pcm[0],
        "last_sample": pcm[-1],
        "dc_offset_pcm_units": round(dc, 6),
        "clipped_samples": 0,
        "caf_roundtrip_sample_exact": True,
        "bundle_matches_preview": True,
        "synthesis_reproducible": True,
        "pcm_sha256": pcm_hash,
        "wav_sha256": sha256(wav),
        "caf_sha256": sha256(caf),
    }


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true", help="Validate without modifying any assets.")
    args = parser.parse_args()
    report = {
        "provenance": "Original modal and additive synthesis with deterministic filtered noise defined entirely in generate_tones.py; no recordings, samples, soundfonts, or third-party sound assets.",
        "format": "Mono signed 16-bit little-endian PCM, 44100 Hz",
        "status": "Original synthesized preview assets; corresponding CAFs are bundled by the app",
        "default": "Ripple",
        "silent_option": "None",
        "validation_scope": "Reproducibility, PCM/container equality, sample format, duration, clipping, DC, endpoint silence and energy. Subjective listening quality and device playback volume are not inferred from these checks.",
        "sounds": [],
    }
    for name, resource in RESOURCE_NAMES.items():
        wav, caf = ROOT / f"{name}.wav", ROOT / f"{name}.caf"
        if not args.check:
            data = pcm_bytes(synthesize(name))
            # Do not touch existing containers if their waveform is already the
            # requested waveform. This preserves Ripple CAF and WAV byte-for-byte.
            if not wav.exists() or read_wav(wav) != data:
                write_wav(wav, data)
            if not caf.exists() or caf_pcm(caf) != data:
                subprocess.run(["/usr/bin/afconvert", "-f", "caff", "-d", "LEI16", str(wav), str(caf)], check=True)
            if not (SOURCES / resource).exists() or sha256(SOURCES / resource) != sha256(caf):
                shutil.copy2(caf, SOURCES / resource)
        sound = validate(name)
        report["sounds"].append(sound)
        print(f"{name}: {sound['duration_seconds']:.2f} s, peak {sound['peak_dbfs']:.2f} dBFS, RMS {sound['rms_dbfs']:.2f} dBFS; sample-exact preview and bundled CAF")
    if not args.check:
        (ROOT / "Validation.json").write_text(json.dumps(report, indent=2) + "\n")
    else:
        assert json.loads((ROOT / "Validation.json").read_text()) == report, "Validation report is stale"


if __name__ == "__main__":
    main()
