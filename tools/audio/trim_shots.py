#!/usr/bin/env python3
"""Isolate a SINGLE gunshot from each downloaded firearm recording.

The OpenGameArt "Gunshot Sounds" files are long takes containing several shots
(rifle ~15s, pistol ~7s). A one-shot SFX must be just ONE crack, so this finds the
first transient, cuts a short window around it, fades the tail, and overwrites the
file in place. Stdlib only (wave/struct). Run after fetch_real_audio.ps1 copies them.
"""
import wave, struct, glob, os

# Per-file window length (seconds) after the onset — enough for the crack + a little tail.
WINDOW = {
    "shot_pistol.wav":  0.45,
    "shot_smg.wav":     0.40,
    "shot_rifle.wav":   0.50,
    "shot_dmr.wav":     0.70,   # bolt-action boom has a longer tail
    "shot_shotgun.wav": 0.70,   # already a single ~0.7s shot — keep, just refade
}
PRE_ROLL = 0.012   # seconds of lead-in before the onset
AUDIO_DIR = os.path.join(os.path.dirname(__file__), "..", "..", "assets", "audio")


def trim(path: str) -> None:
    name = os.path.basename(path)
    w = wave.open(path, "rb")
    fr, n, ch, sw = w.getframerate(), w.getnframes(), w.getnchannels(), w.getsampwidth()
    raw = w.readframes(n)
    w.close()
    if sw != 2:
        print(f"  skip {name}: sample width {sw} unsupported")
        return
    samples = struct.unpack("<%dh" % (len(raw) // 2), raw)
    # Per-frame peak amplitude across channels.
    peak = 1
    frames = len(samples) // ch
    amp = [0] * frames
    for i in range(frames):
        m = 0
        for c in range(ch):
            v = abs(samples[i * ch + c])
            if v > m:
                m = v
        amp[i] = m
        if m > peak:
            peak = m
    # First sample exceeding 30% of the file peak = onset of shot #1.
    thresh = int(peak * 0.30)
    onset = next((i for i in range(frames) if amp[i] >= thresh), 0)
    start = max(0, onset - int(PRE_ROLL * fr))
    win = WINDOW.get(name, 0.5)
    end = min(frames, start + int(win * fr))
    cut = list(samples[start * ch:end * ch])
    # Fade the last 35% to silence so the truncated tail has no click.
    out_frames = (end - start)
    fade = int(out_frames * 0.35)
    for i in range(fade):
        g = 1.0 - (i / max(1, fade))
        idx = out_frames - fade + i
        for c in range(ch):
            cut[idx * ch + c] = int(cut[idx * ch + c] * g)
    # 2 ms fade-in to kill any pre-onset click.
    fi = int(0.002 * fr)
    for i in range(min(fi, out_frames)):
        g = i / max(1, fi)
        for c in range(ch):
            cut[i * ch + c] = int(cut[i * ch + c] * g)
    out = wave.open(path, "wb")
    out.setnchannels(ch)
    out.setsampwidth(sw)
    out.setframerate(fr)
    out.writeframes(struct.pack("<%dh" % len(cut), *cut))
    out.close()
    print(f"  {name}: onset {onset/fr:.2f}s -> {out_frames/fr:.2f}s single shot")


def main() -> None:
    for path in sorted(glob.glob(os.path.join(AUDIO_DIR, "shot_*.wav"))):
        trim(path)


if __name__ == "__main__":
    main()
