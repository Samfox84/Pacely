# Your own sounds

Put sound files here, then build the app again in Xcode. Any that are missing use the normal iPhone sound.

| File name | When it plays |
|---|---|
| `pacely-reminder.caf` | Reminders ("Coming up", "Time to start") |
| `pacely-ending.caf` | "5 minutes left" |
| `pacely-timer.caf` | Focus time is up |
| `pacely-added.caf` | Someone added something for you with your link |

Sounds for notifications must be **30 seconds or less**, and `.caf`, `.wav` or `.aiff`.
To turn an `.mp3` into `.caf` on a Mac, open Terminal in this folder and paste:

    for f in *.mp3; do afconvert -f caff -d LEI16 "$f" "${f%.mp3}.caf"; done

Sounds that play *inside* the app (ticking things off, timer end) go in `server/static/sounds/`. See the README there.
