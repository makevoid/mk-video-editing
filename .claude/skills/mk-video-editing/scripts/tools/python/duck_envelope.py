#!/usr/bin/env python3
"""Music ducking gain envelope from a voice key (narration + dialogue).

usage: duck_envelope.py key.wav out.wav length_s depth_db threshold_db attack release hold lookahead bridge
  key.wav    mono 16-bit voice key (everything the music should sit under)
  out.wav    mono 16-bit gain envelope at the key's rate, length_s long (gain 1 past the key's end)
  depth_db   gain while voice is active (e.g. -12): an exact dip, independent of how loud the voice is
  threshold_db  10 ms RMS above this counts as voice (relative to full scale)
  attack     seconds to ramp down; lookahead starts the ramp before the first word so the onset is already ducked
  release    seconds to ramp back up after the hold
  hold       seconds to stay ducked after voice ends
  bridge     voice gaps shorter than this stay ducked (no pumping between words or turns)
prints JSON: {spans: [[s, e]], ducked_s, depth_db, length_s}
"""
import json
import sys
import wave

import numpy as np

HOP = 0.01


def read_mono(path):
    with wave.open(path, "rb") as w:
        rate = w.getframerate()
        if w.getsampwidth() != 2:
            raise ValueError("duck_envelope requires 16-bit PCM WAV")
        data = np.frombuffer(w.readframes(w.getnframes()), dtype=np.int16).astype(np.float32)
        data = data.reshape(-1, w.getnchannels()).mean(axis=1) / 32768.0
    return data, rate


def voice_spans(active, bridge):
    spans, start = [], None
    for i, on in enumerate(active):
        if on and start is None:
            start = i
        elif not on and start is not None:
            spans.append([start * HOP, i * HOP])
            start = None
    if start is not None:
        spans.append([start * HOP, len(active) * HOP])
    merged = []
    for s, e in spans:
        if merged and s - merged[-1][1] < bridge:
            merged[-1][1] = e
        else:
            merged.append([s, e])
    return [sp for sp in merged if sp[1] - sp[0] >= 0.12]  # drop clicks and breaths


def main():
    key, out = sys.argv[1], sys.argv[2]
    length, depth, threshold, attack, release, hold, lookahead, bridge = map(float, sys.argv[3:11])
    data, rate = read_mono(key)
    hop = int(rate * HOP)
    frames = max(len(data) // hop, 1)
    rms = np.sqrt(np.mean(data[: frames * hop].reshape(frames, hop) ** 2, axis=1) + 1e-12)
    spans = voice_spans(20 * np.log10(rms) > threshold, bridge)

    n = int(round(length / HOP)) + 1
    t = np.arange(n) * HOP
    target = np.zeros(n)
    for s, e in spans:
        target[(t >= s - lookahead) & (t < e + hold)] = depth
    # Slew-limit in dB: down at depth/attack, up at depth/release (linear-in-dB ramps sound even).
    down, up = abs(depth) * HOP / max(attack, HOP), abs(depth) * HOP / max(release, HOP)
    gain_db = np.zeros(n)
    g = 0.0
    for i in range(n):
        g = max(target[i], g - down) if target[i] < g else min(target[i], g + up)
        gain_db[i] = g
    samples = int(round(length * rate))
    env = np.interp(np.arange(samples) / rate, t, 10 ** (gain_db / 20))
    with wave.open(out, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(rate)
        w.writeframes((np.clip(env, 0, 1) * 32767).astype(np.int16).tobytes())
    print(json.dumps({"spans": [[round(s, 2), round(e, 2)] for s, e in spans], "ducked_s": round(float((gain_db < -1).sum() * HOP), 2),
                      "depth_db": depth, "length_s": round(length, 3)}))


if __name__ == "__main__":
    main()
