#!/usr/bin/env python3
"""
Pacely sound pack - one coherent, sensory-friendly palette.

Everything uses the same instruments (soft marimba, wood, glass, sine) in
C major pentatonic, so no sound ever clashes with another.

Loudness tiers (peak dBFS):
  NAV    -26  tiny, frequent: tabs, sheets, swipes, drag
  APP    -17  in-app moments: done, step, add, timer
  NOTIFY -14  notifications (heard from a pocket)

Rules on every sound: raised-cosine attack >= 5 ms, fundamentals <= 800 Hz,
4th-order low-pass ~3.5 kHz (nav: 2.5 kHz), exponential decay, tail fade.

Run:  python3 pacely_sounds.py
Out:  out/ios/*.caf   -> ios/Pacely/Sounds/
      out/web/*.mp3   -> server/static/sounds/
"""
import numpy as np, os, subprocess
from scipy.signal import butter, sosfilt
from scipy.io import wavfile

SR = 44100
NAV, APP, NOTIFY = -26.0, -17.0, -14.0
N = dict(C4=261.63, D4=293.66, E4=329.63, G4=392.00, A4=440.0,
         C5=523.25, D5=587.33, E5=659.25, G5=783.99)


def env(n, attack_ms, decay_s):
    t = np.arange(n) / SR
    e = np.exp(-t / decay_s)
    a = max(1, int(SR * attack_ms / 1000))
    e[:a] *= 0.5 - 0.5 * np.cos(np.linspace(0, np.pi, a))
    f = min(n // 3, int(SR * 0.03))
    e[-f:] *= np.linspace(1, 0, f)
    return e


def lp(x, fc):
    return sosfilt(butter(4, fc, fs=SR, output="sos"), x)


def partials(f0, ratios, amps, decays, dur, attack_ms):
    n = int(SR * dur); t = np.arange(n) / SR
    return sum(a * np.sin(2 * np.pi * f0 * r * t) * env(n, attack_ms, d)
               for r, a, d in zip(ratios, amps, decays))


def place(buf, sig, at):
    i = int(SR * at); buf[i:i + len(sig)] += sig[:len(buf) - i]; return buf


def silence(s): return np.zeros(int(SR * s))


# ---- instruments ----
def marimba(f, dur=0.7, decay=0.28):
    return partials(f, [1, 4.0, 9.9], [1, .10, .02], [decay, .06, .02], dur, 7)

def kalimba(f, dur=0.9):
    return partials(f, [1, 2.0, 5.4], [1, .08, .03], [.35, .15, .04], dur, 9)

def glass(f, dur=1.8, decay=0.65):
    return partials(f, [1, 2.0, 2.76], [1, .12, .05], [decay, .35, .2], dur, 22)

def wood(f, dur=0.25, decay=0.06, attack=5):
    body = partials(f, [1, 2.32, 3.9], [1, .25, .08], [decay, decay / 2, decay / 3.5], dur, attack)
    n = len(body)
    knock = lp(np.random.default_rng(int(f)).standard_normal(n), 1600) * env(n, 3, .01) * .12
    return body + knock

def sine_bloom(f, dur=1.2, rise=0.18, decay=0.35):
    n = int(SR * dur); t = np.arange(n) / SR; a = int(SR * rise)
    e = np.ones(n)
    e[:a] = 0.5 - 0.5 * np.cos(np.linspace(0, np.pi, a))
    e[a:] = np.exp(-(t[a:] - t[a]) / decay)
    e[-int(SR * .03):] *= np.linspace(1, 0, int(SR * .03))
    return (np.sin(2 * np.pi * f * t) + .15 * np.sin(4 * np.pi * f * t)) * e

def glide(f_from, f_to, dur=0.16, attack_ms=25, decay=0.07):
    # soft pitched "puff" - a sine that bends gently between two notes
    n = int(SR * dur); t = np.arange(n) / SR
    f = f_from * (f_to / f_from) ** np.clip(t / (dur * .6), 0, 1)
    ph = 2 * np.pi * np.cumsum(f) / SR
    return (np.sin(ph) + .1 * np.sin(2 * ph)) * env(n, attack_ms, decay)

def breath(dur=0.22, fc=900, attack_ms=40, decay=0.06):
    # very soft filtered-noise swish, no hiss
    n = int(SR * dur)
    x = lp(lp(np.random.default_rng(7).standard_normal(n), fc), fc)
    return x * env(n, attack_ms, decay)

def seq(fn, notes, gap, tail=0.8, **kw):
    buf = silence(gap * (len(notes) - 1) + tail)
    for i, nt in enumerate(notes):
        place(buf, fn(N[nt], **kw) * (0.85 ** i if fn is not kalimba else 1), i * gap)
    return buf


# ---- the pack: name -> (builder, loudness tier, lowpass Hz, description) ----
PACK = {
    # existing in-app slots (Feedback.sound / sfx)
    "done":       (lambda: seq(kalimba, ["C5", "E5", "G5"], .10, .95), APP, 3500, "Tick something off - small rising reward"),
    "step":       (lambda: marimba(N["E5"], .35, .14), APP, 3500, "Tick off a step - single soft note"),
    "add":        (lambda: seq(marimba, ["G4", "C5"], .12, .7), APP, 3500, "Add something - two-note ding"),
    "next-step":  (lambda: seq(marimba, ["C5", "D5"], .14, .6, decay=.2), APP, 3500, "Focus moves to next step - gentle nudge"),
    "timer":      (lambda: place(place(silence(2.2), glass(N["C5"]), 0), glass(N["E5"]) * .7, .32), APP, 3500, "Focus time is up - slow glass pair"),

    # existing notification slots (UNNotificationSound, .caf only)
    "pacely-reminder": (lambda: seq(marimba, ["C5", "E5", "G4"], .15, .9), NOTIFY, 3500, "Notification: coming up / time to start"),
    "pacely-ending":   (lambda: place(place(silence(2.0), glass(N["E4"]), 0), glass(N["G4"]) * .8, .16), NOTIFY, 3500, "Notification: 5 minutes left"),
    "pacely-timer":    (lambda: place(place(silence(2.2), glass(N["C5"]), 0), glass(N["E5"]) * .75, .32), NOTIFY, 3500, "Notification: focus time is up"),
    "pacely-added":    (lambda: place(place(silence(.55), wood(520, .35, .07, 6), 0), wood(440, .35, .07, 6) * .8, .14), NOTIFY, 3500, "Notification: someone added something via your link"),

    # NEW navigation sounds (need hooks - see INTEGRATION.md)
    "tab":        (lambda: wood(N["G4"] * 1.33, .12, .025, 5), NAV, 2500, "Switch tab - tiny wood tick"),
    "open":       (lambda: glide(N["E4"], N["G4"]), NAV, 2500, "Open a sheet/panel - soft upward puff"),
    "close":      (lambda: glide(N["G4"], N["E4"]), NAV, 2500, "Close a sheet/panel - soft downward puff"),
    "swipe":      (lambda: breath(), NAV, 1200, "Swipe to another day - quiet air swish"),
    "pickup":     (lambda: wood(N["C4"] * 1.25, .15, .03, 6), NAV, 2500, "Start dragging - low tock"),
    "drop":       (lambda: place(place(silence(.25), wood(N["G4"], .15, .035, 5), 0), wood(N["C4"] * 1.25, .12, .025, 5) * .45, .07), NAV, 2500, "Drop into place - tock + settle"),
    "hover":      (lambda: wood(N["E4"] * 1.5, .08, .015, 5) * .7, NAV, 2200, "Drag over a target - faint tick"),
    "toggle-on":  (lambda: marimba(N["G4"], .2, .05), NAV, 2500, "Switch on"),
    "toggle-off": (lambda: marimba(N["D4"], .2, .05), NAV, 2500, "Switch off"),
    "delete":     (lambda: seq(marimba, ["E4", "C4"], .09, .35, decay=.09), NAV + 4, 2500, "Delete - short soft fall"),
    "undo":       (lambda: seq(marimba, ["C4", "E4"], .09, .35, decay=.09), NAV + 4, 2500, "Undo - short soft rise"),
    "focus-start":(lambda: sine_bloom(N["A4"]), APP, 3000, "Start focus - warm bloom"),
    "pause":      (lambda: sine_bloom(N["E4"], 1.0, .15, .25), APP, 3000, "Pause focus - lower bloom"),
    "welcome":    (lambda: place(seq(kalimba, ["G4", "C5", "E5"], .16, 1.1) * .8, glass(N["C5"], 1.6, .5) * .35, .05), APP - 2, 3200, "Pacely opens - soft three-note hello"),
    "gentle-error":(lambda: seq(marimba, ["E4", "C4"], .18, .8), APP, 3000, "Something didn't work - calm, not alarming"),
}


def render(name, fn, tier, fc, outdir):
    x = lp(fn(), fc); x -= x.mean()
    x *= 10 ** (tier / 20) / np.max(np.abs(x))
    wav = f"{outdir}/wav/{name}.wav"
    wavfile.write(wav, SR, (x * 32767).astype(np.int16))
    run = lambda *a: subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-i", wav, *a], check=True)
    run("-c:a", "pcm_s16le", f"{outdir}/ios/{name}.caf")
    if not name.startswith("pacely-"):          # notification sounds are iOS-only
        run("-c:a", "libmp3lame", "-b:a", "128k", f"{outdir}/web/{name}.mp3")


if __name__ == "__main__":
    out = "out"
    for d in ("wav", "ios", "web"): os.makedirs(f"{out}/{d}", exist_ok=True)
    for k, (fn, tier, fc, desc) in PACK.items():
        render(k, fn, tier, fc, out); print(f"{k:16} {desc}")
