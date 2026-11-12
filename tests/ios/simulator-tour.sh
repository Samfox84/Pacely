#!/bin/bash
# Runs the native iPhone app in the iOS simulator against a local Pacely server full of example plans,
# and takes a screenshot of every screen. Used by the "iPhone app tour" GitHub Action; also works on any Mac with Xcode.
set -u
OUT=${OUT:-$PWD/shots}; mkdir -p "$OUT"
BUNDLE=io.github.samfox84.pacely
PORT=8790
DATA=$(mktemp -d)
export PACELY_DATA=$DATA PACELY_TZ=${PACELY_TZ:-Europe/London} PACELY_PORT=$PORT

python3 -m pip install -q flask waitress pywebpush icalendar recurring_ical_events >/dev/null 2>&1 || pip3 install -q --break-system-packages flask waitress pywebpush icalendar recurring_ical_events
SEED=$(python3 tests/seed_demo.py) || { echo "seeding failed"; exit 1; }
echo "$SEED" > "$OUT/seed.json"
TOKEN=$(python3 -c "import json,sys;print(json.loads(sys.argv[1])['token'])" "$SEED")
SHARE=$(python3 -c "import json,sys;print(json.loads(sys.argv[1])['share'])" "$SEED")
(cd server && nohup python3 app.py > "$OUT/server.log" 2>&1 &)
sleep 3
curl -s -o /dev/null -w "server: %{http_code}\n" http://127.0.0.1:$PORT/api/me

# pick a recent iPhone simulator
UDID=$(xcrun simctl list devices available -j | python3 -c '
import json,sys
d=json.load(sys.stdin)["devices"]
best=None
for rt,devs in d.items():
    if "iOS" not in rt: continue
    v=tuple(int(x) for x in rt.split("iOS-")[-1].split("-") if x.isdigit())
    for dv in devs:
        if dv["name"].startswith("iPhone") and "Pro" in dv["name"] and "Max" not in dv["name"]:
            if best is None or v>best[0]: best=(v,dv["udid"],dv["name"])
print(best[1]); print(best[2]+" iOS "+".".join(map(str,best[0])),file=sys.stderr)')
echo "simulator: $UDID"
xcrun simctl boot "$UDID"; xcrun simctl bootstatus "$UDID" -b >/dev/null
xcrun simctl status_bar "$UDID" override --time "9:41" --batteryLevel 100 --cellularBars 4 2>/dev/null

set -o pipefail
xcodebuild -project ios/Pacely.xcodeproj -scheme Pacely -destination "id=$UDID" -configuration Debug \
  CODE_SIGNING_ALLOWED=NO -derivedDataPath dd build 2>&1 | grep -E "error:|BUILD (SUCCEEDED|FAILED)"
set +o pipefail
APP=$(ls -d dd/Build/Products/Debug-iphonesimulator/Pacely.app)
xcrun simctl install "$UDID" "$APP"

shot() { sleep "${2:-4}"; xcrun simctl io "$UDID" screenshot "$OUT/$1.png" >/dev/null 2>&1; echo "shot $1"; }
alive() { xcrun simctl spawn "$UDID" launchctl list 2>/dev/null | grep -q "UIKitApplication:$BUNDLE\[" && echo "  app running" || echo "  !! APP NOT RUNNING (crashed?)"; }
setd() { xcrun simctl spawn "$UDID" defaults write $BUNDLE "$@"; }
launch() { xcrun simctl terminate "$UDID" $BUNDLE >/dev/null 2>&1; xcrun simctl launch "$UDID" $BUNDLE >/dev/null; }
url() { xcrun simctl terminate "$UDID" $BUNDLE >/dev/null 2>&1; xcrun simctl launch "$UDID" $BUNDLE -pacelyOpen "$1" >/dev/null; }

# 0. the share link page Alex gets, in Safari (first, before anything else is on screen)
xcrun simctl openurl "$UDID" "http://127.0.0.1:$PORT/s/$SHARE"; shot 00-share-page-safari 12

# 1. first run: setup screen
launch; shot 01-setup 5; alive

# 2. signed in as the planner
setd server -string "http://127.0.0.1:$PORT"; setd token -string "$TOKEN"; setd pacely.mode -string Day
launch; shot 02-today 8; alive
ITEM=$(curl -s -H "Authorization: Bearer $TOKEN" "http://127.0.0.1:$PORT/api/day" | python3 -c 'import json,sys;print(next(i["id"] for i in json.load(sys.stdin)["items"] if "prescription" in i["title"]))')
url "pacely://item/$ITEM"; shot 03-detail-steps 7; alive
TOM=$(python3 -c "import datetime;print((datetime.date.today()+datetime.timedelta(days=1)).isoformat())")
url "pacely://day/$TOM"; shot 04-tomorrow-sick-day 7; alive
url "pacely://add"; shot 05-add 7; alive
url "pacely://todo"; shot 06-todo 6; alive
url "pacely://focus"; shot 07-focus 6; alive
url "pacely://routines"; shot 08-routines 6; alive
url "pacely://me"; shot 09-me 8; alive
xcrun simctl terminate "$UDID" $BUNDLE; setd pacely.mode -string Week; launch; sleep 5
echo "  saved view after relaunch: $(xcrun simctl spawn "$UDID" defaults read $BUNDLE pacely.mode 2>&1)"; shot 10a-week-remembered 2
url "pacely://week"; shot 10-week 7; alive
xcrun simctl terminate "$UDID" $BUNDLE; sleep 1; xcrun simctl launch "$UDID" $BUNDLE >/dev/null; shot 10b-week-after-restart 7
url "pacely://month"; shot 11-month 7; alive
xcrun simctl terminate "$UDID" $BUNDLE; setd pacely.mode -string Day
xcrun simctl ui "$UDID" appearance dark; launch; shot 12-today-dark 7; alive
# Calm layout (Me › Calm layout)
xcrun simctl terminate "$UDID" $BUNDLE; setd pacely.mode -string Day; setd pacely.calmLayout -bool YES; url "pacely://day/$(date +%F)"; shot 12a-calm-today 8; alive
url "pacely://me"; shot 12b-calm-me 7; alive
xcrun simctl terminate "$UDID" $BUNDLE; setd pacely.calmLayout -bool NO
xcrun simctl ui "$UDID" appearance light

# 3. partner mode (Alex)
setd token -string ""; setd partnerToken -string "$SHARE"
launch; shot 13-partner 7; alive


# Alex's page in Safari's engine
(npm install --no-save playwright@1.48.2 >/dev/null 2>&1 && npx playwright install webkit >/dev/null 2>&1 && \
  node tests/ui/share-page-webkit.js "http://127.0.0.1:$PORT/s/$SHARE" > "$OUT/share-page-webkit.txt" 2>&1; echo "webkit share page: $(cat "$OUT/share-page-webkit.txt")")

# what the app logged, in case something went wrong
xcrun simctl spawn "$UDID" log show --last 3m --predicate 'process == "Pacely"' --style compact 2>/dev/null | grep -iE "fault|fatal|crash|decod" | grep -v "XPCErrors\|xctest" | head -40 > "$OUT/app-errors.txt"
ls "$OUT"
