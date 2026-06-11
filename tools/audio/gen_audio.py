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


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

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
    ]

    generated = 0
    for filename, fn in jobs:
        samples = fn()
        _write_wav(filename, samples)
        generated += 1

    print(f"\nDone — {generated} WAV files written to {os.path.abspath(OUT_DIR)}")


if __name__ == "__main__":
    main()
