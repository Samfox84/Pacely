# Pacely sound pack

## Plays straight away (no code changes)
- `ios/*.caf` → `ios/Pacely/Sounds/` (the folder syncs with Xcode, so rebuilding is enough)
- `web/*.mp3` → `server/static/sounds/` (on the server: `/opt/pacely/static/sounds/`)

| Slot | Plays when |
|---|---|
| done, step, add, next-step, timer | Already used by `Feedback.sound()` / `sfx()` |
| pacely-reminder, pacely-ending, pacely-timer, pacely-added | Already used by `Sounds.notification()` (iOS only) |

## New sounds that need a one-line call
Web (`server/static/index.html`), using the existing `sfx(name)`:
- `openSheet()` → `sfx('open')`, `closeSheet()` → `sfx('close')`
- Tab buttons → `sfx('tab')`
- Day swipe (the `swipe-out-l/r` line) → `sfx('swipe')`
- Drag start / drag over a target / drop → `sfx('pickup')` / `sfx('hover')` / `sfx('drop')`
- Settings switches → `sfx('toggle-on')` / `sfx('toggle-off')`
- Delete / undo → `sfx('delete')` / `sfx('undo')`
- Focus start / pause → `sfx('focus-start')` / `sfx('pause')`, failures → `sfx('gentle-error')`

iOS native: the same names with `Feedback.sound("tab")` and so on, e.g. in
`RootView` add `.onChange(of: tab) { _ in Feedback.sound("tab") }`.

Navigation sounds are rendered 9 dB quieter than in-app sounds, so they can play often.
To change a sound, edit `PACK` in `pacely_sounds.py` and run `python3 pacely_sounds.py`.
