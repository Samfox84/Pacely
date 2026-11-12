# Changelog

What changed in each version of Pacely. Newest first. Pacely is still early, so versions are 0.x.

## 0.7.0
- **iPhone: "Just use it on this phone"**. No server needed: plans stay on the iPhone, using the same on-device engine as the browser and Mac versions. Reminders, the Lock Screen countdown, calendars and the AI helper (with your own Gemini key) work; the family helper, live journeys, home screen widgets and the Apple Watch need a server
- On-device engine: Make a list, Test the AI helper, quiet hours, and Gemini quietly trying another model when one is busy
- New guides: [How to use Pacely](docs/using-pacely.md), [Privacy in detail](docs/privacy.md), [Helping with Pacely](CONTRIBUTING.md); server and iPhone guides updated
- Optional TfL key can go in `/etc/default/pacely`
- Fonts' licences included (SIL Open Font License)

## 0.6.0
- **Low-stimulation mode** (Me › Calm and quiet): no sounds, no haptics, nothing moves, softer colours
- **Quiet hours**: no notifications between the times you choose (only a focus timer you started yourself can make a sound)
- **Calmer reminder wording**: the activity's name, then a plain statement ("Starting about now.", "In 10 minutes, at 10:00.", "Still here whenever you're ready."). No "Time to start!" or "Still to do"
- **No ticking clock by default**: the Now card says "until 9:15" (the ticking countdown is still a choice)

## 0.5.2
- **Partner app: Day, Coming up and Month views**. Day shows one day at a time (swipe or use the arrows), Month shows the next 6 weeks with coloured dots; tap a day to open it

## 0.5.1
- **Lock Screen card is readable**: dark card with light text on any wallpaper, light or dark mode. No "Late" button on journeys
- **Gentler leave reminders by default**: one heads-up 15 minutes before ("Heads up: leave around 15:01. No rush."). The 20/10/5 countdown is still there as a choice (Me › Getting about › Reminders to leave)
- **Fewer journey alerts**: only when the time you need to leave changes by 10 minutes or more. How the lines are running shows quietly on the card, never as a notification
- **Calm layout**: Day / Week / Month moves into one small button next to the title; the top line is one short line ("🏢 Office · 🏠 15:01"); delays show as a small amber dot, not a warning sign

## 0.5.0
- **Calm layout** (Me › Calm layout, switch back any time): Today shows one line for the day ("🏢 In the office · 🚇 Leave 07:35"), what's happening now and the timeline. Extra add buttons and chips appear only while adding. Things from before fold into one line. Softer colours. Me is grouped into Getting about, Family and calendars, AI helper and Settings
- **Journey card folds to one line** until you tap it
- **Shorter alerts**: "Leave 7 min earlier (07:35)" and "Central line: minor delays."
- **Choose the Gemini model** (or Automatic). Each try waits at most 45 seconds, and a stuck or busy model hands over to the next
- Reading fonts load off the main thread

## 0.4.4
- **Make a list from a message**: paste or say a long message (like a WhatsApp shopping list) and it becomes a clear, tickable list: one thing per line, quantities first, shopping in supermarket order. Works from the partner app too, and the partner sees how much has been ticked off. If the AI is busy, it still splits the message up simply

## 0.4.3
- **Tidy work calendars**: each linked calendar can show only your working hours, hide repeating blocks (focus time, out of office) and hide anything already in Pacely at the same time. Calendars named "Work" start off tidied (9:00 to 15:30)
- **Gemini sticks with the model that answers** once it has had to switch away from a busy one

## 0.4.2
- **Gentle countdown to leave**: 20, 10 and 5 minutes before, then "Time to leave", for journeys to and from work and anything with a leave time
- **Choose your transport**: tube only, or any mix of Elizabeth line, Overground, DLR, bus, trains and tram (Me › Getting about)
- **Swipe between days anywhere**, even on cards like "Leave for work"
- No web-page style scroll bar

## 0.4.1
- **The way home too**: on office days Pacely also checks your journey home before your usual time (Me › Getting about)
- **Journeys on the Lock Screen**: "Leave for work" and "Head home" show in the Lock Screen countdown, Dynamic Island and widgets, with how the lines are running
- **Gemini "high demand"**: Pacely quietly tries another Gemini model instead of giving up
- **The keyboard goes away** when you tap outside a text box or scroll
- Fixed: iPhone calendar sync clashed with live sync

