# Pacely for iPhone and Apple Watch

A fully native iPhone and Apple Watch app. When it first opens you choose:

| Choice | What it means |
|---|---|
| **Connect to my server** | Your phone, watch and computers share one plan. Live sync, family helper, journeys, widgets. See the [server guide](../docs/setup-server.md). |
| **Just use it on this phone** | No server. Your plans stay on this iPhone. Reminders, the Lock Screen countdown, calendars and the AI helper (with your own Gemini key) all work. The family helper, live journeys, home screen widgets and the Apple Watch need a server. |
| **I help someone with their plan** | For a partner or family member: open the invite they sent you. |

Switching later: **Sign out** (at the bottom of **Me**, or **Me › Settings** in the Calm layout) takes you back to this choice. Plans kept on the phone
stay there, so choosing **Just use it on this phone** again brings them back. **Me › Save a copy** makes a backup
file you can load into a server later.

## First install (about 15 minutes)

1. On the Mac, unzip this folder and double-click **Pacely.xcodeproj**. You need Xcode 16 or newer.
   If Xcode asks to download the **iOS** or **watchOS** platform, click **Get** and wait.
2. **Optional but recommended:** in Pacely on your phone go to **Me → iPhone app settings → Copy widget link**
   (or log in at plan.example.com and copy it from there). In Xcode, open **Config → widget-link.txt**
   and paste the link on the empty last line. This makes your watch face and iPhone widgets work without setting up.
3. Plug your iPhone into the Mac with a cable. On the iPhone, tap **Trust** if asked.
4. In Xcode, click **Pacely** (blue icon) at the top of the left-hand list, then **Signing & Capabilities**.
5. Set **Team** to your own Apple ID for **all four** targets: **Pacely**, **PacelyWidgetExtension**,
   **PacelyWatch** and **PacelyWatchWidgetExtension**. (Use Add an Account… if your Apple ID isn't listed.)
6. At the top of the window, pick your **iPhone** as the run destination and press **▶ Run**.
7. First time only, on the iPhone: **Settings → General → VPN & Device Management → your Apple ID → Trust**,
   and **Settings → Privacy & Security → Developer Mode → On** (the phone restarts).
8. Open Pacely. Either type your server's address (for example `plan.example.com`) and your Pacely password and tap
   **Connect**, or tap **Just use it on this phone**. Allow notifications when asked.

If Xcode says the bundle identifier is taken, change `io.github.samfox84.pacely` to something unique in all
four targets, keeping the endings (`.widget`, `.watchkitapp`, `.watchkitapp.widget`) on the other three.

## Apple Watch (works on Series 4 with watchOS 10)
The watch app installs with the iPhone app. If it doesn't appear, open the **Watch** app on your iPhone →
scroll to **Pacely** → **Install**. On the watch, turn on **Settings → Privacy & Security → Developer Mode** if asked.
Open Pacely on the watch once with the iPhone nearby and it links itself.
- Tap **+** to add a to-do by speaking, scribbling or typing, or start something now.
- **Watch face:** press and hold your watch face → Edit → Complications → **Pacely**.
  (Needs the widget link in Config → widget-link.txt.)

## Widgets
Add widgets from the Home Screen or Lock Screen widget gallery:
- **Pacely** – what's now and next, with ✓ buttons to tick things off.
- **Pacely Focus** – start a 10, 25 or 45 minute focus timer with one tap.
If you didn't fill in widget-link.txt, press and hold a widget, tap **Edit Widget**, and paste the link.

## Lock Screen countdown (Live Activity)
Pacely puts your next activity on the Lock Screen up to 6 hours ahead, and it switches to the countdown by itself
when the activity starts. Tapping **Done** on it shows the next one. It refreshes whenever Pacely runs.
To make sure it's ready each morning, add a Shortcuts automation:
**Shortcuts → Automation → + → Alarm → Is Stopped → Run Immediately → add action "Update Pacely" → Done.**

## Calendar (two-way)
**Me → iPhone app settings → Sync with iPhone Calendar**.

## Siri and Control Centre
Say "Add to Pacely", "What's next in Pacely", "I'm running late in Pacely" or "Update Pacely".
Open Control Centre → **+** → **Add a Control** → **Pacely** for **Running late** and **Add to Pacely** buttons.
You can put them on the Lock Screen too (press and hold the Lock Screen → Customise).

## Reminders
Press and hold a reminder (or swipe it down) for **Done**, **Running late (10 min)** and **Remind me in 10 min**.
Old reminders clear themselves, and each activity's reminders stack together.

## Partners and family (same app, needs a server)
The person whose plan it is goes to **Me → Share with family → Invite someone** and sends you the invite.
Open it on your iPhone with Pacely installed (or choose **I help someone with their plan** and paste it).
Each invite works once, on one phone.

You'll see what they share as a **Day**, **Coming up** or **Month** view, and can:
- add things to their plan,
- **send a list** (✨ › Send a list): paste a long message and it becomes a clear list they can tick off as they go,
- **find it and plan it**: type "Christmas fair 28 Nov 1pm" and the AI helper finds the details.

Anything they mark **Private** never shows.

## Calm settings
In **Me**: **Calm layout**, **Low-stimulation mode**, **Quiet hours**, **Text style** (Easy read or OpenDyslexic),
**Calm countdown** ("until 9:15" instead of a ticking clock, on by default), and every sound and haptic.
See [How to use Pacely](../docs/using-pacely.md).

## Your own sounds
The calm sound pack is already in `Pacely/Sounds`. To use different sounds, replace the `.caf` files there with
files of the same names (see `Sounds/README.md`) and build again.

## Every 7 days (free Apple ID only)
Apps signed with a free Apple ID stop opening after 7 days. Plug the phone into the Mac, open the project and
press **▶ Run** again. Your plans are safe: on your server, or on the phone.

With a paid Apple Developer account (£79 a year) apps last a year, and you can send Pacely to family with
**TestFlight** (they install it from an email invite, no cable or Mac needed).
