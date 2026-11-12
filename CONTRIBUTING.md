# Helping with Pacely

Thank you. Pacely is a small, free project for neurodivergent people, so the most useful help is often not code.

## Ideas and problems

[Open an issue](https://github.com/Samfox84/Pacely/issues) and say what happened, what you expected, and (if you can)
add a screenshot with anything private covered. If something in Pacely made you feel pressured, anxious or
overloaded, that's a bug too. Please tell us.

## Design rules

Changes should make Pacely calmer, not busier:

- **Take away before adding.** A new feature should be off by default, or replace something.
- **No pressure.** No streaks that reset, no ticking countdowns by default, no urgent or guilt-based wording.
  Reminders state things plainly ("Starting about now.") rather than giving orders.
- **The person is in control.** Every sound, haptic, animation and notification can be switched off.
- **Predictable.** Things stay where they are. Buttons say exactly what they do.
- **Plain UK English.** Short sentences. No jargon.
- **Private.** Nothing leaves the person's device or server unless they switch it on.

## Code

| Part | Where | Tests |
|---|---|---|
| Server (Python, Flask, SQLite) | `server/app.py` | `python -m pytest -q tests` |
| Web app | `server/static/index.html` | `tests/ui/web-journeys.js` (Playwright) |
| On-device engine (browser, Mac, iPhone) | `server/static/local.js` (copied to `ios/Pacely/Engine/`) | `node tests/local-engine.test.js`, `node tests/iphone-engine.test.js` |
| iPhone and Watch (SwiftUI) | `ios/` | GitHub Actions build check and simulator tour |
| Mac (SwiftUI) | `mac/` | GitHub Actions build |

If you change `server/static/local.js`, `smart.js` or `ical.min.js`, copy them to `ios/Pacely/Engine/` too (a test checks).

By contributing you agree your work is shared under the [GPL-3.0](LICENSE).
