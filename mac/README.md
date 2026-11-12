# Pacely for Mac

Pacely as a proper Mac app, with a menu bar countdown and calm pop-up reminders.
Works on Apple silicon and Intel Macs (macOS 13 Ventura or newer). No Apple ID or paid developer account needed.

The first time it opens, Pacely asks **where to keep your plans**:

| Choice | What it means |
|---|---|
| **On this Mac** | No server needed. Plans are saved in a file on this Mac, with a backup each day (the last 14 are kept). Works offline. |
| **On my Pacely server** | Connect to a Pacely server you (or someone you trust) runs, so your phone, watch and computers all share the same plans. |

You can change your mind later: **File › Change Where Plans Are Kept…**

## Install

### Easiest: download it
1. Go to the [Releases page](https://github.com/Samfox84/Pacely/releases) and download **Pacely-Mac.zip**.
2. Double-click the zip, then drag **Pacely** into your **Applications** folder.
3. The first time, **right-click Pacely › Open**, then click **Open** again.
   (Pacely isn't signed with a paid Apple account, so macOS asks once.
   If it still won't open: System Settings › Privacy & Security › scroll down › **Open Anyway**.)

### Or build it yourself (about 2 minutes)
You need Xcode (free from the App Store), opened once.

1. Download this project (green **Code** button › **Download ZIP**) and unzip it in **Downloads**.
2. Open **Terminal** and paste:

       cd ~/Downloads/pacely-main/mac && bash Install-Pacely.command

Run the same line again any time to update.

## Moving your plans (File menu)
- **File › Export Database…** (⇧⌘E) saves all your plans to one `.json` file.
- **File › Import Database…** (⇧⌘I) loads a file. You choose:
  - **Merge**: keep what you have and add anything new from the file.
  - **Replace**: swap your plans for the file's. A copy of your current plans is kept first.
- **File › Show Backups Folder** opens the daily backups.

The same file works everywhere: another Mac, a Windows PC (Pacely in the browser), or a Pacely server.
Starting fresh on a new Mac? Choose **On this Mac › Load a saved file…** on the welcome screen.

## What it does
- **Menu bar countdown**: what you're doing now and the minutes left, e.g. "🧹 12m".
  Click it for what's next, tick things off, or push the rest of the day back when you're running late.
- **Pop-ups**: a calm card in the top-right corner when an activity starts, 5 minutes before it ends,
  and when focus time is up. It never takes over your typing.
- **The full Pacely app** in its own window. Closing the window keeps Pacely in the menu bar.
- Turn on **Settings › Open Pacely when I log in** so it's there every day.

## Work Macs managed by IT
Some company Macs block apps that aren't from the App Store. If Pacely won't open,
use Pacely in your browser instead: <https://samfox84.github.io/Pacely/> (click Install in Chrome or Edge).

## Using Xcode instead
Open **PacelyMac.xcodeproj**, choose **My Mac** at the top and press **▶ Run**.
The app bundles the web app from `../server/static`, so keep the folders together.
