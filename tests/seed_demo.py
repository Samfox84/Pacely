"""Fills a Pacely server with realistic example plans (for screenshots and app tests).
Usage: PACELY_DATA=/some/folder python3 tests/seed_demo.py   -> prints JSON with password, app key and share link token."""
import os, sys, json, datetime as dt
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'server'))
import app as P

pw = P.init()
P.configure()
c = P.app.test_client()
assert c.post('/api/login', json={'password': pw}).status_code == 200
T = P.today()
D = lambda n: (dt.date.fromisoformat(T) + dt.timedelta(days=n)).isoformat()
now = P.now()
hm = lambda mins: f"{(mins // 60) % 24:02d}:{mins % 60:02d}"
cur = now.hour * 60 + now.minute

def add(**k):
    r = c.post('/api/activities', json=k)
    assert r.status_code == 200, r.data
    return r.get_json()

c.put('/api/settings', json={'my_name': 'Sam', 'numbers': [{'label': 'GP surgery', 'number': '01234 567890', 'words': 'doctor, doctors, gp'}]})
add(title='Drop off Robin', date=D(-1), start='08:45', duration=30, repeat={'type': 'days', 'days': [0, 1, 2]})
add(title='Call doctors', date=T, start=hm(max(0, cur - 10)), duration=40)            # happening now
med = add(title='Pick up prescription', date=T, start=hm(min(1380, cur + 60)), duration=30,
          steps=['Go to pharmacy', 'Drop off library books', 'Post a parcel', 'M&S for bread'])
c.put(f"/api/activities/{med['id']}", json={'steps': [{'t': 'Go to pharmacy', 'd': False}, {'t': 'Drop off library books', 'd': True},
                                                       {'t': 'Post a parcel', 'd': True}, {'t': 'M&S for bread', 'd': False}]})
add(title='Gregoria meeting', date=T, start=hm(min(1400, cur + 150)), duration=30)
add(title='Call the bank', date=T, duration=60)                                              # any time
add(title='Therapy', date=T, start=hm(min(1420, cur + 200)), duration=50, private=True)
add(title='Medical day off', date=D(1), allday='sick')
add(title='In the office', date=D(2), allday='office', repeat={'type': 'days', 'days': [dt.date.fromisoformat(D(2)).weekday(), dt.date.fromisoformat(D(4)).weekday()]})
add(title='See house in Woodside Park', date=D(2), start='12:00', duration=30)
add(title='Renew car insurance', date=D(-1), start='10:00', duration=60)              # a leftover
add(kind='todo', title='Book MOT', priority='now')
add(kind='todo', title='Return parcel', priority='soon', steps=['Print label', 'Drop at post office'])
add(kind='todo', title='Clear out the loft', priority='later')
c.post('/api/moods', json={'mood': 2, 'energy': 2, 'note': 'Busy morning'})
share = c.post('/api/shares', json={'name': 'Alex', 'see': 'all', 'web': True}).get_json()
anon = P.app.test_client()
anon.post(f"/s/{share['token']}/add", json={'title': "Dinner at mum's", 'date': D(3), 'start': '18:00'})
anon.post(f"/s/{share['token']}/add", json={'title': 'Pick up dry cleaning', 'date': T, 'start': hm(min(1430, cur + 240))})
with P.db() as d:
    token = P.sget(d, 'api_token')
print(json.dumps({"password": pw, "token": token, "share": share['token']}))
