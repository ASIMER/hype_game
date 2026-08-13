"""
gen_audio.py — procedural WAV synthesizer for Hype Raiders.

Generates all game SFX + ambient/music beds using only the Python standard
library (wave, struct, math, random).  Run once; re-run to regenerate.
Output: C:\\personal\\hype game\\assets\\audio\\*.wav  (16-bit mono, 44100 Hz)
"""

import math
import os
import random
import struct
import sys
import wave

# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------
SAMPLE_RATE = 44100
OUT_DIR = os.path.join(os.path.dirname(__file__), "..", "..", "assets", "audio")
PEAK_AMPLITUDE = int(32767 * 0.71)   # ~-3 dBFS peak


# ---------------------------------------------------------------------------
# Primitive helpers
# ---------------------------------------------------------------------------

def _write_wav(filename: str, samples: list[float]) -> None:
    """Normalise to PEAK_AMPLITUDE and write a mono 16-bit WAV."""
    peak = max(abs(s) for s in samples) if samples else 1.0
    if peak == 0.0:
        peak = 1.0
    scaled = [int(s / peak * PEAK_AMPLITUDE) for s in samples]
    path = os.path.join(OUT_DIR, filename)
    with wave.open(path, "w") as wf:
        wf.setnchannels(1)
        wf.setsampwidth(2)
        wf.setframerate(SAMPLE_RATE)
        wf.writeframes(struct.pack(f"<{len(scaled)}h", *scaled))
    print(f"  wrote {filename:30s} ({len(samples) / SAMPLE_RATE:.2f}s, {len(samples)} frames)")


def _silence(duration_s: float) -> list[float]:
    return [0.0] * int(SAMPLE_RATE * duration_s)


def _sine(freq: float, duration_s: float, amp: float = 1.0, phase: float = 0.0) -> list[float]:
    n = int(SAMPLE_RATE * duration_s)
    return [amp * math.sin(2 * math.pi * freq * i / SAMPLE_RATE + phase) for i in range(n)]


def _triangle(freq: float, duration_s: float, amp: float = 1.0) -> list[float]:
    n = int(SAMPLE_RATE * duration_s)
    period = SAMPLE_RATE / freq
    out = []
    for i in range(n):
        t = (i % period) / period  # 0..1
        out.append(amp * (2 * abs(2 * t - 1) - 1))
    return out


def _noise(duration_s: float, amp: float = 1.0, seed: int = 42) -> list[float]:
    rng = random.Random(seed)
    n = int(SAMPLE_RATE * duration_s)
    return [(rng.random() * 2 - 1) * amp for _ in range(n)]


def _adsr(
    samples: list[float],
    attack_s: float,
    decay_s: float,
    sustain_level: float,
    release_s: float,
    sustain_s: float = -1.0,
) -> list[float]:
    """Apply an ADSR envelope to samples in-place (returns copy)."""
    n = len(samples)
    a = int(attack_s * SAMPLE_RATE)
    d = int(decay_s * SAMPLE_RATE)
    r = int(release_s * SAMPLE_RATE)
    # sustain length fills the middle if not specified
    if sustain_s < 0:
        s = max(0, n - a - d - r)
    else:
        s = int(sustain_s * SAMPLE_RATE)

    out = []
    for i, v in enumerate(samples):
        if i < a:
            env = i / max(a, 1)
        elif i < a + d:
            env = 1.0 - (1.0 - sustain_level) * (i - a) / max(d, 1)
        elif i < a + d + s:
            env = sustain_level
        else:
            remaining = n - i
            env = sustain_level * (remaining / max(r, 1))
            env = max(0.0, env)
        out.append(v * env)
    return out


def _mix(*tracks: list[float]) -> list[float]:
    """Sum multiple tracks (same length) with soft clipping."""
    max_len = max(len(t) for t in tracks)
    out = [0.0] * max_len
    for track in tracks:
        for i, v in enumerate(track):
            out[i] += v
    # soft-clip (tanh)
    return [math.tanh(s * 0.8) for s in out]


def _concat(*parts: list[float]) -> list[float]:
    out = []
    for p in parts:
        out.extend(p)
    return out


def _mul(track: list[float], factor: float) -> list[float]:
    return [s * factor for s in track]


def _add_tracks(a: list[float], b: list[float]) -> list[float]:
    """Add two tracks, extending the shorter one with silence."""
    la, lb = len(a), len(b)
    if la < lb:
        a = a + [0.0] * (lb - la)
    elif lb < la:
        b = b + [0.0] * (la - lb)
    return [x + y for x, y in zip(a, b)]


def _lowpass(samples: list[float], cutoff_hz: float) -> list[float]:
    """Simple single-pole IIR lowpass."""
    rc = 1.0 / (2 * math.pi * cutoff_hz)
    dt = 1.0 / SAMPLE_RATE
    alpha = dt / (rc + dt)
    out = []
    prev = 0.0
    for s in samples:
        prev = prev + alpha * (s - prev)
        out.append(prev)
    return out


def _highpass(samples: list[float], cutoff_hz: float) -> list[float]:
    """Simple single-pole IIR highpass."""
    rc = 1.0 / (2 * math.pi * cutoff_hz)
    dt = 1.0 / SAMPLE_RATE
    alpha = rc / (rc + dt)
    out = []
    prev_in = 0.0
    prev_out = 0.0
    for s in samples:
        y = alpha * (prev_out + s - prev_in)
        prev_in = s
        prev_out = y
        out.append(y)
    return out


def _fade(samples: list[float], fade_in_s: float = 0.005, fade_out_s: float = 0.005) -> list[float]:
    """Apply a short linear fade-in/out to avoid clicks."""
    n = len(samples)
    fi = int(fade_in_s * SAMPLE_RATE)
    fo = int(fade_out_s * SAMPLE_RATE)
    out = list(samples)
    for i in range(min(fi, n)):
        out[i] *= i / fi
    for i in range(min(fo, n)):
        out[n - 1 - i] *= i / fo
    return out


# ---------------------------------------------------------------------------
# Sound generators
# ---------------------------------------------------------------------------

def gen_shot() -> list[float]:
    """Short punchy laser crack: high transient + descending tone."""
    dur = 0.18
    # transient click
    click = _noise(0.008, amp=1.0, seed=1)
    click = _adsr(click, 0.001, 0.007, 0.0, 0.0)

    # descending laser tone
    n = int(SAMPLE_RATE * dur)
    sweep = []
    for i in range(n):
        t = i / SAMPLE_RATE
        freq = 1800 * math.exp(-t * 22)   # fast descent from 1800 Hz
        sweep.append(0.55 * math.sin(2 * math.pi * freq * i / SAMPLE_RATE))
    sweep = _adsr(sweep, 0.001, 0.04, 0.0, 0.14)

    # body noise band
    body = _noise(dur, amp=0.3, seed=2)
    body = _highpass(body, 900)
    body = _adsr(body, 0.001, 0.03, 0.0, 0.15)

    mixed = _mix(
        click + [0.0] * (n - len(click)),
        sweep,
        body,
    )
    return _fade(mixed, 0.001, 0.01)


