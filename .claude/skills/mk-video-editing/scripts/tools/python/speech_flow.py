"""Speech flow analysis: fillers, hums, repeats, possible false starts and unnatural pauses, with proposed cuts.

usage: speech_flow.py transcript.json audio.wav out.json

The transcript is mlx-whisper chunk JSON (ideally VERBATIM=1 so fillers are written). Whisper word times are rough
(a word often absorbs the pause next to it), so pauses are measured acoustically: speech = frames above an adaptive
energy threshold that are voiced or next to voiced frames (breaths, clicks and applause are not speech). Words are
placed on the timeline by the centroid of the speech frames inside their span.

`speech_runs` lists every speech interval [t0, t1] (10 ms resolution): cut points belong in the gaps between them;
`energy.db` (10 ms hop) lets a cut boundary inside connected speech snap to the quietest point between two words.
Each candidate carries `cut` [t0, t1] (source seconds to remove) and `context`. A pause cut keeps `target` seconds of
the original silence, half on each side, so the cut lands in room tone. Prints a JSON summary; writes out.json and a
readable out.txt (phrases with pause lengths and markers).
"""
import json
import os
import re
import sys

import numpy as np
import soundfile as sf

HOP = 0.01
FILLER = re.compile(r"^(u+[hm]+|e+r+m*|a+h+|h+m+|m+h*m+)$")
FUNCTION_END = {"to", "be", "the", "a", "an", "of", "in", "and", "but", "so", "that", "we", "i", "is", "are", "have",
                "can", "order", "for", "with", "this", "it", "you", "will", "my", "our", "on", "at", "from"}
# Pause targets (seconds of silence kept) and the lengths above which a pause reads as unnatural.
SENTENCE_MAX, SENTENCE_TARGET = 1.0, 0.6
COMMA_MAX, COMMA_TARGET = 0.7, 0.35
PHRASE_MAX, PHRASE_TARGET = 0.45, 0.2


def norm(w):
    return re.sub(r"[^a-z0-9']", "", w.lower())


