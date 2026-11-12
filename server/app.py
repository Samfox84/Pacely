#!/usr/bin/env python3
# Pacely - a calm, self-hosted visual day planner. No tracking, no third parties.
# By Sam Fox (Samfox84). Free and open source.
from html import escape
import os, re, sys, json, sqlite3, secrets, threading, hashlib, hmac, shutil
import time as _time
import datetime as dt
from contextlib import contextmanager
from zoneinfo import ZoneInfo
from functools import wraps
from flask import Flask, request, jsonify, send_from_directory, session, Response

BASE = os.path.dirname(os.path.abspath(__file__))
STATIC = os.path.join(BASE, 'static')
DATA = os.environ.get('PACELY_DATA', os.path.join(BASE, 'data'))
os.makedirs(DATA, exist_ok=True)
DB = os.path.join(DATA, 'pacely.db')
VAPID_PEM = os.path.join(DATA, 'vapid.pem')
def _system_tz():
    try:
        return open('/etc/timezone').read().strip() or 'UTC'
    except Exception:
        try:
            return os.path.realpath('/etc/localtime').split('zoneinfo/')[1]
        except Exception:
            return 'UTC'
TZ = ZoneInfo(os.environ.get('PACELY_TZ') or _system_tz())
CONTACT = os.environ.get('PACELY_CONTACT', 'mailto:admin@example.com')

@contextmanager
def db():
    c = sqlite3.connect(DB, timeout=15)
    c.row_factory = sqlite3.Row
    try:
        yield c
        c.commit()
    finally:
        c.close()

SCHEMA = """
CREATE TABLE IF NOT EXISTS settings(k TEXT PRIMARY KEY, v TEXT);
CREATE TABLE IF NOT EXISTS activities(
  id INTEGER PRIMARY KEY AUTOINCREMENT, kind TEXT DEFAULT 'event',
  title TEXT, emoji TEXT, color TEXT, date TEXT, start TEXT, duration INTEGER DEFAULT 30,
  notes TEXT DEFAULT '', steps TEXT DEFAULT '[]', done INTEGER DEFAULT 0, done_at TEXT,
  is_master INTEGER DEFAULT 0, master_id INTEGER, repeat TEXT DEFAULT '{"type":"none"}',
  remind INTEGER DEFAULT 0, end_alert INTEGER DEFAULT 1, deleted INTEGER DEFAULT 0,
  created TEXT);
CREATE INDEX IF NOT EXISTS ix_act_date ON activities(date);
CREATE INDEX IF NOT EXISTS ix_act_master ON activities(master_id, date);
CREATE TABLE IF NOT EXISTS routines(id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT, emoji TEXT, items TEXT DEFAULT '[]', sort INTEGER DEFAULT 0);
CREATE TABLE IF NOT EXISTS moods(id INTEGER PRIMARY KEY AUTOINCREMENT, ts TEXT, date TEXT, mood INTEGER, note TEXT DEFAULT '');
CREATE TABLE IF NOT EXISTS push_subs(endpoint TEXT PRIMARY KEY, json TEXT);
CREATE TABLE IF NOT EXISTS sent(activity_id INTEGER, kind TEXT, PRIMARY KEY(activity_id, kind));
CREATE TABLE IF NOT EXISTS calendars(id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT, url TEXT, color TEXT, emoji TEXT DEFAULT '📅',
  remind INTEGER DEFAULT 10, last_sync TEXT, error TEXT);
CREATE TABLE IF NOT EXISTS cal_events(id INTEGER PRIMARY KEY AUTOINCREMENT, cal_id INTEGER, uid TEXT, title TEXT, date TEXT,
  start TEXT, duration INTEGER, all_day INTEGER DEFAULT 0, location TEXT DEFAULT '');
CREATE INDEX IF NOT EXISTS ix_cal_date ON cal_events(date);
CREATE TABLE IF NOT EXISTS focus_log(id INTEGER PRIMARY KEY AUTOINCREMENT, ts TEXT, date TEXT, minutes INTEGER, title TEXT);
CREATE TABLE IF NOT EXISTS reviews(date TEXT PRIMARY KEY, well TEXT, hard TEXT, tomorrow TEXT, ts TEXT);
CREATE TABLE IF NOT EXISTS commute(date TEXT PRIMARY KEY, json TEXT);
CREATE TABLE IF NOT EXISTS shares(token TEXT PRIMARY KEY, name TEXT, see TEXT DEFAULT 'all', created TEXT, last_used TEXT);
"""

MIGRATIONS = [("activities", "priority", "TEXT DEFAULT 'soon'"), ("moods", "energy", "INTEGER"),
              ("activities", "allday", "TEXT DEFAULT ''"), ("activities", "added_by", "TEXT DEFAULT ''"),
              ("activities", "private", "INTEGER DEFAULT 0"), ("activities", "nag", "INTEGER DEFAULT 0"),
              ("shares", "invite", "TEXT"), ("shares", "invite_expires", "TEXT"), ("shares", "web", "INTEGER DEFAULT 1"),
              ("shares", "joined", "TEXT"), ("shares", "device", "TEXT"),
              ("activities", "location", "TEXT DEFAULT ''"), ("activities", "link", "TEXT DEFAULT ''"), ("activities", "leave", "TEXT"),
              ("activities", "travel_min", "INTEGER"), ("activities", "travel_by", "TEXT"),
              ("calendars", "hours_from", "TEXT DEFAULT ''"), ("calendars", "hours_to", "TEXT DEFAULT ''"),
              ("calendars", "hide_repeats", "INTEGER DEFAULT 0"), ("calendars", "hide_dupes", "INTEGER DEFAULT 1"),
              ("cal_events", "repeats", "INTEGER DEFAULT 0")]
ALLDAY_TYPES = ('day', 'off', 'sick', 'holiday', 'office', 'home')   # 'off', 'sick' and 'holiday' are quiet days: no reminders
QUIET = ('off', 'sick', 'holiday')

# ---------- smart emoji (same rules as static/smart.js) ----------
def _load_rules():
    import re as _re
    try:
        src = open(os.path.join(STATIC, 'smart.js'), encoding='utf-8').read()
        rules = json.loads(src.split('/*RULES*/', 1)[1].split('/*END*/', 1)[0])
        return [(_re.compile(r'(^|[^a-z])(' + '|'.join(_re.escape(w) for w in words.split('|')) + ')', _re.I), e, col)
                for words, e, col in rules]
    except Exception as e:
        print('smart rules not loaded', e)
        return []
SMART = _load_rules()

def guess(title):
    t = ' ' + str(title or '').lower() + ' '
    for rx, e, col in SMART:
        if rx.search(t):
            return e, col
    return None

SEED_ROUTINES = [
    ("Morning", "🌅", [
        {"title": "Get up", "emoji": "🛏️", "color": "#F6C453", "duration": 5, "steps": ["Curtains open", "Glass of water"]},
        {"title": "Shower", "emoji": "🚿", "color": "#7CB8F0", "duration": 15, "steps": ["Towel ready", "Wash", "Dry off"]},
        {"title": "Get dressed", "emoji": "👕", "color": "#B89AE8", "duration": 10, "steps": []},
        {"title": "Breakfast", "emoji": "🥣", "color": "#F4A07A", "duration": 20, "steps": []},
        {"title": "Pack bag", "emoji": "🎒", "color": "#73CBA8", "duration": 5, "steps": ["Keys", "Phone", "Wallet", "Headphones"]},
    ]),
    ("Start work", "☕", [
        {"title": "Make a drink", "emoji": "☕", "color": "#D9B99B", "duration": 5, "steps": []},
        {"title": "Check inbox", "emoji": "📧", "color": "#7CB8F0", "duration": 15, "steps": []},
        {"title": "Pick top 3 jobs", "emoji": "🗒️", "color": "#73CBA8", "duration": 10, "steps": ["Job 1", "Job 2", "Job 3"]},
    ]),
    ("Wind down", "🌙", [
        {"title": "Screens away", "emoji": "📵", "color": "#9AA8BA", "duration": 5, "steps": []},
        {"title": "Teeth", "emoji": "🦷", "color": "#7CB8F0", "duration": 5, "steps": []},
        {"title": "Read", "emoji": "📚", "color": "#B89AE8", "duration": 20, "steps": []},
        {"title": "Lights out", "emoji": "💤", "color": "#9AA8BA", "duration": 5, "steps": []},
    ]),
]

def sget(c, k, default=None):
    r = c.execute("SELECT v FROM settings WHERE k=?", (k,)).fetchone()
    return r['v'] if r else default

def sset(c, k, v):
    c.execute("INSERT INTO settings(k,v) VALUES(?,?) ON CONFLICT(k) DO UPDATE SET v=excluded.v", (k, v))

def hash_pw(pw, salt=None):
    salt = salt or secrets.token_hex(16)
    h = hashlib.pbkdf2_hmac('sha256', pw.encode(), salt.encode(), 200000).hex()
    return f"{salt}${h}"

def check_pw(pw, stored):
    try:
        salt, _ = stored.split('$', 1)
        return hmac.compare_digest(hash_pw(pw, salt), stored)
    except Exception:
        return False

def new_password():
    words = ["calm", "tide", "moss", "fern", "amber", "pebble", "cloud", "maple", "river", "lantern", "harbor", "willow", "cedar", "meadow", "comet", "otter"]
    return "-".join(secrets.choice(words) for _ in range(3)) + "-" + str(secrets.randbelow(90) + 10)

def ensure_vapid():
    if os.path.exists(VAPID_PEM):
        return
    from cryptography.hazmat.primitives.asymmetric import ec
    from cryptography.hazmat.primitives import serialization
    key = ec.generate_private_key(ec.SECP256R1())
    pem = key.private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8, serialization.NoEncryption())
    with open(VAPID_PEM, 'wb') as f:
        f.write(pem)
    os.chmod(VAPID_PEM, 0o600)

def vapid_public():
    import base64
    from cryptography.hazmat.primitives import serialization
    with open(VAPID_PEM, 'rb') as f:
        key = serialization.load_pem_private_key(f.read(), None)
    raw = key.public_key().public_bytes(serialization.Encoding.X962, serialization.PublicFormat.UncompressedPoint)
    return base64.urlsafe_b64encode(raw).decode().rstrip('=')

def init(print_pw=True):
    """Create database. Returns new password if one was made."""
    pw = None
    with db() as c:
        c.executescript(SCHEMA)
        for table, col, decl in MIGRATIONS:
            cols = {r['name'] for r in c.execute(f"PRAGMA table_info({table})")}
            if col not in cols:
                c.execute(f"ALTER TABLE {table} ADD COLUMN {col} {decl}")
        # one copy per repeating activity per day (two screens loading at once could make two)
        dups = c.execute("""SELECT master_id, date FROM activities WHERE master_id IS NOT NULL
                             GROUP BY master_id, date HAVING COUNT(*) > 1""").fetchall()
        for d in dups:
            rs = c.execute("""SELECT id FROM activities WHERE master_id=? AND date=?
                              ORDER BY done DESC, deleted ASC, id ASC""", (d['master_id'], d['date'])).fetchall()
            c.executemany("DELETE FROM activities WHERE id=?", [(r['id'],) for r in rs[1:]])
        c.execute("CREATE UNIQUE INDEX IF NOT EXISTS ux_master_day ON activities(master_id, date) WHERE master_id IS NOT NULL")
        if not sget(c, 'calrules_v1'):
            # A linked work calendar usually has focus-time and out-of-office blocks every day: start it off tidy
            c.execute("""UPDATE calendars SET hours_from='09:00', hours_to='15:30', hide_repeats=1, hide_dupes=1
                         WHERE lower(name) LIKE '%work%' OR lower(name) LIKE '%outlook%' OR lower(name) LIKE '%office%'""")
            sset(c, 'calrules_v1', '1')
        # A change counter for live sync: any change to plans or routines, from anyone (you, a partner,
        # the AI helper, calendar sync, auto-tick), bumps it, and every open screen refreshes.
        c.execute("CREATE TABLE IF NOT EXISTS sync_seq(id INTEGER PRIMARY KEY CHECK (id=1), v INTEGER)")
        c.execute("INSERT OR IGNORE INTO sync_seq(id, v) VALUES (1, 1)")
        for t in ('activities', 'routines', 'cal_events', 'commute'):
            for ev in ('INSERT', 'UPDATE', 'DELETE'):
                c.execute(f"CREATE TRIGGER IF NOT EXISTS sync_{t}_{ev.lower()} AFTER {ev} ON {t} BEGIN UPDATE sync_seq SET v=v+1 WHERE id=1; END")
        for k in ('api_token', 'read_token'):
            if not sget(c, k):
                sset(c, k, secrets.token_urlsafe(24))
        if not sget(c, 'secret'):
            sset(c, 'secret', secrets.token_hex(32))
        if not sget(c, 'pw'):
            pw = new_password()
            sset(c, 'pw', hash_pw(pw))
        if not sget(c, 'smart_fixed'):
            for r in c.execute("SELECT id, title, start, kind FROM activities WHERE emoji='📝' OR emoji IS NULL OR emoji=''").fetchall():
                g = guess(r['title'])
                if g:
                    c.execute("UPDATE activities SET emoji=?, color=? WHERE id=?", (g[0], g[1], r['id']))
            for r in c.execute("SELECT id, title FROM activities WHERE kind='event' AND (start IS NULL OR start='') AND (allday IS NULL OR allday='')").fetchall():
                t = (r['title'] or '').lower()
                kind = 'sick' if any(w in t for w in ('sick', 'medical', 'unwell', 'poorly')) else \
                       'off' if any(w in t for w in ('day off', 'annual leave', 'holiday', 'time off')) else ''
                if kind:
                    c.execute("UPDATE activities SET allday=? WHERE id=?", (kind, r['id']))
            sset(c, 'smart_fixed', '1')
        if not sget(c, 'seeded'):
            for i, (n, e, items) in enumerate(SEED_ROUTINES):
                c.execute("INSERT INTO routines(name,emoji,items,sort) VALUES(?,?,?,?)", (n, e, json.dumps(items), i))
            sset(c, 'seeded', '1')
    ensure_vapid()
    return pw

# ---------- helpers ----------
def now():
    return dt.datetime.now(TZ)

def today():
    return now().date().isoformat()

def row(r):
    d = dict(r)
    for k in ('steps', 'repeat', 'items'):
        if k in d and isinstance(d[k], str):
            try:
                d[k] = json.loads(d[k])
            except Exception:
                d[k] = [] if k != 'repeat' else {"type": "none"}
    return d

def rule_matches(rule, d, start):
    if d < start:
        return False
    t = (rule or {}).get('type', 'none')
    if t == 'daily':
        return True
    if t == 'weekdays':
        return d.weekday() < 5
    if t == 'days':
        return d.weekday() in (rule.get('days') or [])
    return False

COPY = ('kind', 'title', 'emoji', 'color', 'start', 'duration', 'notes', 'remind', 'end_alert', 'repeat', 'allday', 'private', 'nag',
        'location', 'link', 'leave', 'travel_min', 'travel_by')

def materialize(c, date):
    d = dt.date.fromisoformat(date)
    masters = c.execute("SELECT * FROM activities WHERE is_master=1 AND deleted=0").fetchall()
    for m in masters:
        try:
            rule = json.loads(m['repeat'] or '{}')
            start = dt.date.fromisoformat(m['date'])
        except Exception:
            continue
        if not rule_matches(rule, d, start):
            continue
        if c.execute("SELECT 1 FROM activities WHERE master_id=? AND date=?", (m['id'], date)).fetchone():
            continue
        steps = [dict(s, d=False) for s in json.loads(m['steps'] or '[]')]
        c.execute("""INSERT OR IGNORE INTO activities(kind,title,emoji,color,date,start,duration,notes,steps,remind,end_alert,repeat,master_id,created,priority,allday,added_by,private,nag,
                     location,link,leave,travel_min,travel_by)
                     VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)""",
                  (m['kind'], m['title'], m['emoji'], m['color'], date, m['start'], m['duration'], m['notes'],
                   json.dumps(steps), m['remind'], m['end_alert'], m['repeat'], m['id'], now().isoformat(), m['priority'] or 'soon',
                   m['allday'] or '', m['added_by'] or '', m['private'] or 0, m['nag'] or 0,
                   m['location'] or '', m['link'] or '', m['leave'], m['travel_min'], m['travel_by']))

def valid_date(s):
    """A YYYY-MM-DD date from a request, or today if it's missing or not a real date."""
    try:
        return dt.date.fromisoformat(str(s)).isoformat() if s else today()
    except ValueError:
        return today()

def quiet_day(c, date):
    """A day off, sick day or holiday: reminders stay quiet."""
    materialize(c, date)
    r = c.execute(f"""SELECT allday FROM activities WHERE date=? AND kind='event' AND deleted=0 AND is_master=0
                      AND allday IN ({','.join('?' * len(QUIET))}) LIMIT 1""", (date, *QUIET)).fetchone()
    return r['allday'] if r else ''

def auto_tick(c, upto=None):
    """Repeating activities tick themselves off once they're over (can be switched off in Me)."""
    if sget(c, 'auto_tick', '1') != '1':
        return
    n = upto or now()
    td = n.date().isoformat()
    since = (n.date() - dt.timedelta(days=3)).isoformat()
    for r in c.execute("""SELECT id, date, start, duration FROM activities WHERE master_id IS NOT NULL AND done=0 AND deleted=0
                          AND is_master=0 AND kind='event' AND start IS NOT NULL AND (allday IS NULL OR allday='')
                          AND date BETWEEN ? AND ?""", (since, td)).fetchall():
        try:
            h, m = map(int, r['start'].split(':'))
            en = dt.datetime.combine(dt.date.fromisoformat(r['date']), dt.time(h, m), TZ) + dt.timedelta(minutes=r['duration'] or 0)
        except Exception:
            continue
        if en <= n:
            c.execute("UPDATE activities SET done=1, done_at=? WHERE id=?", (en.isoformat(), r['id']))

def clean_steps(steps):
    out = []
    for s in steps or []:
        if isinstance(s, str):
            s = {"t": s, "d": False}
        t = str(s.get("t", "")).strip()[:200]
        if t:
            st = {"t": t, "d": bool(s.get("d"))}
            try:
                m = int(s.get("m") or 0)
                if 0 < m <= 600: st["m"] = m
            except Exception:
                pass
            out.append(st)
    return out

