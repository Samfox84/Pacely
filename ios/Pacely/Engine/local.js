/*
 * Pacely on-device engine.
 * Runs the whole planner inside the app or browser, with no server. It answers the same
 * requests the Pacely server does, so the rest of the app doesn't need to know the difference.
 * Plans are saved to a file on a Mac (Pacely Mac app) or to the browser's own storage.
 * Free and open source (GPL-3.0). Made by Sam Fox with Claude.
 */
(function () {
  'use strict';

  const APPS = ['tem' + 'po', 'pac' + 'ely'];           // backup files from either name are accepted
  const pad = n => String(n).padStart(2, '0');
  const isoDate = d => `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}`;
  const parseD = s => { const [y, m, d] = s.split('-').map(Number); return new Date(y, m - 1, d); };
  const addD = (s, n) => { const d = parseD(s); d.setDate(d.getDate() + n); return isoDate(d); };
  const today = () => isoDate(new Date());
  const nowIso = () => new Date().toISOString();
  const hhmm = d => `${pad(d.getHours())}:${pad(d.getMinutes())}`;
  const wd = s => (parseD(s).getDay() + 6) % 7;                // Monday = 0, like the server
  const J = (s, d) => { if (s === null || s === undefined) return d; if (typeof s !== 'string') return s; try { return JSON.parse(s); } catch (e) { return d; } };
  const clone = o => JSON.parse(JSON.stringify(o));
  const tzName = () => { try { return Intl.DateTimeFormat().resolvedOptions().timeZone || 'UTC'; } catch (e) { return 'UTC'; } };
  const clamp = (v, a, b) => Math.max(a, Math.min(b, v));
  const int = (v, d) => { const n = parseInt(v, 10); return Number.isFinite(n) ? n : d; };

  class HttpError extends Error { constructor(status, message) { super(message); this.status = status; } }
  const fail = (status, msg) => { throw new HttpError(status, msg); };

  const SEED_ROUTINES = [
    ['Morning', '🌅', [
      { title: 'Get up', emoji: '🛏️', color: '#F6C453', duration: 5, steps: ['Curtains open', 'Glass of water'] },
      { title: 'Shower', emoji: '🚿', color: '#7CB8F0', duration: 15, steps: ['Towel ready', 'Wash', 'Dry off'] },
      { title: 'Get dressed', emoji: '👕', color: '#B89AE8', duration: 10, steps: [] },
      { title: 'Breakfast', emoji: '🥣', color: '#F4A07A', duration: 20, steps: [] },
      { title: 'Pack bag', emoji: '🎒', color: '#73CBA8', duration: 5, steps: ['Keys', 'Phone', 'Wallet', 'Headphones'] }]],
    ['Start work', '☕', [
      { title: 'Make a drink', emoji: '☕', color: '#D9B99B', duration: 5, steps: [] },
      { title: 'Check inbox', emoji: '📧', color: '#7CB8F0', duration: 15, steps: [] },
      { title: 'Pick top 3 jobs', emoji: '🗒️', color: '#73CBA8', duration: 10, steps: ['Job 1', 'Job 2', 'Job 3'] }]],
    ['Wind down', '🌙', [
      { title: 'Screens away', emoji: '📵', color: '#9AA8BA', duration: 5, steps: [] },
      { title: 'Teeth', emoji: '🦷', color: '#7CB8F0', duration: 5, steps: [] },
      { title: 'Read', emoji: '📚', color: '#B89AE8', duration: 20, steps: [] },
      { title: 'Lights out', emoji: '💤', color: '#9AA8BA', duration: 5, steps: [] }]]
  ];
  const TABLES = ['activities', 'routines', 'moods', 'calendars', 'cal_events', 'focus_log', 'reviews'];
  const ACT_DEFAULTS = { kind: 'event', allday: '', added_by: '', title: 'Untitled', emoji: '📝', color: '#7CB8F0', date: null, start: null, duration: 30,
    notes: '', steps: '[]', done: 0, done_at: null, is_master: 0, master_id: null, repeat: '{"type":"none"}', remind: 0,
    end_alert: 1, deleted: 0, created: null, priority: 'soon' };

  let db = null;
  let hasData = false;

  function blank() {
    const b = { app: 'pac' + 'ely', version: 1, settings: {}, focus: null };
    for (const t of TABLES) b[t] = [];
    return b;
  }
  function normaliseDb(raw) {
    const b = blank();
    if (raw && typeof raw === 'object') {
      for (const t of TABLES) if (Array.isArray(raw[t])) b[t] = raw[t];
      if (raw.settings && typeof raw.settings === 'object') b.settings = raw.settings;
      if (raw.focus) b.focus = raw.focus;
    }
    b.activities = b.activities.map(a => Object.assign({}, ACT_DEFAULTS, a));
    return b;
  }
  function seed() {
    SEED_ROUTINES.forEach(([name, emoji, items], i) => {
      db.routines.push({ id: nextId('routines'), name, emoji, items: JSON.stringify(items), sort: i });
    });
    db.settings.seeded = '1';
  }
  const nextId = t => db[t].reduce((m, r) => Math.max(m, r.id || 0), 0) + 1;

  // ---------------------------------------------------------------- storage
  const NATIVE = !!(window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.pacely && window.PACELY_MODE === 'local');
  const IDB = {
    open() {
      return new Promise((res, rej) => {
        if (!('indexedDB' in window)) { rej(new Error('no indexedDB')); return; }
        const r = indexedDB.open('pacely', 1);
        r.onupgradeneeded = () => r.result.createObjectStore('db');
        r.onsuccess = () => res(r.result);
        r.onerror = () => rej(r.error);
      });
    },
    async get() {
      try {
        const d = await this.open();
        return await new Promise((res, rej) => {
          const q = d.transaction('db').objectStore('db').get('state');
          q.onsuccess = () => res(q.result || null); q.onerror = () => rej(q.error);
        });
      } catch (e) { try { return localStorage.getItem('pacely-db'); } catch (e2) { return null; } }
    },
    async put(text) {
      try {
        const d = await this.open();
        await new Promise((res, rej) => {
          const tx = d.transaction('db', 'readwrite'); tx.objectStore('db').put(text, 'state');
          tx.oncomplete = res; tx.onerror = () => rej(tx.error);
        });
      } catch (e) { try { localStorage.setItem('pacely-db', text); } catch (e2) { console.warn('Could not save', e2); } }
    }
  };
  let saveTimer = null;
  function text() { return JSON.stringify(db); }
  function writeNow() {
    clearTimeout(saveTimer); saveTimer = null;
    if (!db) return;
    const t = text();
    if (NATIVE) window.webkit.messageHandlers.pacely.postMessage({ type: 'saveLocal', data: t });
    else IDB.put(t);
  }
  function save() {
    clearTimeout(saveTimer);
    saveTimer = setTimeout(writeNow, 300);
    try { if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.pacely) window.webkit.messageHandlers.pacely.postMessage({ type: 'changed' }); } catch (e) {}
  }
  window.addEventListener('pagehide', () => { if (saveTimer) writeNow(); });
  document.addEventListener('visibilitychange', () => { if (document.visibilityState === 'hidden' && saveTimer) writeNow(); });

  async function load() {
    let raw = null;
    if (NATIVE) raw = window.PACELY_LOCAL_DATA || null;
    else { const t = await IDB.get(); if (t) { try { raw = JSON.parse(t); } catch (e) { raw = null; } } }
    if (raw) { db = normaliseDb(raw); hasData = true; if (!db.settings.seeded && !db.routines.length) seed(); }
    else if (NATIVE) { db = blank(); seed(); hasData = true; writeNow(); }   // the Mac app already asked: start fresh
    else { db = null; hasData = false; }
    if (!NATIVE && navigator.storage && navigator.storage.persist) { try { navigator.storage.persist(); } catch (e) {} }
  }
  const ready = load();

  // ---------------------------------------------------------------- activities
  function insertAct(f) {
    const r = Object.assign({}, ACT_DEFAULTS, f, { id: nextId('activities') });
    db.activities.push(r);
    return r;
  }
  const getAct = id => db.activities.find(a => a.id === Number(id));
  function row(r) {
    const d = Object.assign({}, r);
    if ('steps' in d) d.steps = J(d.steps, []);
    if ('repeat' in d) d.repeat = J(d.repeat, { type: 'none' });
    if ('items' in d) d.items = J(d.items, []);
    return d;
  }
  function ruleMatches(rule, date, start) {
    if (date < start) return false;
    const t = (rule || {}).type || 'none';
    if (t === 'daily') return true;
    if (t === 'weekdays') return wd(date) < 5;
    if (t === 'days') return (rule.days || []).includes(wd(date));
    return false;
  }
  function materialize(date) {
    let changed = false;
    for (const m of db.activities.filter(a => a.is_master && !a.deleted)) {
      if (!m.date || !ruleMatches(J(m.repeat, {}), date, m.date)) continue;
      if (db.activities.some(a => a.master_id === m.id && a.date === date)) continue;
      const steps = J(m.steps, []).map(s => Object.assign({}, s, { d: false }));
      insertAct({ kind: m.kind, title: m.title, emoji: m.emoji, color: m.color, date, start: m.start, duration: m.duration,
        notes: m.notes, steps: JSON.stringify(steps), remind: m.remind, end_alert: m.end_alert, repeat: m.repeat,
        master_id: m.id, created: nowIso(), priority: m.priority || 'soon', allday: m.allday || '', added_by: m.added_by || '' });
      changed = true;
    }
    if (changed) save();
  }
  function cleanSteps(steps) {
    const out = [];
    for (let s of steps || []) {
      if (typeof s === 'string') s = { t: s, d: false };
      const t = String((s && s.t) || '').trim().slice(0, 200);
      if (!t) continue;
      const st = { t, d: !!s.d };
      const m = int(s.m, 0);
      if (m > 0 && m <= 600) st.m = m;
      out.push(st);
    }
    return out;
  }
  function norm(d) {
    const o = {};
    if ('title' in d) o.title = (String(d.title ?? '').trim() || 'Untitled').slice(0, 200);
    if ('emoji' in d) o.emoji = String(d.emoji ?? '').slice(0, 16) || '📝';
    if ('color' in d) o.color = String(d.color ?? '').slice(0, 16);
    if ('date' in d) o.date = d.date || null;
    if ('start' in d) o.start = d.start || null;
    if ('duration' in d) o.duration = clamp(int(d.duration, 30) || 30, 1, 1440);
    if ('notes' in d) o.notes = String(d.notes || '').slice(0, 5000);
    if ('steps' in d) o.steps = JSON.stringify(cleanSteps(d.steps));
    if ('done' in d) { o.done = d.done ? 1 : 0; o.done_at = d.done ? nowIso() : null; }
    if ('remind' in d) o.remind = int(d.remind, 0);
    if ('end_alert' in d) o.end_alert = d.end_alert ? 1 : 0;
    if ('private' in d) o.private = d.private ? 1 : 0;
    if ('allday' in d) { o.allday = ALLDAY.includes(d.allday) ? d.allday : ''; if (o.allday) o.start = null; }
    if ('kind' in d) o.kind = d.kind === 'todo' ? 'todo' : 'event';
    if ('priority' in d) o.priority = ['now', 'soon', 'later'].includes(d.priority) ? d.priority : 'soon';
    if ('repeat' in d) {
      const r = d.repeat || { type: 'none' };
      let t = r.type || 'none';
      if (!['none', 'daily', 'weekdays', 'days'].includes(t)) t = 'none';
      const days = [...new Set((r.days || []).map(Number).filter(x => x >= 0 && x <= 6))].sort();
      if (t === 'days' && !days.length) t = 'none';
      o.repeat = JSON.stringify({ type: t, days });
    }
    return o;
  }
  const isRepeating = rep => (J(rep, {}).type || 'none') !== 'none';
  const DEF_KEYS = ['title', 'emoji', 'color', 'start', 'duration', 'notes', 'remind', 'end_alert', 'priority', 'allday'];
  const ALLDAY = ['day', 'off', 'sick', 'holiday'], QUIET = ['off', 'sick', 'holiday'];
  const smart = () => (typeof window !== 'undefined' && window.PacelySmart) || (typeof globalThis !== 'undefined' && globalThis.PacelySmart) || null;
  const isAllday = a => !!a.allday;
  function quietDay(date) {
    materialize(date);
    const a = db.activities.find(x => x.date === date && x.kind === 'event' && !x.deleted && !x.is_master && QUIET.includes(x.allday));
    return a ? a.allday : '';
  }
  function autoTick() {
    if (db.settings.auto_tick === false) return;
    const now = new Date(), td = today(), since = addD(td, -3); let ch = false;
    for (const a of db.activities) {
      if (!a.master_id || a.done || a.deleted || a.is_master || a.kind !== 'event' || !a.start || a.allday || !a.date || a.date < since || a.date > td) continue;
      const [h, mi] = a.start.split(':').map(Number); const en = parseD(a.date); en.setHours(h, mi + (a.duration || 0), 0, 0);
      if (en <= now) { a.done = 1; a.done_at = en.toISOString(); ch = true; }
    }
    if (ch) save();
  }

  function createAct(data) {
    const f = Object.assign({ kind: 'event', title: 'Untitled', emoji: '📝', color: '#7CB8F0', duration: 30, steps: '[]',
      repeat: '{"type":"none"}', remind: 0, end_alert: 1 }, norm(data || {}));
    if (f.emoji === '📝' && smart()) { const g = smart().guess(f.title); if (g) { f.emoji = g.emoji; if (!data.color || data.color === '#7CB8F0') f.color = g.color; } }
    if (f.kind === 'event' && !f.date) f.date = today();
    f.created = nowIso();
    if (f.kind === 'event' && isRepeating(f.repeat)) {
      const m = insertAct(Object.assign({}, f, { is_master: 1 }));
      materialize(f.date);
      save();
      return row(db.activities.find(a => a.master_id === m.id && a.date === f.date) || m);
    }
    f.repeat = '{"type":"none"}';
    const r = insertAct(f);
    save();
    return row(r);
  }
  function editAct(id, data) {
    data = Object.assign({}, data || {});
    const scope = data.scope || 'this'; delete data.scope;
    const f = norm(data);
    const a = getAct(id);
    if (!a) fail(404, 'not found');
    const newRep = f.repeat; delete f.repeat;
    Object.assign(a, f);
    const mid = a.master_id;
    if (a.kind === 'event') {
      if (mid && scope === 'all') {
        const master = getAct(mid);
        const future = () => db.activities.filter(x => x.master_id === mid && x.date > a.date && !x.done);
        if (newRep !== undefined && !isRepeating(newRep)) {
          if (master) master.deleted = 1;
          future().forEach(x => { x.deleted = 1; });
          a.master_id = null; a.repeat = newRep;
        } else {
          const mf = {};
          for (const k of DEF_KEYS) if (k in f) mf[k] = f[k];
          if ('steps' in f) mf.steps = JSON.stringify(J(f.steps, []).map(s => Object.assign({}, s, { d: false })));
          if (newRep !== undefined) {
            mf.repeat = newRep;
            const drop = new Set(future().map(x => x.id));
            db.activities = db.activities.filter(x => !drop.has(x.id));
            a.repeat = newRep;
          }
          if (master) Object.assign(master, mf);
          future().filter(x => !x.deleted).forEach(x => Object.assign(x, mf));
        }
      } else if (!mid && newRep !== undefined && isRepeating(newRep)) {
        const m = insertAct({ kind: a.kind, title: a.title, emoji: a.emoji, color: a.color, date: a.date, start: a.start,
          duration: a.duration, notes: a.notes, remind: a.remind, end_alert: a.end_alert, priority: a.priority,
          steps: JSON.stringify(J(a.steps, []).map(s => Object.assign({}, s, { d: false }))), repeat: newRep, is_master: 1, created: nowIso() });
        a.master_id = m.id; a.repeat = newRep;
      }
    }
    save();
    return row(a);
  }
  function deleteAct(id, scope) {
    const a = getAct(id);
    if (!a) return { ok: true };
    a.deleted = 1;
    if (scope === 'all' && a.master_id) {
      const m = getAct(a.master_id); if (m) m.deleted = 1;
      db.activities.filter(x => x.master_id === a.master_id && x.date >= a.date && !x.done).forEach(x => { x.deleted = 1; });
    }
    save();
    return { ok: true };
  }

  // ---------------------------------------------------------------- calendars
  function calItems(date) {
    const cals = new Map(db.calendars.map(c => [c.id, c]));
    return db.cal_events.filter(e => e.date === date && cals.has(e.cal_id))
      .sort((a, b) => (a.start || '').localeCompare(b.start || ''))
      .map(e => {
        const k = cals.get(e.cal_id);
        return { id: `c${e.id}`, kind: 'cal', title: e.title, emoji: k.emoji || '📅', color: k.color || '#9AA8BA', date: e.date,
          start: e.start, duration: e.duration || 30, all_day: e.all_day, notes: e.location || '', calendar: k.name, steps: [], done: 0, master_id: null };
      });
  }

  async function xfetch(url, opt) {
    opt = opt || {};
    const h = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.pacelyFetch;
    if (h) {
      const r = await h.postMessage({ url, method: opt.method || 'GET', headers: opt.headers || {}, body: opt.body || null });
      return { status: r.status, text: r.text };
    }
    const r = await fetch(url, { method: opt.method || 'GET', headers: opt.headers, body: opt.body });
    return { status: r.status, text: await r.text() };
  }

  async function syncCalendar(cal) {
    try {
      if (!window.ICAL) throw new Error('The calendar reader is missing');
      let url = cal.url.trim();
      if (url.startsWith('webcal://')) url = 'https://' + url.slice(9);
      let res;
      try { res = await xfetch(url); }
      catch (e) { throw new Error(NATIVE ? 'Couldn’t download the calendar. Check the link and your internet.' : 'This browser can’t read that calendar link. Use the Pacely Mac app or a Pacely server for linked calendars.'); }
      if (res.status >= 400) throw new Error(`The calendar link answered with error ${res.status}`);
      const comp = new ICAL.Component(ICAL.parse(res.text));
      for (const tz of comp.getAllSubcomponents('vtimezone')) { try { ICAL.TimezoneService.register(tz); } catch (e) {} }
      const from = new Date(); from.setDate(from.getDate() - 14); from.setHours(0, 0, 0, 0);
      const to = new Date(); to.setDate(to.getDate() + 90);
      const rows = [];
      const vevents = comp.getAllSubcomponents('vevent').map(v => new ICAL.Event(v));
      const base = new Map();
      for (const ev of vevents) if (!ev.isRecurrenceException()) base.set(ev.uid, ev);
      for (const ev of vevents) if (ev.isRecurrenceException() && base.has(ev.uid)) { try { base.get(ev.uid).relateException(ev); } catch (e) {} }
      const push = (sd, ed, item) => {
        const title = String(item.summary || 'Busy').slice(0, 200);
        const loc = String(item.location || '').slice(0, 300);
        if (sd.isDate) {
          let d = new Date(sd.year, sd.month - 1, sd.day);
          const end = ed ? new Date(ed.year, ed.month - 1, ed.day) : new Date(d.getTime() + 86400000);
          while (d < end && d <= to) {
            if (d >= from) rows.push({ cal_id: cal.id, uid: item.uid || '', title, date: isoDate(d), start: null, duration: 1440, all_day: 1, location: loc });
            d = new Date(d.getFullYear(), d.getMonth(), d.getDate() + 1);
          }
          return;
        }
        const s = sd.toJSDate();
        if (s < from || s > to) return;
        const e = ed ? ed.toJSDate() : new Date(s.getTime() + 30 * 60000);
        const mins = clamp(Math.round((e - s) / 60000) || 30, 5, 1440);
        rows.push({ cal_id: cal.id, uid: item.uid || '', title, date: isoDate(s), start: hhmm(s), duration: mins, all_day: 0, location: loc });
      };
      for (const ev of base.values()) {
        if (ev.isRecurring()) {
          const it = ev.iterator();
          let next, n = 0;
          while ((next = it.next()) && n < 1000) {
            n++;
            if (next.toJSDate() > to) break;
            const det = ev.getOccurrenceDetails(next);
            push(det.startDate, det.endDate, det.item);
          }
        } else {
          push(ev.startDate, ev.endDate, ev);
        }
      }
      db.cal_events = db.cal_events.filter(e => e.cal_id !== cal.id);
      let id = nextId('cal_events');
      for (const r of rows) db.cal_events.push(Object.assign({ id: id++ }, r));
      cal.last_sync = nowIso(); cal.error = null;
      save();
      return [rows.length, null];
    } catch (e) {
      cal.error = String(e.message || e).slice(0, 300);
      save();
      return [0, cal.error];
    }
  }
  async function syncAll() {
    const out = [];
    for (const c of db.calendars) { const [n, err] = await syncCalendar(c); out.push({ name: c.name, events: n, error: err }); }
    return out;
  }
  let lastCalSync = 0;
  function maybeSyncCalendars() {
    if (!db || !db.calendars.length || Date.now() - lastCalSync < 15 * 60000) return;
    lastCalSync = Date.now();
    syncAll().catch(() => {});
  }

  // ---------------------------------------------------------------- insights
  const TROPHIES = [
    ['first', '🌱', 'First step', 'Finish your first activity'], ['ten', '🌿', 'Getting going', 'Finish 10 activities'],
    ['fifty', '🌳', 'Steady growth', 'Finish 50 activities'], ['hundred', '🏔️', 'Mountain mover', 'Finish 100 activities'],
    ['streak3', '🔥', 'Three in a row', 'Get something done 3 days running'], ['streak7', '⭐', 'Full week', 'Get something done 7 days running'],
    ['streak30', '🏆', 'Monthly habit', 'Get something done 30 days running'], ['focus1', '⏳', 'In the zone', 'Finish a focus session'],
    ['focus10', '🎯', 'Deep focus', 'Finish 10 focus sessions'], ['checkin7', '💛', 'Checking in', 'Do 7 mood check-ins'],
    ['review3', '📓', 'Reflective', 'Review your day 3 times'], ['routine', '🔁', 'Routine starter', 'Finish every activity on a day with 3 or more']];
  function insights() {
    const td = today();
    const byDay = {};
    for (const a of db.activities) if (a.done && !a.deleted && !a.is_master && a.date) byDay[a.date] = (byDay[a.date] || 0) + 1;
    const todoDone = db.activities.filter(a => a.done && !a.deleted && a.kind === 'todo').length;
    const total = Object.values(byDay).reduce((x, y) => x + y, 0) + todoDone;
    let streak = 0, d = td;
    if (!byDay[d]) d = addD(d, -1);
    while (byDay[d]) { streak++; d = addD(d, -1); }
    let best = 0, run = 0;
    for (let i = 365; i >= 0; i--) { if (byDay[addD(td, -i)]) { run++; best = Math.max(best, run); } else run = 0; }
    const weekStart = addD(td, -wd(td));
    const weekDone = Object.entries(byDay).filter(([k]) => k >= weekStart).reduce((x, [, v]) => x + v, 0);
    const focusN = db.focus_log.length, focusM = db.focus_log.reduce((x, f) => x + (f.minutes || 0), 0);
    const focusWeek = db.focus_log.filter(f => f.date >= weekStart).reduce((x, f) => x + (f.minutes || 0), 0);
    const perDay = {};
    for (const a of db.activities) if (a.kind === 'event' && !a.deleted && !a.is_master && a.date && a.date <= td) {
      const p = perDay[a.date] || (perDay[a.date] = { n: 0, d: 0 }); p.n++; if (a.done) p.d++;
    }
    const fullDay = Object.values(perDay).some(p => p.n >= 3 && p.d === p.n);
    const days = [];
    for (let i = 13; i >= 0; i--) {
      const dd = addD(td, -i);
      const ms = db.moods.filter(m => m.date === dd);
      const avg = k => { const v = ms.filter(m => m[k]).map(m => m[k]); return v.length ? v.reduce((x, y) => x + y, 0) / v.length : null; };
      days.push({ date: dd, done: byDay[dd] || 0, mood: avg('mood'), energy: avg('energy') });
    }
    const have = { first: total >= 1, ten: total >= 10, fifty: total >= 50, hundred: total >= 100, streak3: best >= 3, streak7: best >= 7,
      streak30: best >= 30, focus1: focusN >= 1, focus10: focusN >= 10, checkin7: db.moods.length >= 7, review3: db.reviews.length >= 3, routine: fullDay };
    return { streak, best, total, week_done: weekDone, focus_sessions: focusN, focus_minutes: focusM, focus_week: focusWeek, days,
      trophies: TROPHIES.map(([key, emoji, name, desc]) => ({ key, emoji, name, desc, got: have[key] })) };
  }

  // ---------------------------------------------------------------- AI helper
  const AI_STYLE = 'You help an adult with ADHD and autism plan their day. Use UK English. Be calm and concrete. ' +
    'Break work into small, clear, physical first steps. Give realistic time estimates in minutes, adding a little buffer. ' +
    'Never invent tasks the person did not mention.';
  const STEP_SCHEMA = { type: 'array', items: { type: 'object', properties: { t: { type: 'string' }, m: { type: 'integer' } }, required: ['t', 'm'] } };
  const TASK_SCHEMA = { type: 'object', properties: { tasks: { type: 'array', items: { type: 'object', properties: {
    title: { type: 'string' }, emoji: { type: 'string' }, minutes: { type: 'integer' }, priority: { type: 'string', enum: ['now', 'soon', 'later'] },
    steps: STEP_SCHEMA }, required: ['title', 'emoji', 'minutes', 'priority', 'steps'] } } }, required: ['tasks'] };
  const GEMINI = 'https://generativelanguage.googleapis.com/v1beta';
  function ai() {
    const s = db.settings;
    return { provider: s.ai_provider || 'ollama', key: s.gemini_key || '', gmodel: s.gemini_model || 'gemini-3.8-flash',
      model: s.ai_model || 'llama3.2:3b', url: (s.ollama_url || 'http://127.0.0.1:11434').replace(/\/+$/, '') };
  }
  const upperTypes = sc => Array.isArray(sc) ? sc.map(upperTypes) : (sc && typeof sc === 'object')
    ? Object.fromEntries(Object.entries(sc).map(([k, v]) => [k, k === 'type' && typeof v === 'string' ? v.toUpperCase() : upperTypes(v)])) : sc;
  function parseJsonText(t) {
    try { return JSON.parse(t); } catch (e) { const a = t.indexOf('{'), b = t.lastIndexOf('}'); return a >= 0 ? JSON.parse(t.slice(a, b + 1)) : {}; }
  }
  async function gemini(path, payload) {
    const st = ai();
    let r;
    try {
      r = await xfetch(GEMINI + path, { method: payload ? 'POST' : 'GET', headers: { 'Content-Type': 'application/json', 'x-goog-api-key': st.key },
        body: payload ? JSON.stringify(payload) : null });
    } catch (e) { fail(502, 'Can’t reach Gemini right now. Check your internet.'); }
    let j = {}; try { j = JSON.parse(r.text); } catch (e) {}
    if (r.status >= 400) {
      const msg = ((j.error || {}).message || '');
      if ([400, 401, 403].includes(r.status) && /key/i.test(msg)) fail(400, 'Gemini didn’t accept the API key. Check it in Me › AI helper.');
      if ([429, 500, 503, 504].includes(r.status) || /demand|overloaded/i.test(msg)) fail(503, 'BUSY:' + msg);
      fail(502, 'Gemini said: ' + (msg.slice(0, 200) || 'error ' + r.status));
    }
    return j;
  }
  async function ollama(path, payload) {
    let r;
    try { r = await xfetch(ai().url + path, { method: payload ? 'POST' : 'GET', headers: { 'Content-Type': 'application/json' }, body: payload ? JSON.stringify(payload) : null }); }
    catch (e) { fail(502, 'The private AI helper (Ollama) isn’t running on this computer.'); }
    if (r.status >= 400) fail(502, 'The private AI helper answered with error ' + r.status);
    return JSON.parse(r.text);
  }
  async function aiJson(system, user, schema, history, image) {
    const st = ai();
    if (st.provider === 'gemini' && st.key) {
      const contents = (history || []).slice(-16).filter(h => h.text)
        .map(h => ({ role: h.role === 'assistant' ? 'model' : 'user', parts: [{ text: String(h.text).slice(0, 4000) }] }));
      const parts = [{ text: user }];
      if (image) parts.push({ inline_data: { mime_type: image.mime, data: image.data } });
      contents.push({ role: 'user', parts });
      const payload = { systemInstruction: { parts: [{ text: system }] }, contents,
        generationConfig: { responseMimeType: 'application/json', responseSchema: upperTypes(schema), temperature: 0.4 } };
      // If a model is busy ("high demand") or out of free uses, quietly try the next one
      let res = null, tried = [st.gmodel];
      try {
        const list = await gemini('/models?pageSize=200');
        const names = (list.models || []).filter(m => (m.supportedGenerationMethods || []).includes('generateContent')).map(m => m.name.split('/').pop())
          .filter(n => /flash/.test(n) && !/image|tts|live|audio|exp|thinking/.test(n))
          .sort((a, b) => (/preview/.test(a) - /preview/.test(b)) || (/lite/.test(a) - /lite/.test(b)) || b.localeCompare(a, undefined, { numeric: true }));
        tried = tried.concat(names.filter(n => n !== st.gmodel).slice(0, 4));
      } catch (e) {}
      for (const m of tried) {
        try { res = await gemini(`/models/${m}:generateContent`, payload); if (m !== st.gmodel && db.settings.gemini_auto !== false) { db.settings.gemini_model = m; save(); } break; }
        catch (e) { if (!String(e.message).startsWith('BUSY:')) throw e; }
      }
      if (!res) fail(503, 'Gemini is very busy right now. That’s on Google’s side, not something you did. Try again in a few minutes.');
      const c = (res.candidates || [])[0];
      if (!c) fail(502, 'Gemini didn’t give an answer. Try rewording it.');
      return parseJsonText(((c.content || {}).parts || []).map(p => p.text || '').join('') || '{}');
    }
    if (image) fail(400, 'Photo to tasks needs Gemini switched on in Me › AI helper.');
    const msgs = [{ role: 'system', content: system }]
      .concat((history || []).slice(-12).filter(h => h.text).map(h => ({ role: h.role === 'assistant' ? 'assistant' : 'user', content: String(h.text).slice(0, 4000) })))
      .concat([{ role: 'user', content: user }]);
    const res = await ollama('/api/chat', { model: st.model, stream: false, format: schema, keep_alive: '2h',
      options: { temperature: 0.3, num_ctx: history ? 4096 : 2048 }, messages: msgs });
    return parseJsonText(((res.message || {}).content) || '{}');
  }
  function cleanAiTasks(tasks) {
    const out = [];
    for (const t of tasks || []) {
      const title = String(t.title || '').trim().slice(0, 120);
      if (!title) continue;
      const steps = (t.steps || []).filter(s => String(s.t || '').trim())
        .map(s => ({ t: String(s.t).trim().slice(0, 150), m: clamp(int(s.m, 5) || 5, 1, 120), d: false })).slice(0, 8);
      let mins = clamp(int(t.minutes, 15) || 15, 5, 480);
      const sum = steps.reduce((x, s) => x + s.m, 0);
      if (steps.length && sum > mins) mins = sum;
      out.push({ title, emoji: (String(t.emoji || '📝').trim() || '📝').slice(0, 8), minutes: mins,
        priority: ['now', 'soon', 'later'].includes(t.priority) ? t.priority : 'soon', steps });
    }
    return out.slice(0, 20);
  }
  async function aiStatus() {
    const st = ai();
    if (st.provider === 'gemini') {
      const base = { provider: 'gemini', has_key: !!st.key, model: st.gmodel, models: [] };
      if (!st.key) return Object.assign(base, { ok: false, error: 'Add your free Gemini API key in Me › AI helper.' });
      try {
        const res = await gemini('/models?pageSize=200');
        const names = (res.models || []).filter(m => (m.supportedGenerationMethods || []).includes('generateContent')).map(m => m.name.split('/').pop());
        if (!names.includes(st.gmodel)) {
          const good = names.filter(n => n.includes('flash') && !/image|tts|live|audio|preview|exp/.test(n)).sort().reverse();
          if (!good.length) return Object.assign(base, { ok: false, error: 'No suitable Gemini model found for this key.' });
          db.settings.gemini_model = good[0]; base.model = good[0]; save();
        }
        return Object.assign(base, { ok: true, error: null, models: names });
      } catch (e) { return Object.assign(base, { ok: false, error: e.message }); }
    }
    try {
      const tags = await ollama('/api/tags');
      const names = (tags.models || []).map(m => m.name);
      const ok = names.some(n => n === st.model || n.split(':')[0] === st.model);
      return { ok, model: st.model, models: names, provider: 'ollama', has_key: !!st.key,
        error: ok ? null : `The AI model (${st.model}) isn’t downloaded yet. In Terminal run:  ollama pull ${st.model}` };
    } catch (e) {
      return { ok: false, model: st.model, models: [], provider: 'ollama', has_key: !!st.key,
        error: 'The private AI helper isn’t installed on this computer. Install Ollama from ollama.com, or switch to Gemini.' };
    }
  }

  // ---------------------------------------------------------------- backup files
  function exportObj() {
    const s = db.settings;
    return { app: 'pac' + 'ely', version: 1, exported: new Date().toISOString(),
      activities: db.activities.filter(a => !a.deleted), routines: db.routines, moods: db.moods, calendars: db.calendars,
      focus_log: db.focus_log, reviews: db.reviews,
      settings: { theme: s.theme || 'auto', ai_provider: s.ai_provider || 'ollama', ai_model: s.ai_model || '', gemini_model: s.gemini_model || '' } };
  }
  function validBackup(d) { return d && typeof d === 'object' && (APPS.includes(d.app) || Array.isArray(d.activities)); }
  function importData(d, mode) {
    if (typeof d === 'string') { try { d = JSON.parse(d); } catch (e) { fail(400, 'That file isn’t a Pacely backup.'); } }
    if (!validBackup(d)) fail(400, 'That file isn’t a Pacely backup.');
    const inc = normaliseDb(d);
    const added = {};
    if (mode !== 'merge') {
      const keep = db ? db.settings : {};
      db = blank();
      for (const t of TABLES) if (Array.isArray(d[t])) db[t] = inc[t];
      db.settings = Object.assign({}, keep, d.settings ? { theme: d.settings.theme || keep.theme } : {});
      db.settings.seeded = '1';
      if (!db.routines.length && !Array.isArray(d.routines)) seed();
      hasData = true; writeNow();
      return { ok: true, mode: 'replace', activities: db.activities.length };
    }
    // merge: keep everything here, add anything new from the file
    const ids = {};
    const sig = a => [a.kind, a.title, a.date || '', a.start || '', a.created || ''].join('|');
    const have = new Set(db.activities.map(sig));
    const incoming = inc.activities.filter(a => !a.deleted).sort((a, b) => (b.is_master || 0) - (a.is_master || 0));
    let n = 0;
    for (const a of incoming) {
      if (have.has(sig(a))) continue;
      const copy = Object.assign({}, a);
      const oldId = copy.id; delete copy.id;
      if (copy.master_id) copy.master_id = ids[copy.master_id] || null;
      const r = insertAct(copy); ids[oldId] = r.id; have.add(sig(r)); n++;
    }
    added.activities = n;
    const addSimple = (t, key) => {
      const seen = new Set(db[t].map(key)); let c = 0, id = nextId(t);
      for (const r of inc[t]) { if (seen.has(key(r))) continue; db[t].push(Object.assign({}, r, { id: id++ })); seen.add(key(r)); c++; }
      added[t] = c;
    };
    addSimple('routines', r => r.name + '|' + r.items);
    addSimple('moods', r => r.ts);
    addSimple('focus_log', r => r.ts);
    addSimple('calendars', r => r.url);
    const dates = new Set(db.reviews.map(r => r.date)); let rv = 0;
    for (const r of inc.reviews) if (!dates.has(r.date)) { db.reviews.push(Object.assign({}, r)); rv++; }
    added.reviews = rv;
    hasData = true; writeNow();
    return Object.assign({ ok: true, mode: 'merge' }, added);
  }

  // ---------------------------------------------------------------- routes
  const clip = (v, n) => String(v || '').slice(0, n);
  function cleanItems(items) {
    return (items || []).map(it => ({ title: clip(String(it.title || '').trim(), 200), emoji: clip(it.emoji || '📝', 16), color: clip(it.color || '#7CB8F0', 16),
      duration: clamp(int(it.duration, 10) || 10, 1, 600), steps: (it.steps || []).map(s => String(s).trim().slice(0, 200)).filter(Boolean) }))
      .filter(it => it.title);
  }
  function upcoming() {
    const items = [];
    for (let i = 0; i < 2; i++) {
      const d = addD(today(), i);
      materialize(d);
      const quiet = quietDay(d);
      for (const r of db.activities.filter(a => !quiet && a.date === d && a.kind === 'event' && !a.deleted && !a.is_master && a.start)) {
        items.push({ id: r.id, date: d, start: r.start, duration: r.duration, title: r.title, emoji: r.emoji, color: r.color,
          remind: r.remind, end_alert: r.end_alert, done: r.done, steps: J(r.steps, []) });
      }
      const cals = new Map(db.calendars.map(c => [c.id, c]));
      for (const e of db.cal_events.filter(e => e.date === d && !e.all_day && cals.has(e.cal_id))) {
        const k = cals.get(e.cal_id);
        items.push({ id: -e.id, date: d, start: e.start, duration: e.duration, title: e.title, emoji: k.emoji || '📅', color: k.color || '#9AA8BA',
          remind: k.remind, end_alert: 0, done: 0, steps: [] });
      }
    }
    items.sort((a, b) => (a.date + a.start).localeCompare(b.date + b.start));
    const f = db.focus && db.focus.end > Date.now() ? db.focus : null;
    return { items, focus: f, tz: tzName(), leave_style: 'gentle', quiet_from: db.settings.quiet_from || '', quiet_to: db.settings.quiet_to || '' };
  }

  async function route(method, path, body) {
    const u = new URL(path, 'http://local');
    const p = u.pathname, q = u.searchParams;
    body = body || {};
    let m;
    maybeSyncCalendars();

    if (p === '/api/me') return { ok: true, local: true, vapid: null, theme: db.settings.theme || 'auto', subs: 0, today: today(),
      now: hhmm(new Date()), features: ['merge', 'local', 'allday', 'smart', 'leftovers', 'numbers', 'quiet'], last_backup: db.settings.last_backup || null, numbers: db.settings.numbers || [],
      auto_tick: db.settings.auto_tick !== false, my_name: db.settings.my_name || '',
      quiet: { from: db.settings.quiet_from || '', to: db.settings.quiet_to || '' } };
    if (p === '/api/login' || p === '/api/logout') return { ok: true };
    if (p === '/api/day') {
      const date = q.get('date') || today();
      materialize(date); autoTick();
      const mine = db.activities.filter(a => a.date === date && a.kind === 'event' && !a.deleted && !a.is_master).map(row);
      const items = mine.filter(a => !isAllday(a)).concat(calItems(date).filter(x => !x.all_day));
      items.sort((a, b) => ((a.start === null) - (b.start === null)) || (a.start || '').localeCompare(b.start || '') || String(a.id).localeCompare(String(b.id), undefined, { numeric: true }));
      const review = db.reviews.find(r => r.date === date) || null;
      const q2 = mine.find(a => QUIET.includes(a.allday));
      return { date, items, allday: mine.filter(isAllday).concat(calItems(date).filter(x => x.all_day)), quiet: q2 ? q2.allday : '', moods: db.moods.filter(x => x.date === date).sort((a, b) => a.ts.localeCompare(b.ts)), review };
    }
    if (p === '/api/week') {
      const start = q.get('start') || today(); const out = {};
      for (let i = 0; i < 7; i++) {
        const d = addD(start, i); materialize(d);
        const rows = db.activities.filter(a => a.date === d && a.kind === 'event' && !a.deleted && !a.is_master)
          .sort((a, b) => ((a.start === null) - (b.start === null)) || (a.start || '').localeCompare(b.start || ''));
        const timed = rows.filter(a => !isAllday(a));
        out[d] = { n: timed.length, done: timed.filter(a => a.done).length,
          items: rows.map(x => ({ title: x.title, emoji: x.emoji, color: x.color, start: x.start, duration: x.duration, done: x.done, allday: x.allday || '' }))
            .concat(calItems(d).map(x => ({ title: x.title, emoji: x.emoji, color: x.color, start: x.start, duration: x.duration, done: 0, cal: 1 }))) };
      }
      return out;
    }
    if (p === '/api/todos' && method === 'GET') {
      return db.activities.filter(a => a.kind === 'todo' && !a.deleted).sort((a, b) => (a.done - b.done) || (b.id - a.id)).map(row);
    }
    if (p === '/api/activities' && method === 'POST') return createAct(body);
    if ((m = p.match(/^\/api\/activities\/(\d+)$/))) {
      if (method === 'PUT') return editAct(m[1], body);
      if (method === 'DELETE') return deleteAct(Number(m[1]), q.get('scope') || 'this');
    }
    if (p === '/api/todos/clear') { db.activities.filter(a => a.kind === 'todo' && a.done).forEach(a => { a.deleted = 1; }); save(); return { ok: true }; }

    if (p === '/api/routines' && method === 'GET') return db.routines.slice().sort((a, b) => (a.sort - b.sort) || (a.id - b.id)).map(row);
    if (p === '/api/routines' && method === 'POST') {
      const r = { id: nextId('routines'), name: clip(body.name || 'Routine', 100), emoji: clip(body.emoji || '✨', 16), items: JSON.stringify(cleanItems(body.items)), sort: 99 };
      db.routines.push(r); save(); return row(r);
    }
    if ((m = p.match(/^\/api\/routines\/(\d+)$/))) {
      const r = db.routines.find(x => x.id === Number(m[1]));
      if (method === 'PUT') { if (!r) fail(404, 'not found'); Object.assign(r, { name: clip(body.name || 'Routine', 100), emoji: clip(body.emoji || '✨', 16), items: JSON.stringify(cleanItems(body.items)) }); save(); return row(r); }
      if (method === 'DELETE') { db.routines = db.routines.filter(x => x.id !== Number(m[1])); save(); return { ok: true }; }
    }
    if ((m = p.match(/^\/api\/routines\/(\d+)\/apply$/))) {
      const r = db.routines.find(x => x.id === Number(m[1])); if (!r) fail(404, 'not found');
      const date = body.date || today();
      const [h, mi] = (body.start || '08:00').split(':').map(Number); let t = h * 60 + mi;
      for (const it of J(r.items, [])) {
        insertAct({ kind: 'event', title: it.title, emoji: it.emoji, color: it.color, date, start: `${pad(Math.floor(t / 60) % 24)}:${pad(t % 60)}`,
          duration: it.duration, steps: JSON.stringify((it.steps || []).map(s => ({ t: s, d: false }))), remind: 0, end_alert: 0, created: nowIso() });
        t += it.duration;
      }
      save(); return { ok: true };
    }

    if (p === '/api/moods' && method === 'GET') return db.moods.slice().sort((a, b) => b.ts.localeCompare(a.ts)).slice(0, 60);
    if (p === '/api/moods' && method === 'POST') {
      const e = body.energy ? clamp(int(body.energy, 3), 1, 5) : null;
      db.moods.push({ id: nextId('moods'), ts: nowIso(), date: today(), mood: clamp(int(body.mood, 3) || 3, 1, 5), note: clip(body.note, 1000), energy: e });
      save(); return { ok: true };
    }
    if ((m = p.match(/^\/api\/moods\/(\d+)$/)) && method === 'DELETE') { db.moods = db.moods.filter(x => x.id !== Number(m[1])); save(); return { ok: true }; }

    if (p === '/api/focus' && method === 'GET') return db.focus && db.focus.end > Date.now() ? db.focus : {};
    if (p === '/api/focus' && method === 'POST') {
      db.focus = body.end ? { end: int(body.end, 0), title: clip(body.title, 200), total: int(body.total, 0), item: int(body.item, 0), color: clip(body.color, 16) } : null;
      save(); return { ok: true };
    }
    if (p === '/api/focus/log') { db.focus_log.push({ id: nextId('focus_log'), ts: nowIso(), date: today(), minutes: clamp(int(body.minutes, 1) || 1, 1, 600), title: clip(body.title, 200) }); save(); return { ok: true }; }

    if (p === '/api/settings' && Array.isArray(body.numbers)) db.settings.numbers = body.numbers.slice(0, 40).map(n => ({ label: clip(String(n.label || '').trim(), 40), number: clip(String(n.number || '').trim(), 30), words: clip(String(n.words || '').trim(), 200) })).filter(n => n.label && n.number);
    if (p === '/api/settings' && ('quiet_from' in body || 'quiet_to' in body)) {
      const ok = v => /^([01]\d|2[0-3]):[0-5]\d$/.test(String(v || '')) ? v : '';
      const f = ok(body.quiet_from), t = ok(body.quiet_to);
      db.settings.quiet_from = f && t ? f : ''; db.settings.quiet_to = f && t ? t : ''; save();
    }
    if (p === '/api/settings') { if ('auto_tick' in body) db.settings.auto_tick = !!body.auto_tick; if ('my_name' in body) db.settings.my_name = clip(String(body.my_name || '').trim(), 40); }
    if (p === '/api/recent') {
      const since = addD(today(), -60), seen = new Map();
      for (const a of db.activities.filter(a => a.kind === 'event' && !a.deleted && !a.is_master && !a.allday && (a.date || '') >= since)) {
        const k = (a.title || '').toLowerCase(); const e = seen.get(k) || { n: 0, last: '', a };
        e.n++; if ((a.created || '') >= e.last) { e.last = a.created || ''; e.a = a; } seen.set(k, e);
      }
      return [...seen.values()].sort((x, y) => (y.n - x.n) || y.last.localeCompare(x.last)).slice(0, 8).map(({ a }) => ({ title: a.title, emoji: a.emoji, color: a.color,
        duration: a.duration, start: a.start, steps: J(a.steps, []).map(s => Object.assign({}, s, { d: false })) }));
    }
    if (p === '/api/leftovers' && method === 'GET') {
      const td = today(), from = addD(td, -7), to = addD(td, -1);
      return db.activities.filter(a => a.kind === 'event' && !a.deleted && !a.is_master && !a.done && !a.master_id && !a.allday && a.date >= from && a.date <= to)
        .sort((a, b) => (a.date + (a.start || '')).localeCompare(b.date + (b.start || ''))).map(row);
    }
    if (p === '/api/leftovers' && method === 'POST') {
      const ids = (body.ids || []).map(Number).slice(0, 200), now = hhmm(new Date());
      for (const id of ids) {
        const a = getAct(id); if (!a || a.deleted) continue;
        if (body.action === 'today') { a.date = today(); if (a.start && a.start <= now) a.start = null; }
        else if (body.action === 'todo') { a.kind = 'todo'; a.date = null; a.start = null; }
        else if (body.action === 'move' && /^\d{4}-\d{2}-\d{2}$/.test(body.to || '')) { a.date = body.to; a.master_id = null; }
        else if (body.action === 'let_go') a.deleted = 1;
      }
      save(); return { ok: true, n: ids.length };
    }
    if (p === '/api/settings') { if (['auto', 'light', 'dark'].includes(body.theme)) db.settings.theme = body.theme; save(); return { ok: true }; }
    if (p === '/api/export') return exportObj();
    if (p === '/api/import') return importData(body, body.mode === 'merge' ? 'merge' : 'replace');

    if (p === '/api/calendars' && method === 'GET') {
      return { calendars: db.calendars.map(c => Object.assign({}, c, { n: db.cal_events.filter(e => e.cal_id === c.id).length })), feed: null };
    }
    if (p === '/api/calendars' && method === 'POST') {
      const url = String(body.url || '').trim();
      if (!/^(https?|webcal):\/\//.test(url)) fail(400, 'Paste the calendar link that starts with https:// or webcal://');
      const cal = { id: nextId('calendars'), name: clip(body.name || 'Calendar', 80), url, color: clip(body.color || '#9AA8BA', 16), emoji: clip(body.emoji || '📅', 16),
        remind: body.remind !== undefined && body.remind !== null ? int(body.remind, 10) : 10, last_sync: null, error: null };
      db.calendars.push(cal); save();
      const [n, err] = await syncCalendar(cal);
      return { ok: true, events: n, error: err };
    }
    if (p === '/api/calendars/sync') { lastCalSync = Date.now(); return { results: await syncAll() }; }
    if ((m = p.match(/^\/api\/calendars\/(\d+)$/))) {
      const id = Number(m[1]);
      if (method === 'DELETE') { db.calendars = db.calendars.filter(c => c.id !== id); db.cal_events = db.cal_events.filter(e => e.cal_id !== id); save(); return { ok: true }; }
      if (method === 'PUT') {
        const c = db.calendars.find(x => x.id === id); if (!c) fail(404, 'not found');
        Object.assign(c, { name: clip(body.name || c.name, 80), color: clip(body.color || c.color, 16), emoji: clip(body.emoji || c.emoji, 16),
          remind: body.remind !== undefined && body.remind !== null ? int(body.remind, c.remind) : c.remind });
        save(); return { ok: true };
      }
    }

    if (p === '/api/shift') {
      const date = body.date || today(); const mins = clamp(int(body.minutes, 0), -240, 240);
      const from = body.from || hhmm(new Date()); const fm = int(from.slice(0, 2), 0) * 60 + int(from.slice(3, 5), 0);
      let n = 0;
      for (const a of db.activities.filter(a => a.date === date && a.kind === 'event' && !a.deleted && !a.is_master && !a.done && a.start)) {
        const st = int(a.start.slice(0, 2), 0) * 60 + int(a.start.slice(3, 5), 0);
        if (st + (a.duration || 0) > fm) { const ns = clamp(st + mins, 0, 1439); a.start = `${pad(Math.floor(ns / 60))}:${pad(ns % 60)}`; n++; }
      }
      save(); return { ok: true, moved: n };
    }
    if (p === '/api/move_undone') {
      const from = body.date || today(); const to = addD(from, 1);
      const rows = db.activities.filter(a => a.date === from && a.kind === 'event' && !a.deleted && !a.is_master && !a.done && !a.master_id);
      rows.forEach(a => { a.date = to; });
      save(); return { ok: true, moved: rows.length };
    }
    if (p === '/api/insights') return insights();
    if (p === '/api/review') {
      const date = body.date || today();
      db.reviews = db.reviews.filter(r => r.date !== date);
      db.reviews.push({ date, well: clip(body.well, 2000), hard: clip(body.hard, 2000), tomorrow: clip(body.tomorrow, 2000), ts: nowIso() });
      save(); return { ok: true };
    }
    if (p === '/api/reviews') return db.reviews.slice().sort((a, b) => b.date.localeCompare(a.date)).slice(0, 30);
    if (p === '/api/upcoming') return upcoming();

    // AI helper
    if (p === '/api/ai/status') return aiStatus();
    if (p === '/api/ai/settings') {
      if (['ollama', 'gemini'].includes(body.provider)) db.settings.ai_provider = body.provider;
      if ('key' in body) db.settings.gemini_key = String(body.key || '').trim().slice(0, 200);
      if (body.gemini_model === 'auto') db.settings.gemini_auto = true;
      else if (body.gemini_model) { db.settings.gemini_model = String(body.gemini_model).trim().slice(0, 80); db.settings.gemini_auto = false; }
      if (body.model) db.settings.ai_model = String(body.model).trim().slice(0, 80);
      if (body.ollama_url) db.settings.ollama_url = String(body.ollama_url).trim().slice(0, 200);
      save(); return { ok: true };
    }
    if (p === '/api/ai/check') {
      const t0 = Date.now();
      const res = await aiJson('Answer in JSON.', 'Say hello in five words or fewer.', { type: 'object', properties: { reply: { type: 'string' } }, required: ['reply'] });
      return { reply: clip(String(res.reply || ''), 200), seconds: Math.round((Date.now() - t0) / 100) / 10, provider: ai().provider };
    }
    if (p === '/api/ai/tidy') {
      // A messy message into a calm list. Works without AI too (a simple split), and AI makes it tidier.
      const text = clip(String(body.text || '').trim(), 6000); if (text.length < 3) fail(400, 'Paste the message first');
      const seen = new Set(), steps = [];
      for (let x of text.split(/\n|,|;|\s+\band\b\s+|\s+&\s+|•|\s-\s/)) {
        x = x.replace(/^\s*(?:[-*•]|\d+[.)])\s*/, '').replace(/^[\s.]+|[\s.]+$/g, '');
        if (x && x.length < 150 && !seen.has(x.toLowerCase())) { seen.add(x.toLowerCase()); steps.push(x[0].toUpperCase() + x.slice(1)); }
      }
      const shop = /\b(shop|shopping|tesco|sainsbury|asda|aldi|lidl|groceries|supermarket|milk|bread|eggs)\b/i.test(text);
      const out = { title: shop ? 'Shopping' : 'List', emoji: shop ? '🛒' : '📝', color: shop ? '#73CBA8' : '#7CB8F0', kind: 'todo', date: '', start: '',
        notes: '', steps: steps.slice(0, 60), ai: false, note: '' };
      const st = ai();
      if (st.provider === 'gemini' && st.key) {
        try {
          const res = await aiJson(AI_STYLE + ' Turn this message into one clear checklist. Each step is ONE thing, quantity first if there is one, ' +
            'detail in brackets. For shopping, order it the way you walk round a UK supermarket. Give a short title. Put anything that is not a step in notes. ' +
            'Keep every item they mentioned and do not add any.', 'Message:\n' + text,
            { type: 'object', properties: { title: { type: 'string' }, notes: { type: 'string' }, steps: { type: 'array', items: { type: 'string' } } }, required: ['title', 'notes', 'steps'] });
          const s2 = (res.steps || []).map(x => clip(String(x).trim(), 150)).filter(Boolean);
          if (s2.length) Object.assign(out, { title: clip(String(res.title || out.title), 80), notes: clip(String(res.notes || ''), 600), steps: s2.slice(0, 60), ai: true });
        } catch (e) { out.note = e.message || ''; }
      }
      return out;
    }
    if (p === '/api/ai/model') { db.settings.ai_model = clip(String(body.model || '').trim(), 80); save(); return { ok: true }; }
    if (p === '/api/ai/plan') {
      const t = clip(String(body.text || '').trim(), 4000); if (!t) fail(400, 'Type or say what is on your mind first');
      const res = await aiJson(AI_STYLE + ' Turn the brain dump into a list of separate tasks. Each task gets an emoji, a total time, a priority ' +
        '(now = urgent or time-sensitive today, soon = this week, later = whenever) and 2 to 6 small steps with minutes each. ' +
        'Simple tasks can have no steps.', 'Brain dump:\n' + t, TASK_SCHEMA);
      return { tasks: cleanAiTasks(res.tasks) };
    }
    if (p === '/api/ai/breakdown') {
      const title = clip(String(body.title || '').trim(), 200); if (!title) fail(400, 'Give the activity a name first');
      const schema = { type: 'object', properties: { steps: STEP_SCHEMA, emoji: { type: 'string' }, minutes: { type: 'integer' } }, required: ['steps', 'emoji', 'minutes'] };
      const res = await aiJson(AI_STYLE + ' Break this one activity into 3 to 7 small steps. Each step is a short instruction starting with a verb, ' +
        'with minutes. Also suggest one emoji and the total minutes.', `Activity: ${title}\nNotes: ${clip(body.notes, 1000)}`, schema);
      const t = cleanAiTasks([{ title, emoji: res.emoji, minutes: res.minutes, priority: 'soon', steps: res.steps }]);
      return t[0] || { steps: [] };
    }
    if (p === '/api/ai/prioritise') {
      const todos = db.activities.filter(a => a.kind === 'todo' && !a.deleted && !a.done);
      if (!todos.length) return { ok: true, changed: 0 };
      const schema = { type: 'object', properties: { items: { type: 'array', items: { type: 'object', properties: { id: { type: 'integer' },
        priority: { type: 'string', enum: ['now', 'soon', 'later'] } }, required: ['id', 'priority'] } } }, required: ['items'] };
      const res = await aiJson(AI_STYLE + ' Sort each to-do into now (urgent, has a deadline, or blocks other things), soon (this week) or later (nice to do). ' +
        'Keep roughly a third or fewer in now. Return every id.', 'To-dos (id: title):\n' + todos.map(t => `${t.id}: ${t.title}`).join('\n'), schema);
      let n = 0;
      for (const it of res.items || []) { const a = todos.find(x => x.id === it.id); if (a && ['now', 'soon', 'later'].includes(it.priority)) { a.priority = it.priority; n++; } }
      save(); return { ok: true, changed: n };
    }
    if (p === '/api/ai/chat') {
      const t = clip(String(body.text || '').trim(), 3000); if (!t) fail(400, 'Type or say something first');
      const when = new Date().toLocaleString('en-GB', { weekday: 'long', day: '2-digit', month: 'long', hour: '2-digit', minute: '2-digit' });
      const schema = { type: 'object', properties: { reply: { type: 'string' }, tasks: TASK_SCHEMA.properties.tasks }, required: ['reply', 'tasks'] };
      const res = await aiJson(AI_STYLE + ` It is ${when}. You are a calm planning buddy having a short conversation. ` +
        'Help the person untangle what\'s on their mind and decide what to do. Ask at most one question at a time. ' +
        'Keep replies under 60 words, warm and plain. Do not lecture. ' +
        'Only fill \'tasks\' when you are suggesting concrete tasks they could add (with steps and minutes); otherwise leave it empty.',
        t, schema, body.history || []);
      return { reply: clip(String(res.reply || '').trim(), 1500) || 'Tell me a bit more?', tasks: cleanAiTasks(res.tasks) };
    }
    if (p === '/api/ai/photo') {
      const img = String(body.image || '');
      if (!img.startsWith('data:image/') || !img.includes(';base64,')) fail(400, 'That photo could not be read. Try another.');
      const [mime, data] = img.slice(5).split(';base64,');
      const note = clip(body.note, 500);
      const res = await aiJson(AI_STYLE + ' Read the photo (a handwritten list, whiteboard, letter, screenshot or note) and turn what needs doing ' +
        'into separate tasks with small steps and minutes. Only include things actually in the photo.',
        'Turn this photo into tasks.' + (note ? ' Extra note: ' + note : ''), TASK_SCHEMA, null, { mime, data });
      return { tasks: cleanAiTasks(res.tasks) };
    }
    if (p === '/api/ai/add') {
      const tasks = cleanAiTasks(body.tasks); const mode = body.mode || 'todo'; const date = body.date || today();
      const gap = clamp(int(body.gap, 0), 0, 60);
      let t = null;
      if (mode === 'schedule') { const [h, mi] = (body.start || hhmm(new Date())).split(':').map(Number); t = h * 60 + mi; }
      const colors = ['#7CB8F0', '#73CBA8', '#F4A07A', '#B89AE8', '#F6C453', '#EE8FA6', '#A8C686', '#D9B99B'];
      tasks.forEach((k, i) => {
        const base = { title: k.title, emoji: k.emoji, color: colors[i % colors.length], duration: k.minutes, steps: JSON.stringify(k.steps),
          priority: k.priority, created: nowIso(), remind: 0, end_alert: 1 };
        if (mode === 'schedule') { Object.assign(base, { kind: 'event', date, start: `${pad(Math.floor(t / 60) % 24)}:${pad(t % 60)}` }); t += k.minutes + gap; }
        else base.kind = 'todo';
        insertAct(base);
      });
      save(); return { ok: true, added: tasks.length };
    }

    fail(400, 'That isn’t available when Pacely keeps your plans on this device.');
  }

  window.LOCAL = {
    ready,
    get hasData() { return hasData; },
    native: NATIVE,
    /** Start using Pacely on this device: fresh, or from a backup file's contents. */
    async start(fileData) {
      await ready;
      if (fileData) { importData(fileData, 'replace'); }
      else { db = blank(); seed(); hasData = true; writeNow(); }
    },
    async call(method, path, body) {
      await ready;
      if (!db) fail(400, 'Pacely isn’t set up on this device yet.');
      return clone(await route((method || 'GET').toUpperCase(), path, body));
    },
    exportText() { return JSON.stringify(exportObj(), null, 1); },
    importData(data, mode) { return clone(importData(data, mode)); },
    markBackedUp() { if (db) { db.settings.last_backup = new Date().toISOString(); save(); } },
    flush() { writeNow(); return db ? text() : ''; },
    HttpError
  };
})();