## 0.4.0
- **Opens instantly, even with no signal**: the iPhone app keeps a copy of your plan and shows it straight away, then catches up. A calm "Getting your day ready" screen shows the very first time, instead of a frozen, empty screen
- **Live two-way sync**: when you, your partner, the AI helper or a calendar changes something, every open screen updates by itself within a second or two (iPhone, partner app and web)
- **Changes made offline wait and send themselves** when your server answers again
- **Find it and plan it** (✨ next to Add): "Audley End Christmas event 28 Nov 1pm" → the AI helper looks it up online, finds the website, price and address, and works out when to leave
- **When to leave**: add a place to any activity and Pacely works out the drive or public transport time from home, and reminds you 10 minutes before you need to go
- **TfL watch on office days**: checks your route to work every 5 minutes before you start and tells you if a delay changes when you need to leave
- **Gentle nudges** to drink, eat and take a little pause (each one switched on separately)
- **Easier-to-read text**: Atkinson Hyperlegible or OpenDyslexic
- **AI for partners**: Alex can use Find it and plan it from their side too
- **Test the AI helper** button that says exactly why it isn't answering, and clearer AI error messages
- Sounds play off the main thread, so the screen never stutters

## 0.3.0
- **Private one-time partner invites**: an invite opens straight in the Pacely app and works once, on one phone. Making a new invite signs the old phone out. The web page and calendar feed are off unless you switch them on
- **Office and work-from-home days**: "in the office every tue and thu" makes a repeating all-day banner across the top of those days
- **A gentle hello when Pacely opens**, with a switch in Me
- **AI thinking glow**: a soft, slowly moving light round the edge of the screen while the AI helper works, with a timer and a Cancel button (breathes instead of moving if Reduce Motion is on)
- **Keep nudging me until it's done**: up to three gentle follow-ups for important things
- **Show less**: Today can show just now and next
- **Good days** instead of a streak, so a missed day never resets anything

## 0.2.0
- **iPhone app is now fully native** (SwiftUI): Today with day, week and month views, To-do, Focus, Routines and Me, all real iPhone screens
- **Partner mode**: the same app, signed in with someone's share link. See their plan (if they allow it), add things for them, and get a note when they tick off something you added. **Private** activities never show to family
- **Share link page** for anyone without the app: add things to someone's plan and subscribe to it in any calendar app
- **Type it like a text**: "pick up meds tomorrow 11am" fills in the day and time. Emoji and colour are picked for you
- **Quick add, recent items as one-tap buttons, steps you can tick straight from the timeline**
- **Couldn't do it today**: moves just the unfinished steps to another day, the to-do list, or lets it go. Never shown as a failure
- **All-day items, day off, sick day and holiday**: reminders stay quiet on those days, and the day's things can be moved in one tap
- **Leftovers**: things not done from earlier days can be moved to today, the to-do list, or let go
- **Repeating things can tick themselves off** when their time is over (switch off in Me)
- **Reminders tidy themselves**: old ones are cleared, each activity's alerts stack together, and each has Done, Running late and Remind me in 10 min buttons
- **Running late** from the Lock Screen, a widget, Control Centre, Siri ("I'm running late in Pacely") or inside the app
- **Calm countdown and CarPlay**: "until 9:15" instead of a ticking clock; CarPlay and Apple Watch show a still, calm card
- **Calm sound pack** (23 soft sounds in one key) and **calm line icons** in place of emoji, on iPhone, widgets, Lock Screen, Mac and web
- **Speak instead of typing** with the iPhone's on-device speech recognition
- **Meeting notes or a transcript → plans** with the AI helper, and **Share how my week went** (for Gemini, a therapist or a supporter)
- **Call buttons**: save numbers once, and "Call doctors" shows a big Call button (or Find the number)
- **Swipe** between days, weeks and months; **drag** an activity onto another day
- Server: one copy per repeating activity per day (fixes rare duplicates), safer tunnel script for people who already have a tunnel

## 0.1.0 (first public version)
- **Visual day planner:** timeline with colour blocks, now-ring and now-line, free-time gaps; day, week and month views
- **Drag and drop** activities to new times and days, and to-dos into your day
- **Steps** with optional minutes, a **focus timer** that walks you through them, **routines**, a **to-do list** with Now / Soon / Later
- **Running late?** pushes the rest of today back; **reminders** before, at the start and near the end
- **Check-ins**, evening review, streaks and trophies
- **Optional AI helper:** brain dump, talk it through, photo to tasks, auto-prioritise. Private on your server (Ollama) or with your own Gemini key
- **Calendars:** show calendar links on your timeline, and publish your plan as a calendar feed
- **Keep plans where you choose:**
  - in the browser on your device (no server needed), at https://samfox84.github.io/Pacely/
  - on your Mac, with a daily backup
  - on your own Pacely server
- **Backups that move with you:** save one file; load it later and choose **merge** (keep yours, add anything new) or **replace** (a safety copy is kept first)
- **Mac app** (Apple silicon and Intel): asks where to keep plans on first run, menu bar countdown, calm pop-ups,
  File › Export Database / Import Database / Show Backups Folder
- **iPhone and Apple Watch apps:** widgets, Lock Screen countdown and Dynamic Island, Siri, two-way Calendar sync, watch complications
- **Server:** one-line installer, `setup-tunnel.sh` for a free Cloudflare Tunnel (adds to an existing tunnel without touching your other sites), profiles for other people in your home