def norm(data):
    """Normalise incoming activity fields; only keys present are returned."""
    out = {}
    if 'title' in data: out['title'] = (str(data['title']).strip() or 'Untitled')[:200]
    if 'emoji' in data: out['emoji'] = str(data['emoji'])[:16] or '📝'
    if 'color' in data: out['color'] = str(data['color'])[:16]
    if 'date' in data: out['date'] = data['date'] or None
    if 'start' in data: out['start'] = data['start'] or None
    if 'duration' in data: out['duration'] = max(1, min(1440, int(data['duration'] or 30)))
    if 'notes' in data: out['notes'] = str(data['notes'] or '')[:5000]
    if 'steps' in data: out['steps'] = json.dumps(clean_steps(data['steps']))
    if 'done' in data:
        out['done'] = 1 if data['done'] else 0
        out['done_at'] = now().isoformat() if data['done'] else None
    if 'remind' in data: out['remind'] = int(data['remind'])
    if 'end_alert' in data: out['end_alert'] = 1 if data['end_alert'] else 0
    if 'private' in data:
        out['private'] = 1 if data['private'] else 0
    if 'nag' in data:
        out['nag'] = 1 if data['nag'] else 0
    if 'allday' in data:
        out['allday'] = data['allday'] if data['allday'] in ALLDAY_TYPES else ''
        if out['allday']: out['start'] = None
    if 'kind' in data: out['kind'] = 'todo' if data['kind'] == 'todo' else 'event'
    if 'location' in data: out['location'] = str(data['location'] or '').strip()[:200]
    if 'link' in data:
        l = str(data['link'] or '').strip()[:400]
        out['link'] = l if re.fullmatch(r'https?://[^\s"<>]+', l) else ''
    if 'leave' in data: out['leave'] = data['leave'] if re.fullmatch(r'([01]\d|2[0-3]):[0-5]\d', str(data['leave'] or '')) else None
    if 'travel_min' in data:
        try: out['travel_min'] = max(0, min(600, int(data['travel_min']))) if data['travel_min'] else None
        except (TypeError, ValueError): out['travel_min'] = None
    if 'travel_by' in data: out['travel_by'] = data['travel_by'] if data['travel_by'] in ('car', 'transit', 'walk', 'bike') else None
    if 'priority' in data: out['priority'] = data['priority'] if data['priority'] in ('now', 'soon', 'later') else 'soon'
    if 'repeat' in data:
        r = data['repeat'] or {"type": "none"}
        t = r.get('type', 'none')
        if t not in ('none', 'daily', 'weekdays', 'days'): t = 'none'
        days = sorted({int(x) for x in (r.get('days') or []) if 0 <= int(x) <= 6})
        if t == 'days' and not days: t = 'none'
        out['repeat'] = json.dumps({"type": t, "days": days})
    return out

def update(c, id_, fields):
    if not fields: return
    moved_from = None
    if 'date' in fields:
        a = c.execute("SELECT master_id, date FROM activities WHERE id=?", (id_,)).fetchone()
        if a and a['master_id'] and fields['date'] != a['date']:
            # a repeat copy moved to another day stands on its own; a hidden marker stops a new copy appearing in its old place
            moved_from = (a['master_id'], a['date'])
            fields = dict(fields, master_id=None)
    if fields.get('start') and 'leave' not in fields:
        a = c.execute("SELECT travel_min FROM activities WHERE id=?", (id_,)).fetchone()
        if a and a['travel_min']:
            try:
                buf = int(sget(c, 'travel_buffer', '10') or 10)
                h, m = map(int, fields['start'].split(':'))
                fields = dict(fields, leave=(dt.datetime(2000, 1, 1, h, m) - dt.timedelta(minutes=a['travel_min'] + buf)).strftime('%H:%M'))
            except Exception:
                pass
    keys = list(fields)
    c.execute(f"UPDATE activities SET {', '.join(k + '=?' for k in keys)} WHERE id=?", [fields[k] for k in keys] + [id_])
    if moved_from:
        c.execute("INSERT OR IGNORE INTO activities(kind,title,date,master_id,deleted,is_master,created) VALUES('event','(moved)',?,?,1,0,?)",
                  (moved_from[1], moved_from[0], now().isoformat()))
    if any(k in fields for k in ('start', 'duration', 'remind', 'date', 'done')):
        c.execute("DELETE FROM sent WHERE activity_id=?", (id_,))

def is_repeating(rep_json):
    try: return json.loads(rep_json or '{}').get('type', 'none') != 'none'
    except Exception: return False

# ---------- push ----------
def push_all(title, body, tag='pacely', url='/'):
    try:
        from pywebpush import webpush, WebPushException
    except Exception as e:
        print('pywebpush missing', e); return 0
    sent_n = 0
    with db() as c:
        subs = c.execute("SELECT * FROM push_subs").fetchall()
    for s in subs:
        try:
            webpush(subscription_info=json.loads(s['json']),
                    data=json.dumps({"title": title, "body": body, "tag": tag, "url": url}),
                    vapid_private_key=VAPID_PEM, vapid_claims={"sub": CONTACT}, ttl=900)
            sent_n += 1
        except WebPushException as e:
            code = getattr(e.response, 'status_code', None)
            print('push failed', code, e)
            if code in (403, 404, 410):
                with db() as c:
                    c.execute("DELETE FROM push_subs WHERE endpoint=?", (s['endpoint'],))
        except Exception as e:
            print('push error', e)
    return sent_n

def in_quiet_hours(c, when):
    """Quiet hours (Me › Settings): no notifications between these times, e.g. 20:00 to 07:00."""
    f, t = sget(c, 'quiet_from', ''), sget(c, 'quiet_to', '')
    if not (f and t):
        return False
    hm = when.strftime('%H:%M')
    return (f <= hm < t) if f < t else (hm >= f or hm < t)

def check_reminders():
    n = now()
    td = n.date().isoformat()
    todo = []
    with db() as c:
        materialize(c, td)
        auto_tick(c, n)
        quiet = quiet_day(c, td)
        rows = [] if quiet else c.execute("""SELECT * FROM activities WHERE date=? AND kind='event' AND deleted=0 AND is_master=0
                            AND start IS NOT NULL AND done=0""", (td,)).fetchall()
        for r in rows:
            try:
                h, m = map(int, r['start'].split(':'))
            except Exception:
                continue
            st = dt.datetime.combine(n.date(), dt.time(h, m), TZ)
            en = st + dt.timedelta(minutes=r['duration'] or 0)
            label = f"{r['emoji'] or ''} {r['title']}".strip()
            ev = []
            if r['remind'] is not None and r['remind'] > 0:
                ev.append(('before', st - dt.timedelta(minutes=r['remind']), label, f"In {r['remind']} minutes, at {r['start']}."))
            if r['remind'] is not None and r['remind'] >= 0:
                ev.append(('start', st, label, "Starting about now."))
            if r['end_alert'] and (r['duration'] or 0) >= 10:
                ev.append(('end', en - dt.timedelta(minutes=5), label, "About 5 minutes left."))
            if r['leave']:
                try:
                    lv = at(td, r['leave'])
                    how = {'transit': 'by public transport', 'car': 'drive'}.get(r['travel_by'] or '', '')
                    trip = f" · {r['travel_min']} min {how}".rstrip() if r['travel_min'] else ''
                    if sget(c, 'leave_style', 'gentle') == 'countdown':
                        for mins in (20, 10, 5):
                            ev.append((f'leave{mins}', lv - dt.timedelta(minutes=mins), f"Leave in {mins} minutes", f"{label}{trip}"))
                        ev.append(('leave', lv, "Time to leave", f"{label}{trip}"))
                    else:
                        ev.append(('leave15', lv - dt.timedelta(minutes=15), f"Heads up: leave around {r['leave']}", f"{label}{trip}. No rush."))
                except Exception:
                    pass
            if r['nag']:
                for k in (1, 2, 3):
                    ev.append((f'nag{k}', st + dt.timedelta(minutes=10 * k), label, "Still here whenever you're ready."))
            for kind, when, title, body in ev:
                if when <= n < when + dt.timedelta(minutes=10):
                    if not c.execute("SELECT 1 FROM sent WHERE activity_id=? AND kind=?", (r['id'], kind)).fetchone():
                        c.execute("INSERT OR IGNORE INTO sent VALUES(?,?)", (r['id'], kind))
                        todo.append((title, body, f"a{r['id']}{kind}"))
        for e in cal_rows(c, td, "AND e.all_day=0 AND e.start IS NOT NULL"):
            h, m = map(int, e['start'].split(':'))
            st = dt.datetime.combine(n.date(), dt.time(h, m), TZ)
            evs = []
            if e['remind'] and e['remind'] > 0:
                evs.append(('before', st - dt.timedelta(minutes=e['remind']), f"Coming up in {e['remind']} min"))
            evs.append(('start', st, "Starting now"))
            for kind, when, title in evs:
                if when <= n < when + dt.timedelta(minutes=10):
                    if not c.execute("SELECT 1 FROM sent WHERE activity_id=? AND kind=?", (-e['id'], kind)).fetchone():
                        c.execute("INSERT OR IGNORE INTO sent VALUES(?,?)", (-e['id'], kind))
                        todo.append((title, f"📅 {e['title']}", f"c{e['id']}{kind}"))
        for key, t, title, body in nudge_list(c):
            when = at(td, t)
            if when <= n < when + dt.timedelta(minutes=10) and not in_quiet_hours(c, when) and not c.execute("SELECT 1 FROM sent WHERE activity_id=0 AND kind=?", (f"n{td}{key}{t}",)).fetchone():
                c.execute("INSERT OR IGNORE INTO sent VALUES(0,?)", (f"n{td}{key}{t}",))
                todo.append((title, body, f"n{key}"))
        for it in commute_items(c, td):
            st = at(td, it['start'])
            what = it['title']
            plan = ([(f'c{m}', st - dt.timedelta(minutes=m), f"{it['emoji']} {what} in {m} minutes") for m in (20, 10, 5)] +
                    [('c0', st, f"{it['emoji']} Time to {what.lower()}")]) if sget(c, 'leave_style', 'gentle') == 'countdown' else \
                   [('c15', st - dt.timedelta(minutes=15), f"{it['emoji']} Heads up: {what.lower()} around {it['start']}")]
            for kind, when, ttl in plan:
                k = f"commute{td}{it['id']}{kind}{it['start']}"
                if when <= n < when + dt.timedelta(minutes=10) and not c.execute("SELECT 1 FROM sent WHERE activity_id=0 AND kind=?", (k,)).fetchone():
                    c.execute("INSERT OR IGNORE INTO sent VALUES(0,?)", (k,))
                    todo.append((ttl, it['summary'] or 'No rush.', 'commute'))
        f = sget(c, 'focus')
        if f:
            try:
                fj = json.loads(f)
                end = dt.datetime.fromtimestamp(fj['end'] / 1000, TZ)
                if n >= end:
                    sset(c, 'focus', '')
                    if n < end + dt.timedelta(minutes=10):
                        todo.append(("Focus time is up", fj.get('title') or 'Nice work. Take a breath.', 'focus'))
            except Exception:
                sset(c, 'focus', '')
    with db() as c:
        hush = in_quiet_hours(c, n)
    for t in todo:
        if hush and t[2] != 'focus':      # quiet hours: only a focus timer you started yourself can make a sound
            continue
        push_all(*t)

def scheduler():
    last_cal = 0
    while True:
        try:
            check_reminders()
        except Exception as e:
            print('scheduler error', e)
        try:
            commute_check()
        except Exception as e:
            print('commute check error', e)
        if _time.time() - last_cal > 900:
            last_cal = _time.time()
            try:
                sync_calendars()
            except Exception as e:
                print('calendar sync error', e)
        _time.sleep(20)

# ---------- app ----------
app = Flask(__name__, static_folder=None)
fails = {}

def token_ok(kind='api_token'):
    h = request.headers.get('Authorization', '')
    tok = h[7:].strip() if h.startswith('Bearer ') else ''
    if not tok:
        return False
    with db() as c:
        good = sget(c, kind, '')
    return bool(good) and hmac.compare_digest(tok, good)

def auth(f):
    @wraps(f)
    def w(*a, **k):
        if not session.get('ok') and not token_ok():
            return jsonify(error='login'), 401
        return f(*a, **k)
    return w

def client_ip():
    return request.headers.get('CF-Connecting-IP') or request.remote_addr or '?'

@app.after_request
def headers(r):
    r.headers['X-Content-Type-Options'] = 'nosniff'
    r.headers['Referrer-Policy'] = 'no-referrer'
    r.headers['X-Frame-Options'] = 'DENY'
    if request.path.startswith('/api/'):
        r.headers['Cache-Control'] = 'no-store'
    return r

@app.post('/api/login')
def login():
    ip = client_ip()
    cnt, until = fails.get(ip, (0, 0))
    if _time.time() < until:
        return jsonify(error=f"Too many tries. Wait {int(until - _time.time())}s"), 429
    pw = (request.json or {}).get('password', '')
    with db() as c:
        ok = check_pw(pw, sget(c, 'pw', ''))
    if not ok:
        cnt += 1
        fails[ip] = (0, _time.time() + 60) if cnt >= 5 else (cnt, 0)
        return jsonify(error='Wrong password'), 403
    fails.pop(ip, None)
    session.permanent = True
    session['ok'] = True
    return jsonify(ok=True)

@app.post('/api/logout')
def logout():
    session.clear()
    return jsonify(ok=True)

@app.get('/api/me')
@auth
def me():
    with db() as c:
        theme = sget(c, 'theme', 'auto')
        subs = c.execute("SELECT COUNT(*) n FROM push_subs").fetchone()['n']
        auto = sget(c, 'auto_tick', '1') == '1'
        my_name = sget(c, 'my_name', '')
        numbers = json.loads(sget(c, 'numbers', '[]') or '[]')
        travel = travel_prefs(c)
        try:
            nudges = json.loads(sget(c, 'nudges', '{}') or '{}')
        except Exception:
            nudges = {}
    with db() as c:
        quiet = {"from": sget(c, 'quiet_from', ''), "to": sget(c, 'quiet_to', '')}
    return jsonify(numbers=numbers, travel=travel, quiet=quiet, nudges={k: bool(nudges.get(k)) for k in ('drink', 'eat', 'rest')}, ok=True, vapid=vapid_public(), theme=theme, subs=subs, today=today(), now=now().strftime('%H:%M'),
                   auto_tick=auto, my_name=my_name, features=['merge', 'allday', 'share', 'smart', 'leftovers', 'numbers', 'summary', 'sync', 'travel', 'nudges', 'smartevent', 'quiet'])

@app.get('/api/day')
@auth
def day():
    date = valid_date(request.args.get('date'))
    dt.date.fromisoformat(date)
    with db() as c:
        materialize(c, date)
        auto_tick(c)
        rows = c.execute("""SELECT * FROM activities WHERE date=? AND kind='event' AND deleted=0 AND is_master=0
                            ORDER BY start IS NULL, start, id""", (date,)).fetchall()
        moods = c.execute("SELECT * FROM moods WHERE date=? ORDER BY ts", (date,)).fetchall()
        cal = cal_items(c, date)
        review = c.execute("SELECT * FROM reviews WHERE date=?", (date,)).fetchone()
        commute = commute_get(c, date)
    mine = [row(r) for r in rows]
    items = [x for x in mine if not x.get('allday')] + [x for x in cal if not x['all_day']]
    items.sort(key=lambda x: (x['start'] is None, x['start'] or '', str(x['id'])))
    allday = [x for x in mine if x.get('allday')] + [x for x in cal if x['all_day']]
    quiet = next((x['allday'] for x in mine if x.get('allday') in QUIET), '')
    return jsonify(date=date, items=items, allday=allday, quiet=quiet, moods=[dict(m) for m in moods],
                   review=dict(review) if review else None, commute=commute)

@app.get('/api/week')
@auth
def week():
    start = dt.date.fromisoformat(valid_date(request.args.get('start')))
    out = {}
    with db() as c:
        for i in range(7):
            d = (start + dt.timedelta(days=i)).isoformat()
            materialize(c, d)
            r = c.execute("""SELECT COUNT(*) n, COALESCE(SUM(done),0) dn FROM activities WHERE date=? AND kind='event'
                             AND deleted=0 AND is_master=0 AND (allday IS NULL OR allday='')""", (d,)).fetchone()
            items = c.execute("""SELECT title, emoji, color, start, duration, done, allday FROM activities WHERE date=? AND kind='event'
                                 AND deleted=0 AND is_master=0 ORDER BY start IS NULL, start""", (d,)).fetchall()
            out[d] = {"n": r['n'], "done": r['dn'], "items": [dict(x) for x in items] + [
                {"title": x['title'], "emoji": x['emoji'], "color": x['color'], "start": x['start'], "duration": x['duration'], "done": 0, "cal": 1}
                for x in cal_items(c, d)]}
    return jsonify(out)

@app.get('/api/todos')
@auth
def todos():
    with db() as c:
        rows = c.execute("SELECT * FROM activities WHERE kind='todo' AND deleted=0 ORDER BY done, id DESC").fetchall()
    return jsonify([row(r) for r in rows])

@app.post('/api/activities')
@auth
def create():
    data = request.json or {}
    f = norm(data)
    f.setdefault('kind', 'event'); f.setdefault('title', 'Untitled')
    if f.get('emoji', '📝') == '📝':
        g = guess(f['title'])
        if g:
            f['emoji'] = g[0]
            if not data.get('color') or data.get('color') == '#7CB8F0':
                f['color'] = g[1]
    f.setdefault('emoji', '📝')
    f.setdefault('color', '#7CB8F0'); f.setdefault('duration', 30); f.setdefault('steps', '[]')
    f.setdefault('repeat', '{"type": "none"}'); f.setdefault('remind', 0); f.setdefault('end_alert', 1)
    if f['kind'] == 'event' and not f.get('date'):
        f['date'] = today()
    f['created'] = now().isoformat()
    with db() as c:
        if f['kind'] == 'event' and is_repeating(f['repeat']):
            mf = dict(f, is_master=1)
            keys = list(mf)
            cur = c.execute(f"INSERT INTO activities({','.join(keys)}) VALUES({','.join('?' * len(keys))})", [mf[k] for k in keys])
            mid = cur.lastrowid
            materialize(c, f['date'])
            r = c.execute("SELECT * FROM activities WHERE master_id=? AND date=?", (mid, f['date'])).fetchone()
            if r is None:  # start date does not match rule; still return master
                r = c.execute("SELECT * FROM activities WHERE id=?", (mid,)).fetchone()
        else:
            f['repeat'] = '{"type": "none"}'
            keys = list(f)
            cur = c.execute(f"INSERT INTO activities({','.join(keys)}) VALUES({','.join('?' * len(keys))})", [f[k] for k in keys])
            r = c.execute("SELECT * FROM activities WHERE id=?", (cur.lastrowid,)).fetchone()
    return jsonify(row(r))

DEF_KEYS = ('title', 'emoji', 'color', 'start', 'duration', 'notes', 'remind', 'end_alert', 'priority', 'allday', 'private', 'nag',
            'location', 'link', 'leave', 'travel_min', 'travel_by')