def gen_hit() -> list[float]:
    """Short impact tick: snappy transient."""
    dur = 0.07
    noise = _noise(dur, amp=1.0, seed=10)
    noise = _highpass(noise, 500)
    noise = _adsr(noise, 0.001, 0.01, 0.2, 0.059)
    tone = _sine(220, dur, 0.4)
    tone = _adsr(tone, 0.001, 0.01, 0.0, 0.059)
    return _fade(_mix(noise, tone), 0.001, 0.005)


def gen_explosion() -> list[float]:
    """Low-frequency noise burst with rumble tail."""
    dur = 0.7
    # sub boom
    boom_freq = 55
    n = int(SAMPLE_RATE * dur)
    boom = []
    for i in range(n):
        t = i / SAMPLE_RATE
        f = boom_freq * math.exp(-t * 6)
        boom.append(math.sin(2 * math.pi * f * i / SAMPLE_RATE))
    boom = _adsr(boom, 0.002, 0.12, 0.3, 0.578)

    # noise burst
    burst = _noise(dur, amp=0.8, seed=20)
    burst = _lowpass(burst, 600)
    burst = _adsr(burst, 0.001, 0.15, 0.15, 0.549)

    # mid crack
    crack = _noise(dur, amp=0.55, seed=21)
    crack = _highpass(crack, 300)
    crack = _lowpass(crack, 2000)
    crack = _adsr(crack, 0.001, 0.04, 0.0, 0.659)

    mixed = _mix(boom, burst, crack)
    return _fade(mixed, 0.001, 0.05)


def gen_player_death() -> list[float]:
    """Descending minor tone — ominous."""
    dur = 1.1
    notes = [330, 247, 185, 138]
    step = dur / len(notes)
    out = []
    for note in notes:
        seg = _triangle(note, step, amp=0.7)
        seg = _adsr(seg, 0.01, step * 0.3, 0.5, step * 0.4)
        out.extend(seg)
    noise_bed = _noise(dur, amp=0.08, seed=30)
    noise_bed = _lowpass(noise_bed, 200)
    while len(noise_bed) > len(out):
        noise_bed.pop()
    mixed = _mix(out, noise_bed + [0.0] * max(0, len(out) - len(noise_bed)))
    return _fade(mixed, 0.005, 0.08)


def gen_extract_beep() -> list[float]:
    """Clean short beep — extraction proximity cue."""
    dur = 0.18
    tone = _sine(880, dur, amp=0.9)
    tone = _adsr(tone, 0.005, 0.02, 0.8, 0.155)
    return _fade(tone, 0.003, 0.02)


def gen_extract_done() -> list[float]:
    """Rising 2-note chime — success."""
    seg1 = _sine(523, 0.2, amp=0.85)  # C5
    seg1 = _adsr(seg1, 0.005, 0.05, 0.7, 0.145)
    seg2 = _sine(784, 0.3, amp=0.85)  # G5
    seg2 = _adsr(seg2, 0.005, 0.08, 0.6, 0.215)
    return _fade(_concat(seg1, seg2), 0.003, 0.03)


def gen_extract_cancel() -> list[float]:
    """Low buzz — failure/cancel."""
    dur = 0.22
    tone = _sine(140, dur, amp=0.7)
    noise = _noise(dur, amp=0.25, seed=40)
    noise = _lowpass(noise, 300)
    mixed = _mix(
        _adsr(tone,  0.003, 0.02, 0.7, 0.197),
        _adsr(noise, 0.003, 0.02, 0.5, 0.197),
    )
    return _fade(mixed, 0.003, 0.04)


def gen_wave_alert() -> list[float]:
    """Two-tone alarm: alternating hi/lo pulses."""
    hi = _sine(880, 0.18, amp=0.85)
    lo = _sine(660, 0.18, amp=0.85)
    gap = _silence(0.04)
    hi = _adsr(hi, 0.005, 0.02, 0.8, 0.155)
    lo = _adsr(lo, 0.005, 0.02, 0.8, 0.155)
    return _fade(_concat(hi, gap, lo, gap, hi, gap, lo), 0.003, 0.03)


def gen_win() -> list[float]:
    """Major arpeggio: C-E-G-C5."""
    notes_hz = [261.63, 329.63, 392.0, 523.25]
    segs = []
    for hz in notes_hz:
        seg = _sine(hz, 0.22, amp=0.8)
        seg = _adsr(seg, 0.01, 0.04, 0.7, 0.17)
        segs.append(seg)
    # final sustain on last note
    tail = _sine(523.25, 0.4, amp=0.6)
    tail = _adsr(tail, 0.01, 0.05, 0.5, 0.34)
    return _fade(_concat(*segs, tail), 0.005, 0.04)


def gen_lose() -> list[float]:
    """Minor descending arpeggio: A-F-D-A3."""
    notes_hz = [440.0, 349.23, 293.66, 220.0]
    segs = []
    for hz in notes_hz:
        seg = _triangle(hz, 0.24, amp=0.75)
        seg = _adsr(seg, 0.01, 0.05, 0.6, 0.18)
        segs.append(seg)
    tail = _triangle(220.0, 0.5, amp=0.5)
    tail = _adsr(tail, 0.01, 0.06, 0.4, 0.43)
    return _fade(_concat(*segs, tail), 0.005, 0.06)


def gen_footstep(seed: int = 100) -> list[float]:
    """Soft thud with a brief low-frequency transient."""
    dur = 0.09
    rng = random.Random(seed)
    # randomise the fundamental slightly for variety
    freq = rng.uniform(55, 75)
    boom = _sine(freq, dur, amp=0.55)
    boom = _adsr(boom, 0.002, 0.025, 0.0, 0.063)
    noise = _noise(dur, amp=0.6, seed=seed)
    noise = _lowpass(noise, 280)
    noise = _highpass(noise, 40)
    noise = _adsr(noise, 0.002, 0.018, 0.0, 0.070)
    mixed = _mix(boom, noise)
    return _fade(mixed, 0.002, 0.01)


