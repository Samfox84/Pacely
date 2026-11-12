// Runs the iPhone's "Just this phone" engine the way the app does (JavaScriptCore: no URL class, no fetch,
// no browser storage), using the exact set-up script from LocalEngine.swift. Also checks the engine files
// bundled in the iPhone app match the web app's.
const fs = require('fs'), vm = require('vm'), path = require('path');
const root = path.join(__dirname, '..');
const out = (...a) => process.stdout.write(a.map(String).join(' ') + '\n');
for (const f of ['local.js', 'smart.js', 'ical.min.js']) {
  if (fs.readFileSync(path.join(root, 'server/static', f), 'utf8') !== fs.readFileSync(path.join(root, 'ios/Pacely/Engine', f), 'utf8')) {
    out(`FAIL ios/Pacely/Engine/${f} is out of date. Copy it from server/static/${f}.`); process.exit(1);
  }
}
const swift = fs.readFileSync(path.join(root, 'ios/Pacely/Native/LocalEngine.swift'), 'utf8');
const a = swift.indexOf('c.evaluateScript("""') + 'c.evaluateScript("""'.length;
const shim = swift.slice(a, swift.indexOf('"""', a)).replace(/\\\\/g, '\\').replace('\\(saved.isEmpty ? "null" : saved)', 'null');
delete globalThis.URL; delete globalThis.fetch; delete globalThis.URLSearchParams;
let saves = 0;
globalThis.__pacelySave = () => { saves++; };
globalThis.__pacelyChanged = () => {};
globalThis.__pacelyFetch = (j, res, rej) => rej('no network in tests');
vm.runInThisContext(shim);
for (const f of ['ical.min', 'smart', 'local']) vm.runInThisContext(fs.readFileSync(path.join(root, 'ios/Pacely/Engine', f + '.js'), 'utf8'));
const check = (name, ok, info) => { out((ok ? 'PASS ' : 'FAIL ') + name + (ok ? '' : ' ' + JSON.stringify(info))); if (!ok) process.exitCode = 1; };
(async () => {
  const me = await LOCAL.call('GET', '/api/me');
  check('starts a fresh plan', me.local && me.features.includes('local'), me);
  await LOCAL.call('POST', '/api/activities', { title: 'Dentist', date: me.today, start: '10:00', duration: 30 });
  const day = await LOCAL.call('GET', '/api/day?date=' + me.today);
  check('adds and shows an activity (query strings work without URL)', day.items.some(i => i.title === 'Dentist'), day.items);
  const up = await LOCAL.call('GET', '/api/upcoming');
  check('reminders list works', up.items.length >= 1 && up.leave_style === 'gentle', up);
  const tidy = await LOCAL.call('POST', '/api/ai/tidy', { text: 'milk, bread and 2 tins of tomatoes' });
  check('make a list works without AI', tidy.steps.length === 3 && tidy.title === 'Shopping', tidy);
  await LOCAL.call('PUT', '/api/settings', { quiet_from: '20:00', quiet_to: '07:00' });
  check('quiet hours are kept', (await LOCAL.call('GET', '/api/me')).quiet.from === '20:00');
  let err = null; try { await LOCAL.call('GET', '/api/commute'); } catch (e) { err = e; }
  check('server-only features say so politely', err && err.status === 400, err && err.message);
  await new Promise(r => setTimeout(r, 500));
  check('plan is saved to the phone', saves > 0, saves);
  out(process.exitCode ? 'iPhone engine tests FAILED' : 'iPhone engine tests passed');
})().catch(e => { out('FAIL', e.status, e.message); process.exit(1); });