@app.put('/api/activities/<int:id_>')
@auth
def edit(id_):
    data = request.json or {}
    scope = data.pop('scope', 'this')
    f = norm(data)
    with db() as c:
        a = c.execute("SELECT * FROM activities WHERE id=?", (id_,)).fetchone()
        if not a:
            return jsonify(error='not found'), 404
        new_rep = f.pop('repeat', None)
        update(c, id_, f)
        a = c.execute("SELECT * FROM activities WHERE id=?", (id_,)).fetchone()
        mid = a['master_id']
        if a['kind'] == 'event':
            if mid and scope == 'all':
                if new_rep is not None and not is_repeating(new_rep):
                    # stop repeating: end master, remove future undone copies, detach this one
                    c.execute("UPDATE activities SET deleted=1 WHERE id=?", (mid,))
                    c.execute("UPDATE activities SET deleted=1 WHERE master_id=? AND date>? AND done=0", (mid, a['date']))
                    c.execute("UPDATE activities SET master_id=NULL, repeat=? WHERE id=?", (new_rep, id_))
                else:
                    mf = {k: f[k] for k in DEF_KEYS if k in f}
                    if 'steps' in f:
                        mf['steps'] = json.dumps([dict(s, d=False) for s in json.loads(f['steps'])])
                    if new_rep is not None:
                        mf['repeat'] = new_rep
                        # rule changed: future copies are regenerated from the new rule
                        c.execute("DELETE FROM activities WHERE master_id=? AND date>? AND done=0", (mid, a['date']))
                        c.execute("UPDATE activities SET repeat=? WHERE id=?", (new_rep, id_))
                    update(c, mid, mf)
                    fut = c.execute("SELECT id FROM activities WHERE master_id=? AND date>? AND done=0 AND deleted=0", (mid, a['date'])).fetchall()
                    for r in fut:
                        update(c, r['id'], mf)
            elif not mid and new_rep is not None and is_repeating(new_rep):
                # turn a one-off into a repeating series starting today
                keys = ['kind', 'title', 'emoji', 'color', 'date', 'start', 'duration', 'notes', 'remind', 'end_alert', 'allday']
                vals = [a[k] for k in keys]
                steps = json.dumps([dict(s, d=False) for s in json.loads(a['steps'] or '[]')])
                cur = c.execute(f"INSERT INTO activities({','.join(keys)},steps,repeat,is_master,created) VALUES({','.join('?' * len(keys))},?,?,1,?)",
                                vals + [steps, new_rep, now().isoformat()])
                c.execute("UPDATE activities SET master_id=?, repeat=? WHERE id=?", (cur.lastrowid, new_rep, id_))
        a = c.execute("SELECT * FROM activities WHERE id=?", (id_,)).fetchone()
    return jsonify(row(a))

@app.delete('/api/activities/<int:id_>')
@auth
def delete(id_):
    scope = request.args.get('scope', 'this')
    with db() as c:
        a = c.execute("SELECT * FROM activities WHERE id=?", (id_,)).fetchone()
        if not a:
            return jsonify(ok=True)
        c.execute("UPDATE activities SET deleted=1 WHERE id=?", (id_,))
        if scope == 'all' and a['master_id']:
            c.execute("UPDATE activities SET deleted=1 WHERE id=?", (a['master_id'],))
            c.execute("UPDATE activities SET deleted=1 WHERE master_id=? AND date>=? AND done=0", (a['master_id'], a['date']))
    return jsonify(ok=True)

@app.post('/api/todos/clear')
@auth
def clear_done():
    with db() as c:
        c.execute("UPDATE activities SET deleted=1 WHERE kind='todo' AND done=1")
    return jsonify(ok=True)

# routines
@app.get('/api/routines')
@auth
def routines():
    with db() as c:
        rows = c.execute("SELECT * FROM routines ORDER BY sort, id").fetchall()
    return jsonify([row(r) for r in rows])

def clean_items(items):
    out = []
    for it in items or []:
        t = str(it.get('title', '')).strip()[:200]
        if not t: continue
        out.append({"title": t, "emoji": str(it.get('emoji') or '📝')[:16], "color": str(it.get('color') or '#7CB8F0')[:16],
                    "duration": max(1, min(600, int(it.get('duration') or 10))),
                    "steps": [str(s).strip()[:200] for s in (it.get('steps') or []) if str(s).strip()]})
    return out

@app.post('/api/routines')
@auth
def routine_new():
    d = request.json or {}
    with db() as c:
        cur = c.execute("INSERT INTO routines(name,emoji,items,sort) VALUES(?,?,?,?)",
                        ((d.get('name') or 'Routine')[:100], (d.get('emoji') or '✨')[:16], json.dumps(clean_items(d.get('items'))), 99))
        r = c.execute("SELECT * FROM routines WHERE id=?", (cur.lastrowid,)).fetchone()
    return jsonify(row(r))

@app.put('/api/routines/<int:id_>')
@auth
def routine_edit(id_):
    d = request.json or {}
    with db() as c:
        c.execute("UPDATE routines SET name=?, emoji=?, items=? WHERE id=?",
                  ((d.get('name') or 'Routine')[:100], (d.get('emoji') or '✨')[:16], json.dumps(clean_items(d.get('items'))), id_))
        r = c.execute("SELECT * FROM routines WHERE id=?", (id_,)).fetchone()
    return jsonify(row(r))

@app.delete('/api/routines/<int:id_>')
@auth
def routine_del(id_):
    with db() as c:
        c.execute("DELETE FROM routines WHERE id=?", (id_,))
    return jsonify(ok=True)

@app.post('/api/routines/<int:id_>/apply')
@auth
def routine_apply(id_):
    d = request.json or {}
    date = d.get('date') or today()
    dt.date.fromisoformat(date)
    h, m = map(int, (d.get('start') or '08:00').split(':'))
    t = h * 60 + m
    with db() as c:
        r = c.execute("SELECT * FROM routines WHERE id=?", (id_,)).fetchone()
        if not r:
            return jsonify(error='not found'), 404
        for it in json.loads(r['items']):
            st = f"{(t // 60) % 24:02d}:{t % 60:02d}"
            c.execute("""INSERT INTO activities(kind,title,emoji,color,date,start,duration,steps,remind,end_alert,created)
                         VALUES('event',?,?,?,?,?,?,?,0,0,?)""",
                      (it['title'], it['emoji'], it['color'], date, st, it['duration'],
                       json.dumps([{"t": s, "d": False} for s in it.get('steps', [])]), now().isoformat()))
            t += it['duration']
    return jsonify(ok=True)

# moods
@app.get('/api/moods')
@auth
def moods():
    with db() as c:
        rows = c.execute("SELECT * FROM moods ORDER BY ts DESC LIMIT 60").fetchall()
    return jsonify([dict(r) for r in rows])

@app.post('/api/moods')
@auth
def mood_add():
    d = request.json or {}
    mood = max(1, min(5, int(d.get('mood') or 3)))
    energy = int(d['energy']) if d.get('energy') else None
    if energy is not None: energy = max(1, min(5, energy))
    with db() as c:
        c.execute("INSERT INTO moods(ts,date,mood,note,energy) VALUES(?,?,?,?,?)", (now().isoformat(), today(), mood, str(d.get('note') or '')[:1000], energy))
    return jsonify(ok=True)

@app.delete('/api/moods/<int:id_>')
@auth
def mood_del(id_):
    with db() as c:
        c.execute("DELETE FROM moods WHERE id=?", (id_,))
    return jsonify(ok=True)

# focus timer (so the server can send the end alert while the phone is locked)
@app.post('/api/focus')
@auth
def focus():
    d = request.json or {}
    with db() as c:
        if d.get('end'):
            sset(c, 'focus', json.dumps({"end": int(d['end']), "title": str(d.get('title') or '')[:200],
                                         "total": int(d.get('total') or 0), "item": int(d.get('item') or 0),
                                         "color": str(d.get('color') or '')[:16]}))
        else:
            sset(c, 'focus', '')
    return jsonify(ok=True)

@app.get('/api/focus')
@auth
def focus_get():
    with db() as c:
        f = sget(c, 'focus')
    try:
        j = json.loads(f) if f else {}
    except Exception:
        j = {}
    if j.get('end', 0) / 1000 < _time.time():
        j = {}
    return jsonify(j)

# push
@app.post('/api/push/subscribe')
@auth
def push_sub():
    sub = (request.json or {}).get('sub') or {}
    if not sub.get('endpoint'):
        return jsonify(error='bad subscription'), 400
    with db() as c:
        c.execute("INSERT OR REPLACE INTO push_subs VALUES(?,?)", (sub['endpoint'], json.dumps(sub)))
    return jsonify(ok=True)

@app.post('/api/push/test')
@auth
def push_test():
    n = push_all("Pacely", "Notifications are working 🎉", "test")
    return jsonify(ok=True, sent=n)

# settings
@app.put('/api/settings')
@auth
def settings():
    d = request.json or {}
    with db() as c:
        if d.get('theme') in ('auto', 'light', 'dark'):
            sset(c, 'theme', d['theme'])
        if 'auto_tick' in d:
            sset(c, 'auto_tick', '1' if d['auto_tick'] else '0')
        if 'my_name' in d:
            sset(c, 'my_name', str(d['my_name'] or '').strip()[:40])
        for k in ('home', 'work'):
            if k in d:
                sset(c, k, str(d[k] or '').strip()[:200])
        if 'quiet_from' in d or 'quiet_to' in d:
            ok = lambda v: v if re.fullmatch(r'([01]\d|2[0-3]):[0-5]\d', str(v or '')) else ''
            f, t = ok(d.get('quiet_from')), ok(d.get('quiet_to'))
            sset(c, 'quiet_from', f if f and t else '')
            sset(c, 'quiet_to', t if f and t else '')
        if d.get('leave_style') in ('gentle', 'countdown'):
            sset(c, 'leave_style', d['leave_style'])
        if isinstance(d.get('modes'), list):
            ms = [m for m in d['modes'] if m in TFL_MODES]
            if ms:
                sset(c, 'tfl_modes', ','.join(ms))
        if 'home_time' in d and re.fullmatch(r'([01]\d|2[0-3]):[0-5]\d', str(d['home_time'] or '')):
            sset(c, 'home_time', d['home_time'])
        if 'work_start' in d and re.fullmatch(r'([01]\d|2[0-3]):[0-5]\d', str(d['work_start'] or '')):
            sset(c, 'work_start', d['work_start'])
        if d.get('travel_by') in ('car', 'transit', 'both'):
            sset(c, 'travel_by', d['travel_by'])
        if 'travel_buffer' in d:
            try: sset(c, 'travel_buffer', str(max(0, min(60, int(d['travel_buffer'])))))
            except (TypeError, ValueError): pass
        if 'commute' in d:
            sset(c, 'commute', '1' if d['commute'] else '0')
        if isinstance(d.get('nudges'), dict):
            sset(c, 'nudges', json.dumps({k: bool(d['nudges'].get(k)) for k in ('drink', 'eat', 'rest')}))
        if isinstance(d.get('numbers'), list):
            nums = [{"label": str(n.get('label') or '').strip()[:40], "number": str(n.get('number') or '').strip()[:30],
                     "words": str(n.get('words') or '').strip()[:200]} for n in d['numbers'][:40] if isinstance(n, dict)]
            sset(c, 'numbers', json.dumps([n for n in nums if n['label'] and n['number']]))
    return jsonify(ok=True)

@app.post('/api/password')
@auth
def password():
    d = request.json or {}
    new = str(d.get('new') or '')
    with db() as c:
        if not check_pw(str(d.get('old') or ''), sget(c, 'pw', '')):
            return jsonify(error='Current password is wrong'), 403
        if len(new) < 6:
            return jsonify(error='Use at least 6 characters'), 400
        sset(c, 'pw', hash_pw(new))
    return jsonify(ok=True)

@app.get('/api/export')
@auth
def export():
    with db() as c:
        out = {"app": "pacely", "version": 1, "exported": now().isoformat(),
               "activities": [dict(r) for r in c.execute("SELECT * FROM activities WHERE deleted=0")],
               "routines": [dict(r) for r in c.execute("SELECT * FROM routines")],
               "moods": [dict(r) for r in c.execute("SELECT * FROM moods")],
               "calendars": [dict(r) for r in c.execute("SELECT * FROM calendars")],
               "focus_log": [dict(r) for r in c.execute("SELECT * FROM focus_log")],
               "reviews": [dict(r) for r in c.execute("SELECT * FROM reviews")]}
    return Response(json.dumps(out, ensure_ascii=False, indent=1), mimetype='application/json',
                    headers={"Content-Disposition": f"attachment; filename=pacely-backup-{today()}.json"})

BACKUP_APPS = ('tem' + 'po', 'pac' + 'ely')   # backup files from either name are accepted
IMPORT_TABLES = ('activities', 'routines', 'moods', 'calendars', 'focus_log', 'reviews')

def _insert(c, table, r, cols):
    keys = [k for k in r if k in cols]
    cur = c.execute(f"INSERT OR IGNORE INTO {table}({','.join(keys)}) VALUES({','.join('?' * len(keys))})", [r[k] for k in keys])
    return cur.lastrowid

@app.post('/api/import')
@auth
def import_():
    """Load a backup file. mode 'replace' swaps everything for the file; 'merge' keeps what's here and adds anything new."""
    d = request.json or {}
    if d.get('app') not in BACKUP_APPS and not isinstance(d.get('activities'), list):
        return jsonify(error='That file isn’t a Pacely backup.'), 400
    mode = 'merge' if d.get('mode') == 'merge' else 'replace'
    shutil.copy(DB, os.path.join(DATA, f"before-import-{int(_time.time())}.db"))
    added = {}
    with db() as c:
        cols = {t: {r['name'] for r in c.execute(f"PRAGMA table_info({t})")} for t in IMPORT_TABLES}
        if mode == 'replace':
            for table in IMPORT_TABLES:
                if table not in d:
                    continue
                c.execute(f"DELETE FROM {table}")
                for r in d.get(table) or []:
                    _insert(c, table, r, cols[table])
            c.execute("DELETE FROM sent")
            return jsonify(ok=True, mode='replace')
        # merge
        sig = lambda a: '|'.join(str(a.get(k) or '') for k in ('kind', 'title', 'date', 'start', 'created'))
        have = {sig(dict(r)) for r in c.execute("SELECT kind,title,date,start,created FROM activities")}
        ids, n = {}, 0
        incoming = sorted([a for a in d.get('activities') or [] if not a.get('deleted')], key=lambda a: -(a.get('is_master') or 0))
        for a in incoming:
            if sig(a) in have:
                continue
            r = dict(a)
            old = r.pop('id', None)
            if r.get('master_id'):
                r['master_id'] = ids.get(r['master_id'])
            new_id = _insert(c, 'activities', r, cols['activities'])
            ids[old] = new_id
            have.add(sig(r))
            n += 1
        added['activities'] = n
        for table, key in (('routines', lambda r: f"{r.get('name')}|{r.get('items')}"), ('moods', lambda r: r.get('ts')),
                           ('focus_log', lambda r: r.get('ts')), ('calendars', lambda r: r.get('url'))):
            seen = {key(dict(r)) for r in c.execute(f"SELECT * FROM {table}")}
            cnt = 0
            for r in d.get(table) or []:
                if key(r) in seen:
                    continue
                r = dict(r)
                r.pop('id', None)
                _insert(c, table, r, cols[table])
                seen.add(key(r))
                cnt += 1
            added[table] = cnt
        dates = {r['date'] for r in c.execute("SELECT date FROM reviews")}
        rv = 0
        for r in d.get('reviews') or []:
            if r.get('date') and r['date'] not in dates:
                _insert(c, 'reviews', r, cols['reviews'])
                rv += 1
        added['reviews'] = rv
    return jsonify(ok=True, mode='merge', **added)


# ---------- calendars (read-only import of ICS links) ----------
def cal_rows(c, date, extra=''):
    """Calendar events for a day, tidied by each calendar's rules: only within its hours (say 9:00 to 15:30), no repeating
    blocks (focus time, out of office), and nothing that's already in Pacely at the same time (you added it there too)."""
    rows = c.execute(f"""SELECT e.*, k.color kcolor, k.emoji kemoji, k.name kname, k.remind, k.hours_from, k.hours_to, k.hide_repeats, k.hide_dupes
                         FROM cal_events e JOIN calendars k ON k.id=e.cal_id WHERE e.date=? {extra} ORDER BY e.start""", (date,)).fetchall()
    if not rows:
        return []
    mine = [toks(r['start']) for r in c.execute("""SELECT start FROM activities WHERE date=? AND kind='event' AND deleted=0 AND is_master=0
                                                    AND start IS NOT NULL""", (date,))]
    out = []
    for r in rows:
        if r['hide_repeats'] and not r['all_day'] and r['start']:
            if r['repeats']:
                continue
            # no repeat info (some work calendars only share "Busy"): the same block at the same time on 3+ days counts as repeating
            n = c.execute("""SELECT COUNT(DISTINCT date) n FROM cal_events WHERE cal_id=? AND title=? AND start=? AND duration=?""",
                          (r['cal_id'], r['title'], r['start'], r['duration'])).fetchone()['n']
            if n >= 3:
                continue
        if r['hours_from'] and r['hours_to'] and r['start'] and not r['all_day']:
            if not (r['hours_from'] <= r['start'] < r['hours_to']):
                continue
        if r['hide_dupes'] and r['start'] and any(abs(toks(r['start']) - m) <= 10 for m in mine):
            continue
        out.append(r)
    return out

def toks(hhmm):
    try:
        h, m = map(int, str(hhmm).split(':'))
        return h * 60 + m
    except Exception:
        return -9999

def cal_items(c, date):
    rows = cal_rows(c, date)
    return [{"id": f"c{r['id']}", "kind": "cal", "title": r['title'], "emoji": r['kemoji'] or '📅', "color": r['kcolor'] or '#9AA8BA',
             "date": r['date'], "start": r['start'], "duration": r['duration'] or 30, "all_day": r['all_day'], "notes": r['location'] or '',
             "calendar": r['kname'], "steps": [], "done": 0, "master_id": None} for r in rows]

def fetch_url(url):
    import urllib.request
    url = url.strip()
    if url.startswith('webcal://'):
        url = 'https://' + url[9:]
    req = urllib.request.Request(url, headers={"User-Agent": "Pacely-Calendar/1.0"})
    with urllib.request.urlopen(req, timeout=30) as r:
        return r.read()