def gen_reload() -> list[float]:
    """Mechanical clack-click: two discrete transients."""
    # first clack — eject
    def transient(seed_v: int, freq: float, dur: float, amp: float) -> list[float]:
        n = _noise(dur, amp=amp, seed=seed_v)
        n = _highpass(n, freq)
        n = _adsr(n, 0.001, dur * 0.25, 0.0, dur * 0.74)
        return n

    clack1 = transient(50, 1200, 0.06, 0.9)
    gap1   = _silence(0.12)
    clack2 = transient(51, 900,  0.05, 0.7)   # slide
    gap2   = _silence(0.08)
    click  = transient(52, 1600, 0.04, 0.85)   # chamber click
    return _fade(_concat(clack1, gap1, clack2, gap2, click), 0.001, 0.01)


def gen_weapon_switch() -> list[float]:
    """Short metallic shink — rising high freq click."""
    dur = 0.09
    n = int(SAMPLE_RATE * dur)
    sweep = []
    for i in range(n):
        t = i / n
        freq = 400 + 3200 * t
        sweep.append(0.6 * math.sin(2 * math.pi * freq * i / SAMPLE_RATE))
    sweep = _adsr(sweep, 0.001, 0.02, 0.0, 0.069)
    noise = _noise(dur, amp=0.3, seed=60)
    noise = _highpass(noise, 1500)
    noise = _adsr(noise, 0.001, 0.015, 0.0, 0.074)
    return _fade(_mix(sweep, noise), 0.001, 0.01)


def gen_ui_click() -> list[float]:
    """Soft UI tick — short, quiet, round."""
    dur = 0.05
    tone = _sine(1200, dur, amp=0.5)
    tone = _adsr(tone, 0.001, 0.01, 0.2, 0.039)
    noise = _noise(dur, amp=0.2, seed=70)
    noise = _highpass(noise, 800)
    noise = _adsr(noise, 0.001, 0.008, 0.0, 0.041)
    return _fade(_mix(tone, noise), 0.001, 0.008)


def gen_heartbeat() -> list[float]:
    """
    Low dull thud (meant to loop).  Two-pulse cardiac shape.
    Keep start/end at zero for clean looping.
    """
    total = 0.72   # comfortable loop length at ~83 BPM
    # pulse 1 — main
    def thud(freq: float, dur: float, amp: float, seed_v: int) -> list[float]:
        sine_p = _sine(freq, dur, amp)
        noise_p = _noise(dur, amp * 0.25, seed_v)
        noise_p = _lowpass(noise_p, 120)
        mixed = _mix(sine_p, noise_p)
        return _adsr(mixed, 0.004, dur * 0.4, 0.0, dur * 0.59)

    p1 = thud(55, 0.12, 0.9, 80)
    p2 = thud(48, 0.10, 0.65, 81)   # softer second pulse

    gap12 = _silence(0.07)
    gap_rest = _silence(total - 0.12 - 0.07 - 0.10)

    raw = _concat(p1, gap12, p2, gap_rest)
    # ensure seamless loop: fade both ends to zero
    return _fade(raw, 0.005, 0.01)


def gen_water_splash() -> list[float]:
    """Entering-water splash: a bright filtered-noise burst with a quick wet decay,
    plus a low 'gloop' body so it reads as a heavy splash rather than static."""
    dur = 0.55
    # bright spray: bandpassed noise (highpass then lowpass) with fast decay
    spray = _noise(dur, amp=1.0, seed=200)
    spray = _highpass(spray, 600)
    spray = _lowpass(spray, 6000)
    spray = _adsr(spray, 0.003, 0.18, 0.12, 0.36)
    # mid body: a quick downward 'gloop'
    n = int(SAMPLE_RATE * dur)
    gloop = []
    for i in range(n):
        t = i / SAMPLE_RATE
        f = 380 * math.exp(-t * 7)
        gloop.append(0.5 * math.sin(2 * math.pi * f * i / SAMPLE_RATE))
    gloop = _adsr(gloop, 0.002, 0.10, 0.0, 0.44)
    # low sub thump on entry
    sub = _noise(dur, amp=0.5, seed=201)
    sub = _lowpass(sub, 220)
    sub = _adsr(sub, 0.002, 0.08, 0.0, 0.46)
    mixed = _mix(spray, gloop, sub)
    return _fade(mixed, 0.002, 0.05)


def gen_underwater() -> list[float]:
    """Muffled submerged ambience (loopable): low rumble + slow filtered-noise surge,
    everything lowpassed hard so it sounds like being underwater."""
    dur = 4.0
    n = int(SAMPLE_RATE * dur)
    # deep rumble at ~45 Hz with slow wobble
    rumble = []
    for i in range(n):
        t = i / SAMPLE_RATE
        mod = 0.5 * math.sin(2 * math.pi * 0.3 * t)
        f = 45 + 5 * mod
        rumble.append(0.5 * math.sin(2 * math.pi * f * i / SAMPLE_RATE))
    # slow muffled noise surge (water moving past the ears)
    surge = _noise(dur, amp=0.5, seed=210)
    surge = _lowpass(surge, 350)
    surge = _lowpass(surge, 350)   # extra pole — heavier muffle
    # very slow amplitude swell on the surge
    for i in range(n):
        t = i / SAMPLE_RATE
        surge[i] *= 0.5 + 0.5 * (0.5 + 0.5 * math.sin(2 * math.pi * 0.18 * t))
    sub = _sine(28, dur, amp=0.22)
    mixed = _mix(rumble, surge, sub)
    return _fade(mixed, 0.2, 0.2)


def gen_ambient() -> list[float]:
    """
    Quiet evolving low drone/wind bed (loopable).
    Low filtered noise + slow sine wobble — sounds like distant wind.
    """
    dur = 4.0
    n = int(SAMPLE_RATE * dur)

    # wind: lowpass noise
    wind = _noise(dur, amp=0.55, seed=90)
    wind = _lowpass(wind, 180)

    # slow wobble drone at 55 Hz with slight FM
    drone = []
    for i in range(n):
        t = i / SAMPLE_RATE
        mod = 0.5 * math.sin(2 * math.pi * 0.4 * t)   # 0.4 Hz LFO
        freq = 55 + 3 * mod
        drone.append(0.35 * math.sin(2 * math.pi * freq * i / SAMPLE_RATE))

    # sub rumble at 30 Hz, very quiet
    sub = _sine(30, dur, amp=0.18)

    mixed = _mix(wind, drone, sub)
    # seamless: long fade in/out so loop point is quiet
    return _fade(mixed, 0.15, 0.15)


