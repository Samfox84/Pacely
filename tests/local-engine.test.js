// Tests for the on-device engine (server/static/local.js) used by Pacely in the browser and the Mac app
// when plans are kept on the device. Run:  node tests/local-engine.test.js
const assert = require('node:assert/strict');
const path = require('node:path');
global.window = global;
global.document = { addEventListener() {}, visibilityState: 'visible' };
global.addEventListener = () => {};
const store = {};
global.localStorage = { getItem: k => store[k] ?? null, setItem: (k, v) => { store[k] = v; } };
global.navigator = {};
global.ICAL = require(path.join(__dirname, '..', 'server', 'static', 'ical.min.js'));

const pad = n => String(n).padStart(2, '0');
const dayStr = (add = 0) => { const d = new Date(); d.setDate(d.getDate() + add); return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}`; };
const today = dayStr(0), tomorrow = dayStr(1), later = dayStr(10);
const ics = ['BEGIN:VCALENDAR', 'VERSION:2.0',
  'BEGIN:VEVENT', 'UID:a1', `DTSTART:${today.replace(/-/g, '')}T140000`, `DTEND:${today.replace(/-/g, '')}T150000`, 'SUMMARY:Team call', 'END:VEVENT',
  'BEGIN:VEVENT', 'UID:a2', `DTSTART;VALUE=DATE:${today.replace(/-/g, '')}`, 'SUMMARY:Bin day', 'END:VEVENT',
  'END:VCALENDAR', ''].join('\r\n');
global.fetch = async url => {
  if (url.includes('cal.ics')) return { status: 200, text: async () => ics };
  throw new Error('offline');
};

require(path.join(__dirname, '..', 'server', 'static', 'local.js'));
const L = window.LOCAL;

(async () => {
  await L.ready;
  await L.start(null);
  assert.ok((await L.call('GET', '/api/routines')).length > 0, 'starter routines');

  const a = await L.call('POST', '/api/activities', { title: 'Hoover', date: today, start: '10:00', duration: 30, steps: ['a', 'b'] });
  const r = await L.call('POST', '/api/activities', { title: 'Walk', date: today, start: '07:00', duration: 20, repeat: { type: 'daily' } });
  assert.deepEqual((await L.call('GET', '/api/day?date=' + tomorrow)).items.map(i => i.title), ['Walk'], 'repeats tomorrow');

  await L.call('PUT', '/api/activities/' + r.id, { title: 'Morning walk', scope: 'all' });
  assert.deepEqual((await L.call('GET', '/api/day?date=' + tomorrow)).items.map(i => i.title), ['Morning walk'], 'edit all repeats');
  await L.call('PUT', '/api/activities/' + r.id, { repeat: { type: 'none' }, scope: 'all' });
  assert.equal((await L.call('GET', '/api/day?date=' + later)).items.length, 0, 'stopped repeating');

  await L.call('PUT', '/api/activities/' + a.id, { done: true });
  await L.call('POST', '/api/activities', { kind: 'todo', title: 'Ring the council' });
  assert.equal((await L.call('GET', '/api/todos')).length, 1);

  await L.call('POST', '/api/calendars', { name: 'Work', url: 'https://example.com/cal.ics' });
  const day = await L.call('GET', '/api/day?date=' + today);
  assert.ok(day.items.some(i => i.title === 'Team call'), 'calendar event shows');
  assert.ok(day.allday.some(i => i.title === 'Bin day'), 'all-day event shows');

  const exp = L.exportText();
  const ej = JSON.parse(exp);
  assert.equal(ej.app, 'pacely');
  assert.ok(!exp.includes('gemini_key'), 'export never holds the AI key');

  const before = (await L.call('GET', '/api/day?date=' + today)).items.length;
  L.importData(exp, 'merge');
  assert.equal((await L.call('GET', '/api/day?date=' + today)).items.length, before, 'merging the same file adds nothing');

  const fromServer = { app: 'pacely', activities: [{ id: 99, kind: 'event', title: 'From server', date: today, start: '18:00', duration: 30, steps: '[]', repeat: '{"type": "none"}', done: 0, deleted: 0, is_master: 0, created: 'x' }], moods: [], routines: [], reviews: [] };
  L.importData(fromServer, 'merge');
  assert.ok((await L.call('GET', '/api/day?date=' + today)).items.some(i => i.title === 'From server'), 'merge adds new');

  L.importData(fromServer, 'replace');
  assert.deepEqual((await L.call('GET', '/api/day?date=' + today)).items.filter(i => !i.cal).map(i => i.title), ['From server'], 'replace swaps everything');

  assert.throws(() => L.importData({ hello: 1 }, 'merge'), 'not a backup');
  await assert.rejects(L.call('POST', '/api/password', {}), 'unsupported route');
  console.log('local engine tests passed');
})().catch(e => { console.error(e); process.exit(1); });
