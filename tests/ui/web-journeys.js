// Clicks through Pacely in a phone-sized browser, like a person would, and reports what worked.
// Usage: node tests/ui/web-journeys.js http://127.0.0.1:8790 <password> <share-token> [screenshot-folder]
const { chromium, devices } = require('playwright');
const [,, BASE, PW, SHARE, SHOTS = '/tmp/journeys'] = process.argv;
const fs = require('fs'); fs.mkdirSync(SHOTS, { recursive: true });
const results = []; const errors = [];
const ok = (name, cond, detail = '') => results.push([name, !!cond, detail]);

(async () => {
  const b = await chromium.launch();
  const ctx = await b.newContext({ ...devices['iPhone 13'], timezoneId: 'Europe/London', hasTouch: true });
  const p = await ctx.newPage();
  p.on('pageerror', e => errors.push('page: ' + e.message));
  p.on('console', m => { if (m.type() === 'error' && !/401|Failed to load resource/.test(m.text())) errors.push('console: ' + m.text()); });
  const wait = ms => p.waitForTimeout(ms);
  const api = (path, body, method) => p.evaluate(([path, body, method]) => api(path, body ? { method: method || 'POST', body } : {}), [path, body, method]);
  const shot = n => p.screenshot({ path: `${SHOTS}/${n}.png` });
  const step = async (name, fn) => { try { await fn(); } catch (e) { ok(name, false, e.message.split('\n')[0]); await shot('fail-' + name.replace(/\W+/g, '-')).catch(() => {}); } };
  const sheetBtn = async label => { await p.locator('#sheetBody button', { hasText: label }).first().click(); await wait(600); };

  await p.goto(BASE + '/'); await wait(900);
  await step('log in', async () => {
    await p.fill('input[type=password]', PW); await p.keyboard.press('Enter'); await wait(1500);
    ok('log in', await p.evaluate(() => S.view === 'today' && !!S.day));
  });
  const T = await p.evaluate(() => S.today);
  const D = n => p.evaluate(n => addDays(S.today, n), n);

  await step('today shows the plan with calm icons', async () => {
    const t = await p.textContent('#app');
    ok('today shows the plan with calm icons', t.includes('Pick up prescription') && await p.locator('#app .blk .em svg').count() > 2);
    ok('leftovers card appears', t.includes('left from before'));
    ok('private items show to you', t.includes('Therapy'));
    ok("Alex's item is marked", (await p.textContent('#app')).includes('Alex'));
    await shot('01-today');
  });

  await step('quick add understands words and can undo', async () => {
    await p.fill('#qa', 'pick up prescription tomorrow 11am');
    await p.dispatchEvent('#qa', 'input'); const hint = await p.textContent('#qaHint');
    await p.keyboard.press('Enter'); await wait(900);
    const tom = await api('/api/day?date=' + await D(1));
    const it = tom.items.find(i => i.title === 'Pick up prescription');
    ok('quick add understands words and can undo', hint.includes('Tomorrow') && it && it.start === '11:00' && it.emoji === '💊', JSON.stringify(it && [it.title, it.start, it.emoji]));
    await p.locator('#toast button').click(); await wait(900);
    const tom2 = await api('/api/day?date=' + await D(1));
    ok('undo removes it again', !tom2.items.some(i => i.title === 'Pick up prescription'));
  });

  await step('tick a step on the timeline', async () => {
    const before = (await api('/api/day')).items.find(i => i.title.includes('prescription')).steps.filter(s => s.d).length;
    await p.locator('.blk', { hasText: 'prescription' }).locator('.istep').first().click(); await wait(800);
    const after = (await api('/api/day')).items.find(i => i.title.includes('prescription')).steps.filter(s => s.d).length;
    ok('tick a step on the timeline', after === before + 1, `${before}->${after}`);
  });

  await step("couldn't do it today moves only what's left", async () => {
    await p.locator('.blk', { hasText: 'prescription' }).locator('.ti').click(); await wait(700);
    await shot('02-detail');
    await p.click('#dCouldnt'); await wait(500);
    await shot('03-couldnt');
    await sheetBtn('Tomorrow');
    const today = (await api('/api/day')).items.find(i => i.title.includes('prescription'));
    const tom = (await api('/api/day?date=' + await D(1))).items.find(i => i.title.includes('prescription'));
    ok("couldn't do it today moves only what's left", today && today.done && today.steps.every(s => s.d) && tom && tom.steps.length >= 1 && tom.steps.every(s => !s.d),
      JSON.stringify([today && today.steps, tom && tom.steps]));
  });

  await step('call button for doctors', async () => {
    await p.locator('.blk', { hasText: 'Call doctors' }).locator('.ti').click(); await wait(600);
    const btn = await p.locator('a.callbtn').getAttribute('href').catch(() => null);
    ok('call button for doctors', btn === 'tel:01234567890', btn);
    await p.evaluate(() => closeSheet()); await wait(400);
  });

  await step('leftovers: move to today', async () => {
    await p.locator('[data-lo=today]').click(); await wait(900);
    ok('leftovers: move to today', (await api('/api/day')).items.some(i => i.title === 'Renew car insurance'));
  });

  await step('sick day tomorrow is quiet', async () => {
    await p.evaluate(() => { S.date = addDays(S.today, 1); loadDay(); }); await wait(900);
    const t = await p.textContent('#app');
    ok('sick day tomorrow is quiet', t.includes('Sick day: reminders are quiet'));
    await shot('04-sick-day');
    if (await p.locator('#quietMove').count()) {
      await p.click('#quietMove'); await wait(400); await sheetBtn('Tomorrow');
      const left = (await api('/api/day?date=' + await D(1))).items.filter(i => !i.done && i.kind !== 'cal');
      ok('sick day: move everything on', left.length === 0, left.map(i => i.title));
    }
  });

  await step('swipe changes day', async () => {
    const before = await p.evaluate(() => S.date);
    const box = await p.locator('#app').boundingBox();
    const y = box.y + 420;
    await p.evaluate(([y]) => {
      const el = document.querySelector('#app'); const mk = (type, x) => {
        const t = new Touch({ identifier: 1, target: el, clientX: x, clientY: y });
        el.dispatchEvent(new TouchEvent(type, { touches: type === 'touchend' ? [] : [t], changedTouches: [t], bubbles: true }));
      };
      mk('touchstart', 320); mk('touchend', 60);
    }, [y]);
    await wait(900);
    const after = await p.evaluate(() => S.date);
    ok('swipe changes day', after === await p.evaluate(d => addDays(d, 1), before), `${before} -> ${after}`);
    await p.evaluate(() => { S.date = S.today; loadDay(); }); await wait(600);
  });

  await step('week and month views', async () => {
    await p.click('[data-mode=week]'); await wait(900); await shot('05-week');
    const wk = await p.textContent('#app');
    await p.click('[data-mode=month]'); await wait(900); await shot('06-month');
    const mo = await p.textContent('#app');
    await p.click('[data-mode=day]'); await wait(700);
    ok('week and month views', wk.includes('Drop off Robin') && /\d/.test(mo));
  });

  await step('add a repeating activity with the editor', async () => {
    await p.click('#fab'); await wait(600);
    await p.fill('#eTitle', 'Swim'); await p.dispatchEvent('#eTitle', 'input');
    await p.locator('[data-when=time]').click(); await wait(300);
    await p.fill('#eStart', '18:30');
    await p.locator('[data-rep=weekdays]').click().catch(() => {});
    await wait(200); await shot('07-editor');
    await p.click('#eSave'); await wait(1000);
    let d = await D(1); while ([0, 6].includes(new Date(d + 'T12:00').getDay())) d = await p.evaluate(x => addDays(x, 1), d);
    const it = (await api('/api/day?date=' + d)).items.find(i => i.title === 'Swim');
    ok('add a repeating activity with the editor', it && it.start === '18:30' && it.master_id, JSON.stringify(it && [it.start, it.master_id, it.emoji]));
    ok('editor picks a fitting icon', it && it.emoji === '🏃', it && it.emoji);
  });

  await step('private is hidden from Alex', async () => {
    const shareData = await (await p.request.get(`${BASE}/s/${SHARE}/data`)).json();
    ok('private is hidden from Alex', !shareData.items.some(i => i.title === 'Therapy') && shareData.items.length > 0);
  });

  await step('to-do: add, plan into a day', async () => {
    await p.evaluate(() => go('todo')); await wait(800);
    await p.fill('#tIn', 'Ring the bank'); await p.keyboard.press('Enter'); await wait(800);
    const td = await api('/api/todos');
    const t = td.find(x => x.title === 'Ring the bank');
    ok('to-do: add', !!t && t.emoji === '📞', t && t.emoji);
    await shot('08-todo');
  });

  await step('routine: add to today', async () => {
    await p.evaluate(() => go('routines')); await wait(800); await shot('09-routines');
    await p.locator('[data-r]').first().click(); await wait(600);
    await p.click('#rApply'); await wait(1000);
    ok('routine: add to today', (await api('/api/day')).items.length > 5);
  });

  await step('focus: start and pause', async () => {
    await p.evaluate(() => go('focus')); await wait(700);
    await p.click('#fGo'); await wait(1300);
    const running = await p.evaluate(() => F.running);
    await shot('10-focus');
    await p.click('#fPause'); await wait(500);
    ok('focus: start and pause', running && !(await p.evaluate(() => F.running)));
  });

  await step('me: mood check-in', async () => {
    await p.evaluate(() => go('me')); await wait(1200); await shot('11-me');
    await p.click('#meMood'); await wait(500);
    await p.locator('[data-m="4"]').click(); await wait(200);
    await p.click('#mSave'); await wait(800);
    ok('me: mood check-in', (await api('/api/day')).moods.length >= 2);
  });

  await step('me: make a share link', async () => {
    await p.click('#shNew'); await wait(500);
    await p.fill('#shName', 'Mum'); await p.click('#shMake'); await wait(1000);
    ok('me: make a share link', (await api('/api/shares')).some(s => s.name === 'Mum'));
  });

  await step('me: week summary', async () => {
    await p.evaluate(() => closeSheet()); await wait(300);
    await p.click('#meWeek'); await wait(800);
    const t = await p.inputValue('#wkTxt');
    ok('me: week summary', t.includes('My planner') && t.includes('done'), t.slice(0, 80));
    await p.evaluate(() => closeSheet()); await wait(300);
  });

  // Alex's page, no app
  const g = await ctx.newPage();
  g.on('pageerror', e => errors.push('share page: ' + e.message));
  await step("Alex's page: add for Sam", async () => {
    await g.goto(`${BASE}/s/${SHARE}`); await g.waitForTimeout(1000);
    await g.fill('#title', 'Buy birthday card friday 4pm'); await g.dispatchEvent('#title', 'input');
    const pickOn = await g.locator('[data-d=pick].on').count();
    await g.screenshot({ path: `${SHOTS}/12-share-page.png` });
    await g.click('#send'); await g.waitForTimeout(1000);
    const all = await api('/api/export');
    const it = all.activities.find(a => a.title === 'Buy birthday card');
    ok("Alex's page: add for Sam", it && it.start === '16:00' && it.added_by === 'Alex', JSON.stringify(it && [it.title, it.date, it.start]));
    ok("Alex's page: buttons follow what she types", pickOn === 1 || (await D(1)) === it?.date);
  });

  // on-device mode (no server), like the browser version on GitHub
  const l = await ctx.newPage();
  l.on('pageerror', e => errors.push('local: ' + e.message));
  await step('no-server mode: start, add, keep after reload', async () => {
    await l.goto(`${BASE}/index.html?local`); await l.waitForTimeout(500);
    await l.evaluate(() => { window.PACELY_MODE = 'local'; });
    await l.addInitScript(() => { window.PACELY_MODE = 'local'; });
    await l.reload(); await l.waitForTimeout(1500);
    await l.getByText('Start planning').first().click(); await l.waitForTimeout(1000);
    await l.fill('#qa', 'water plants tomorrow 9am'); await l.keyboard.press('Enter'); await l.waitForTimeout(800);
    await l.reload(); await l.waitForTimeout(1500);
    const has = await l.evaluate(async () => (await LOCAL.call('GET', '/api/day?date=' + addDays(S.today, 1))).items.some(i => i.title === 'Water plants'));
    ok('no-server mode: start, add, keep after reload', has);
  });

  const width = Math.max(...results.map(r => r[0].length));
  for (const [n, pass, d] of results) console.log((pass ? 'PASS  ' : 'FAIL  ') + n.padEnd(width) + (pass ? '' : '   ' + d));
  console.log(`\n${results.filter(r => r[1]).length} passed, ${results.filter(r => !r[1]).length} failed`);
  console.log('page errors:', errors.length ? errors : 'none');
  await b.close();
  process.exit(results.some(r => !r[1]) || errors.length ? 1 : 0);
})();