def gen_music() -> list[float]:
    """
    Slow low-tension pad/pulse loop (a few seconds, loopable).
    Layered detuned fifths + rhythmic pulse.
    """
    dur = 6.0
    n = int(SAMPLE_RATE * dur)

    # bass pad — root + fifth, very detuned for width feeling
    def pad_layer(freq: float, amp: float, detune: float = 0.0) -> list[float]:
        out = []
        for i in range(n):
            t = i / SAMPLE_RATE
            # slow tremolo
            trem = 1.0 + 0.15 * math.sin(2 * math.pi * 0.25 * t)
            out.append(amp * trem * math.sin(2 * math.pi * (freq + detune) * i / SAMPLE_RATE))
        return out

    pad_root  = pad_layer(82.41, 0.30)         # E2
    pad_fifth = pad_layer(123.47, 0.20, 0.4)   # B2
    pad_oct   = pad_layer(164.81, 0.12, -0.3)  # E3

    # rhythmic noise pulse every ~1.5 s
    pulse_all = []
    for beat_t in [0.0, 1.5, 3.0, 4.5]:
        silence_before = int(beat_t * SAMPLE_RATE)
        beat_dur = 0.18
        beat_n = _noise(beat_dur, amp=0.22, seed=95)
        beat_n = _lowpass(beat_n, 200)
        beat_n = _adsr(beat_n, 0.005, 0.05, 0.0, 0.125)
        beat_full = [0.0] * silence_before + beat_n + [0.0] * max(0, n - silence_before - len(beat_n))
        pulse_all.append(beat_full[:n])

    # sum pads + pulses
    mixed = _mix(pad_root, pad_fifth, pad_oct, *pulse_all)
    return _fade(mixed, 0.25, 0.25)


def gen_glass_break() -> list[float]:
    """Window shatter: a bright high-passed noise CRACK followed by 4-6 staggered
    decaying sine 'tinkles' (falling shards). ~0.55 s total."""
    total = 0.55
    n = int(SAMPLE_RATE * total)
    # The crack: short bright noise burst, high-passed hard.
    crack = _noise(0.08, amp=1.0, seed=300)
    crack = _highpass(crack, 2500)
    crack = _adsr(crack, 0.001, 0.02, 0.2, 0.05)
    out = crack + [0.0] * (n - len(crack))
    # Shard tinkles: staggered short decaying sines at glassy frequencies.
    rng_seed = 301
    offsets = [0.05, 0.10, 0.16, 0.24, 0.31, 0.40]
    freqs = [2600.0, 3400.0, 4200.0, 5100.0, 3000.0, 5800.0]
    for k in range(len(offsets)):
        dur = 0.06 + 0.03 * ((rng_seed + k * 7) % 4)
        tink = _sine(freqs[k], dur, amp=0.35)
        tink = _adsr(tink, 0.001, dur * 0.25, 0.0, dur * 0.7)
        start = int(offsets[k] * SAMPLE_RATE)
        for i in range(len(tink)):
            if start + i < n:
                out[start + i] += tink[i]
    # Clamp + fade.
    out = [max(-1.0, min(1.0, s)) for s in out]
    return _fade(out, 0.001, 0.06)


def gen_chunk_concrete() -> list[float]:
    """Concrete crumble: a low sub THUMP + a gritty muffled rubble gurgle (double-lowpassed noise)
    + a short mid CRACK attack. The 'обвал' centerpiece — heavy + dusty. ~0.55 s."""
    total = 0.55
    n = int(SAMPLE_RATE * total)
    # Sub thump: descending 70 -> 40 Hz sine (weight under the break).
    boom = []
    for i in range(n):
        t = i / SAMPLE_RATE
        f = 70.0 * math.exp(-t * 5.0)
        boom.append(0.9 * math.sin(2 * math.pi * f * i / SAMPLE_RATE))
    boom = _adsr(boom, 0.002, 0.12, 0.2, 0.40)
    # Rubble body: noise → double single-pole lowpass for a granular, muffled scatter.
    body = _noise(total, amp=0.9, seed=310)
    body = _lowpass(body, 800)
    body = _lowpass(body, 800)
    body = _adsr(body, 0.001, 0.18, 0.25, 0.32)
    # Mid crack transient so the break has an attack edge.
    crack = _noise(0.06, amp=0.7, seed=311)
    crack = _highpass(crack, 400)
    crack = _adsr(crack, 0.001, 0.03, 0.0, 0.03)
    crack = crack + [0.0] * (n - len(crack))
    return _fade(_mix(boom, body, crack), 0.001, 0.06)


def gen_chunk_metal() -> list[float]:
    """Container clang: 3 INHARMONIC resonant partials (metallic ring) + a high-passed impact crunch
    + a small low thump for weight. ~0.45 s."""
    total = 0.45
    n = int(SAMPLE_RATE * total)
    # Inharmonic partials (not octaves → metal, not a tone).
    ring_a = _adsr(_sine(322.0, total, amp=0.5), 0.001, 0.25, 0.0, 0.24)
    ring_b = _adsr(_sine(505.0, total, amp=0.32), 0.001, 0.22, 0.0, 0.21)
    ring_c = _adsr(_sine(781.0, total, amp=0.22), 0.001, 0.20, 0.0, 0.19)
    # Impact crunch.
    crunch = _noise(0.08, amp=0.8, seed=320)
    crunch = _highpass(crunch, 900)
    crunch = _adsr(crunch, 0.001, 0.04, 0.0, 0.04)
    crunch = crunch + [0.0] * (n - len(crunch))
    # Low body thump.
    thump = _adsr(_sine(90.0, 0.14, amp=0.4), 0.001, 0.05, 0.0, 0.09)
    thump = thump + [0.0] * (n - len(thump))
    return _fade(_mix(ring_a, ring_b, ring_c, crunch, thump), 0.001, 0.05)


def gen_chunk_stone() -> list[float]:
    """Rock crack: a sharp DRY high-passed crack (brighter than concrete, little sub) + a short
    lowpassed gravel tail + a small mid thump. ~0.4 s."""
    total = 0.4
    n = int(SAMPLE_RATE * total)
    # Sharp dry crack.
    crack = _noise(0.07, amp=1.0, seed=330)
    crack = _highpass(crack, 1200)
    crack = _lowpass(crack, 5000)
    crack = _adsr(crack, 0.001, 0.025, 0.1, 0.03)
    crack = crack + [0.0] * (n - len(crack))
    # Gravel tail.
    grav = _noise(total, amp=0.5, seed=331)
    grav = _lowpass(grav, 1500)
    grav = _adsr(grav, 0.001, 0.10, 0.2, 0.22)
    # Small mid thump for body (quieter than concrete).
    thump = _adsr(_sine(120.0, 0.1, amp=0.35), 0.001, 0.04, 0.0, 0.06)
    thump = thump + [0.0] * (n - len(thump))
    return _fade(_mix(crack, grav, thump), 0.001, 0.05)