def sync_calendar(c, cal):
    import icalendar, recurring_ical_events
    try:
        ical = icalendar.Calendar.from_ical(fetch_url(cal['url']))
        start = now().date() - dt.timedelta(days=14)
        end = now().date() + dt.timedelta(days=90)
        events = recurring_ical_events.of(ical).between(start, end)
        rows = []
        for ev in events:
            ds, de = ev.get('DTSTART'), ev.get('DTEND')
            if ds is None:
                continue
            ds = ds.dt
            title = str(ev.get('SUMMARY') or 'Busy')[:200]
            loc = str(ev.get('LOCATION') or '')[:300]
            uid = str(ev.get('UID') or '')
            rep_ = 1 if (ev.get('RRULE') is not None or ev.get('RECURRENCE-ID') is not None) else 0
            if isinstance(ds, dt.datetime):
                if ds.tzinfo is None:
                    ds = ds.replace(tzinfo=TZ)
                ds = ds.astimezone(TZ)
                if de is not None and isinstance(de.dt, dt.datetime):
                    e2 = de.dt if de.dt.tzinfo else de.dt.replace(tzinfo=TZ)
                    mins = max(5, int((e2.astimezone(TZ) - ds).total_seconds() // 60))
                elif ev.get('DURATION') is not None:
                    mins = max(5, int(ev.get('DURATION').dt.total_seconds() // 60))
                else:
                    mins = 30
                rows.append((cal['id'], uid, title, ds.date().isoformat(), ds.strftime('%H:%M'), min(mins, 1440), 0, loc, rep_))
            else:
                d2 = de.dt if de is not None else ds + dt.timedelta(days=1)
                d = ds
                while d < d2 and d <= end:
                    rows.append((cal['id'], uid, title, d.isoformat(), None, 1440, 1, loc, rep_))
                    d += dt.timedelta(days=1)
        c.execute("DELETE FROM cal_events WHERE cal_id=?", (cal['id'],))
        c.executemany("INSERT INTO cal_events(cal_id,uid,title,date,start,duration,all_day,location,repeats) VALUES(?,?,?,?,?,?,?,?,?)", rows)
        c.execute("UPDATE calendars SET last_sync=?, error=NULL WHERE id=?", (now().isoformat(), cal['id']))
        return len(rows), None
    except Exception as e:
        msg = str(e)[:300]
        c.execute("UPDATE calendars SET error=? WHERE id=?", (msg, cal['id']))
        return 0, msg

def sync_calendars():
    with db() as c:
        for cal in c.execute("SELECT * FROM calendars WHERE url NOT LIKE 'device://%'").fetchall():
            sync_calendar(c, cal)

@app.get('/api/calendars')
@auth
def calendars():
    with db() as c:
        rows = c.execute("""SELECT k.*, (SELECT COUNT(*) FROM cal_events e WHERE e.cal_id=k.id) n FROM calendars k ORDER BY id""").fetchall()
        tok = sget(c, 'read_token')
    return jsonify(calendars=[dict(r) for r in rows], feed=f"/cal/{tok}.ics")

@app.post('/api/calendars')
@auth
def calendar_add():
    d = request.json or {}
    url = str(d.get('url') or '').strip()
    if not url.startswith(('http://', 'https://', 'webcal://')):
        return jsonify(error='Paste the calendar link that starts with https:// or webcal://'), 400
    with db() as c:
        cur = c.execute("INSERT INTO calendars(name,url,color,emoji,remind) VALUES(?,?,?,?,?)",
                        ((d.get('name') or 'Calendar')[:80], url, (d.get('color') or '#9AA8BA')[:16], (d.get('emoji') or '📅')[:16],
                         int(d.get('remind') if d.get('remind') is not None else 10)))
        cal = c.execute("SELECT * FROM calendars WHERE id=?", (cur.lastrowid,)).fetchone()
        n, err = sync_calendar(c, cal)
    return jsonify(ok=True, events=n, error=err)

@app.put('/api/calendars/<int:id_>')
@auth
def calendar_edit(id_):
    d = request.json or {}
    with db() as c:
        cal = c.execute("SELECT * FROM calendars WHERE id=?", (id_,)).fetchone()
        if not cal:
            return jsonify(error='not found'), 404
        c.execute("UPDATE calendars SET name=?, color=?, emoji=?, remind=? WHERE id=?",
                  ((d.get('name') or cal['name'])[:80], (d.get('color') or cal['color'])[:16], (d.get('emoji') or cal['emoji'])[:16],
                   int(d.get('remind') if d.get('remind') is not None else cal['remind']), id_))
        hm = lambda v: v if re.fullmatch(r'([01]\d|2[0-3]):[0-5]\d', str(v or '')) else ''
        if 'hours_from' in d or 'hours_to' in d:
            f, t = hm(d.get('hours_from')), hm(d.get('hours_to'))
            c.execute("UPDATE calendars SET hours_from=?, hours_to=? WHERE id=?", (f if f and t else '', t if f and t else '', id_))
        for k in ('hide_repeats', 'hide_dupes'):
            if k in d:
                c.execute(f"UPDATE calendars SET {k}=? WHERE id=?", (1 if d[k] else 0, id_))
    return jsonify(ok=True)

@app.post('/api/calendars/sync')
@auth
def calendar_sync():
    out = []
    with db() as c:
        for cal in c.execute("SELECT * FROM calendars WHERE url NOT LIKE 'device://%'").fetchall():
            n, err = sync_calendar(c, cal)
            out.append({"name": cal['name'], "events": n, "error": err})
    return jsonify(results=out)

@app.delete('/api/calendars/<int:id_>')
@auth
def calendar_del(id_):
    with db() as c:
        c.execute("DELETE FROM cal_events WHERE cal_id=?", (id_,))
        c.execute("DELETE FROM calendars WHERE id=?", (id_,))
    return jsonify(ok=True)

def ics_escape(t):
    return str(t or '').replace('\\', '\\\\').replace(';', '\\;').replace(',', '\\,').replace('\n', '\\n')

@app.get('/cal/<tok>.ics')
def ics_feed(tok):
    with db() as c:
        good = sget(c, 'read_token', '')
        if not good or not hmac.compare_digest(tok, good):
            return Response('not found', 404)
        base = now().date()
        lines = ["BEGIN:VCALENDAR", "VERSION:2.0", "PRODID:-//Pacely//Self-hosted//EN", "X-WR-CALNAME:Pacely", "CALSCALE:GREGORIAN"]
        for i in range(-7, 31):
            d = (base + dt.timedelta(days=i)).isoformat()
            materialize(c, d)
        rows = c.execute("""SELECT * FROM activities WHERE kind='event' AND deleted=0 AND is_master=0
                            AND (start IS NOT NULL OR allday<>'') AND date BETWEEN ? AND ?""",
                         ((base - dt.timedelta(days=7)).isoformat(), (base + dt.timedelta(days=30)).isoformat())).fetchall()
    lines += ics_events(rows)
    lines.append("END:VCALENDAR")
    return Response("\r\n".join(lines) + "\r\n", mimetype='text/calendar')

def ics_events(rows, uid_prefix='pacely'):
    lines = []
    stamp = dt.datetime.now(dt.timezone.utc).strftime('%Y%m%dT%H%M%SZ')
    for r in rows:
        if not r['start']:
            d0 = dt.date.fromisoformat(r['date'])
            lines += ["BEGIN:VEVENT", f"UID:{uid_prefix}-{r['id']}@pacely", f"DTSTAMP:{stamp}", f"DTSTART;VALUE=DATE:{d0.strftime('%Y%m%d')}",
                      f"DTEND;VALUE=DATE:{(d0 + dt.timedelta(days=1)).strftime('%Y%m%d')}",
                      f"SUMMARY:{ics_escape((r['emoji'] or '') + ' ' + r['title'])}", "TRANSP:TRANSPARENT", "END:VEVENT"]
            continue
        h, m = map(int, r['start'].split(':'))
        st = dt.datetime.combine(dt.date.fromisoformat(r['date']), dt.time(h, m), TZ).astimezone(dt.timezone.utc)
        en = st + dt.timedelta(minutes=r['duration'] or 30)
        steps = json.loads(r['steps'] or '[]')
        desc = (r['notes'] or '') + ('\n' if r['notes'] and steps else '') + '\n'.join(('✓ ' if s.get('d') else '• ') + s['t'] for s in steps)
        lines += ["BEGIN:VEVENT", f"UID:{uid_prefix}-{r['id']}@pacely", f"DTSTAMP:{stamp}", f"DTSTART:{st.strftime('%Y%m%dT%H%M%SZ')}",
                  f"DTEND:{en.strftime('%Y%m%dT%H%M%SZ')}", f"SUMMARY:{ics_escape((r['emoji'] or '') + ' ' + r['title'])}"]
        if desc:
            lines.append(f"DESCRIPTION:{ics_escape(desc)}")
        lines.append("END:VEVENT")
    return lines

# ---------- running late / move ----------
@app.post('/api/shift')
@auth
def shift():
    d = request.json or {}
    date = d.get('date') or today()
    mins = max(-240, min(240, int(d.get('minutes') or 0)))
    frm = d.get('from') or now().strftime('%H:%M')
    fm = int(frm[:2]) * 60 + int(frm[3:5])
    n = 0
    with db() as c:
        rows = c.execute("""SELECT id, start, duration FROM activities WHERE date=? AND kind='event' AND deleted=0 AND is_master=0
                            AND done=0 AND start IS NOT NULL""", (date,)).fetchall()
        for r in rows:
            st = int(r['start'][:2]) * 60 + int(r['start'][3:5])
            if st + (r['duration'] or 0) > fm:  # still running or still to come
                nst = max(0, min(1439, st + mins))
                update(c, r['id'], {"start": f"{nst // 60:02d}:{nst % 60:02d}"})
                n += 1
    return jsonify(ok=True, moved=n)

@app.post('/api/move_undone')
@auth
def move_undone():
    d = request.json or {}
    frm = d.get('date') or today()
    to = (dt.date.fromisoformat(frm) + dt.timedelta(days=1)).isoformat()
    with db() as c:
        rows = c.execute("""SELECT id FROM activities WHERE date=? AND kind='event' AND deleted=0 AND is_master=0 AND done=0
                            AND master_id IS NULL""", (frm,)).fetchall()
        for r in rows:
            update(c, r['id'], {"date": to})
    return jsonify(ok=True, moved=len(rows))

# ---------- insights, streaks, trophies, reviews ----------
TROPHIES = [
    ("first", "🌱", "First step", "Finish your first activity"),
    ("ten", "🌿", "Getting going", "Finish 10 activities"),
    ("fifty", "🌳", "Steady growth", "Finish 50 activities"),
    ("hundred", "🏔️", "Mountain mover", "Finish 100 activities"),
    ("streak3", "🔥", "Three in a row", "Get something done 3 days running"),
    ("streak7", "⭐", "Full week", "Get something done 7 days running"),
    ("streak30", "🏆", "Monthly habit", "Get something done 30 days running"),
    ("focus1", "⏳", "In the zone", "Finish a focus session"),
    ("focus10", "🎯", "Deep focus", "Finish 10 focus sessions"),
    ("checkin7", "💛", "Checking in", "Do 7 mood check-ins"),
    ("review3", "📓", "Reflective", "Review your day 3 times"),
    ("routine", "🔁", "Routine starter", "Finish every activity on a day with 3 or more"),
]

def compute_insights(c):
    td = now().date()
    done_by_day = {r['date']: r['n'] for r in c.execute(
        "SELECT date, COUNT(*) n FROM activities WHERE done=1 AND deleted=0 AND is_master=0 AND date IS NOT NULL GROUP BY date")}
    todo_done = c.execute("SELECT COUNT(*) n FROM activities WHERE done=1 AND deleted=0 AND kind='todo'").fetchone()['n']
    total_done = sum(done_by_day.values()) + todo_done
    # streak counts back from today (or yesterday if nothing yet today)
    streak, d = 0, td
    if not done_by_day.get(d.isoformat()):
        d -= dt.timedelta(days=1)
    while done_by_day.get(d.isoformat()):
        streak += 1
        d -= dt.timedelta(days=1)
    best, run = 0, 0
    for i in range(365, -1, -1):
        if done_by_day.get((td - dt.timedelta(days=i)).isoformat()):
            run += 1; best = max(best, run)
        else:
            run = 0
    week_start = td - dt.timedelta(days=td.weekday())
    week_done = sum(v for k, v in done_by_day.items() if k >= week_start.isoformat())
    focus = c.execute("SELECT COUNT(*) n, COALESCE(SUM(minutes),0) m FROM focus_log").fetchone()
    focus_week = c.execute("SELECT COALESCE(SUM(minutes),0) m FROM focus_log WHERE date>=?", (week_start.isoformat(),)).fetchone()['m']
    checkins = c.execute("SELECT COUNT(*) n FROM moods").fetchone()['n']
    reviews = c.execute("SELECT COUNT(*) n FROM reviews").fetchone()['n']
    full_day = c.execute("""SELECT 1 FROM activities WHERE kind='event' AND deleted=0 AND is_master=0 AND date<=?
                            GROUP BY date HAVING COUNT(*)>=3 AND SUM(done)=COUNT(*) LIMIT 1""", (td.isoformat(),)).fetchone()
    days14 = []
    for i in range(13, -1, -1):
        dd = (td - dt.timedelta(days=i)).isoformat()
        m = c.execute("SELECT AVG(mood) m, AVG(energy) e FROM moods WHERE date=?", (dd,)).fetchone()
        days14.append({"date": dd, "done": done_by_day.get(dd, 0), "mood": m['m'], "energy": m['e']})
    have = {"first": total_done >= 1, "ten": total_done >= 10, "fifty": total_done >= 50, "hundred": total_done >= 100,
            "streak3": best >= 3, "streak7": best >= 7, "streak30": best >= 30, "focus1": focus['n'] >= 1, "focus10": focus['n'] >= 10,
            "checkin7": checkins >= 7, "review3": reviews >= 3, "routine": bool(full_day)}
    good14 = sum(1 for i in range(14) if done_by_day.get((td - dt.timedelta(days=i)).isoformat()))
    return {"good_days": good14, "streak": streak, "best": best, "total": total_done, "week_done": week_done, "focus_sessions": focus['n'],
            "focus_minutes": focus['m'], "focus_week": focus_week, "days": days14,
            "trophies": [{"key": k, "emoji": e, "name": n, "desc": ds, "got": have[k]} for k, e, n, ds in TROPHIES]}

@app.get('/api/insights')
@auth
def insights():
    with db() as c:
        return jsonify(compute_insights(c))

@app.post('/api/focus/log')
@auth
def focus_log():
    d = request.json or {}
    mins = max(1, min(600, int(d.get('minutes') or 1)))
    with db() as c:
        c.execute("INSERT INTO focus_log(ts,date,minutes,title) VALUES(?,?,?,?)", (now().isoformat(), today(), mins, str(d.get('title') or '')[:200]))
    return jsonify(ok=True)

@app.post('/api/review')
@auth
def review_save():
    d = request.json or {}
    date = d.get('date') or today()
    with db() as c:
        c.execute("INSERT OR REPLACE INTO reviews(date,well,hard,tomorrow,ts) VALUES(?,?,?,?,?)",
                  (date, str(d.get('well') or '')[:2000], str(d.get('hard') or '')[:2000], str(d.get('tomorrow') or '')[:2000], now().isoformat()))
    return jsonify(ok=True)

@app.get('/api/reviews')
@auth
def reviews():
    with db() as c:
        return jsonify([dict(r) for r in c.execute("SELECT * FROM reviews ORDER BY date DESC LIMIT 30")])

# ---------- AI co-planner (runs on your own server with Ollama) ----------
AI_URL = os.environ.get('PACELY_AI_URL', 'http://127.0.0.1:11434')

def ai_model(c=None):
    if c is not None:
        return sget(c, 'ai_model') or os.environ.get('PACELY_AI_MODEL', 'llama3.2:3b')
    with db() as cc:
        return sget(cc, 'ai_model') or os.environ.get('PACELY_AI_MODEL', 'llama3.2:3b')

def ollama(path, payload=None, timeout=900):
    import urllib.request
    data = json.dumps(payload).encode() if payload is not None else None
    req = urllib.request.Request(AI_URL + path, data=data, headers={"Content-Type": "application/json"}, method='POST' if data else 'GET')
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.loads(r.read())

def ai_settings():
    with db() as c:
        return {"provider": sget(c, 'ai_provider') or 'ollama', "key": sget(c, 'gemini_key') or '',
                "gmodel": sget(c, 'gemini_model') or 'gemini-3.8-flash', "model": ai_model(c)}

def parse_json_text(txt):
    try:
        return json.loads(txt)
    except Exception:
        a, b = txt.find('{'), txt.rfind('}')
        return json.loads(txt[a:b + 1]) if a >= 0 else {}

def gemini_schema(sc):
    """Gemini wants OpenAPI-style upper-case type names."""
    if isinstance(sc, dict):
        return {k: (v.upper() if k == 'type' and isinstance(v, str) else gemini_schema(v)) for k, v in sc.items()}
    if isinstance(sc, list):
        return [gemini_schema(x) for x in sc]
    return sc

GEMINI = "https://generativelanguage.googleapis.com/v1beta"

def gemini_request(path, key, payload=None, timeout=120):
    import urllib.request, urllib.error
    data = json.dumps(payload).encode() if payload is not None else None
    req = urllib.request.Request(GEMINI + path, data=data, method='POST' if data else 'GET',
                                 headers={"Content-Type": "application/json", "x-goog-api-key": key})
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return json.loads(r.read())
    except (TimeoutError, OSError) as e:
        if not isinstance(e, urllib.error.HTTPError) and ('timed out' in str(e).lower() or isinstance(e, TimeoutError)):
            raise GeminiBusy("took too long to answer")     # treat a stuck model like a busy one: try the next
        if not isinstance(e, urllib.error.HTTPError):
            raise
        return _gemini_http_error(e)

def _gemini_http_error(e):
    try:
        msg = json.loads(e.read()).get('error', {}).get('message', '')
    except Exception:
        msg = ''
    if e.code in (400, 401, 403) and 'key' in msg.lower():
        raise ValueError("Gemini didn't accept the API key. Check it in Me > AI helper.")
    if e.code in (404, 429, 500, 503, 504) or 'demand' in msg.lower() or 'overloaded' in msg.lower():
        raise GeminiBusy(msg or f"error {e.code}")
    raise ValueError(f"Gemini said: {msg[:200] or 'error ' + str(e.code)}")

class GeminiBusy(ValueError):
    """Google's side is busy or this model's free limit is used up: try another model."""

_gem_models = {"t": 0, "names": []}

def gemini_models(key):
    """Gemini text models this key can use, steadiest first (cached for an hour)."""
    if _time.time() - _gem_models['t'] > 3600 or not _gem_models['names']:
        try:
            res = gemini_request("/models?pageSize=200", key, timeout=15)
            names = [m.get('name', '').split('/')[-1] for m in res.get('models', [])
                     if 'generateContent' in (m.get('supportedGenerationMethods') or [])]
            good = [n for n in names if 'flash' in n and not any(x in n for x in ('image', 'tts', 'live', 'audio', 'exp', 'thinking'))]
            good.sort(key=lambda n: ('preview' in n, 'lite' in n, [-int(x) if x.isdigit() else 0 for x in re.findall(r'\d+', n)]))
            _gem_models.update(t=_time.time(), names=good)
        except Exception as e:
            print('gemini model list failed', e)
    return _gem_models['names']

def gemini_generate(st, payload, timeout=120):
    """Asks Gemini, and if that model is busy ("high demand"), stuck, or out of free uses, quietly tries the next one.
    Each try waits at most 45 seconds, so a busy model never leaves you waiting minutes."""
    tried = [st['gmodel']] + [m for m in gemini_models(st['key']) if m != st['gmodel']][:4]
    for i, m in enumerate(tried):
        try:
            res = gemini_request(f"/models/{m}:generateContent", st['key'], payload, timeout=min(timeout, 45))
            if i:
                print('gemini: used', m, 'because', tried[0], 'was busy')
                with db() as c:
                    if sget(c, 'gemini_auto', '1') == '1':
                        sset(c, 'gemini_model', m)      # automatic: stick with the one that answers
            return res
        except GeminiBusy as e:
            print('gemini busy', m, e)
            _time.sleep(1)
    raise ValueError("Gemini is very busy right now. That's on Google's side, not something you did. Try again in a few minutes, "
                     "or switch to the private helper in Me › AI helper.")

def ai_json(system, user, schema, history=None, image=None):
    st = ai_settings()
    if st['provider'] == 'gemini' and st['key']:
        contents = [{"role": "model" if h.get('role') == 'assistant' else "user", "parts": [{"text": str(h.get('text') or '')[:4000]}]}
                    for h in (history or [])[-16:] if h.get('text')]
        parts = [{"text": user}]
        if image:
            parts.append({"inline_data": {"mime_type": image['mime'], "data": image['data']}})
        contents.append({"role": "user", "parts": parts})
        res = gemini_generate(st, {
            "systemInstruction": {"parts": [{"text": system}]}, "contents": contents,
            "generationConfig": {"responseMimeType": "application/json", "responseSchema": gemini_schema(schema), "temperature": 0.4}})
        cands = res.get('candidates') or []
        if not cands:
            raise ValueError("Gemini didn't give an answer. Try rewording it.")
        txt = "".join(p.get('text', '') for p in cands[0].get('content', {}).get('parts', []))
        return parse_json_text(txt or '{}')
    if image:
        raise ValueError("Photo to tasks needs Gemini switched on in Me > AI helper.")
    msgs = [{"role": "system", "content": system}]
    msgs += [{"role": "assistant" if h.get('role') == 'assistant' else "user", "content": str(h.get('text') or '')[:4000]}
             for h in (history or [])[-12:] if h.get('text')]
    msgs.append({"role": "user", "content": user})
    res = ollama('/api/chat', {"model": st['model'], "stream": False, "format": schema, "keep_alive": "2h",
                               "options": {"temperature": 0.3, "num_ctx": 4096 if history else 2048}, "messages": msgs})
    return parse_json_text(res.get('message', {}).get('content', '{}'))

AI_STYLE = ("You help an adult with ADHD and autism plan their day. Use UK English. Be calm and concrete. "
            "Break work into small, clear, physical first steps. Give realistic time estimates in minutes, adding a little buffer. "
            "Never invent tasks the person did not mention.")
TASK_SCHEMA = {"type": "object", "properties": {"tasks": {"type": "array", "items": {"type": "object", "properties": {
    "title": {"type": "string"}, "emoji": {"type": "string"}, "minutes": {"type": "integer"},
    "priority": {"type": "string", "enum": ["now", "soon", "later"]},
    "steps": {"type": "array", "items": {"type": "object", "properties": {"t": {"type": "string"}, "m": {"type": "integer"}}, "required": ["t", "m"]}}},
    "required": ["title", "emoji", "minutes", "priority", "steps"]}}}, "required": ["tasks"]}

def clean_ai_tasks(tasks):
    out = []
    for t in tasks or []:
        title = str(t.get('title') or '').strip()[:120]
        if not title:
            continue
        steps = [{"t": str(s.get('t') or '').strip()[:150], "m": max(1, min(120, int(s.get('m') or 5))), "d": False}
                 for s in (t.get('steps') or []) if str(s.get('t') or '').strip()][:8]
        mins = max(5, min(480, int(t.get('minutes') or 15)))
        if steps and sum(s['m'] for s in steps) > mins:
            mins = sum(s['m'] for s in steps)
        out.append({"title": title, "emoji": (str(t.get('emoji') or '📝').strip() or '📝')[:8], "minutes": mins,
                    "priority": t.get('priority') if t.get('priority') in ('now', 'soon', 'later') else 'soon', "steps": steps})
    return out[:20]

# AI answers can take a few minutes on an older computer, longer than Cloudflare waits
# for one request (100 s). So each AI request runs as a background job the app checks on.
AI_JOBS = {}
AI_ERR = "The AI helper didn't answer. Check it's ready in Me > AI helper."

def ai_reason(e):
    """A plain-English reason the AI helper didn't answer, so you know what to fix."""
    import urllib.error, socket
    if isinstance(e, ValueError):
        return str(e)
    if isinstance(e, urllib.error.HTTPError):
        if e.code == 404:
            return f"The AI model ({ai_model()}) isn't downloaded on the server yet. In SSH run:  ollama pull {ai_model()}"
        return f"The AI helper answered with error {e.code}. Try again in a minute."
    r = getattr(e, 'reason', e)
    if isinstance(r, ConnectionRefusedError) or 'refused' in str(r).lower():
        return "The private AI helper (Ollama) isn't running on the server. In SSH run:  sudo systemctl start ollama"
    if isinstance(r, (socket.timeout, TimeoutError)) or 'timed out' in str(r).lower():
        return "The AI helper took too long. Older computers are slow at this: try something shorter, or switch to Gemini in Me › AI helper."
    if isinstance(e, (json.JSONDecodeError, KeyError, TypeError)):
        return "The AI helper's answer came back in a muddle. Try again, or try a bigger model or Gemini."
    return AI_ERR + f" ({type(e).__name__})"

def start_job(fn, *args):
    for k in [k for k, v in AI_JOBS.items() if _time.time() - v['t'] > 3600]:
        AI_JOBS.pop(k, None)
    jid = secrets.token_hex(8)
    AI_JOBS[jid] = {"status": "running", "t": _time.time()}
    job = AI_JOBS[jid]
    def work():
        _jobctx.job = job
        try:
            job.update(status="done", result=fn(*args))
        except Exception as e:
            print('ai job error', repr(e))
            job.update(status="error", error=ai_reason(e))
        AI_JOBS.setdefault(jid, job)
    threading.Thread(target=work, daemon=True).start()
    return jsonify(job=jid)

_jobctx = threading.local()

def job_cancelled():
    """True when the person pressed Cancel while this AI job was thinking, so it changes nothing."""
    j = getattr(_jobctx, 'job', None)
    return bool(j and j.get('cancelled'))

@app.post('/api/ai/job/<jid>/cancel')
@auth
def ai_job_cancel(jid):
    j = AI_JOBS.get(jid)
    if j:
        j['cancelled'] = True
    return jsonify(ok=True)

@app.get('/api/ai/job/<jid>')
@auth
def ai_job(jid):
    j = AI_JOBS.get(jid)
    if not j:
        return jsonify(status="error", error="That request expired. Please try again.")
    return jsonify({k: v for k, v in j.items() if k != 't'})

def sync_version():
    with db() as c:
        r = c.execute("SELECT v FROM sync_seq WHERE id=1").fetchone()
    return r['v'] if r else 0

def wait_for_change(since, wait):
    """Long-poll: answers as soon as something changes, or after `wait` seconds with no change."""
    end = _time.time() + max(0, min(wait, 25))
    v = sync_version()
    while v == since and _time.time() < end:
        _time.sleep(1)
        v = sync_version()
    return v

@app.get('/api/live')
@auth
def api_live():
    """Live sync. Apps call /api/live?v=<last version>&wait=25 and reload when the version changes."""
    try:
        since, wait = int(request.args.get('v', -1)), float(request.args.get('wait', 0))
    except ValueError:
        since, wait = -1, 0
    return jsonify(v=wait_for_change(since, wait))

@app.get('/api/ai/status')
@auth
def ai_status():
    st = ai_settings()
    if st['provider'] == 'gemini':
        base = dict(provider='gemini', has_key=bool(st['key']), model=st['gmodel'], models=[])
        if not st['key']:
            return jsonify(ok=False, error="Add your free Gemini API key in Me > AI helper.", **base)
        try:
            res = gemini_request("/models?pageSize=200", st['key'], timeout=15)
            names = [m.get('name', '').split('/')[-1] for m in res.get('models', [])
                     if 'generateContent' in (m.get('supportedGenerationMethods') or [])]
            if st['gmodel'] not in names:
                good = [n for n in names if 'flash' in n and not any(x in n for x in ('image', 'tts', 'live', 'audio', 'preview', 'exp'))]
                if good:
                    pick = sorted(good, reverse=True)[0]
                    with db() as c:
                        sset(c, 'gemini_model', pick)
                    base['model'] = pick
                else:
                    return jsonify(ok=False, error="No suitable Gemini model found for this key.", **base)
            base['models'] = [n for n in gemini_models(st['key']) if n in names] or names
            with db() as c:
                base['auto'] = sget(c, 'gemini_auto', '1') == '1'
            return jsonify(ok=True, error=None, **base)
        except ValueError as e:
            return jsonify(ok=False, error=str(e), **base)
        except Exception:
            return jsonify(ok=False, error="Can't reach Gemini from the server right now.", **base)
    try:
        tags = ollama('/api/tags', timeout=5)
        names = [m.get('name') for m in tags.get('models', [])]
        model = ai_model()
        ok = any(n == model or n.split(':')[0] == model for n in names)
        return jsonify(ok=ok, model=model, models=names, provider='ollama', has_key=bool(st['key']),
                       error=None if ok else f"The AI model ({model}) is still downloading. This can take 10–20 minutes the first time.")
    except Exception as e:
        return jsonify(ok=False, model=ai_model(), models=[], provider='ollama', has_key=bool(st['key']),
                       error="The private AI helper isn't running on the server")

@app.put('/api/ai/settings')
@auth
def ai_set_settings():
    d = request.json or {}
    with db() as c:
        if d.get('provider') in ('ollama', 'gemini'):
            sset(c, 'ai_provider', d['provider'])
        if 'key' in d:
            sset(c, 'gemini_key', str(d['key'] or '').strip()[:200])
        if d.get('gemini_model') == 'auto':
            sset(c, 'gemini_auto', '1')
            pick = (gemini_models(sget(c, 'gemini_key') or '') or [''])[0]
            if pick:
                sset(c, 'gemini_model', pick)
        elif d.get('gemini_model'):
            sset(c, 'gemini_model', str(d['gemini_model']).strip()[:80])
            sset(c, 'gemini_auto', '0')
        if d.get('model'):
            sset(c, 'ai_model', str(d['model']).strip()[:80])
    return jsonify(ok=True)

@app.put('/api/ai/model')
@auth
def ai_set_model():
    m = str((request.json or {}).get('model') or '').strip()[:80]
    with db() as c:
        sset(c, 'ai_model', m)
    return jsonify(ok=True)

@app.post('/api/ai/plan')
@auth
def ai_plan():
    text = str((request.json or {}).get('text') or '').strip()[:4000]
    if not text:
        return jsonify(error='Type or say what is on your mind first'), 400
    def job():
        res = ai_json(AI_STYLE + " Turn the brain dump into a list of separate tasks. Each task gets an emoji, a total time, a priority "
                      "(now = urgent or time-sensitive today, soon = this week, later = whenever) and 2 to 6 small steps with minutes each. "
                      "Simple tasks can have no steps.", f"Brain dump:\n{text}", TASK_SCHEMA)
        return {"tasks": clean_ai_tasks(res.get('tasks'))}
    return start_job(job)

@app.post('/api/ai/breakdown')
@auth
def ai_breakdown():
    d = request.json or {}
    title = str(d.get('title') or '').strip()[:200]
    if not title:
        return jsonify(error='Give the activity a name first'), 400
    schema = {"type": "object", "properties": {"steps": TASK_SCHEMA['properties']['tasks']['items']['properties']['steps'],
                                               "emoji": {"type": "string"}, "minutes": {"type": "integer"}}, "required": ["steps", "emoji", "minutes"]}
    def job():
        res = ai_json(AI_STYLE + " Break this one activity into 3 to 7 small steps. Each step is a short instruction starting with a verb, "
                      "with minutes. Also suggest one emoji and the total minutes.",
                      f"Activity: {title}\nNotes: {str(d.get('notes') or '')[:1000]}", schema)
        t = clean_ai_tasks([{"title": title, "emoji": res.get('emoji'), "minutes": res.get('minutes'), "priority": "soon", "steps": res.get('steps')}])
        return t[0] if t else {"steps": []}
    return start_job(job)

@app.post('/api/ai/prioritise')
@auth
def ai_prioritise():
    with db() as c:
        todos = c.execute("SELECT id, title FROM activities WHERE kind='todo' AND deleted=0 AND done=0").fetchall()
    if not todos:
        return jsonify(ok=True, changed=0)
    schema = {"type": "object", "properties": {"items": {"type": "array", "items": {"type": "object", "properties": {
        "id": {"type": "integer"}, "priority": {"type": "string", "enum": ["now", "soon", "later"]}}, "required": ["id", "priority"]}}}, "required": ["items"]}
    listing = "\n".join(f"{t['id']}: {t['title']}" for t in todos)
    ids = {t['id'] for t in todos}
    def job():
        res = ai_json(AI_STYLE + " Sort each to-do into now (urgent, has a deadline, or blocks other things), soon (this week) or later (nice to do). "
                      "Keep roughly a third or fewer in now. Return every id.", f"To-dos (id: title):\n{listing}", schema)
        n = 0
        if job_cancelled():
            return {"ok": True, "changed": 0}
        with db() as c:
            for it in res.get('items', []):
                if it.get('id') in ids and it.get('priority') in ('now', 'soon', 'later'):
                    c.execute("UPDATE activities SET priority=? WHERE id=?", (it['priority'], it['id'])); n += 1
        return {"ok": True, "changed": n}
    return start_job(job)

CHAT_SCHEMA = {"type": "object", "properties": {"reply": {"type": "string"}, "tasks": TASK_SCHEMA['properties']['tasks']},
               "required": ["reply", "tasks"]}

@app.post('/api/ai/chat')
@auth
def ai_chat():
    d = request.json or {}
    text = str(d.get('text') or '').strip()[:3000]
    history = d.get('history') or []
    if not text:
        return jsonify(error='Type or say something first'), 400
    when = now().strftime('%A %d %B, %H:%M')
    if d.get('week') and not history:
        text = f"(For context, here is how my week has gone:\n{week_summary(7)}\n)\n\n{text}"[:12000]
    def job():
        res = ai_json(AI_STYLE + f" It is {when}. You are a calm planning buddy having a short conversation. "
                      "Help the person untangle what's on their mind and decide what to do. Ask at most one question at a time. "
                      "Keep replies under 60 words, warm and plain. Do not lecture. "
                      "Only fill 'tasks' when you are suggesting concrete tasks they could add (with steps and minutes); otherwise leave it empty.",
                      text, CHAT_SCHEMA, history=history)
        return {"reply": str(res.get('reply') or '').strip()[:1500] or "Tell me a bit more?", "tasks": clean_ai_tasks(res.get('tasks'))}
    return start_job(job)

@app.post('/api/ai/photo')
@auth
def ai_photo():
    d = request.json or {}
    img = str(d.get('image') or '')
    if not img.startswith('data:image/') or ';base64,' not in img:
        return jsonify(error='That photo could not be read. Try another.'), 400
    mime, data = img[5:].split(';base64,', 1)
    if len(data) > 8_000_000:
        return jsonify(error='That photo is too big. Try a smaller one.'), 400
    note = str(d.get('note') or '')[:500]
    def job():
        res = ai_json(AI_STYLE + " Read the photo (a handwritten list, whiteboard, letter, screenshot or note) and turn what needs doing "
                      "into separate tasks with small steps and minutes. Only include things actually in the photo.",
                      "Turn this photo into tasks." + (f" Extra note: {note}" if note else ""), TASK_SCHEMA,
                      image={"mime": mime, "data": data})
        return {"tasks": clean_ai_tasks(res.get('tasks'))}
    return start_job(job)

EXTRACT_SCHEMA = {"type": "object", "properties": {"items": {"type": "array", "items": {"type": "object", "properties": {
    "title": {"type": "string"}, "emoji": {"type": "string"}, "kind": {"type": "string", "enum": ["event", "todo"]},
    "date": {"type": "string"}, "start": {"type": "string"}, "minutes": {"type": "integer"}, "notes": {"type": "string"}},
    "required": ["title", "emoji", "kind", "date", "start", "minutes", "notes"]}}}, "required": ["items"]}

def clean_extract(items, base):
    out = []
    for t in items or []:
        title = str(t.get('title') or '').strip()[:120]
        if not title:
            continue
        date = str(t.get('date') or '').strip()
        try:
            date = dt.date.fromisoformat(date).isoformat()
        except Exception:
            date = ''
        start = str(t.get('start') or '').strip()
        if not re.fullmatch(r'([01]\d|2[0-3]):[0-5]\d', start):
            start = ''
        kind = 'event' if (t.get('kind') == 'event' and date) else 'todo'
        g = guess(title)
        out.append({"title": title, "emoji": (g[0] if g else (str(t.get('emoji') or '📝').strip() or '📝'))[:8],
                    "color": g[1] if g else '#7CB8F0', "kind": kind, "date": date if kind == 'event' else '',
                    "start": start if kind == 'event' else '', "minutes": max(5, min(480, int(t.get('minutes') or 30))),
                    "notes": str(t.get('notes') or '').strip()[:500]})
    return out[:25]

@app.post('/api/ai/extract')
@auth
def ai_extract():
    """Meeting notes, a transcript, an email or a letter: find appointments and things to do."""
    text = str((request.json or {}).get('text') or '').strip()[:30000]
    if len(text) < 10:
        return jsonify(error='Paste the notes or transcript first'), 400
    base = now()
    when = base.strftime('%A %d %B %Y')
    def job():
        res = ai_json(AI_STYLE + f" Today is {when}. Read the text (meeting notes, a transcript, an email or a letter) and pick out "
                      "only things this person needs to do or go to: appointments, calls, meetings, deadlines and tasks. "
                      "For anything on a particular day, set kind to event and give the date as YYYY-MM-DD (work out words like 'next Tuesday' "
                      "from today's date) and the start time as HH:MM if one is said, otherwise an empty string. Things with no day are kind todo "
                      "with an empty date. Write short, plain titles starting with a verb where it makes sense. Put useful details "
                      "(who, where, phone numbers, what to bring) in notes. Do not invent anything that is not in the text.",
                      f"Text:\n{text}", EXTRACT_SCHEMA)
        return {"items": clean_extract(res.get('items'), base)}
    return start_job(job)

def week_summary(days=7):
    """A plain-text picture of how the last week went, to share with an AI or a supporter."""
    end = now().date()
    start = end - dt.timedelta(days=days - 1)
    lines = [f"My planner, {start.strftime('%a %-d %b')} to {end.strftime('%a %-d %b %Y')}:"]
    with db() as c:
        for i in range(days):
            d = (start + dt.timedelta(days=i)).isoformat()
            rows = c.execute("""SELECT title, start, done, steps, allday, master_id FROM activities WHERE date=? AND kind='event'
                                AND deleted=0 AND is_master=0 ORDER BY start IS NULL, start""", (d,)).fetchall()
            moods = c.execute("SELECT mood, energy, note FROM moods WHERE date=? ORDER BY ts", (d,)).fetchall()
            rev = c.execute("SELECT well, hard FROM reviews WHERE date=?", (d,)).fetchone()
            if not rows and not moods and not rev:
                continue
            day = dt.date.fromisoformat(d).strftime('%A %-d %b')
            ad = [r['title'] for r in rows if r['allday']]
            timed = [r for r in rows if not r['allday']]
            done = sum(1 for r in timed if r['done'])
            lines.append(f"\n{day}" + (f" ({', '.join(ad)})" if ad else "") + (f": {done} of {len(timed)} done" if timed else ""))
            for r in timed:
                st = json.loads(r['steps'] or '[]')
                part = f" ({sum(1 for x in st if x.get('d'))}/{len(st)} steps)" if st and not r['done'] else ''
                lines.append(f"  {'✓' if r['done'] else '·'} {r['start'] or 'any time'} {r['title']}{part}")
            for m in moods:
                mw = {1: 'low', 2: 'not great', 3: 'okay', 4: 'good', 5: 'great'}.get(m['mood'], str(m['mood']))
                lines.append(f"  Mood: {mw}" + (f", energy {m['energy']}/5" if m['energy'] else '') + (f", {m['note']}" if m['note'] else ''))
            if rev and (rev['well'] or rev['hard']):
                if rev['well']: lines.append(f"  Went well: {rev['well']}")
                if rev['hard']: lines.append(f"  Was hard: {rev['hard']}")
        todos = c.execute("SELECT title, priority FROM activities WHERE kind='todo' AND deleted=0 AND done=0").fetchall()
        ahead = c.execute("""SELECT date, start, title FROM activities WHERE kind='event' AND deleted=0 AND is_master=0 AND done=0
                             AND date BETWEEN ? AND ? ORDER BY date, start""", ((end + dt.timedelta(days=1)).isoformat(), (end + dt.timedelta(days=7)).isoformat())).fetchall()
    if todos:
        lines.append("\nStill on my to-do list: " + "; ".join(f"{t['title']}" + (" (urgent)" if t['priority'] == 'now' else '') for t in todos[:25]))
    if ahead:
        lines.append("\nComing up: " + "; ".join(f"{dt.date.fromisoformat(a['date']).strftime('%a')} {a['start'] or ''} {a['title']}".replace('  ', ' ') for a in ahead[:25]))
    return "\n".join(lines)

# ---------- Out and about: what an event is, how to get there, live TfL, and body nudges ----------
UA = {"User-Agent": "Pacely/0.3 (self-hosted day planner; github.com/Samfox84/pacely)"}
TFL = "https://api.tfl.gov.uk"
TFL_KEY = os.environ.get('PACELY_TFL_KEY', '')
PC_RE = re.compile(r'\b([A-Za-z]{1,2}\d[A-Za-z\d]?)\s*(\d[A-Za-z]{2})\b')
_geo_cache = {}

def web_get(url, timeout=20, as_json=True):
    import urllib.request
    req = urllib.request.Request(url, headers=UA)
    with urllib.request.urlopen(req, timeout=timeout) as r:
        raw = r.read()
    return json.loads(raw) if as_json else raw.decode('utf-8', 'replace')

def geocode(text):
    """A UK postcode, address or place name -> (lat, lon, label), or None."""
    from urllib.parse import quote
    q = str(text or '').strip()[:200]
    if not q:
        return None
    if q.lower() in _geo_cache:
        return _geo_cache[q.lower()]
    out = None
    try:
        m = PC_RE.search(q)
        if m:
            r = web_get("https://api.postcodes.io/postcodes/" + quote((m.group(1) + m.group(2)).upper()), timeout=10)
            res = r.get('result') or {}
            if res.get('latitude'):
                out = (res['latitude'], res['longitude'], res.get('postcode') or q)
        if not out:
            r = web_get("https://nominatim.openstreetmap.org/search?format=json&limit=1&countrycodes=gb&q=" + quote(q), timeout=15)
            if r:
                out = (float(r[0]['lat']), float(r[0]['lon']), r[0].get('display_name') or q)
    except Exception as e:
        print('geocode failed', q, e)
    if out:
        _geo_cache[q.lower()] = out
    return out

def drive_minutes(a, b):
    """Driving time. OpenStreetMap routing doesn't know about traffic, so it adds a fifth plus 5 minutes."""
    try:
        r = web_get(f"https://router.project-osrm.org/route/v1/driving/{a[1]},{a[0]};{b[1]},{b[0]}?overview=false", timeout=15)
        rt = r['routes'][0]
        return {"minutes": int(round(rt['duration'] / 60 * 1.2 + 5)), "miles": round(rt['distance'] / 1609.34, 1)}
    except Exception as e:
        print('drive time failed', e)
        return None

TFL_MODES = ('tube', 'elizabeth-line', 'overground', 'dlr', 'bus', 'national-rail', 'tram')

def tfl_journey(a, b, when, arriving=True, modes=None):
    """Public transport from TfL's journey planner, which knows about live disruptions. `when` is a local datetime.
    `modes` limits it to the kinds of transport you're happy to take (walking is always allowed)."""
    q = f"date={when:%Y%m%d}&time={when:%H%M}&timeIs={'Arriving' if arriving else 'Departing'}&journeyPreference=LeastTime"
    if modes:
        q += "&mode=" + ",".join([m for m in modes if m in TFL_MODES] + ['walking'])
    if TFL_KEY:
        q += "&app_key=" + TFL_KEY
    try:
        r = web_get(f"{TFL}/Journey/JourneyResults/{a[0]:.5f},{a[1]:.5f}/to/{b[0]:.5f},{b[1]:.5f}?{q}", timeout=25)
    except Exception as e:
        print('tfl journey failed', e)
        return None
    best = None
    for j in r.get('journeys') or []:
        try:
            st = dt.datetime.fromisoformat(j['startDateTime']).replace(tzinfo=TZ)
            en = dt.datetime.fromisoformat(j['arrivalDateTime']).replace(tzinfo=TZ)
        except Exception:
            continue
        if arriving and en > when + dt.timedelta(minutes=1):
            continue
        if best and (st <= best['_st'] if arriving else en >= best['_en']):
            continue
        lines, steps, notes = [], [], []
        for leg in j.get('legs') or []:
            mode = (leg.get('mode') or {}).get('id') or (leg.get('mode') or {}).get('name') or ''
            names = []
            for ro in leg.get('routeOptions') or []:
                li = (ro.get('lineIdentifier') or {}).get('id')
                if li and mode != 'walking' and li not in lines:
                    lines.append(li)
                if ro.get('name') and mode != 'walking':
                    names.append(ro['name'])
            if mode == 'walking':
                steps.append(f"walk {leg.get('duration', 0)} min")
            elif names:
                steps.append(names[0] + ('' if mode in ('bus', 'national-rail') else ' line' if mode == 'tube' else ''))
            for d in leg.get('disruptions') or []:
                if d.get('description') and d['description'] not in notes:
                    notes.append(d['description'][:240])
        best = {"_st": st, "_en": en, "leave": st.strftime('%H:%M'), "arrive": en.strftime('%H:%M'),
                "minutes": int(j.get('duration') or (en - st).seconds // 60), "lines": lines,
                "summary": ", then ".join(s for s in steps if s)[:200], "disruptions": notes[:3]}
    if best:
        best.pop('_st'); best.pop('_en')
    return best

def line_status(lines):
    """How each line on the route is running right now: [{line, status, good, reason}]."""
    if not lines:
        return []
    try:
        r = web_get(f"{TFL}/Line/{','.join(lines[:8])}/Status" + (f"?app_key={TFL_KEY}" if TFL_KEY else ''), timeout=15)
    except Exception as e:
        print('tfl status failed', e)
        return []
    out = []
    for l in r or []:
        for s in l.get('lineStatuses') or []:
            out.append({"line": l.get('name') or l.get('id'), "status": s.get('statusSeverityDescription') or '',
                        "good": s.get('statusSeverity', 10) == 10, "reason": (s.get('reason') or '')[:300]})
            break
    return out

def travel_prefs(c):
    try:
        buf = int(sget(c, 'travel_buffer', '10') or 10)
    except ValueError:
        buf = 10
    return {"home": sget(c, 'home', ''), "work": sget(c, 'work', ''), "work_start": sget(c, 'work_start', '09:00') or '09:00',
            "leave_style": sget(c, 'leave_style', 'gentle') or 'gentle',
            "modes": [m for m in (sget(c, 'tfl_modes', '') or ','.join(TFL_MODES)).split(',') if m in TFL_MODES] or list(TFL_MODES),
            "travel_by": sget(c, 'travel_by', 'car') or 'car', "home_time": sget(c, 'home_time', '15:00') or '15:00', "travel_buffer": buf, "commute": sget(c, 'commute', '1') == '1'}

def at(date, hhmm):
    h, m = map(int, hhmm.split(':'))
    return dt.datetime.combine(dt.date.fromisoformat(date), dt.time(h, m), TZ)

def plan_trip(place, date='', start='', by=None):
    """How long it takes to get from home to `place`, and when to leave to arrive in time (with your buffer)."""
    with db() as c:
        p = travel_prefs(c)
    if not p['home']:
        return {"error": "Add your home postcode in Me › Getting about, and Pacely can work out when to leave."}
    a, b = geocode(p['home']), geocode(place)
    if not a:
        return {"error": "Couldn't find your home postcode. Check it in Me › Getting about."}
    if not b:
        return {"error": f"Couldn't find {place} on the map."}
    by = by if by in ('car', 'transit', 'both') else p['travel_by']
    out = {"place": place, "found": b[2], "buffer": p['travel_buffer']}
    arrive = None
    if date and re.fullmatch(r'\d\d:\d\d', start or ''):
        try:
            arrive = at(date, start) - dt.timedelta(minutes=p['travel_buffer'])
        except Exception:
            arrive = None
    if by in ('car', 'both'):
        out['drive'] = drive_minutes(a, b)
    if by in ('transit', 'both'):
        out['transit'] = tfl_journey(a, b, arrive or (now() + dt.timedelta(minutes=30)), arriving=bool(arrive), modes=p['modes'])
    use_transit = out.get('transit') and (by == 'transit' or not out.get('drive'))
    if use_transit:
        out.update(by='transit', minutes=out['transit']['minutes'], leave=out['transit']['leave'] if arrive else '')
    elif out.get('drive'):
        mins = out['drive']['minutes']
        out.update(by='car', minutes=mins, leave=(arrive - dt.timedelta(minutes=mins)).strftime('%H:%M') if arrive else '')
    else:
        out['error'] = "Couldn't work out the journey just now."
    return out

def web_search(q, n=5):
    """A few web results (title, link, snippet) from DuckDuckGo, for the private AI helper, which can't search by itself."""
    from urllib.parse import quote, unquote
    try:
        h = web_get("https://html.duckduckgo.com/html/?q=" + quote(q), as_json=False, timeout=15)
    except Exception as e:
        print('web search failed', e)
        return []
    out = []
    tag = lambda s: re.sub(r'\s+', ' ', re.sub(r'<[^>]+>', '', s)).replace('&amp;', '&').replace('&#x27;', "'").replace('&quot;', '"').strip()
    for m in re.finditer(r'class="result__a"[^>]*href="([^"]+)"[^>]*>(.*?)</a>(.*?)(?=class="result__a"|$)', h, re.S):
        href = m.group(1)
        u = re.search(r'uddg=([^&]+)', href)
        href = unquote(u.group(1)) if u else href
        if 'duckduckgo.com/y.js' in href:
            continue   # adverts
        sn = re.search(r'class="result__snippet"[^>]*>(.*?)</a>', m.group(3), re.S)
        out.append({"title": tag(m.group(2))[:150], "url": href[:400], "snippet": tag(sn.group(1))[:400] if sn else ''})
        if len(out) >= n:
            break
    return out

def look_up(text):
    """What the web says about an event or place: (facts, sources). Gemini searches Google; the private helper uses DuckDuckGo."""
    st = ai_settings()
    if st['provider'] == 'gemini' and st['key']:
        res = gemini_generate(st, {
            "contents": [{"role": "user", "parts": [{"text":
                f"Today is {now():%A %d %B %Y}. Someone in the UK wrote this in their planner: \"{text}\". Search the web and say briefly: "
                "what it is, the venue name, the full address with postcode, the official website, ticket prices, the times on that day, "
                "whether you need to book, and parking or travel tips. Say 'unknown' for anything you can't find."}]}],
            "tools": [{"google_search": {}}]}, timeout=120)
        c0 = (res.get('candidates') or [{}])[0]
        txt = "".join(p.get('text', '') for p in (c0.get('content') or {}).get('parts', []))
        srcs = [{"title": (ch.get('web') or {}).get('title', ''), "url": (ch.get('web') or {}).get('uri', '')}
                for ch in (c0.get('groundingMetadata') or {}).get('groundingChunks') or []]
        return txt[:6000], [s for s in srcs if s['url']][:5]
    results = web_search(text + " UK")
    return "\n".join(f"- {r['title']} ({r['url']}): {r['snippet']}" for r in results), [{"title": r['title'], "url": r['url']} for r in results]

EVENT_SCHEMA = {"type": "object", "properties": {
    "title": {"type": "string"}, "emoji": {"type": "string"}, "date": {"type": "string"}, "start": {"type": "string"},
    "minutes": {"type": "integer"}, "place": {"type": "string"}, "address": {"type": "string"}, "website": {"type": "string"},
    "price": {"type": "string"}, "notes": {"type": "string"}},
    "required": ["title", "emoji", "date", "start", "minutes", "place", "address", "website", "price", "notes"]}

def smart_event(text):
    """'audley end christmas event 28 nov 1pm' -> a ready-to-add plan item with the venue, website, price and when to leave."""
    facts, srcs = '', []
    try:
        facts, srcs = look_up(text)
    except ValueError:
        raise
    except Exception as e:
        print('look up failed', e)
    res = ai_json(AI_STYLE + f" Today is {now():%A %d %B %Y}. Turn what the person wrote into one planner entry. Use the web facts to fill in "
                  "the venue (place), full address with postcode, official website and ticket price, but only when they clearly match. "
                  "What the person wrote always wins for the date and time. date is YYYY-MM-DD (work out words like 'next Saturday'), start is HH:MM "
                  "or an empty string. minutes is how long they'll be there (a realistic guess if not said). notes is 2 to 4 short, useful lines: "
                  "what it is, booking, parking or what to bring. Use empty strings for anything unknown. Never invent a website or price.",
                  f"They wrote: {text}\n\nWhat the web says:\n{facts or '(nothing found)'}", EVENT_SCHEMA)
    if job_cancelled():
        return {"item": None}
    title = str(res.get('title') or text).strip()[:120]
    date = str(res.get('date') or '').strip()
    try:
        date = dt.date.fromisoformat(date).isoformat()
    except Exception:
        date = ''
    start = str(res.get('start') or '').strip()
    if not re.fullmatch(r'([01]\d|2[0-3]):[0-5]\d', start):
        start = ''
    web = str(res.get('website') or '').strip()
    if web and not web.startswith('http'):
        web = 'https://' + web
    if not re.fullmatch(r'https?://[^\s"<>]+', web):
        web = ''
    price = str(res.get('price') or '').strip()
    price = '' if price.lower() in ('unknown', 'n/a', 'none') else price[:120]
    place = str(res.get('place') or '').strip()[:120]
    address = str(res.get('address') or '').strip()[:200]
    if address.lower() == 'unknown': address = ''
    if place.lower() == 'unknown': place = ''
    notes = [str(res.get('notes') or '').strip()[:600]]
    if price: notes.append(f"Tickets: {price}")
    g = guess(title) or (str(res.get('emoji') or '📍')[:8], '#7CB8F0')
    item = {"title": title, "emoji": g[0], "color": g[1], "date": date, "start": start,
            "duration": max(15, min(720, int(res.get('minutes') or 120))), "location": address or place, "link": web,
            "notes": "\n".join(n for n in notes if n), "price": price, "place": place}
    trip = plan_trip(address or place or title, date, start) if (address or place) else None
    if trip and not trip.get('error'):
        item.update(travel_min=trip.get('minutes'), travel_by=trip.get('by'), leave=trip.get('leave') or None)
    return {"item": item, "trip": trip, "sources": srcs}

def nudge_list(c):
    """Gentle body reminders the person switched on: drink, eat, rest. [(key, HH:MM, title, body)]"""
    try:
        on = json.loads(sget(c, 'nudges', '{}') or '{}')
    except Exception:
        on = {}
    out = []
    if on.get('drink'):
        out += [('drink', t, '💧 Sip of water?', 'A few sips now. Your brain runs on it.') for t in ('10:00', '12:00', '14:00', '16:00', '18:00', '20:00')]
    if on.get('eat'):
        out += [('eat', t, f'🍽️ Time for {m}?', 'Even something small counts.') for t, m in (('08:30', 'breakfast'), ('12:30', 'lunch'), ('18:30', 'dinner'))]
    if on.get('rest'):
        out += [('rest', t, '🧘 A little pause', 'Stand up, stretch, breathe out slowly. Two minutes is enough.') for t in ('11:00', '15:00', '19:30')]
    return sorted(out, key=lambda x: x[1])

def commute_get(c, date):
    r = c.execute("SELECT json FROM commute WHERE date=?", (date,)).fetchone()
    try:
        return json.loads(r['json']) if r else None
    except Exception:
        return None

def _leg_alert(prev, j, status, outbound, td):
    """Should we tell you? Only when the time you need to leave really changes (10 minutes or more).
    How the lines are running shows quietly on the card, without a notification. Returns (title, body) or None."""
    if not prev:
        return None
    bad = [x for x in status if not x['good']]
    why = f"{bad[0]['line']} line has {bad[0]['status'].lower()}." if bad else "The route has changed."
    if outbound:
        diff = int((at(td, prev['leave']) - at(td, j['leave'])).total_seconds() // 60)   # minutes earlier than before
        if diff >= 10:
            return (f"🚇 Leave a bit earlier today: {j['leave']}", f"{diff} min earlier than before. {why}")
        if diff <= -10:
            return (f"🚇 You can leave a bit later: {j['leave']}", f"{-diff} min later than before.")
    else:
        longer = (j.get('minutes') or 0) - (prev.get('minutes') or 0)
        if longer >= 15:
            return ("🏠 Getting home is slower today", f"About {longer} min longer, home around {j['arrive']}. {why}")
    return None

def commute_check(force=False):
    """On office days, checks the TfL route to work (in the 3 hours before you start) and home again (in the 2 hours
    before you head home) every 5 minutes, and tells you if a delay changes things."""
    n = now()
    td = n.date().isoformat()
    with db() as c:
        p = travel_prefs(c)
        if not (p['commute'] and p['home'] and p['work']):
            return None
        materialize(c, td)
        office = c.execute("SELECT 1 FROM activities WHERE date=? AND allday='office' AND deleted=0 AND is_master=0", (td,)).fetchone()
        prev = commute_get(c, td) or {}
    if not office:
        return None
    try:
        start, home_at = at(td, p['work_start']), at(td, p['home_time'])
    except Exception:
        return prev or None
    a = b = None
    info = dict(prev)
    alerts = []
    due = lambda leg: force or not leg or n - dt.datetime.fromisoformat(leg['checked']) >= dt.timedelta(minutes=5)
    # there
    if (force or start - dt.timedelta(hours=3) <= n <= start) and due(prev if prev.get('leave') else None):
        a, b = geocode(p['home']), geocode(p['work'])
        j = tfl_journey(a, b, start - dt.timedelta(minutes=p['travel_buffer']), modes=p['modes']) if a and b else None
        if j:
            st = line_status(j['lines'])
            al = _leg_alert(prev if prev.get('leave') else None, j, st, True, td)
            info.update(j, date=td, status=st, checked=n.isoformat(), work_start=p['work_start'], alert=al[1] if al else prev.get('alert'),
                        alerted=al[0] if al else prev.get('alerted', ''))
            if al: alerts.append(al)
    # and home again
    back = prev.get('back')
    if (force or home_at - dt.timedelta(hours=2) <= n <= home_at + dt.timedelta(minutes=10)) and due(back):
        a, b = a or geocode(p['home']), b or geocode(p['work'])
        j = tfl_journey(b, a, home_at, arriving=False, modes=p['modes']) if a and b else None
        if j:
            st = line_status(j['lines'])
            al = _leg_alert(back, j, st, False, td)
            info['back'] = dict(j, status=st, checked=n.isoformat(), home_time=p['home_time'],
                                alert=al[1] if al else (back or {}).get('alert'), alerted=al[0] if al else (back or {}).get('alerted', ''))
            info.setdefault('date', td)
            if al: alerts.append(al)
    if info != prev:
        with db() as c:
            c.execute("INSERT OR REPLACE INTO commute(date, json) VALUES(?, ?)", (td, json.dumps(info)))
    with db() as c:
        hush = in_quiet_hours(c, n)
    for t, body in alerts:
        if not hush:
            push_all(t, body, tag='commute')
    return info or None

def commute_items(c, date):
    """Your journeys as items, so they show on the Lock Screen countdown and widgets like any other activity."""
    cm = commute_get(c, date) or {}
    out = []
    for key, leg, title in (('to', cm, 'Leave for work'), ('back', cm.get('back') or {}, 'Head home')):
        if not leg.get('leave'):
            continue
        out.append({"id": -900001 if key == 'to' else -900002, "date": date, "start": leg['leave'], "duration": max(5, leg.get('minutes') or 30),
                    "title": title, "emoji": '🚇' if key == 'to' else '🏠', "color": '#7CB8F0',
                    "remind": -1, "end_alert": 0, "done": 0, "steps": [], "nag": 0, "leave": leg['leave'], "travel_min": leg.get('minutes') or 0,
                    "travel_by": 'transit',
                    "summary": leg.get('summary') or ''})
    return out

@app.post('/api/ai/event')
@auth
def ai_event():
    """One thing in plain words ('audley end christmas event 28 nov 1pm'): find it online and work out when to leave."""
    text = str((request.json or {}).get('text') or '').strip()[:1000]
    if len(text) < 3:
        return jsonify(error='Type or say what it is first'), 400
    return start_job(smart_event, text)

LIST_SCHEMA = {"type": "object", "properties": {
    "title": {"type": "string"}, "emoji": {"type": "string"}, "kind": {"type": "string", "enum": ["todo", "event"]},
    "date": {"type": "string"}, "start": {"type": "string"}, "notes": {"type": "string"},
    "steps": {"type": "array", "items": {"type": "string"}}},
    "required": ["title", "emoji", "kind", "date", "start", "notes", "steps"]}

def simple_list(text):
    """No AI needed: split a long message into one thing per line."""
    parts = re.split(r'\n|,|;|\s+\band\b\s+|\s+&\s+|•|\s-\s', text)
    steps = []
    for x in parts:
        x = re.sub(r'^\s*(?:[-*•]|\d+[.)])\s*', '', x).strip(' .\t')
        if x and len(x) < 150 and x.lower() not in [s.lower() for s in steps]:
            steps.append(x[:1].upper() + x[1:])
    return steps[:60]

def tidy_list(text):
    """A messy message ("milk eggs bread 2 tins chopped tomatoes and the good cheese") -> a calm, tickable list."""
    base = {"title": "List", "emoji": "📝", "kind": "todo", "date": "", "start": "", "notes": "", "steps": simple_list(text), "ai": False}
    if re.search(r'\b(shop|shopping|tesco|sainsbury|asda|aldi|lidl|groceries|supermarket|milk|bread|eggs)\b', text, re.I):
        base.update(title="Shopping", emoji="🛒")
    try:
        res = ai_json(AI_STYLE + f" Today is {now():%A %d %B %Y}. Someone sent this message to a person with ADHD and autism, who finds long "
                      "run-on messages hard to read. Turn it into one clear checklist. Each step is ONE thing, written plainly, quantity first "
                      "if there is one (e.g. '2 × tins of chopped tomatoes'), with any detail in brackets (e.g. 'Cheese (the mature cheddar)'). "
                      "For shopping, order the steps the way you walk round a UK supermarket: fruit and veg, bread, meat and fish, dairy and "
                      "eggs, cupboard food, frozen, drinks, household. Give a short title (e.g. 'Shopping', 'Before Saturday'). If it must be done "
                      "on a particular day set kind to event with date YYYY-MM-DD and start HH:MM or empty; otherwise kind todo. Put anything that "
                      "isn't a step (who it's for, reminders, context) in notes. Keep every item they mentioned and don't add any.",
                      f"Message:\n{text}", LIST_SCHEMA)
        steps = [str(x).strip()[:150] for x in res.get('steps') or [] if str(x).strip()][:60]
        if steps:
            date = str(res.get('date') or '')
            try:
                date = dt.date.fromisoformat(date).isoformat()
            except Exception:
                date = ''
            start = str(res.get('start') or '')
            base.update(title=str(res.get('title') or base['title']).strip()[:80], emoji=(str(res.get('emoji') or base['emoji']).strip() or '📝')[:8],
                        kind='event' if res.get('kind') == 'event' and date else 'todo', date=date,
                        start=start if re.fullmatch(r'([01]\d|2[0-3]):[0-5]\d', start) else '',
                        notes=str(res.get('notes') or '').strip()[:600], steps=steps, ai=True)
    except Exception as e:
        print('tidy list: using the simple version', repr(e))
        base['note'] = ai_reason(e)
    g = guess(base['title'])
    base['color'] = g[1] if g else '#7CB8F0'
    if g and base['emoji'] == '📝':
        base['emoji'] = g[0]
    return base

@app.post('/api/ai/tidy')
@auth
def ai_tidy():
    text = str((request.json or {}).get('text') or '').strip()[:6000]
    if len(text) < 3:
        return jsonify(error='Paste the message first'), 400
    return start_job(tidy_list, text)

@app.post('/api/ai/check')
@auth
def ai_check():
    """Asks the AI helper something tiny, and says how long it took (or exactly why it didn't answer)."""
    def job():
        t0 = _time.time()
        res = ai_json("Answer in JSON.", "Say hello in five words or fewer.", {"type": "object", "properties": {"reply": {"type": "string"}}, "required": ["reply"]})
        return {"reply": str(res.get('reply') or '')[:200], "seconds": round(_time.time() - t0, 1), "provider": ai_settings()['provider']}
    return start_job(job)

@app.post('/api/trip')
@auth
def api_trip():
    d = request.json or {}
    place = str(d.get('place') or '').strip()
    if not place:
        return jsonify(error='Where to?'), 400
    return jsonify(plan_trip(place, str(d.get('date') or ''), str(d.get('start') or ''), d.get('by')))

@app.get('/api/commute')
@auth
def api_commute():
    """Today's route to work. ?refresh=1 checks TfL now."""
    info = commute_check(force=request.args.get('refresh') == '1')
    if info is None:
        with db() as c:
            p = travel_prefs(c)
        if not (p['home'] and p['work']):
            return jsonify(error="Add your home and work postcodes in Me › Getting about."), 400
        return jsonify(error="Today isn't an office day. Add 'In the office' to a day and Pacely watches your route that morning."), 404
    return jsonify(info)

@app.get('/api/summary')
@auth
def summary():
    days = max(1, min(31, int(request.args.get('days') or 7)))
    return jsonify(text=week_summary(days))

@app.post('/api/ai/add')
@auth
def ai_add():
    """Add reviewed AI tasks: to the to-do list, or scheduled one after another from a start time."""
    d = request.json or {}
    tasks = clean_ai_tasks(d.get('tasks'))
    mode = d.get('mode', 'todo')
    date = d.get('date') or today()
    gap = max(0, min(60, int(d.get('gap') or 0)))
    t = None
    if mode == 'schedule':
        h, m = map(int, (d.get('start') or now().strftime('%H:%M')).split(':'))
        t = h * 60 + m
    colors = ['#7CB8F0', '#73CBA8', '#F4A07A', '#B89AE8', '#F6C453', '#EE8FA6', '#A8C686', '#D9B99B']
    with db() as c:
        for i, k in enumerate(tasks):
            base = dict(title=k['title'], emoji=k['emoji'], color=colors[i % len(colors)], duration=k['minutes'],
                        steps=json.dumps(k['steps']), priority=k['priority'], created=now().isoformat(), remind=0, end_alert=1)
            if mode == 'schedule':
                base.update(kind='event', date=date, start=f"{(t // 60) % 24:02d}:{t % 60:02d}")
                t += k['minutes'] + gap
            else:
                base.update(kind='todo')
            keys = list(base)
            c.execute(f"INSERT INTO activities({','.join(keys)}) VALUES({','.join('?' * len(keys))})", [base[x] for x in keys])
    return jsonify(ok=True, added=len(tasks))

# ---------- iPhone app + widget ----------
@app.post('/api/token')
def get_token():
    ip = client_ip()
    cnt, until = fails.get(ip, (0, 0))
    if _time.time() < until:
        return jsonify(error=f"Too many tries. Wait {int(until - _time.time())}s"), 429
    pw = (request.json or {}).get('password', '')
    with db() as c:
        if not check_pw(pw, sget(c, 'pw', '')):
            cnt += 1
            fails[ip] = (0, _time.time() + 60) if cnt >= 5 else (cnt, 0)
            return jsonify(error='Wrong password'), 403
        return jsonify(token=sget(c, 'api_token'), widget=sget(c, 'read_token'))

@app.get('/auth')
def auth_link():
    tok = request.args.get('t', '')
    with db() as c:
        good = sget(c, 'api_token', '')
    if good and tok and hmac.compare_digest(tok, good):
        session.permanent = True
        session['ok'] = True
    from flask import redirect
    return redirect('/')

@app.get('/api/upcoming')
@auth
def upcoming():
    """Everything the iPhone app needs to schedule its own reminders for the next two days."""
    out = []
    with db() as c:
        for i in range(2):
            d = (now().date() + dt.timedelta(days=i)).isoformat()
            materialize(c, d)
            quiet = quiet_day(c, d)
            for r in ([] if quiet else c.execute("""SELECT * FROM activities WHERE date=? AND kind='event' AND deleted=0 AND is_master=0
                                  AND start IS NOT NULL""", (d,)).fetchall()):
                out.append({"id": r['id'], "date": d, "start": r['start'], "duration": r['duration'], "title": r['title'],
                            "emoji": r['emoji'], "color": r['color'], "remind": r['remind'], "end_alert": r['end_alert'], "done": r['done'],
                            "steps": json.loads(r['steps'] or '[]'), "nag": r['nag'] or 0, "leave": r['leave'] or '',
                            "travel_min": r['travel_min'] or 0, "travel_by": r['travel_by'] or ''})
            for e in cal_rows(c, d, "AND e.all_day=0"):
                out.append({"id": -e['id'], "date": d, "start": e['start'], "duration": e['duration'], "title": e['title'],
                            "emoji": e['kemoji'] or '📅', "color": e['kcolor'] or '#9AA8BA', "remind": e['remind'], "end_alert": 0,
                            "done": 0, "steps": []})
        f = sget(c, 'focus')
        nudges = [{"date": (now().date() + dt.timedelta(days=i)).isoformat(), "key": k, "time": t, "title": ti, "body": b}
                  for i in range(2) for k, t, ti, b in nudge_list(c)]
        out += commute_items(c, today())
    out.sort(key=lambda x: (x['date'], x['start']))
    added = []
    with db() as c:
        since = (now() - dt.timedelta(days=2)).isoformat()
        for r in c.execute("""SELECT id, title, emoji, date, start, added_by, created FROM activities WHERE added_by<>'' AND deleted=0
                              AND created>=? ORDER BY created""", (since,)).fetchall():
            try:
                ts = dt.datetime.fromisoformat(r['created']).timestamp()
            except Exception:
                ts = None
            d0 = dt.date.fromisoformat(r['date']) if r['date'] else None
            when = 'today' if r['date'] == today() else (d0.strftime('%a %-d %b') if d0 else 'to-do')
            added.append({"id": r['id'], "title": r['title'], "emoji": r['emoji'], "by": r['added_by'],
                          "when": when + (f" at {r['start']}" if r['start'] else ''), "createdTs": ts})
    with db() as c:
        style = sget(c, 'leave_style', 'gentle') or 'gentle'
        qf, qt = sget(c, 'quiet_from', ''), sget(c, 'quiet_to', '')
    return jsonify(items=out, focus=json.loads(f) if f else None, tz=str(TZ), added=added, nudges=nudges, leave_style=style,
                   quiet_from=qf, quiet_to=qt)

@app.get('/api/widget')
def widget():
    """Read-only summary for the home screen widget. Uses the separate widget code, not your password."""
    k = request.args.get('k', '') or (request.headers.get('Authorization', '')[7:] if request.headers.get('Authorization', '').startswith('Bearer ') else '')
    with db() as c:
        good = sget(c, 'read_token', '')
        if not good or not k or not hmac.compare_digest(k, good):
            return jsonify(error='bad code'), 401
        n = now()
        td = n.date().isoformat()
        materialize(c, td)
        auto_tick(c, n)
        rows = [dict(r) for r in c.execute("""SELECT id, title, emoji, color, start, duration, done, steps FROM activities WHERE date=?
                    AND kind='event' AND deleted=0 AND is_master=0 AND (allday IS NULL OR allday='') ORDER BY start IS NULL, start""", (td,))]
        cal = cal_items(c, td)
        trips = commute_items(c, td)
    items = []
    for r in rows + [x for x in cal if not x['all_day']] + trips:
        if not r.get('start'):
            continue
        h, m = map(int, r['start'].split(':'))
        st = dt.datetime.combine(n.date(), dt.time(h, m), TZ)
        en = st + dt.timedelta(minutes=r['duration'] or 30)
        steps = r['steps'] if isinstance(r['steps'], list) else json.loads(r['steps'] or '[]')
        rid = r['id'] if isinstance(r.get('id'), int) else 0
        items.append({"id": rid, "title": r['title'], "emoji": r['emoji'] or '📝', "color": r['color'] or '#7CB8F0', "start": r['start'],
                      "startTs": int(st.timestamp()), "endTs": int(en.timestamp()), "done": bool(r['done']),
                      "steps": len(steps), "stepsDone": sum(1 for s in steps if s.get('d'))})
    items.sort(key=lambda x: x['startTs'])
    ts = n.timestamp()
    cur = next((i for i in items if i['startTs'] <= ts < i['endTs'] and not i['done']), None)
    nxt = [i for i in items if i['startTs'] > ts and not i['done']][:4]
    total = len(rows)
    with db() as c:
        f = sget(c, 'focus')
    try:
        fj = json.loads(f) if f else None
    except Exception:
        fj = None
    focus = None
    if fj and fj.get('end', 0) / 1000 > ts:
        end_s = fj['end'] / 1000
        ftotal = fj.get('total') or 0
        focus = {"title": fj.get('title') or '⏳ Focus', "endTs": int(end_s),
                 "startTs": int(end_s - ftotal) if ftotal else int(ts), "color": fj.get('color') or '#73CBA8'}
    return jsonify(now=cur, next=nxt, done=sum(1 for r in rows if r['done']), total=total, date=td, generated=int(ts), focus=focus)

@app.post('/api/widget/done')
def widget_done():
    """Lets a widget or Lock Screen button tick an activity off. Uses the widget code, which can only do this."""
    k = request.args.get('k', '')
    with db() as c:
        good = sget(c, 'read_token', '')
        if not good or not k or not hmac.compare_digest(k, good):
            return jsonify(error='bad code'), 401
        id_ = int((request.json or {}).get('id') or request.args.get('id') or 0)
        a = c.execute("SELECT id FROM activities WHERE id=? AND deleted=0", (id_,)).fetchone()
        if not a:
            return jsonify(error='not found'), 404
        update(c, id_, {"done": 1, "done_at": now().isoformat()})
    return jsonify(ok=True)

# ---- two-way sync with the iPhone's own calendars ----
@app.get('/api/sync')
@auth
def sync_window():
    days = max(1, min(31, int(request.args.get('days') or 14)))
    out = []
    with db() as c:
        start = now().date() - dt.timedelta(days=1)
        for i in range(days + 1):
            materialize(c, (start + dt.timedelta(days=i)).isoformat())
        for r in c.execute("""SELECT * FROM activities WHERE kind='event' AND deleted=0 AND is_master=0 AND start IS NOT NULL
                              AND date BETWEEN ? AND ?""", (start.isoformat(), (start + dt.timedelta(days=days)).isoformat())):
            steps = json.loads(r['steps'] or '[]')
            notes = (r['notes'] or '') + ('\n\n' if r['notes'] and steps else '') + '\n'.join(('✓ ' if s.get('d') else '• ') + s['t'] for s in steps)
            out.append({"id": r['id'], "date": r['date'], "start": r['start'], "duration": r['duration'], "title": r['title'],
                        "emoji": r['emoji'] or '', "notes": notes, "done": r['done'], "repeating": bool(r['master_id'])})
    return jsonify(items=out, tz=str(TZ), from_=start.isoformat())

@app.post('/api/phonecal')
@auth
def phonecal():
    """Events read from the calendars on the iPhone (iCloud, Google, Outlook accounts)."""
    evs = (request.json or {}).get('events') or []
    with db() as c:
        cal = c.execute("SELECT * FROM calendars WHERE url='device://iphone'").fetchone()
        if not cal:
            cur = c.execute("INSERT INTO calendars(name,url,color,emoji,remind) VALUES('iPhone calendars','device://iphone','#9AA8BA','📅',10)")
            cal_id = cur.lastrowid
        else:
            cal_id = cal['id']
        c.execute("DELETE FROM cal_events WHERE cal_id=?", (cal_id,))
        rows = []
        for e in evs[:3000]:
            try:
                dt.date.fromisoformat(e['date'])
                rows.append((cal_id, str(e.get('uid') or '')[:200], str(e.get('title') or 'Busy')[:200], e['date'],
                             e.get('start') if not e.get('all_day') else None, max(5, min(1440, int(e.get('duration') or 30))),
                             1 if e.get('all_day') else 0, str(e.get('location') or '')[:300], 1 if e.get('repeats') else 0))
            except Exception:
                continue
        c.executemany("INSERT INTO cal_events(cal_id,uid,title,date,start,duration,all_day,location,repeats) VALUES(?,?,?,?,?,?,?,?,?)", rows)
        c.execute("UPDATE calendars SET last_sync=?, error=NULL WHERE id=?", (now().isoformat(), cal_id))
    return jsonify(ok=True, events=len(rows))

# ---------- less friction: recent items, leftovers ----------
@app.get('/api/recent')
@auth
def recent():
    """Things you add often, for one-tap adding."""
    since = (now().date() - dt.timedelta(days=60)).isoformat()
    with db() as c:
        rows = c.execute("""SELECT title, emoji, color, duration, steps, start, COUNT(*) n, MAX(created) last FROM activities
                            WHERE kind='event' AND deleted=0 AND is_master=0 AND (allday IS NULL OR allday='') AND COALESCE(date, '') >= ?
                            GROUP BY lower(title) ORDER BY n DESC, last DESC LIMIT 8""", (since,)).fetchall()
    out = []
    for r in rows:
        steps = [dict(s, d=False) for s in json.loads(r['steps'] or '[]')]
        out.append({"title": r['title'], "emoji": r['emoji'], "color": r['color'], "duration": r['duration'], "start": r['start'], "steps": steps})
    return jsonify(out)

@app.get('/api/leftovers')
@auth
def leftovers():
    """One-off activities from the last week that weren't ticked off."""
    td = now().date()
    with db() as c:
        rows = c.execute("""SELECT * FROM activities WHERE kind='event' AND deleted=0 AND is_master=0 AND done=0 AND master_id IS NULL
                            AND (allday IS NULL OR allday='') AND date BETWEEN ? AND ? ORDER BY date, start""",
                         ((td - dt.timedelta(days=7)).isoformat(), (td - dt.timedelta(days=1)).isoformat())).fetchall()
    return jsonify([row(r) for r in rows])

@app.post('/api/leftovers')
@auth
def leftovers_do():
    """Deal with leftovers in one go: action 'today', 'todo' or 'let_go'."""
    d = request.json or {}
    ids = [int(x) for x in (d.get('ids') or [])][:200]
    act = d.get('action')
    n = now()
    with db() as c:
        for id_ in ids:
            a = c.execute("SELECT * FROM activities WHERE id=? AND deleted=0", (id_,)).fetchone()
            if not a:
                continue
            if act == 'today':
                start = a['start']
                if start and start <= n.strftime('%H:%M'):
                    start = None   # its time has gone today, so it becomes "anytime today"
                update(c, id_, {"date": n.date().isoformat(), "start": start})
            elif act == 'todo':
                update(c, id_, {"kind": "todo", "date": None, "start": None})
            elif act == 'move':
                try:
                    to = dt.date.fromisoformat(d.get('to') or '').isoformat()
                except Exception:
                    continue
                update(c, id_, {"date": to})
            elif act == 'let_go':
                update(c, id_, {"deleted": 1})
    return jsonify(ok=True, n=len(ids))

# ---------- sharing: let someone add things for you, no app needed ----------
def share_for(c, tok):
    if not tok or len(tok) < 16:
        return None
    for r in c.execute("SELECT * FROM shares").fetchall():
        if hmac.compare_digest(tok, r['token']):
            return r
    return None

def new_invite(c, tok):
    code = secrets.token_urlsafe(9)
    c.execute("UPDATE shares SET invite=?, invite_expires=? WHERE token=?",
              (code, (now() + dt.timedelta(days=7)).isoformat(), tok))
    return code

@app.get('/api/shares')
@auth
def shares():
    with db() as c:
        out = []
        for r in c.execute("SELECT * FROM shares ORDER BY created").fetchall():
            d = dict(r)
            if d.get('invite') and (d.get('invite_expires') or '') < now().isoformat():
                d['invite'] = None
            d['invite_path'] = f"/join/{d['invite']}" if d.get('invite') else None
            out.append(d)
        return jsonify(out)

@app.post('/api/shares/<tok>/invite')
@auth
def share_reinvite(tok):
    """A fresh one-time invite. When it's used, the phone that used the old one is signed out."""
    with db() as c:
        if not c.execute("SELECT 1 FROM shares WHERE token=?", (tok,)).fetchone():
            return jsonify(error='not found'), 404
        code = new_invite(c, tok)
    return jsonify(invite=code, invite_path=f"/join/{code}")

def invite_row(c, code):
    if not code or len(code) < 8:
        return None
    for r in c.execute("SELECT * FROM shares WHERE invite IS NOT NULL").fetchall():
        if hmac.compare_digest(code, r['invite']) and (r['invite_expires'] or '') >= now().isoformat():
            return r
    return None

@app.get('/join/<code>')
def join_page(code):
    """Opens the Pacely app to accept an invite. Shows nothing of the plan."""
    with db() as c:
        r = invite_row(c, code)
        owner = sget(c, 'my_name', '') or 'Someone'
    if not r:
        body = "<h1>This invite has been used</h1><p>Each invite works once. Ask for a new one.</p>"
    else:
        body = (f"<h1>{escape(owner)} invited you to Pacely</h1><p>Opening the Pacely app…</p>"
                f"<p><a class=b id=go href='#'>Open in Pacely</a></p>"
                "<p class=s>Pacely needs to be on this phone first. Once you join, this link stops working.</p>"
                "<script>var u='pacely://join?server='+encodeURIComponent(location.origin)+'&code='+encodeURIComponent(location.pathname.split('/').pop());"
                "document.getElementById('go').href=u;setTimeout(function(){location.href=u},300);</script>")
    html = ("<!doctype html><meta charset=utf-8><meta name=viewport content='width=device-width,initial-scale=1'><meta name=robots content=noindex>"
            "<title>Pacely invite</title><style>body{font:18px/1.45 -apple-system,system-ui,sans-serif;margin:0;padding:48px 24px;background:#FBF7F1;color:#2B2A33;text-align:center}"
            "@media(prefers-color-scheme:dark){body{background:#15171C;color:#ECEAF0}}h1{font-size:26px}"
            ".b{display:inline-block;background:#2F7D78;color:#fff;padding:14px 26px;border-radius:16px;text-decoration:none;font-weight:700}.s{opacity:.7;font-size:15px}</style>" + body)
    r2 = Response(html, mimetype='text/html')
    r2.headers['Cache-Control'] = 'no-store'
    r2.headers['X-Robots-Tag'] = 'noindex'
    return r2

@app.post('/join/<code>')
def join_redeem(code):
    """The app swaps a one-time invite for its own private key. The invite stops working."""
    d = request.json or {}
    with db() as c:
        r = invite_row(c, code)
        if not r:
            return jsonify(error='This invite has been used or has run out. Ask for a new one.'), 404
        fresh = secrets.token_urlsafe(32)      # a new key, so any older phone or link stops working
        c.execute("UPDATE shares SET token=?, invite=NULL, invite_expires=NULL, joined=?, device=?, web=0 WHERE token=?",
                  (fresh, now().isoformat(), str(d.get('device') or 'iPhone')[:60], r['token']))
        owner = sget(c, 'my_name', '') or 'them'
    push_all(f"💌 {r['name']} joined your plan", "They can now add things for you from the Pacely app.", tag='share')
    return jsonify(token=fresh, name=r['name'], owner=owner)

@app.post('/api/shares')
@auth
def share_new():
    d = request.json or {}
    name = str(d.get('name') or '').strip()[:40] or 'Family'
    see = 'own' if d.get('see') == 'own' else 'all'
    tok = secrets.token_urlsafe(32)
    with db() as c:
        c.execute("INSERT INTO shares(token,name,see,created,web) VALUES(?,?,?,?,?)", (tok, name, see, now().isoformat(), 1 if d.get('web') else 0))
        if d.get('my_name'):
            sset(c, 'my_name', str(d['my_name']).strip()[:40])
        code = new_invite(c, tok)
        r = dict(c.execute("SELECT * FROM shares WHERE token=?", (tok,)).fetchone())
    r['invite_path'] = f"/join/{code}"
    return jsonify(r)

@app.put('/api/shares/<tok>')
@auth
def share_edit(tok):
    d = request.json or {}
    with db() as c:
        if 'see' in d:
            c.execute("UPDATE shares SET see=? WHERE token=?", ('own' if d['see'] == 'own' else 'all', tok))
        if d.get('name'):
            c.execute("UPDATE shares SET name=? WHERE token=?", (str(d['name']).strip()[:40], tok))
        if 'web' in d:
            c.execute("UPDATE shares SET web=? WHERE token=?", (1 if d['web'] else 0, tok))
    return jsonify(ok=True)

@app.delete('/api/shares/<tok>')
@auth
def share_del(tok):
    with db() as c:
        c.execute("DELETE FROM shares WHERE token=?", (tok,))
    return jsonify(ok=True)

def share_rows(c, sh, days=21):
    base = now().date()
    for i in range(-1, days):
        materialize(c, (base + dt.timedelta(days=i)).isoformat())
    q = """SELECT * FROM activities WHERE kind='event' AND deleted=0 AND is_master=0 AND date BETWEEN ? AND ?"""
    args = [(base - dt.timedelta(days=1)).isoformat(), (base + dt.timedelta(days=days)).isoformat()]
    if sh['see'] == 'own':
        q += " AND added_by=?"
        args.append(sh['name'])
    else:
        q += " AND (COALESCE(private, 0)=0 OR added_by=?)"   # private things stay private
        args.append(sh['name'])
    return c.execute(q + " ORDER BY date, start IS NOT NULL, start", args).fetchall()

@app.get('/s/<tok>')
def share_page(tok):
    with db() as c:
        sh = share_for(c, tok)
        if not sh or not sh['web']:
            return Response('This link has been switched off.', 404)
    r = send_from_directory(STATIC, 'share.html')
    r.headers['Cache-Control'] = 'no-cache'
    r.headers['X-Robots-Tag'] = 'noindex'
    return r

@app.get('/s/<tok>/data')
def share_data(tok):
    with db() as c:
        sh = share_for(c, tok)
        if not sh:
            return jsonify(error='This link has been switched off.'), 404
        c.execute("UPDATE shares SET last_used=? WHERE token=?", (now().isoformat(), sh['token']))
        try:
            days = max(7, min(62, int(request.args.get('days', 14))))   # the partner app asks for 6 weeks, for its month view
        except ValueError:
            days = 14
        rows = share_rows(c, sh, days)
        owner = sget(c, 'my_name', '') or 'them'
        lists = c.execute("""SELECT * FROM activities WHERE kind='todo' AND deleted=0 AND added_by=?
                             AND (done=0 OR done_at>=?) ORDER BY created DESC LIMIT 30""",
                          (sh['name'], (now() - dt.timedelta(days=3)).isoformat())).fetchall()
    items = [{"id": r['id'], "date": r['date'], "start": r['start'], "duration": r['duration'], "title": r['title'],
              "emoji": r['emoji'], "color": r['color'], "allday": r['allday'] or '', "done": r['done'],
              "mine": (r['added_by'] or '') == sh['name'], "steps": json.loads(r['steps'] or '[]')} for r in rows]
    todos = [{"id": r['id'], "title": r['title'], "emoji": r['emoji'], "color": r['color'], "done": r['done'],
              "steps": json.loads(r['steps'] or '[]')} for r in lists]
    return jsonify(name=sh['name'], owner=owner, see=sh['see'], today=today(), items=items, todos=todos)

@app.get('/s/<tok>/live')
def share_sync(tok):
    with db() as c:
        if not share_for(c, tok):
            return jsonify(error='This link has been switched off.'), 404
    try:
        since, wait = int(request.args.get('v', -1)), float(request.args.get('wait', 0))
    except ValueError:
        since, wait = -1, 0
    return jsonify(v=wait_for_change(since, wait))

@app.post('/s/<tok>/add')
def share_add(tok):
    d = request.json or {}
    with db() as c:
        sh = share_for(c, tok)
        if not sh:
            return jsonify(error='This link has been switched off.'), 404
        f = norm({k: d[k] for k in ('title', 'date', 'start', 'duration', 'notes', 'allday', 'location', 'link', 'leave', 'travel_min', 'travel_by', 'steps') if k in d})
        todo = d.get('kind') == 'todo'
        if not f.get('title') or f['title'] == 'Untitled':
            return jsonify(error='What is it?'), 400
        try:
            dt.date.fromisoformat(f.get('date') or '')
        except Exception:
            f['date'] = today()
        g = guess(f['title']) or ((str(d['emoji'])[:8], '#EE8FA6') if d.get('emoji') else ('💌', '#EE8FA6'))
        f.update(kind='todo' if todo else 'event', emoji=g[0], color=g[1], repeat='{"type": "none"}', remind=10 if f.get('start') and not todo else 0,
                 end_alert=0, added_by=sh['name'], created=now().isoformat())
        f.setdefault('steps', '[]')
        if todo:
            f.update(date=None, start=None, priority='soon')
        f.setdefault('duration', 30)
        f['notes'] = (f.get('notes') or '').strip()
        keys = list(f)
        c.execute(f"INSERT INTO activities({','.join(keys)}) VALUES({','.join('?' * len(keys))})", [f[k] for k in keys])
    when = 'to-do list' if not f.get('date') else 'today' if f['date'] == today() else dt.date.fromisoformat(f['date']).strftime('%a %-d %b')
    push_all(f"💌 {sh['name']} added something", f"{f['emoji']} {f['title']} · {when}{' at ' + f['start'] if f.get('start') else ''}", tag='share')
    return jsonify(ok=True)

# The AI helper for partners: same helper, same server, but only for adding things (it can't see private items)
@app.post('/s/<tok>/ai/event')
def share_ai_event(tok):
    with db() as c:
        if not share_for(c, tok):
            return jsonify(error='This link has been switched off.'), 404
    text = str((request.json or {}).get('text') or '').strip()[:1000]
    if len(text) < 3:
        return jsonify(error='Type or say what it is first'), 400
    return start_job(smart_event, text)

@app.post('/s/<tok>/ai/tidy')
def share_ai_tidy(tok):
    with db() as c:
        if not share_for(c, tok):
            return jsonify(error='This link has been switched off.'), 404
    text = str((request.json or {}).get('text') or '').strip()[:6000]
    if len(text) < 3:
        return jsonify(error='Type or paste the list first'), 400
    return start_job(tidy_list, text)

@app.post('/s/<tok>/ai/extract')
def share_ai_extract(tok):
    with db() as c:
        if not share_for(c, tok):
            return jsonify(error='This link has been switched off.'), 404
    return ai_extract.__wrapped__()   # the same helper as Notes to plans, without needing the password

@app.get('/s/<tok>/ai/job/<jid>')
def share_ai_job(tok, jid):
    with db() as c:
        if not share_for(c, tok):
            return jsonify(error='This link has been switched off.'), 404
    j = AI_JOBS.get(jid)
    if not j:
        return jsonify(status="error", error="That request expired. Please try again.")
    return jsonify({k: v for k, v in j.items() if k != 't'})

@app.post('/s/<tok>/ai/job/<jid>/cancel')
def share_ai_cancel(tok, jid):
    with db() as c:
        if not share_for(c, tok):
            return jsonify(error='This link has been switched off.'), 404
    if AI_JOBS.get(jid):
        AI_JOBS[jid]['cancelled'] = True
    return jsonify(ok=True)

@app.get('/s/<tok>/ai/status')
def share_ai_status(tok):
    with db() as c:
        if not share_for(c, tok):
            return jsonify(error='This link has been switched off.'), 404
    st = ai_settings()
    return jsonify(ok=st['provider'] != 'gemini' or bool(st['key']), provider=st['provider'])

@app.delete('/s/<tok>/item/<int:id_>')
def share_remove(tok, id_):
    """They can take back things they added themselves."""
    with db() as c:
        sh = share_for(c, tok)
        if not sh:
            return jsonify(error='This link has been switched off.'), 404
        c.execute("UPDATE activities SET deleted=1 WHERE id=? AND added_by=? AND done=0", (id_, sh['name']))
    return jsonify(ok=True)

@app.get('/s/<tok>.ics')
def share_ics(tok):
    with db() as c:
        sh = share_for(c, tok)
        if not sh or not sh['web']:
            return Response('not found', 404)
        rows = share_rows(c, sh, 60)
        owner = sget(c, 'my_name', '') or 'Pacely'
    lines = ["BEGIN:VCALENDAR", "VERSION:2.0", "PRODID:-//Pacely//Self-hosted//EN", f"X-WR-CALNAME:{ics_escape(owner)} (Pacely)",
             "CALSCALE:GREGORIAN", "REFRESH-INTERVAL;VALUE=DURATION:PT15M", "X-PUBLISHED-TTL:PT15M"]
    lines += ics_events(rows, 'share')
    lines.append("END:VCALENDAR")
    return Response("\r\n".join(lines) + "\r\n", mimetype='text/calendar')

# static
@app.get('/')
def index():
    r = send_from_directory(STATIC, 'index.html')
    r.headers['Cache-Control'] = 'no-cache'
    return r

@app.get('/sw.js')
def sw():
    r = send_from_directory(STATIC, 'sw.js', mimetype='application/javascript')
    r.headers['Cache-Control'] = 'no-cache'
    return r

@app.get('/<path:p>')
def static_files(p):
    if p.startswith('api/'):
        return jsonify(error='not found'), 404
    return send_from_directory(STATIC, p)

def configure():
    with db() as c:
        app.secret_key = sget(c, 'secret')
    app.config.update(MAX_CONTENT_LENGTH=12 * 1024 * 1024, PERMANENT_SESSION_LIFETIME=dt.timedelta(days=365), SESSION_COOKIE_HTTPONLY=True,
                      SESSION_COOKIE_SAMESITE='Lax', SESSION_COOKIE_NAME='pacely')

if __name__ == '__main__':
    if '--init' in sys.argv:
        pw = init()
        if pw:
            print(f"\n  Your Pacely password:  {pw}\n  (You can change it later in Me > Password)\n")
        else:
            print("\n  Pacely already set up - your existing password still works.\n")
        sys.exit(0)
    if '--reset-password' in sys.argv:
        init()
        pw = new_password()
        with db() as c:
            sset(c, 'pw', hash_pw(pw))
        print(f"\n  New Pacely password:  {pw}\n")
        sys.exit(0)
    init()
    configure()
    threading.Thread(target=scheduler, daemon=True).start()
    port = int(os.environ.get('PACELY_PORT', '8742'))
    from waitress import serve
    print(f"Pacely running on port {port}")
    serve(app, host='0.0.0.0', port=port, threads=32, channel_timeout=60)
