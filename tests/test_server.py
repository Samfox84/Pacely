"""Server tests. Run from the project folder:  python3 -m pytest tests  (or  python3 tests/test_server.py)"""
import json, os, sys, tempfile, importlib

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, '..', 'server'))


def make_client():
    os.environ['PACELY_DATA'] = tempfile.mkdtemp(prefix='pacely-test-')
    os.environ['PACELY_TZ'] = 'Europe/London'
    import app as pacely
    pacely = importlib.reload(pacely)
    pw = pacely.init()
    pacely.configure()
    c = pacely.app.test_client()
    r = c.post('/api/login', json={'password': pw})
    assert r.status_code == 200, r.data
    return pacely, c


def test_plan_export_merge_replace():
    pacely, c = make_client()
    me = c.get('/api/me').get_json()
    assert 'merge' in me.get('features', [])

    r = c.post('/api/activities', json={'title': 'Hoover', 'date': '2030-01-02', 'start': '10:00', 'duration': 30})
    assert r.status_code == 200
    c.post('/api/activities', json={'kind': 'todo', 'title': 'Ring the council'})
    day = c.get('/api/day?date=2030-01-02').get_json()
    assert [i['title'] for i in day['items']] == ['Hoover']

    backup = c.get('/api/export').get_json()
    assert backup['app'] == 'pacely'
    assert 'gemini_key' not in json.dumps(backup)

    # merging the same file adds nothing
    r = c.post('/api/import', json=dict(backup, mode='merge')).get_json()
    assert r['ok'] and r.get('activities', 0) == 0
    assert len(c.get('/api/day?date=2030-01-02').get_json()['items']) == 1

    # merging a file with one new activity adds just that one
    extra = dict(backup)
    extra['activities'] = backup['activities'] + [dict(backup['activities'][0], id=999, title='Walk', start='12:00', created='new')]
    r = c.post('/api/import', json=dict(extra, mode='merge')).get_json()
    assert r.get('activities') == 1
    assert len(c.get('/api/day?date=2030-01-02').get_json()['items']) == 2

    # replace swaps everything for the file, and keeps a safety copy first
    r = c.post('/api/import', json=dict(backup, mode='replace'))
    assert r.status_code == 200
    assert len(c.get('/api/day?date=2030-01-02').get_json()['items']) == 1
    assert any(f.startswith('before-import-') for f in os.listdir(os.environ['PACELY_DATA']))

    # not a backup
    assert c.post('/api/import', json={'hello': 1}).status_code == 400


def test_needs_login():
    pacely, c = make_client()
    anon = pacely.app.test_client()
    assert anon.get('/api/day').status_code in (401, 403)


if __name__ == '__main__':
    test_plan_export_merge_replace()
    test_needs_login()
    print('server tests passed')