def _chord_pad(freqs: list[float], dur: float, amp: float, detune: float = 0.6) -> list[float]:
    """Detuned dual-osc pad for a chord segment, slow tremolo, lowpassed."""
    n = int(SAMPLE_RATE * dur)
    out = [0.0] * n
    for note in freqs:
        for osc, det in ((0.55, 0.0), (0.45, detune)):
            ph = 0.0
            step = 2 * math.pi * (note + det) / SAMPLE_RATE
            for i in range(n):
                t = i / SAMPLE_RATE
                trem = 1.0 + 0.12 * math.sin(2 * math.pi * 0.19 * t + note)
                out[i] += amp * osc * trem * math.sin(ph)
                ph += step
    return _lowpass(out, 900)


def gen_music_long() -> list[float]:
    """~96 s evolving dark-ambient loop: 4-chord minor progression pads + sub pulse +
    sparse inharmonic metallic hits + slow noise swells. Replaces the 6 s pad stub."""
    seg_dur = 24.0
    chords = [
        [82.41, 98.00, 123.47],   # Em (E2 G2 B2)
        [65.41, 82.41, 98.00],    # C  (C2 E2 G2)
        [55.00, 65.41, 82.41],    # Am (A1 C2 E2)
        [61.74, 73.42, 92.50],    # Bdim-ish (B1 D2 F#2)
    ]
    out: list[float] = []
    for ci, chord in enumerate(chords):
        seg = _chord_pad(chord, seg_dur, 0.30)
        # Slow bandpassed noise swell across the segment (cinematic breath).
        swell = _lowpass(_highpass(_noise(seg_dur, 0.5, seed=500 + ci), 250), 900)
        n = len(seg)
        for i in range(n):
            t = i / SAMPLE_RATE
            env = 0.5 - 0.5 * math.cos(2 * math.pi * t / seg_dur)  # rise+fall per segment
            seg[i] += swell[i] * 0.16 * env
        # Sub pulse every 2 s (soft 42 Hz thump).
        thump_len = int(0.30 * SAMPLE_RATE)
        for beat in range(int(seg_dur / 2.0)):
            start = int(beat * 2.0 * SAMPLE_RATE)
            for i in range(thump_len):
                if start + i < n:
                    tt = i / SAMPLE_RATE
                    envp = math.exp(-tt * 9.0)
                    seg[start + i] += 0.22 * envp * math.sin(2 * math.pi * 42.0 * tt)
        # Sparse metallic rings (inharmonic partials, quiet, seeded offsets).
        rng = random.Random(900 + ci)
        for _hit in range(2):
            start = int(rng.uniform(3.0, seg_dur - 4.0) * SAMPLE_RATE)
            ring_len = int(2.2 * SAMPLE_RATE)
            for i in range(ring_len):
                if start + i < n:
                    tt = i / SAMPLE_RATE
                    envr = math.exp(-tt * 2.2)
                    v = 0.055 * envr * (
                        math.sin(2 * math.pi * 317.0 * tt)
                        + 0.6 * math.sin(2 * math.pi * 503.0 * tt)
                        + 0.4 * math.sin(2 * math.pi * 787.0 * tt)
                    )
                    seg[start + i] += v
        out.extend(seg)
    # Soft-clip the mix and keep the loop seam quiet.
    out = [math.tanh(s * 0.85) for s in out]
    return _fade(out, 0.4, 0.6)


def _amb_wind(dur: float, lp: float, amp: float, seed: int, gust_hz: float = 0.07) -> list[float]:
    wind = _lowpass(_noise(dur, amp, seed=seed), lp)
    n = len(wind)
    for i in range(n):
        t = i / SAMPLE_RATE
        wind[i] *= 0.6 + 0.4 * (0.5 + 0.5 * math.sin(2 * math.pi * gust_hz * t + seed))
    return wind


def gen_amb_urban() -> list[float]:
    """Urban ruins: low wind + faint machine hum + a distant groan once per loop."""
    dur = 28.0
    wind = _amb_wind(dur, 200, 0.55, seed=1100)
    n = len(wind)
    for i in range(n):
        t = i / SAMPLE_RATE
        hum = 0.05 * math.sin(2 * math.pi * 55.0 * t) + 0.03 * math.sin(2 * math.pi * 110.3 * t)
        wind[i] += hum * (0.7 + 0.3 * math.sin(2 * math.pi * 0.05 * t))
    groan = _lowpass(_noise(2.5, 0.35, seed=1101), 300)
    groan = _adsr(groan, 0.8, 0.6, 0.4, 1.0)
    start = int(14.0 * SAMPLE_RATE)
    for i in range(len(groan)):
        if start + i < n:
            wind[start + i] += groan[i] * 0.4
    return _fade(wind, 0.3, 0.3)


def gen_amb_snow() -> list[float]:
    """Alpine: whistling airy wind — band-swept noise, no hum, cold gusts."""
    dur = 28.0
    base = _amb_wind(dur, 500, 0.5, seed=1200, gust_hz=0.11)
    whistle = _highpass(_lowpass(_noise(dur, 0.30, seed=1201), 1100), 350)
    n = len(base)
    for i in range(n):
        t = i / SAMPLE_RATE
        base[i] += whistle[i] * (0.35 + 0.35 * math.sin(2 * math.pi * 0.09 * t + 1.0))
    return _fade(base, 0.3, 0.3)


def gen_amb_desert() -> list[float]:
    """Desert: dry mid wind + thin grit shimmer + slow deep swells."""
    dur = 28.0
    base = _amb_wind(dur, 420, 0.5, seed=1300, gust_hz=0.05)
    grit = _highpass(_noise(dur, 0.12, seed=1301), 2400)
    sub = _lowpass(_noise(dur, 0.4, seed=1302), 90)
    n = len(base)
    for i in range(n):
        t = i / SAMPLE_RATE
        base[i] += grit[i] * (0.5 + 0.5 * math.sin(2 * math.pi * 0.23 * t))
        base[i] += sub[i] * (0.4 + 0.6 * (0.5 + 0.5 * math.sin(2 * math.pi * 0.03 * t)))
    return _fade(base, 0.3, 0.3)


def gen_amb_rain() -> list[float]:
    """Rain biome: steady patter (banded noise flutter) + low rumble + a soft far thunder."""
    dur = 28.0
    patter = _highpass(_lowpass(_noise(dur, 0.6, seed=1400), 6500), 1400)
    n = len(patter)
    flutter = random.Random(1401)
    amp = 0.8
    for i in range(n):
        if i % 441 == 0:  # ~10 ms grains — rain density flicker
            amp = 0.65 + flutter.random() * 0.5
        patter[i] *= amp
    rumble = _lowpass(_noise(dur, 0.35, seed=1402), 120)
    thunder = _lowpass(_noise(4.0, 0.6, seed=1403), 160)
    thunder = _adsr(thunder, 1.2, 1.0, 0.35, 1.6)
    start = int(17.0 * SAMPLE_RATE)
    for i in range(n):
        patter[i] = patter[i] * 0.55 + rumble[i] * 0.5
    for i in range(len(thunder)):
        if start + i < n:
            patter[start + i] += thunder[i] * 0.5
    return _fade(patter, 0.3, 0.3)