def frames(audio, sr):
    hop, win = int(sr * HOP), int(sr * 0.03)
    n = max(1, (len(audio) - win) // hop + 1)
    idx = np.arange(win)[None, :] + hop * np.arange(n)[:, None]
    seg = audio[idx]
    rms = np.sqrt((seg ** 2).mean(1) + 1e-12)
    db = 20 * np.log10(rms + 1e-9)
    # Voicing: normalized autocorrelation peak in the 75-400 Hz pitch range over a 40 ms window.
    w4 = int(sr * 0.04)
    idx4 = np.clip(np.arange(w4)[None, :] + hop * np.arange(n)[:, None], 0, len(audio) - 1)
    s4 = audio[idx4] - audio[idx4].mean(1, keepdims=True)
    spec = np.fft.rfft(s4, 2 * w4)
    ac = np.fft.irfft(np.abs(spec) ** 2)[:, :w4]
    lo, hi = int(sr / 400), int(sr / 75)
    peak = ac[:, lo:hi].max(1) / (ac[:, 0] + 1e-12)
    f0 = sr / (lo + ac[:, lo:hi].argmax(1))
    return db, peak, f0


def runs(mask):
    """[start, end) index runs where mask is True."""
    d = np.diff(np.concatenate([[0], mask.astype(int), [0]]))
    return list(zip(np.where(d == 1)[0], np.where(d == -1)[0]))


def main():
    tpath, apath, out = sys.argv[1:4]
    chunks = json.load(open(tpath))["chunks"]
    audio, sr = sf.read(apath, always_2d=True)
    audio = audio.mean(1).astype(np.float64)
    db, peak, f0 = frames(audio, sr)
    floor, p90 = np.percentile(db, 10), np.percentile(db, 90)
    thr = floor + max(8.0, 0.35 * (p90 - floor))
    voiced = (peak > 0.45) & (db > thr)
    near = np.convolve(voiced.astype(float), np.ones(17), "same") > 0  # +-80 ms around voiced frames
    speech = (db > thr) & near
    # Close gaps under 80 ms (stops inside words) and drop blips under 60 ms.
    for a, b in runs(~speech):
        if b - a < 8 and a > 0:
            speech[a:b] = True
    for a, b in runs(speech):
        if b - a < 6:
            speech[a:b] = False
    t = lambda i: round(i * HOP, 3)

    words = []
    for c in chunks:
        s, e = c["timestamp"][0], c["timestamp"][1] if c["timestamp"][1] is not None else c["timestamp"][0] + 0.3
        i0, i1 = int(s / HOP), max(int(s / HOP) + 1, int(e / HOP))
        act = np.where(speech[i0:i1])[0]
        center = (i0 + act.mean()) * HOP if len(act) else (s + e) / 2
        rs, re_ = ((i0 + act[0]) * HOP, (i0 + act[-1] + 1) * HOP) if len(act) else (s, e)
        words.append({"text": c["text"], "n": norm(c["text"]), "start": s, "end": e, "center": center,
                      "speech": [round(rs, 3), round(re_, 3)]})

    def before(x):
        return [w for w in words if w["center"] < x]

    def after(x):
        return [w for w in words if w["center"] >= x]

    def context(a, b, k=5):
        pre, post = before(a)[-k:], after(b)[:k]
        return " ".join(w["text"] for w in pre) + " ‖ " + " ".join(w["text"] for w in post)

    first_speech = words[0]["speech"][0] if words else 0
    last_speech = words[-1]["speech"][1] if words else 0
    pauses = []
    for a, b in runs(~speech):
        ta, tb = a * HOP, b * HOP
        if tb - ta < 0.25 or ta < first_speech or tb > last_speech:
            continue
        pre = before((ta + tb) / 2)
        last = pre[-1]["text"] if pre else ""
        if re.search(r"[.?!]$", last):
            kind, mx, target = "sentence", SENTENCE_MAX, SENTENCE_TARGET
        elif last.endswith(",") or last.endswith(";"):
            kind, mx, target = "comma", COMMA_MAX, COMMA_TARGET
        else:
            kind, mx, target = "phrase", PHRASE_MAX, PHRASE_TARGET
        p = {"t0": t(a), "t1": t(b), "dur": round(tb - ta, 3), "kind": kind, "context": context(ta, tb)}
        if tb - ta > mx:
            p["unnatural"] = True
            p["target"] = target
            p["cut"] = [round(ta + target / 2, 3), round(tb - target / 2, 3)]
        pauses.append(p)

    def surrounding_pause(s, e):
        """Silence run touching a span on each side (seconds), to remove filler + hesitation together."""
        pre = next((p for p in reversed(pauses) if p["t1"] <= s + 0.05), None)
        post = next((p for p in pauses if p["t0"] >= e - 0.05), None)
        return (pre if pre and s - pre["t1"] < 0.15 else None), (post if post and post["t0"] - e < 0.15 else None)

    fillers = []
    for w in words:
        if FILLER.match(w["n"]):
            s, e = w["speech"]
            pre, post = surrounding_pause(s, e)
            a = pre["t0"] + PHRASE_TARGET / 2 if pre else s - 0.02
            b = post["t1"] - PHRASE_TARGET / 2 if post else e + 0.02
            fillers.append({"word": w["text"], "t0": round(s, 3), "t1": round(e, 3), "cut": [round(a, 3), round(b, 3)],
                            "context": context(s, e)})
    # Untranscribed hums: steady-pitch voiced runs (0.15-1.2 s) with no word centered on them.
    for a, b in runs(speech):
        ta, tb = a * HOP, b * HOP
        if not 0.15 <= tb - ta <= 1.2 or any(ta - 0.05 <= w["center"] <= tb + 0.05 for w in words):
            continue
        v = voiced[a:b]
        if v.mean() < 0.6 or np.std(f0[a:b][v]) > 18:
            continue
        pre, post = surrounding_pause(ta, tb)
        ca = pre["t0"] + PHRASE_TARGET / 2 if pre else ta - 0.02
        cb = post["t1"] - PHRASE_TARGET / 2 if post else tb + 0.02
        fillers.append({"word": "(hum)", "t0": t(a), "t1": t(b), "cut": [round(ca, 3), round(cb, 3)], "context": context(ta, tb)})

    repeats = []
    ns = [w["n"] for w in words]
    i = 0
    while i < len(words):
        for n in (5, 4, 3, 2, 1):
            if i + 2 * n <= len(words) and ns[i:i + n] == ns[i + n:i + 2 * n] and all(ns[i:i + n]) \
                    and not (n == 1 and ns[i] in {"very", "really", "no", "yes", "so"}):
                a, b = words[i]["speech"][0], words[i + n]["speech"][0]
                repeats.append({"words": " ".join(w["text"] for w in words[i:i + n]), "t0": round(a, 3), "t1": round(b, 3),
                                "cut": [round(a - 0.02, 3), round(b - 0.02, 3)], "context": context(a, b)})
                i += n
                break
        else:
            i += 1

    # Phrases between pauses >= 0.25 s; a short unterminated phrase ending on a function word, followed by a pause,
    # is a possible false start (review by ear: some are just dramatic pauses).
    phrases, cur = [], []
    pause_iter = iter(pauses + [{"t0": 1e9, "t1": 1e9}])
    nxt = next(pause_iter)
    for w in words:
        while w["center"] > nxt["t1"]:
            if cur:
                phrases.append({"words": cur, "pause_after": nxt})
                cur = []
            nxt = next(pause_iter)
        cur.append(w)
    if cur:
        phrases.append({"words": cur, "pause_after": None})
    false_starts = []
    for k, ph in enumerate(phrases):
        ws, pa = ph["words"], ph["pause_after"]
        last = ws[-1]["text"]
        if pa and len(ws) <= 6 and not re.search(r"[.?!]$", last) and ws[-1]["n"] in FUNCTION_END | {w["n"] for w in ws[:-1]}:
            a, b = ws[0]["speech"][0], pa["t1"]
            false_starts.append({"words": " ".join(w["text"] for w in ws), "t0": round(a, 3), "t1": round(b, 3),
                                 "cut": [round(a - 0.05, 3), round(b - PHRASE_TARGET / 2, 3)],
                                 "context": context(a, b)})

    result = {"transcript": tpath, "audio": apath, "threshold_db": round(float(thr), 1), "floor_db": round(float(floor), 1),
              "speech_span": [first_speech, last_speech], "pauses": pauses, "fillers": fillers, "repeats": repeats,
              "false_starts": false_starts,
              "words": [{"text": w["text"], "center": round(w["center"], 3), "speech": w["speech"]} for w in words],
              "speech_runs": [[t(a), t(b)] for a, b in runs(speech)],
              "energy": {"hop": HOP, "db": [round(float(x), 1) for x in db]},
              "phrases": [{"t0": ph["words"][0]["speech"][0], "t1": ph["words"][-1]["speech"][1],
                           "text": " ".join(w["text"] for w in ph["words"]),
                           "pause_after": ph["pause_after"]["dur"] if ph["pause_after"] else None} for ph in phrases]}
    os.makedirs(os.path.dirname(os.path.abspath(out)), exist_ok=True)
    json.dump(result, open(out, "w"), indent=1)
    marks = sorted([(f["t0"], "FILLER " + f["word"]) for f in fillers] + [(r["t0"], "REPEAT " + r["words"]) for r in repeats] +
                   [(f["t0"], "FALSE START? " + f["words"]) for f in false_starts] +
                   [(p["t0"], f"PAUSE {p['kind']} {p['dur']}s") for p in pauses if p.get("unnatural")])
    with open(re.sub(r"\.json$", "", out) + ".txt", "w") as fh:
        for ph in result["phrases"]:
            fh.write(f"{ph['t0']:7.2f}-{ph['t1']:7.2f}  {ph['text']}" + (f"  ⟨{ph['pause_after']:.2f}⟩" if ph["pause_after"] else "") + "\n")
        fh.write("\nMarkers:\n" + "".join(f"{t0:7.2f}  {m}\n" for t0, m in marks))
    print(json.dumps({"out": out, "pauses": len(pauses), "unnatural_pauses": sum(1 for p in pauses if p.get("unnatural")),
                      "fillers": len(fillers), "repeats": len(repeats), "false_starts": len(false_starts)}))


if __name__ == "__main__":
    main()
