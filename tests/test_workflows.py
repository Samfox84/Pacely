"""User-journey tests for the Pacely server. Run: python3 tests/test_workflows.py  (or with pytest)."""
import os, sys, json, tempfile, importlib, datetime as dt

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, '..', 'server'))
RESULTS = []

def check(name, ok, detail=''):
    RESULTS.append((name, bool(ok), detail))

def fresh():
    os.environ['PACELY_DATA'] = tempfile.mkdtemp(prefix='pacely-wf-')
    os.environ['PACELY_TZ'] = 'Europe/London'
    import app as P
    P = importlib.reload(P)
    pw = P.init(); P.configure()
    c = P.app.test_client()
    c.post('/api/login', json={'password': pw})
    return P, c

def run():
    P, c = fresh()
    T = P.today(); D = lambda n: (dt.date.fromisoformat(T) + dt.timedelta(days=n)).isoformat()
    day = lambda d: c.get('/api/day?date=' + d).get_json()
    titles = lambda d: [i['title'] for i in day(d)['items'] if i.get('kind') != 'cal']
    add = lambda **k: c.post('/api/activities', json=k).get_json()

    # --- repeating activities ---
    r = add(title='Walk', date=D(1), start='07:00', duration=20, repeat={'type': 'daily'})
    copies = [i for i in day(D(2))['items'] if i['title'] == 'Walk']
    check('repeat appears on later days', len(copies) == 1)
    c2 = copies[0]
    c.put(f"/api/activities/{c2['id']}", json={'start': '08:00', 'scope': 'this'})
    check('edit "just this one" changes only that day',
          [i['start'] for i in day(D(2))['items'] if i['title'] == 'Walk'] == ['08:00'] and
          [i['start'] for i in day(D(3))['items'] if i['title'] == 'Walk'] == ['07:00'])
    c.put(f"/api/activities/{c2['id']}", json={'title': 'Morning walk', 'scope': 'all'})
    check('edit "all" renames future days', 'Morning walk' in titles(D(4)))
    c4 = next(i for i in day(D(4))['items'] if i['title'] == 'Morning walk')
    c.delete(f"/api/activities/{c4['id']}?scope=this")
    check('delete "just this one" stays deleted', 'Morning walk' not in titles(D(4)) and 'Morning walk' in titles(D(5)))
    c5 = next(i for i in day(D(5))['items'] if i['title'] == 'Morning walk')
    rr = c.put(f"/api/activities/{c5['id']}", json={'date': D(6), 'scope': 'this'})
    check('move a repeat to another day works', rr.status_code == 200, rr.status_code)
    check('moved repeat leaves its old day empty', titles(D(5)).count('Morning walk') == 0, titles(D(5)))
    check('moved repeat sits beside that day\'s own copy', titles(D(6)).count('Morning walk') == 2, titles(D(6)))
    c7 = next(i for i in day(D(7))['items'] if i['title'] == 'Morning walk')
    c.delete(f"/api/activities/{c7['id']}?scope=all")
    check('delete "this and all future" stops it', 'Morning walk' not in titles(D(9)) and 'Morning walk' not in titles(D(7)))
    check('...but earlier days keep theirs', 'Morning walk' in titles(D(3)))
    w = add(title='Gym', date=D(1), start='18:00', repeat={'type': 'days', 'days': [dt.date.fromisoformat(D(1)).weekday()]})
    check('repeat on chosen weekdays', 'Gym' in titles(D(8)) and 'Gym' not in titles(D(2)))

    # --- steps on a repeat copy ---
    g = next(i for i in day(D(8))['items'] if i['title'] == 'Gym')
    c.put(f"/api/activities/{g['id']}", json={'steps': [{'t': 'Pack bag', 'd': True}], 'scope': 'this'})
    check('ticking a step on one repeat day only', [s['d'] for s in next(i for i in day(D(8))['items'] if i['title'] == 'Gym')['steps']] == [True]
          and not next(i for i in day(D(15))['items'] if i['title'] == 'Gym')['steps'])

    # --- all-day, sick days, quiet reminders ---
    add(title='Sick day', date=T, allday='sick')
    add(title='Dentist', date=T, start='23:59', remind=10)
    dd = day(T)
    check('sick day shows at the top, not on the timeline', 'Sick day' in [a['title'] for a in dd['allday']] and 'Sick day' not in titles(T))
    check('sick day marks the day quiet', dd['quiet'] == 'sick')
    up = c.get('/api/upcoming').get_json()
    check('no phone reminders on a sick day', not [i for i in up['items'] if i['date'] == T])
    pushed = []
    P.push_all = lambda *a, **k: pushed.append(a)
    P.check_reminders()
    check('server sends no push reminders on a sick day', not pushed, pushed)
    wk = c.get('/api/week?start=' + T).get_json()
    check('week counts ignore all-day items', wk[T]['n'] == len([i for i in titles(T)]), (wk[T]['n'], titles(T)))
    note = add(title='Bins out', date=D(1), allday='day')
    check('plain all-day note is not quiet', day(D(1))['quiet'] == '')
    c.put(f"/api/activities/{note['id']}", json={'allday': '', 'start': '19:00'})
    check('all-day can become timed again', 'Bins out' in titles(D(1)) and day(D(1))['allday'] == [] or 'Bins out' in titles(D(1)))

    # --- leftovers ---
    old = add(title='Ring the council', date=D(-1), start='10:00')
    add(title='Repeat yday', date=D(-2), start='09:00', repeat={'type': 'daily'})
    day(D(-1))
    lo = c.get('/api/leftovers').get_json()
    check('leftovers lists unfinished one-offs', 'Ring the council' in [l['title'] for l in lo])
    check('leftovers skips repeats', 'Repeat yday' not in [l['title'] for l in lo])
    c.post('/api/leftovers', json={'action': 'today', 'ids': [old['id']]})
    check('leftovers: move to today', 'Ring the council' in titles(T))
    o2 = add(title='Post letter', date=D(-2), start='11:00')
    c.post('/api/leftovers', json={'action': 'todo', 'ids': [o2['id']]})
    check('leftovers: to the to-do list', 'Post letter' in [t['title'] for t in c.get('/api/todos').get_json()])
    o3 = add(title='Old thing', date=D(-3))
    c.post('/api/leftovers', json={'action': 'let_go', 'ids': [o3['id']]})
    check('leftovers: let go', 'Old thing' not in [l['title'] for l in c.get('/api/leftovers').get_json()])

    # --- to-dos ---
    t = add(kind='todo', title='Book MOT', priority='now')
    check('to-do gets a fitting icon', t['emoji'] in ('🔧', '📝'), t['emoji'])
    c.put(f"/api/activities/{t['id']}", json={'kind': 'event', 'date': D(1), 'start': '09:00'})
    check('plan a to-do into a day', 'Book MOT' in titles(D(1)) and 'Book MOT' not in [x['title'] for x in c.get('/api/todos').get_json()])

    # --- sharing / partner ---
    add(title='Therapy', date=D(1), start='10:00', private=True)
    sh = c.post('/api/shares', json={'name': 'Alex', 'see': 'all', 'my_name': 'Sam', 'web': True}).get_json()
    anon = P.app.test_client()
    data = anon.get(f"/s/{sh['token']}/data").get_json()
    check('partner sees the plan', 'Book MOT' in [i['title'] for i in data['items']])
    check('partner never sees private things', 'Therapy' not in [i['title'] for i in data['items']])
    check('partner page shows your name', data['owner'] == 'Sam')
    check('partner add: empty title refused', anon.post(f"/s/{sh['token']}/add", json={'title': ''}).status_code == 400)
    check('partner add: bad date falls back to today', anon.post(f"/s/{sh['token']}/add", json={'title': 'X', 'date': 'nope'}).status_code == 200
          and 'X' in titles(T))
    r = anon.post(f"/s/{sh['token']}/add", json={'title': '<script>alert(1)</script>Flowers', 'date': D(2), 'start': '17:00'})
    check('partner add works', r.status_code == 200)
    mine = [i for i in anon.get(f"/s/{sh['token']}/data").get_json()['items'] if i['mine']]
    check('partner sees what they added', any('Flowers' in i['title'] for i in mine))
    fl = next(i for i in mine if 'Flowers' in i['title'])
    full = next(i for i in day(D(2))['items'] if 'Flowers' in i['title'])
    check('added items are marked with their name', full['added_by'] == 'Alex')
    check('their item gets a reminder', full['remind'] == 10)
    sam_item = next(i for i in data['items'] if i['title'] == 'Book MOT')
    anon.delete(f"/s/{sh['token']}/item/{sam_item['id']}")
    check('partner cannot remove your things', 'Book MOT' in titles(D(1)))
    c.put(f"/api/activities/{fl['id']}", json={'done': True})
    done_seen = [i for i in anon.get(f"/s/{sh['token']}/data").get_json()['items'] if i['id'] == fl['id']]
    check('partner sees when you tick off their item', done_seen and done_seen[0]['done'])
    anon.delete(f"/s/{sh['token']}/item/{fl['id']}")
    check('partner cannot remove things you already did', any(i['id'] == fl['id'] for i in anon.get(f"/s/{sh['token']}/data").get_json()['items']))
    ics = anon.get(f"/s/{sh['token']}.ics")
    try:
        import icalendar
        cal = icalendar.Calendar.from_ical(ics.data)
        names = [str(e.get('summary')) for e in cal.walk('VEVENT')]
        check('partner calendar feed is valid and has plans', ics.status_code == 200 and any('Book MOT' in n for n in names))
        check('partner calendar feed hides private', not any('Therapy' in n for n in names))
    except Exception as e:
        check('partner calendar feed is valid', False, repr(e))
    added = c.get('/api/upcoming').get_json().get('added', [])
    check('your phone hears about what they added', any('Flowers' in a['title'] for a in added))
    c.put(f"/api/shares/{sh['token']}", json={'see': 'own'})
    check('"only what they add" hides your plan', 'Book MOT' not in [i['title'] for i in anon.get(f"/s/{sh['token']}/data").get_json()['items']])
    check('share page needs the right link', anon.get('/s/wrong-wrong-wrong-wrong/data').status_code == 404 and anon.get('/s/x').status_code == 404)
    c.delete(f"/api/shares/{sh['token']}")
    check('switched-off link stops working', anon.get(f"/s/{sh['token']}/data").status_code == 404 and anon.get(f"/s/{sh['token']}.ics").status_code == 404)

    # --- one-time invites (partner joins in the app) ---
    inv = c.post('/api/shares', json={'name': 'Mum', 'see': 'all'}).get_json()
    code = inv['invite_path'].split('/')[-1]
    check('new partner links are app-only (no web page)', anon.get(f"/s/{inv['token']}").status_code == 404 and anon.get(f"/s/{inv['token']}.ics").status_code == 404)
    page = anon.get(f'/join/{code}')
    check('invite page opens the app and shows no plans', page.status_code == 200 and b'pacely://join' in page.data and b'Book MOT' not in page.data)
    j = anon.post(f'/join/{code}', json={'device': "Mum's iPhone"})
    tok_new = (j.get_json() or {}).get('token')
    check('the app swaps the invite for its own key', j.status_code == 200 and tok_new and tok_new != inv['token'])
    check('the app can read the plan with its key', anon.get(f'/s/{tok_new}/data').status_code == 200)
    check('an invite works only once', anon.post(f'/join/{code}', json={}).status_code == 404 and b'has been used' in anon.get(f'/join/{code}').data)
    check('the key from the invite is not usable as a web page', anon.get(f'/s/{tok_new}').status_code == 404)
    lst = next(x for x in c.get('/api/shares').get_json() if x['name'] == 'Mum')
    check('you can see when and on what they joined', lst['joined'] and lst['device'] == "Mum's iPhone" and not lst['invite_path'])
    re_ = c.post(f"/api/shares/{lst['token']}/invite").get_json()
    j2 = anon.post(f"/join/{re_['invite']}", json={'device': 'New phone'}).get_json()
    check('a new invite signs out the old phone', anon.get(f'/s/{tok_new}/data').status_code == 404 and anon.get(f"/s/{j2['token']}/data").status_code == 200)
    check('wrong invite codes do nothing', anon.post('/join/notarealcode123', json={}).status_code == 404)

    # --- office days that repeat ---
    off = add(title='In the office', date=D(1), allday='office', repeat={'type': 'days', 'days': [dt.date.fromisoformat(D(1)).weekday()]})
    nxt = day(D(8))
    check('office day repeats each week, all day', any(a['title'] == 'In the office' and a['allday'] == 'office' for a in nxt['allday']))
    check('office days are not quiet days', nxt['quiet'] == '')
    wkd = c.get('/api/week?start=' + D(8)).get_json()[D(8)]
    check('week view knows about the office day', any(x.get('allday') == 'office' for x in wkd['items']))

    # --- keep nudging until done ---
    ng = add(title='Take tablets', date=D(1), start='08:00', nag=True)
    up2 = c.get('/api/upcoming').get_json()['items']
    check('important things carry the keep-nudging flag to the phone', any(i['title'] == 'Take tablets' and i.get('nag') == 1 for i in up2) or D(1) > D(1))

    # --- gentler progress ---
    ins = c.get('/api/insights').get_json()
    check('progress shows good days, not a streak that resets', 'good_days' in ins)

    # --- privacy of the main API ---
    for path in ['/api/day', '/api/todos', '/api/export', '/api/summary', '/api/shares', '/api/leftovers', '/api/recent']:
        check(f'needs login: {path}', anon.get(path).status_code in (401, 403))

    # --- export / import ---
    exp = c.get('/api/export').get_json()
    check('backup includes new fields', any(a.get('private') for a in exp['activities']) and any(a.get('added_by') for a in exp['activities'])
          and any(a.get('allday') for a in exp['activities']))
    # --- other ---
    s = c.get('/api/summary').get_json()['text']
    check('week summary mentions moods and plans', 'Ring the council' in s or 'Sick day' in s, s[:200])
    c.put('/api/settings', json={'numbers': [{'label': 'GP', 'number': '0123'}, {'label': '', 'number': ''}, 'junk']})
    check('saved numbers are cleaned', c.get('/api/me').get_json()['numbers'] == [{'label': 'GP', 'number': '0123', 'words': ''}])
    check('bad date gives a clear error, not a crash', c.get('/api/day?date=banana').status_code in (200, 400))
    long = add(title='x' * 5000, date=T)
    check('very long titles are trimmed', len(long['title']) <= 200)
    em = add(title='Café ☕ — naïve 😀', date=T)
    check('accents and emoji in titles are kept', em['title'] == 'Café ☕ — naïve 😀')
    ai = c.post('/api/ai/extract', json={'text': 'Dentist next Tuesday at 3pm with Dr Lee'})
    check('AI with nothing set up answers kindly, not with a crash', ai.status_code in (200, 400, 503), ai.status_code)
    check('/smart.js is public (the app uses it)', anon.get('/smart.js').status_code == 200)
    wid = c.get('/api/me').get_json()

    P3, c3 = fresh()
    c3.post('/api/import', json=dict(exp, mode='replace'))
    T3 = P3.today()
    check('backup restores private and all-day', any(a['title'] == 'Sick day' for a in c3.get(f'/api/day?date={T}').get_json()['allday']))
    before = len(c3.get('/api/export').get_json()['activities'])
    r = c3.post('/api/import', json=dict(exp, mode='merge'))
    after = len(c3.get('/api/export').get_json()['activities'])
    check('merging the same backup twice adds nothing', r.status_code == 200 and before == after, (before, after))

    # --- running late ---
    P2, c2c = fresh()
    T2 = P2.today()
    nowm = P2.now().hour * 60 + P2.now().minute
    if nowm < 22 * 60:
        later = f"{(nowm + 60) // 60:02d}:{(nowm + 60) % 60:02d}"
        c2c.post('/api/activities', json={'title': 'Later thing', 'date': T2, 'start': later})
        c2c.post('/api/activities', json={'title': 'Off day note', 'date': T2, 'allday': 'day'})
        r = c2c.post('/api/shift', json={'minutes': 10}).get_json()
        st = next(i['start'] for i in c2c.get('/api/day?date=' + T2).get_json()['items'] if i['title'] == 'Later thing')
        check('running late pushes later things back 10 min', st == f"{(nowm + 70) // 60:02d}:{(nowm + 70) % 60:02d}", (later, st, r))

    # --- live sync, travel, smart add, nudges, TfL commute (internet calls are faked) ---
    P3, c3s = fresh()
    T3 = P3.today()
    v0 = c3s.get('/api/live').get_json()['v']
    c3s.post('/api/activities', json={'title': 'Dentist', 'date': T3, 'start': '15:00'})
    v1 = c3s.get('/api/live?v=%d&wait=5' % v0).get_json()['v']
    check('live sync: a change bumps the version', v1 > v0, (v0, v1))
    import time as _t, threading as _th
    t0 = _t.time()
    _th.Timer(1.0, lambda: c3s.post('/api/activities', json={'title': 'Added elsewhere', 'date': T3})).start()
    v2 = c3s.get('/api/live?v=%d&wait=10' % v1).get_json()['v']
    check('live sync: waiting answers as soon as something changes', v2 > v1 and _t.time() - t0 < 5, (_t.time() - t0))
    sh3 = c3s.post('/api/shares', json={'name': 'Alex'}).get_json()
    anon3 = P3.app.test_client()
    check('iPhone calendar sync still works', 'items' in c3s.get('/api/sync?days=14').get_json())
    check('live sync works for a partner too', 'v' in anon3.get(f"/s/{sh3['token']}/live").get_json())

    def fake_web(url, timeout=20, as_json=True):
        if 'postcodes.io' in url:
            return {'result': {'latitude': 51.6, 'longitude': 0.05, 'postcode': 'SW1A 1AA'}}
        if 'nominatim' in url:
            return [{'lat': '52.02', 'lon': '0.22', 'display_name': 'Audley End House, Saffron Walden CB11 4JF'}]
        if 'project-osrm' in url:
            return {'routes': [{'duration': 2700, 'distance': 50000}]}
        if 'JourneyResults' in url:
            st = P3.now().replace(hour=8, minute=0, second=0, microsecond=0).replace(tzinfo=None)
            delay = FAKE['delay']
            return {'journeys': [{'startDateTime': (st - dt.timedelta(minutes=delay)).isoformat(), 'arrivalDateTime': (st + dt.timedelta(minutes=45)).isoformat(),
                                  'duration': 45 + delay, 'legs': [{'mode': {'id': 'walking'}, 'duration': 8},
                                  {'mode': {'id': 'tube'}, 'routeOptions': [{'name': 'Central', 'lineIdentifier': {'id': 'central'}}], 'disruptions': []}]}]}
        if '/Line/' in url:
            return [{'name': 'Central', 'lineStatuses': [{'statusSeverity': 10 if not FAKE['delay'] else 6, 'statusSeverityDescription': 'Good Service' if not FAKE['delay'] else 'Severe Delays', 'reason': ''}]}]
        if 'duckduckgo' in url:
            return '<a class="result__a" href="https://example.org/xmas">Christmas at Audley End</a><a class="result__snippet">Tickets £20</a>'
        raise OSError('no internet in tests')
    FAKE = {'delay': 0}
    P3.web_get = fake_web
    c3s.put('/api/settings', json={'home': 'SW1A 1AA', 'work': 'W1A 1AA', 'work_start': '09:00', 'travel_by': 'car', 'travel_buffer': 10,
                                   'nudges': {'drink': True, 'eat': False, 'rest': True}})
    me3 = c3s.get('/api/me').get_json()
    check('travel settings are saved', me3['travel']['home'] == 'SW1A 1AA' and me3['travel']['work_start'] == '09:00')
    D3 = (dt.date.fromisoformat(T3) + dt.timedelta(days=5)).isoformat()
    trip = c3s.post('/api/trip', json={'place': 'Audley End House', 'date': D3, 'start': '13:00'}).get_json()
    check('trip: drive time and when to leave', trip.get('by') == 'car' and trip.get('minutes') == 59 and trip.get('leave') == '11:51', trip)

    P3.ai_json = lambda system, user, schema, history=None, image=None: {
        'title': 'Christmas at Audley End', 'emoji': '🎄', 'date': D3, 'start': '13:00', 'minutes': 180, 'place': 'Audley End House',
        'address': 'Audley End House, Saffron Walden CB11 4JF', 'website': 'example.org/xmas', 'price': '£20 adult', 'notes': 'Book ahead.'}
    ev = P3.smart_event('audley end christmas event 1pm')
    it = ev['item']
    check('smart add: finds the website, price and place', it['link'] == 'https://example.org/xmas' and '£20' in it['notes'] and 'CB11' in it['location'], it)
    check('smart add: works out when to leave', it.get('leave') == '11:51' and it.get('travel_min') == 59, it)
    check('smart add: the private helper searches the web too', len(ev['sources']) == 1 and ev['sources'][0]['url'] == 'https://example.org/xmas', ev['sources'])
    made = c3s.post('/api/activities', json={k: it[k] for k in ('title', 'emoji', 'color', 'date', 'start', 'duration', 'location', 'link', 'notes', 'leave', 'travel_min', 'travel_by')}).get_json()
    got = next(i for i in c3s.get('/api/day?date=' + D3).get_json()['items'] if i['title'] == 'Christmas at Audley End')
    check('travel details are kept on the item', got['leave'] == '11:51' and got['link'].startswith('https://') and got['travel_by'] == 'car', got)
    c3s.put(f"/api/activities/{got['id']}", json={'start': '14:00'})
    got = next(i for i in c3s.get('/api/day?date=' + D3).get_json()['items'] if i['title'] == 'Christmas at Audley End')
    check('moving the start time moves the leave time', got['leave'] == '12:51', got['leave'])
    check('a bad link is not saved', c3s.post('/api/activities', json={'title': 'X', 'link': 'javascript:alert(1)'}).get_json().get('link', '') == '')
    pj = anon3.post(f"/s/{sh3['token']}/ai/event", json={'text': 'audley end christmas'}).get_json()
    check('partner can use the AI helper', 'job' in pj, pj)
    for _ in range(50):
        jj = anon3.get(f"/s/{sh3['token']}/ai/job/{pj['job']}").get_json()
        if jj['status'] != 'running': break
        _t.sleep(0.1)
    check('partner AI answer comes back', jj['status'] == 'done' and jj['result']['item']['title'] == 'Christmas at Audley End', jj)
    check('partner AI needs a working link', anon3.post('/s/not-a-real-token-123456/ai/event', json={'text': 'x y z'}).status_code == 404)
    pa = anon3.post(f"/s/{sh3['token']}/add", json=dict(title='Panto', date=D3, start='18:00', location='Palladium', leave='17:00', travel_min=40, travel_by='transit')).status_code
    pp = next(i for i in c3s.get('/api/day?date=' + D3).get_json()['items'] if i['title'] == 'Panto')
    check('partner adds keep the place and leave time', pa == 200 and pp['location'] == 'Palladium' and pp['leave'] == '17:00', pp)

    up3 = c3s.get('/api/upcoming').get_json()
    check('nudges go to the phone (drink and rest, not eat)', {n['key'] for n in up3['nudges']} == {'drink', 'rest'} and len(up3['nudges']) == 18, len(up3['nudges']))
    import urllib.error, socket
    check('AI says when Ollama is not running', 'systemctl start ollama' in P3.ai_reason(urllib.error.URLError(ConnectionRefusedError())))
    check('AI says when the model is missing', 'ollama pull' in P3.ai_reason(urllib.error.HTTPError('u', 404, 'nf', {}, None)))
    check('AI says when it is too slow', 'too long' in P3.ai_reason(socket.timeout()))

    # commute: office day, then a delay on the Central line
    c3s.post('/api/activities', json={'title': 'In the office', 'date': T3, 'allday': 'office'})
    info = c3s.get('/api/commute?refresh=1').get_json()
    check('commute: leave time from TfL', info.get('leave') == '08:00' and info['status'][0]['good'], info)
    pushed3 = []
    P3.push_all = lambda *a, **k: pushed3.append(a)
    FAKE['delay'] = 12
    info2 = c3s.get('/api/commute?refresh=1').get_json()
    check('commute: a delay makes you leave earlier', info2.get('leave') == '07:48', info2.get('leave'))
    check('commute: you get told straight away (calmly)', pushed3 and 'a bit earlier' in pushed3[0][0] and '12 min earlier' in pushed3[0][1], pushed3)
    check('commute shows on the day', (c3s.get('/api/day?date=' + T3).get_json().get('commute') or {}).get('leave') == '07:48')
    check('commute: the way home is checked too', (info2.get('back') or {}).get('leave') and info2['back']['status'], info2.get('back'))
    check('commute: a small slowdown home does not send an alert', not any('home' in p[0].lower() for p in pushed3), pushed3)
    trips = [i for i in c3s.get('/api/upcoming').get_json()['items'] if i['id'] in (-900001, -900002)]
    check('journeys show on the Lock Screen countdown (as items)', [t['title'] for t in trips] == ['Leave for work', 'Head home'], trips)
    check('leave reminders are gentle by default', c3s.get('/api/upcoming').get_json()['leave_style'] == 'gentle')
    c3s.put('/api/settings', json={'leave_style': 'countdown'})
    check('countdown style can be chosen', c3s.get('/api/me').get_json()['travel']['leave_style'] == 'countdown')
    c3s.put('/api/settings', json={'home_time': '15:30'})
    c3s.put('/api/settings', json={'modes': ['tube', 'nonsense']})
    check('transport choices are saved', c3s.get('/api/me').get_json()['travel']['modes'] == ['tube'])
    seen_urls = []
    old_web = P3.web_get
    P3.web_get = lambda url, timeout=20, as_json=True: (seen_urls.append(url), old_web(url, timeout, as_json))[1]
    c3s.get('/api/commute?refresh=1')
    P3.web_get = old_web
    check('journeys only use the transport you chose', any('mode=tube,walking' in u for u in seen_urls), seen_urls)
    lv = [i for i in c3s.get('/api/upcoming').get_json()['items'] if i['id'] == -900001]
    check('journeys get the 20, 10, 5 minute countdown', lv and lv[0]['leave'] == lv[0]['start'] and lv[0]['remind'] == -1, lv)
    check('head-home time is saved', c3s.get('/api/me').get_json()['travel']['home_time'] == '15:30')
    busy = []
    def fake_gem(path, key, payload=None, timeout=120):
        if path.startswith('/models?'):
            return {'models': [{'name': 'models/gemini-9-flash', 'supportedGenerationMethods': ['generateContent']},
                               {'name': 'models/gemini-8-flash', 'supportedGenerationMethods': ['generateContent']}]}
        busy.append(path)
        if 'gemini-9-flash' in path:
            raise P3.GeminiBusy('This model is currently experiencing high demand.')
        return {'candidates': [{'content': {'parts': [{'text': '{"reply": "Hello Sam"}'}]}}]}
    P3.gemini_request = fake_gem
    real_sleep, P3._time.sleep = P3._time.sleep, (lambda s: None)
    r = P3.gemini_generate({'gmodel': 'gemini-9-flash', 'key': 'k'}, {})
    P3._time.sleep = real_sleep
    check('Gemini busy: quietly tries another model', 'Hello' in json.dumps(r) and any('gemini-8-flash' in b for b in busy), busy)

    # --- partner sends a messy list ---
    def no_ai(*a, **k): raise OSError('no AI in tests')
    P3.ai_json = no_ai
    t = P3.tidy_list('milk eggs and bread, 2 tins chopped tomatoes\nthe good cheese')
    check('messy message becomes a list, even without AI', t['title'] == 'Shopping' and '2 tins chopped tomatoes' in t['steps'] and 'Bread' in t['steps'] and len(t['steps']) >= 4, t['steps'])
    r = anon3.post(f"/s/{sh3['token']}/add", json={'title': 'Shopping', 'kind': 'todo', 'steps': [{'t': 'Milk', 'd': False}, {'t': 'Bread', 'd': False}]})
    td = [x for x in c3s.get('/api/todos').get_json() if x['title'] == 'Shopping']
    check('partner list lands on your to-do list with tickable items', r.status_code == 200 and td and len(td[0]['steps']) == 2 and td[0]['added_by'] == 'Alex', td)
    pdat = anon3.get(f"/s/{sh3['token']}/data").get_json()
    check('partner can see the lists they sent', any(x['title'] == 'Shopping' for x in pdat.get('todos', [])), pdat.get('todos'))
    pj = anon3.post(f"/s/{sh3['token']}/ai/tidy", json={'text': 'milk, bread'}).get_json()
    check('partner can ask AI to tidy a list', 'job' in pj, pj)

    # --- quiet hours ---
    c3s.put('/api/settings', json={'quiet_from': '20:00', 'quiet_to': '07:00'})
    with P3.db() as cx:
        check('quiet hours: overnight window works', P3.in_quiet_hours(cx, P3.now().replace(hour=23, minute=0)) and P3.in_quiet_hours(cx, P3.now().replace(hour=6, minute=30))
              and not P3.in_quiet_hours(cx, P3.now().replace(hour=12, minute=0)))
    up = c3s.get('/api/upcoming').get_json()
    check('quiet hours reach the phone', up['quiet_from'] == '20:00' and up['quiet_to'] == '07:00', up.get('quiet_from'))
    c3s.put('/api/settings', json={'quiet_from': '', 'quiet_to': ''})
    check('quiet hours can be switched off', c3s.get('/api/me').get_json()['quiet'] == {'from': '', 'to': ''})

    # --- tidy work calendar ---
    P4, c4 = fresh()
    T4 = P4.today()
    with P4.db() as cx:
        cx.execute("INSERT INTO calendars(name,url,color,emoji,remind) VALUES('Work','https://x','#9AA8BA','📅',10)")
        kid = cx.execute("SELECT id FROM calendars WHERE name='Work'").fetchone()['id']
        for i in range(5):
            d = (dt.date.fromisoformat(T4) + dt.timedelta(days=i)).isoformat()
            cx.execute("INSERT INTO cal_events(cal_id,uid,title,date,start,duration) VALUES(?,?,?,?,?,?)", (kid, 'f', 'Busy', d, '06:00', 60))
        cx.execute("INSERT INTO cal_events(cal_id,uid,title,date,start,duration) VALUES(?,?,?,?,?,?)", (kid, 'h', 'Busy', T4, '10:00', 60))
        cx.execute("INSERT INTO cal_events(cal_id,uid,title,date,start,duration) VALUES(?,?,?,?,?,?)", (kid, 'm', 'Busy', T4, '11:30', 30))
        cx.execute("INSERT INTO cal_events(cal_id,uid,title,date,start,duration) VALUES(?,?,?,?,?,?)", (kid, 'o', 'Busy', T4, '16:00', 90))
    c4.post('/api/activities', json={'title': 'Call the bank', 'date': T4, 'start': '10:00', 'duration': 60})
    cal_titles = lambda: [i['start'] for i in c4.get('/api/day?date=' + T4).get_json()['items'] if i['kind'] == 'cal']
    check('work calendar: same-time copy of a Pacely item is hidden', '10:00' not in cal_titles(), cal_titles())
    c4.put(f'/api/calendars/{kid}', json={'hide_repeats': True, 'hours_from': '09:00', 'hours_to': '15:30'})
    check('work calendar: repeating blocks and out-of-hours hidden, real meetings kept', cal_titles() == ['11:30'], cal_titles())
    c4.put(f'/api/calendars/{kid}', json={'hide_repeats': False, 'hours_from': '', 'hours_to': '', 'hide_dupes': False})
    check('work calendar: rules can be switched off', len(cal_titles()) == 4, cal_titles())

    # --- results ---
    width = max(len(n) for n, _, _ in RESULTS)
    fails = [r for r in RESULTS if not r[1]]
    for n, ok, d in RESULTS:
        print(('PASS  ' if ok else 'FAIL  ') + n.ljust(width) + ('' if ok else f'   {d}'))
    print(f'\n{len(RESULTS) - len(fails)} passed, {len(fails)} failed')
    return fails

def test_workflows():
    assert not run()

if __name__ == '__main__':
    sys.exit(1 if run() else 0)