def gen_robot_alert() -> list[float]:
    """Machine spotted you: two rising FM chirps + a click. Stealth-relevant cue."""
    def chirp(f0: float, f1: float, dur: float, amp: float) -> list[float]:
        n = int(SAMPLE_RATE * dur)
        out = []
        ph = 0.0
        for i in range(n):
            t = i / n
            f = f0 + (f1 - f0) * t
            ph += 2 * math.pi * f / SAMPLE_RATE
            v = math.sin(ph) + 0.35 * math.sin(2 * ph)  # square-ish edge
            out.append(amp * v)
        return _adsr(out, 0.004, dur * 0.2, 0.6, dur * 0.4)

    click = _adsr(_highpass(_noise(0.03, 0.8, seed=1500), 1800), 0.001, 0.01, 0.0, 0.019)
    gap = _silence(0.05)
    c1 = chirp(620.0, 1150.0, 0.16, 0.7)
    c2 = chirp(780.0, 1500.0, 0.20, 0.75)
    return _fade(_concat(click, c1, gap, c2), 0.002, 0.03)


def gen_robot_death() -> list[float]:
    """Power-down: descending quantized sweep + spark crackle (layered under the boom)."""
    dur = 0.85
    n = int(SAMPLE_RATE * dur)
    sweep = []
    ph = 0.0
    for i in range(n):
        t = i / n
        f = 880.0 * math.exp(-t * 3.2) + 55.0
        f = round(f / 40.0) * 40.0  # coarse steps → glitchy power-down
        ph += 2 * math.pi * f / SAMPLE_RATE
        sweep.append(0.6 * math.sin(ph) * (1.0 - t * 0.6))
    sweep = _adsr(sweep, 0.004, 0.1, 0.7, 0.35)
    crackle = _highpass(_noise(dur, 0.4, seed=1600), 2200)
    rng = random.Random(1601)
    gate = 0.0
    for i in range(n):
        if i % 220 == 0:
            gate = 1.0 if rng.random() < 0.35 else 0.15
        crackle[i] *= gate * (1.0 - i / n)
    return _fade(_mix(sweep, crackle), 0.002, 0.06)


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def gen_music_combat() -> list[float]:
    """COMBAT overlay stem (M1 music layers): 24 s percussive dark loop — kick
    pulse + metallic hats + a tense low drone. Faded IN over the calm bed while
    machines are actively fighting the player; loops seamlessly."""
    dur = 24.0
    n = int(SAMPLE_RATE * dur)
    bpm = 132.0
    beat = 60.0 / bpm

    out = [0.0] * n

    def add(samples: list[float], at_s: float, gain: float = 1.0) -> None:
        start = int(at_s * SAMPLE_RATE)
        for j, v in enumerate(samples):
            k = start + j
            if 0 <= k < n:
                out[k] += v * gain

    # Kick: pitch-dropping sine thump every beat.
    kick = []
    kn = int(SAMPLE_RATE * 0.16)
    ph = 0.0
    for i in range(kn):
        t = i / kn
        f = 120.0 - 75.0 * t
        ph += 2 * math.pi * f / SAMPLE_RATE
        kick.append(0.9 * math.sin(ph) * (1.0 - t) ** 1.5)
    # Metallic hat: short highpassed noise tick.
    hat = _adsr(_highpass(_noise(0.05, 0.5, seed=3100), 4000), 0.001, 0.02, 0.2, 0.028)
    total_beats = int(dur / beat)
    for b in range(total_beats):
        t0 = b * beat
        add(kick, t0, 1.0 if b % 4 != 3 else 0.7)
        add(hat, t0 + beat * 0.5, 0.5)
        if b % 8 in (2, 6):
            add(hat, t0 + beat * 0.75, 0.35)
    # Tense drone: slow-beating detuned low pair, present the whole loop.
    drone_a = _sine(55.0, dur, 0.16)
    drone_b = _sine(55.9, dur, 0.14)
    drone = _lowpass(_mix(drone_a, drone_b), 300)
    for i in range(n):
        out[i] += drone[i]
    # Gentle loop-safe fade only at the extreme edges (kept tiny for looping).
    return _fade([math.tanh(s * 0.9) for s in out], 0.01, 0.01)


def gen_music_tension() -> list[float]:
    """TENSION stem (v0.5-B3 music layers): ~36 s sparse unease between calm and combat —
    a slow sub heartbeat, a barely-there detuned shimmer, sparse metallic pings and a
    breathing air swell. Faded IN while machines SEARCH near the player; loops seamlessly."""
    dur = 36.0
    n = int(SAMPLE_RATE * dur)
    out = [0.0] * n

    def add(samples: list[float], at_s: float, gain: float = 1.0) -> None:
        start = int(at_s * SAMPLE_RATE)
        for j, v in enumerate(samples):
            k = start + j
            if 0 <= k < n:
                out[k] += v * gain

    # Slow sub heartbeat: a soft pitch-dropping thump pair every 2.4 s.
    thump = []
    tn = int(SAMPLE_RATE * 0.22)
    ph = 0.0
    for i in range(tn):
        t = i / tn
        f = 52.0 - 18.0 * t
        ph += 2 * math.pi * f / SAMPLE_RATE
        thump.append(0.5 * math.sin(ph) * (1.0 - t) ** 2)
    beat_period = 2.4
    for b in range(int(dur / beat_period)):
        t0 = b * beat_period
        add(thump, t0, 0.9)
        add(thump, t0 + 0.34, 0.55)
    # Detuned high shimmer with a slow breathing LFO (very quiet — unease, not melody).
    shimmer_a = _sine(659.3, dur, 0.022)
    shimmer_b = _sine(663.1, dur, 0.020)
    for i in range(n):
        lfo = 0.5 + 0.5 * math.sin(2 * math.pi * i / SAMPLE_RATE / 9.0)
        out[i] += (shimmer_a[i] + shimmer_b[i]) * lfo
    # Sparse metallic pings on an irregular (but loop-stable) grid.
    ping = _adsr(_highpass(_noise(0.5, 0.30, seed=4200), 2600), 0.002, 0.1, 0.25, 0.4)
    for t0 in (3.1, 8.7, 13.4, 19.9, 26.2, 31.8):
        add(ping, t0, 0.8)
    # Breathing air bed: lowpassed noise with an 18 s swell cycle.
    air = _lowpass(_noise(dur, 0.10, seed=4300), 500)
    for i in range(n):
        swell = 0.35 + 0.65 * (0.5 + 0.5 * math.sin(2 * math.pi * i / SAMPLE_RATE / 18.0))
        out[i] += air[i] * swell
    return _fade([math.tanh(s) for s in out], 0.02, 0.02)


