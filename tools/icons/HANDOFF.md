# Pacely Calm icons: handoff for the build

Repo: `Samfox84/Pacely`. This pack replaces the emoji used in the interface with one calm, consistent line icon set. It is written so another Claude session can make the change without needing this conversation.

## Why (what this is for)
Pacely is for AuDHD users. Emoji in the interface:
- look different on iPhone, Android and Windows, and some are busy or tiny at small sizes
- bring many competing colours onto one screen
- include faces for moods, which can be harder to read than a simple symbol
- add celebration noise (🎉 ✨ 🔥 👏) to calm moments

The iPhone app's native screens already use SF Symbols, which are calm and consistent, so **leave those as they are.** The main work is in the **web app** (`server/static/index.html`), which the iPhone app also shows inside its WebView, plus **activity and mood icons** on both platforms.

## Rules for any icon added later
- 24×24 grid, 2px padding, stroke 1.75, round caps and joins, `fill="none"`, `stroke="currentColor"`
- Single colour, taken from the surrounding text colour. Never bake in a colour.
- No faces, no spikes or bursts, no detail smaller than about 2px
- Always shown next to a text label; the icon is `aria-hidden`
- Size: 20–24px inline, 22px on tabs, 28–30px for large empty-state icons. Tap targets stay at least 44px.

## What's in the pack
| Path | Use |
|---|---|
| `pacely-icons.js` | Web: `PacelyIcons.icon(name, px?)` and `PacelyIcons.emojiIcon(emoji, px?)` return inline SVG strings |
| `pacely-icons-sprite.svg` | Optional `<use href="#pi-name">` sprite |
| `svg/*.svg` | One file per icon |
| `icons.json` | Names, labels, and `emojiToIcon` (emoji → icon name) |
| `ios/PacelyIcons.xcassets` | Template vector images named `pi-<name>` |
| `ios/PacelyIcon.swift` | SwiftUI `PacelyIcon(emoji:)`: shows the icon, or the emoji if there's no match |
| `icons.py` | Source of truth. Edit it and run `python3 icons.py` to regenerate the web files. |

## Data model: no migration
Items, routines and calendars keep storing an `emoji` string. The app only changes how that string is **displayed**: `emojiIcon(e)` shows the matching icon, or the emoji itself when there isn't one, so custom emoji users picked still work. The AI planner and `smart.js` can keep returning emoji.

## Web app changes (`server/static/index.html`)
1. Copy `pacely-icons.js` to `server/static/` and load it before the main script, next to `smart.js` and `local.js`.
2. Add CSS: `.pi{vertical-align:-0.15em;flex:none}` and `.tabs button .pi{width:22px;height:22px}`. Remove the `filter:grayscale(1)` and `opacity` emoji rules on `.tabs button span`, and colour the active tab with `color:var(--accent)` instead.
3. **Tabs**: replace the `<span>🗓️</span>` and the others with `icon('today')`, `icon('todo')`, `icon('focus')`, `icon('routines')`, `icon('me')`.
4. **Buttons and headings**: swap the emoji prefixes for icons, keeping the words. For example `⏳ Focus` → `${icon('focus')} Focus`, `✓ Done` → `check`, `✏️ Edit` → `edit`, `🗑️ Delete` → `delete`, `🐢 Running late` → `later`, `🌧️ Couldn't do it today` → `rain`, `🗓️ Plan for a day` → `calendar-add`, `✨ Brain dump` → `sparkle`, `💬` → `chat`, `📷` → `camera`, `📝` → `note`, `📊` → `chart`, `📞 Call` → `phone`, `🔎` → `search`, `🎙️` → `mic`, `📄` → `file`, `🔒` → `lock`, `🔔` → `bell`, `📍` → `pin`, `💌` → `love-note`, `🧺` → `basket`, `🌙` → `moon`, `🌤️` (empty day) → `calm-day`, `🌿` (all clear) → `leaf`, `▶` → `play`, `❚❚` → `pause`, `↺` → `undo`.
5. **Activity emoji** (`.em`, todo chips, all-day chips, routine items, AI suggestions): render with `emojiIcon(it.emoji)`. Tint the icon with the block colour mixed with ink, for example `color:color-mix(in srgb,var(--c) 45%,var(--ink))`.
6. **Emoji picker** (`EMOJIS`): show `emojiIcon(e)` on each choice but keep storing `e`. Keep a "More emoji" option for anything without an icon.
7. **Moods**: replace the `MOODS` faces with `icon('mood-1')` … `icon('mood-5')` (weather from rough to great) and always show `MOODNAMES` under them.
8. **Quiet days**: `off` → `palm`, `sick` → `unwell`, `holiday` → `plane`, note → `pin`.
9. **Toasts**: remove the emoji from toast text (`Nice one ✨`, `Done! 🎉`, `💛`). The words and the gentle sound are enough. Optionally put `icon('check')` before them.
10. **Streak**: `${ins.streak}🔥` → `icon('flame')`. Consider a Me setting to hide streaks, since they can feel like pressure.
11. Optional: a **Me › "Show emoji instead of icons"** setting (stored with `fxSet('emoji', …)`) that makes `emojiIcon` return the emoji, for people who prefer colour.
12. Leave `✓` inside `.chk` and `.istep .bx::after` as they are, or swap them for `icon('check')`.

## iPhone native changes
1. Drag `ios/PacelyIcons.xcassets` into `ios/Pacely/`. The folder is synchronised, so it bundles automatically. Add it to the widget and watch targets too if they show activity icons.
2. Add `ios/PacelyIcon.swift` to `ios/Pacely/` (and to `ios/Shared/` if widgets need it).
3. Wherever an item shows `Text(item.emoji)` (`Theme.swift` row view, `TodayView`, `TodoView`, `RoutinesView`, `ItemViews`, the widgets), use `PacelyIcon(emoji: item.emoji, size: 22)` with `.foregroundStyle(...)` from the block colour.
4. Moods (`Look.moods`): use SF Symbols `cloud.bolt`, `cloud.drizzle`, `cloud`, `cloud.sun`, `sun.max`, or `Image("pi-mood-1")` … `Image("pi-mood-5")`, with the labels always visible. Replace `face.smiling` in "How am I feeling?" with `cloud.sun`.
5. Keep all existing SF Symbols in buttons; they already follow these rules.

## Check before merging
- Every icon has a text label beside it, or an `aria-label` on its button
- Light and dark mode both look right, because icons follow `currentColor`
- Emoji that aren't mapped still show as emoji
- No layout shift: icons are 1em or a fixed px size