def gen_music_boss() -> list[float]:
    """BOSS stem (v0.5-B3 music layers): ~24 s heavy industrial assault — driving kick,
    a two-note low riff, dense metallic hats, a dissonant alarm stab and a constant sub.
    REPLACES the combat stem while a live boss is near; loops seamlessly."""
    dur = 24.0
    n = int(SAMPLE_RATE * dur)
    bpm = 140.0
    beat = 60.0 / bpm
    out = [0.0] * n

    def add(samples: list[float], at_s: float, gain: float = 1.0) -> None:
        start = int(at_s * SAMPLE_RATE)
        for j, v in enumerate(samples):
            k = start + j
            if 0 <= k < n:
                out[k] += v * gain

    # Hard kick: deeper + punchier than the combat stem's.
    kick = []
    kn = int(SAMPLE_RATE * 0.18)
    ph = 0.0
    for i in range(kn):
        t = i / kn
        f = 135.0 - 90.0 * t
        ph += 2 * math.pi * f / SAMPLE_RATE
        kick.append(1.0 * math.sin(ph) * (1.0 - t) ** 1.4)
    hat = _adsr(_highpass(_noise(0.04, 0.55, seed=5100), 5000), 0.001, 0.015, 0.2, 0.022)
    # Low riff note: buzzy stacked-harmonic pulse (saw-ish), lowpassed.
    def riff_note(freq: float, note_dur: float) -> list[float]:
        m = int(SAMPLE_RATE * note_dur)
        buf = []
        phase = 0.0
        for i in range(m):
            phase += 2 * math.pi * freq / SAMPLE_RATE
            v = (
                math.sin(phase)
                + 0.5 * math.sin(2 * phase)
                + 0.33 * math.sin(3 * phase)
                + 0.25 * math.sin(4 * phase)
            )
            buf.append(0.30 * v)
        return _adsr(_lowpass(buf, 700), 0.004, 0.05, 0.75, 0.08)

    riff_a = riff_note(55.0, beat * 0.45)  # A1
    riff_c = riff_note(65.4, beat * 0.45)  # C2
    total_beats = int(dur / beat)
    for b in range(total_beats):
        t0 = b * beat
        add(kick, t0, 1.0)
        if b % 4 == 3:
            add(kick, t0 + beat * 0.5, 0.8)  # driving double on the bar end
        add(hat, t0 + beat * 0.5, 0.5)
        if b % 2 == 1:
            add(hat, t0 + beat * 0.25, 0.3)
            add(hat, t0 + beat * 0.75, 0.35)
        # Two-note riff: A1 pumping eighths, C2 lift on the last bar of each 4.
        note = riff_c if (b % 16) >= 12 else riff_a
        add(note, t0, 1.0)
        add(note, t0 + beat * 0.5, 0.75)
    # Dissonant alarm stab every 4 bars (392+415 Hz — a minor-second scream).
    stab_n = int(SAMPLE_RATE * 0.5)
    stab = []
    ph_a = 0.0
    ph_b = 0.0
    for i in range(stab_n):
        t = i / stab_n
        ph_a += 2 * math.pi * 392.0 / SAMPLE_RATE
        ph_b += 2 * math.pi * 415.3 / SAMPLE_RATE
        stab.append(0.16 * (math.sin(ph_a) + math.sin(ph_b)) * (1.0 - t))
    for bar4 in range(int(total_beats / 16)):
        add(stab, bar4 * 16 * beat + 8 * beat, 1.0)
    # Constant sub dread.
    sub = _lowpass(_sine(41.2, dur, 0.14), 120)
    for i in range(n):
        out[i] += sub[i]
    return _fade([math.tanh(s * 0.85) for s in out], 0.01, 0.01)


def gen_skill_cast() -> list[float]:
    """Generic ability cast: a bright two-tone energy chirp (dash/blink/shield…)."""

    def chirp(f0: float, f1: float, dur: float, amp: float) -> list[float]:
        n = int(SAMPLE_RATE * dur)
        out = []
        ph = 0.0
        for i in range(n):
            t = i / n
            f = f0 + (f1 - f0) * t
            ph += 2 * math.pi * f / SAMPLE_RATE
            out.append(amp * (math.sin(ph) + 0.25 * math.sin(2 * ph)))
        return _adsr(out, 0.004, 0.03, 0.7, dur * 0.5)

    return _fade(_concat(chirp(520, 980, 0.1, 0.7), chirp(760, 1400, 0.12, 0.6)), 0.002, 0.04)


def gen_skill_meteor() -> list[float]:
    """Meteor call: a falling WHISTLE (1500→240 Hz) over a growing low rumble —
    the impact itself reuses the existing explosion sample."""
    dur = 0.9
    n = int(SAMPLE_RATE * dur)
    whistle = []
    ph = 0.0
    for i in range(n):
        t = i / n
        f = 1500.0 - 1260.0 * t
        ph += 2 * math.pi * f / SAMPLE_RATE
        whistle.append(0.55 * math.sin(ph) * (0.4 + 0.6 * t))
    rumble = _lowpass(_noise(dur, 0.8, seed=2100), 160)
    rumble = [v * (i / n) for i, v in enumerate(rumble)]
    return _fade(_mix(_adsr(whistle, 0.05, 0.1, 0.9, 0.2), rumble), 0.004, 0.05)


def gen_skill_storm() -> list[float]:
    """Storm field: 4 s of swirling wind with an icy shimmer tremolo."""
    dur = 4.2
    n = int(SAMPLE_RATE * dur)
    wind = _lowpass(_noise(dur, 0.85, seed=2200), 900)
    out = []
    for i, v in enumerate(wind):
        t = i / n
        trem = 0.55 + 0.45 * math.sin(2 * math.pi * 5.2 * t * dur)
        out.append(v * trem * (0.35 + 0.65 * math.sin(math.pi * t)))
    shimmer = []
    ph = 0.0
    for i in range(n):
        t = i / n
        f = 1800.0 + 700.0 * math.sin(2 * math.pi * 0.8 * t * dur)
        ph += 2 * math.pi * f / SAMPLE_RATE
        shimmer.append(0.12 * math.sin(ph) * (0.5 + 0.5 * math.sin(2 * math.pi * 3.0 * t * dur)))
    return _fade(_mix(out, shimmer), 0.05, 0.4)


def gen_skill_leap() -> list[float]:
    """Leap take-off: an upward whoosh (rising band of noise + sine sweep)."""
    dur = 0.35
    n = int(SAMPLE_RATE * dur)
    woosh = _highpass(_noise(dur, 0.7, seed=2300), 500)
    woosh = [v * (i / n) for i, v in enumerate(woosh)]
    sweep = []
    ph = 0.0
    for i in range(n):
        t = i / n
        f = 240.0 + 640.0 * t
        ph += 2 * math.pi * f / SAMPLE_RATE
        sweep.append(0.4 * math.sin(ph) * t)
    return _fade(_mix(woosh, sweep), 0.004, 0.06)


def gen_skill_slam() -> list[float]:
    """Slam landing: a deep body thud + dirt burst."""
    dur = 0.45
    thud = []
    ph = 0.0
    n = int(SAMPLE_RATE * dur)
    for i in range(n):
        t = i / n
        f = 82.0 - 40.0 * t
        ph += 2 * math.pi * f / SAMPLE_RATE
        thud.append(0.95 * math.sin(ph) * (1.0 - t) ** 1.6)
    dirt = _lowpass(_noise(0.22, 0.7, seed=2400), 700)
    dirt = _adsr(dirt, 0.002, 0.05, 0.4, 0.15)
    return _fade(_mix(thud, dirt + _silence(dur - 0.22)), 0.002, 0.08)


def gen_skill_breach() -> list[float]:
    """Breach charge: a mean descending roar with metallic grit."""
    dur = 0.55
    n = int(SAMPLE_RATE * dur)
    roar = []
    ph = 0.0
    for i in range(n):
        t = i / n
        f = 220.0 - 130.0 * t
        ph += 2 * math.pi * f / SAMPLE_RATE
        v = math.sin(ph) + 0.45 * math.sin(2 * ph) + 0.2 * math.sin(3 * ph)
        roar.append(0.6 * v * (1.0 - t * 0.5))
    grit = _highpass(_noise(dur, 0.35, seed=2500), 1400)
    grit = [v * (1.0 - i / n) for i, v in enumerate(grit)]
    return _fade(_mix(_adsr(roar, 0.01, 0.08, 0.8, 0.2), grit), 0.003, 0.08)


def gen_skill_zap() -> list[float]:
    """Chain shock: electric crackle + two descending zap blips."""
    dur = 0.35
    n = int(SAMPLE_RATE * dur)
    crackle = _highpass(_noise(dur, 0.6, seed=2600), 2400)
    rng = random.Random(2601)
    gate = 0.0
    for i in range(n):
        if i % 180 == 0:
            gate = 1.0 if rng.random() < 0.4 else 0.1
        crackle[i] *= gate * (1.0 - i / n)

    def blip(f0: float, f1: float, dur_b: float, amp: float) -> list[float]:
        nb = int(SAMPLE_RATE * dur_b)
        out = []
        ph = 0.0
        for i in range(nb):
            t = i / nb
            f = f0 + (f1 - f0) * t
            ph += 2 * math.pi * f / SAMPLE_RATE
            out.append(amp * math.sin(ph))
        return _adsr(out, 0.002, 0.02, 0.5, dur_b * 0.4)

    blips = _concat(blip(1600, 700, 0.09, 0.55), _silence(0.05), blip(1300, 500, 0.09, 0.45))
    return _fade(_mix(crackle, blips + _silence(max(0.0, dur - 0.23))), 0.002, 0.05)


def main() -> None:
    os.makedirs(OUT_DIR, exist_ok=True)
    print(f"Output dir: {os.path.abspath(OUT_DIR)}\n")

    jobs = [
        # existing ids — replace .ogg refs with .wav so AudioManager owns everything
        ("shot.wav",           gen_shot),
        ("hit.wav",            gen_hit),
        ("explosion.wav",      gen_explosion),
        ("player_death.wav",   gen_player_death),
        ("extract_beep.wav",   gen_extract_beep),
        ("extract_done.wav",   gen_extract_done),
        ("extract_cancel.wav", gen_extract_cancel),
        ("wave_alert.wav",     gen_wave_alert),
        ("win.wav",            gen_win),
        ("lose.wav",           gen_lose),
        # new ids
        ("footstep1.wav",      lambda: gen_footstep(100)),
        ("footstep2.wav",      lambda: gen_footstep(101)),
        ("footstep3.wav",      lambda: gen_footstep(102)),
        ("reload.wav",         gen_reload),
        ("weapon_switch.wav",  gen_weapon_switch),
        ("ui_click.wav",       gen_ui_click),
        ("heartbeat.wav",      gen_heartbeat),
        ("ambient.wav",        gen_ambient),
        ("music.wav",          gen_music),
        # Water immersion (Lane B)
        ("water_splash.wav",   gen_water_splash),
        ("underwater.wav",     gen_underwater),
        # Breakable windows
        ("glass_break.wav",    gen_glass_break),
        # Material-typed building/rock collapse (Destruction 2.1)
        ("chunk_concrete.wav", gen_chunk_concrete),
        ("chunk_metal.wav",    gen_chunk_metal),
        ("chunk_stone.wav",    gen_chunk_stone),
        # Production audio pass (2026-08): long evolving music, biome ambient beds,
        # robot vocalizations (alert = stealth info, death = power-down).
        ("music_long.wav",     gen_music_long),
        ("amb_urban.wav",      gen_amb_urban),
        ("amb_snow.wav",       gen_amb_snow),
        ("amb_desert.wav",     gen_amb_desert),
        ("amb_rain.wav",       gen_amb_rain),
        ("robot_alert.wav",    gen_robot_alert),
        ("robot_death.wav",    gen_robot_death),
        # M1 music layers: combat overlay stem (converted to .ogg for the loop).
        ("music_combat.wav",   gen_music_combat),
        # v0.5-B3 music layers: tension + boss stems (converted to .ogg, WAVs deleted).
        ("music_tension.wav",  gen_music_tension),
        ("music_boss.wav",     gen_music_boss),
        # MOBA skill rework (v0.4.5): per-ability cast/impact sounds.
        ("skill_cast.wav",     gen_skill_cast),
        ("skill_meteor.wav",   gen_skill_meteor),
        ("skill_storm.wav",    gen_skill_storm),
        ("skill_leap.wav",     gen_skill_leap),
        ("skill_slam.wav",     gen_skill_slam),
        ("skill_breach.wav",   gen_skill_breach),
        ("skill_zap.wav",      gen_skill_zap),
    ]

    # Optional CLI filter: `python gen_audio.py music_long amb_rain` regenerates only
    # the named jobs (base name, no extension) instead of all 32.
    wanted = {a.lower() for a in sys.argv[1:]}
    if wanted:
        jobs = [j for j in jobs if j[0].rsplit(".", 1)[0].lower() in wanted]

    generated = 0
    for filename, fn in jobs:
        samples = fn()
        _write_wav(filename, samples)
        generated += 1

    print(f"\nDone — {generated} WAV files written to {os.path.abspath(OUT_DIR)}")


if __name__ == "__main__":
    main()
