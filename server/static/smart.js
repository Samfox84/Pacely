/* Pacely smart helpers: pick an emoji and colour from what you type, and understand
   "pick up meds tomorrow 11am" style text. Used by the web app, the on-device engine and
   (the rule list between the markers) by the server, so everything picks the same emoji. */
(function (G) {
  // [words to look for, emoji, colour]  First match wins, so specific things come first.
  const RULES = /*RULES*/[
    ["in the office|office day|wfo|at the office", "🏢", "#9AA8BA"],
    ["working from home|work from home|wfh|home day", "🏠", "#73CBA8"],
    ["sick|ill|unwell|poorly|medical", "🤒", "#9AA8BA"],
    ["day off|annual leave|holiday|vacation|bank holiday|time off", "🌴", "#73CBA8"],
    ["birthday|bday|party", "🎂", "#EE8FA6"],
    ["medicine|medication|meds|tablets|pills|prescription|pharmacy|chemist|inhaler", "💊", "#EE8FA6"],
    ["dentist|teeth|tooth", "🦷", "#7CB8F0"],
    ["call|ring|phone|hmrc|bank|council|helpline", "📞", "#B89AE8"],
    ["doctor|doctors|gp|hospital|clinic|nurse|appointment|physio|vaccin|jab|health visitor|midwife|scan", "🩺", "#F07F6E"],
    ["drop off|drop-off|pick up|pick-up|pickup|collect|school run|nursery|school|childminder", "🚗", "#F6C453"],
    ["meeting|meet|catch up|catch-up|1:1|one to one|interview|zoom|teams|standup|stand-up", "👥", "#7CB8F0"],
    ["email|e-mail|inbox|reply|message|text ", "📧", "#7CB8F0"],
    ["p60|p45|tax|form|paperwork|document|letter|post |sign ", "📄", "#D9B99B"],
    ["direct debit|direct deb|bill|pay |payment|money|budget|invoice|bank transfer|rent|mortgage|child benefit", "💷", "#A8C686"],
    ["shop|shopping|groceries|supermarket|tesco|sainsbury|asda|aldi|lidl|buy ", "🛒", "#73CBA8"],
    ["cook|dinner|tea time|lunch|breakfast|meal|food", "🍽️", "#F4A07A"],
    ["clean|hoover|vacuum|tidy|dust|mop|bins|bin day|recycling", "🧹", "#73CBA8"],
    ["wash|laundry|washing|ironing|dishwasher|dishes", "🧺", "#7CB8F0"],
    ["bath|bathtime|bath time", "🛁", "#7CB8F0"],
    ["shower", "🚿", "#7CB8F0"],
    ["bed|sleep|nap|bedtime", "💤", "#9AA8BA"],
    ["gym|run|exercise|workout|swim|walk|yoga|football", "🏃", "#A8C686"],
    ["dog|cat|vet|pet|feed the", "🐾", "#D9B99B"],
    ["baby|nappy|bottle", "👶", "#F6C453"],
    ["car|mot|garage|petrol|fuel|tyre|service", "🔧", "#9AA8BA"],
    ["train|bus|travel|drive|journey|station|airport|taxi", "🚆", "#9AA8BA"],
    ["parcel|package|delivery|return|amazon|post office", "📦", "#D9B99B"],
    ["podcast|record|edit|video|film", "🎙️", "#B89AE8"],
    ["work|project|deadline|report|review|compliance|presentation|slides", "💻", "#7CB8F0"],
    ["read|book|study|homework|learn", "📚", "#B89AE8"],
    ["game|gaming|play", "🎮", "#B89AE8"],
    ["garden|plants|lawn|mow", "🌳", "#A8C686"],
    ["fix|repair|diy|build|install", "🔧", "#9AA8BA"],
    ["coffee|tea|drink", "☕", "#D9B99B"],
    ["break|rest|relax|chill", "🧘", "#73CBA8"]
  ]/*END*/;
  const compiled = RULES.map(([w, e, c]) => [new RegExp('(^|[^a-z])(' + w.split('|').map(x => x.replace(/[.*+?^${}()[\]\\]/g, '\\$&')).join('|') + ')', 'i'), e, c]);

  function guess(title) {
    const t = ' ' + String(title || '').toLowerCase() + ' ';
    for (const [re, e, c] of compiled) if (re.test(t)) return { emoji: e, color: c };
    return null;
  }

  const DAYNAMES = ['sunday', 'monday', 'tuesday', 'wednesday', 'thursday', 'friday', 'saturday'];
  const MONTHS = ['jan', 'feb', 'mar', 'apr', 'may', 'jun', 'jul', 'aug', 'sep', 'oct', 'nov', 'dec'];
  const pad = n => String(n).padStart(2, '0');
  const isoOf = d => `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}`;

  /* Understands things like:
     "pick up meds tomorrow 11am", "call HMRC fri at 2", "dentist 14/11 9:30 for 1h",
     "drop off robin every weekday 8:45", "day off monday", "sick day today", "bins tonight" */
  function parse(text, todayIso) {
    let s = ' ' + String(text || '') + ' ';
    const out = {};
    const base = todayIso ? new Date(todayIso + 'T12:00:00') : new Date();
    const take = (re, fn) => { const m = s.match(re); if (m) { const ok = fn(m); if (ok !== false) s = s.replace(m[0], ' '); } };
    const dayAt = n => { const d = new Date(base); d.setDate(d.getDate() + n); return isoOf(d); };

    // repeats
    take(/\s(every\s?day|daily)\b/i, () => { out.repeat = { type: 'daily', days: [] }; });
    take(/\s(every\s+weekday|weekdays|mon(day)?\s*(-|to)\s*fri(day)?)\b/i, () => { out.repeat = { type: 'weekdays', days: [] }; });
    take(/\severy\s+((?:(?:mon|tue|wed|thu|fri|sat|sun)[a-z]*(?:\s*(?:,|and|&)\s*)?)+)/i, m => {
      const days = [...m[1].toLowerCase().matchAll(/(mon|tue|wed|thu|fri|sat|sun)/g)].map(x => (DAYNAMES.findIndex(d => d.startsWith(x[1])) + 6) % 7);
      out.repeat = { type: 'days', days: [...new Set(days)].sort() };
    });
    // all day
    take(/\s(all\s?day)\b/i, () => { out.allday = 'day'; });
    // duration
    take(/\s(?:for\s+)?(\d+(?:\.\d+)?)\s*(h|hr|hrs|hour|hours)\b(?:\s*(\d+)\s*(m|min|mins|minutes))?/i, m => { out.duration = Math.round(parseFloat(m[1]) * 60 + (m[3] ? +m[3] : 0)); });
    take(/\s(?:for\s+)?(\d+)\s*(m|min|mins|minutes)\b/i, m => { out.duration = +m[1]; });
    take(/\sfor\s+(half an hour|an hour)\b/i, m => { out.duration = /half/i.test(m[1]) ? 30 : 60; });
    // dates
    take(/\s(today|tonight|this evening)\b/i, m => { out.date = dayAt(0); if (!/today/i.test(m[1])) out._evening = true; });
    take(/\s(tomorrow|tmrw|tmr)\b/i, () => { out.date = dayAt(1); });
    take(/\sin\s+(\d+)\s+days?\b/i, m => { out.date = dayAt(+m[1]); });
    const weekday = m => {
      if (out.repeat) return false;
      const want = DAYNAMES.findIndex(d => d.startsWith(m[2].toLowerCase().slice(0, 3)));
      let add = (want - base.getDay() + 7) % 7; if (add === 0) add = 7; if (/next/i.test(m[1] || '') && add < 7) add += 7;
      out.date = dayAt(add);
    };
    // full day names anywhere; short ones ("fri") only after "on"/"next", before a time, or at the end
    take(/\s(on\s+|next\s+|on\s+next\s+)?(monday|tuesday|wednesday|thursday|friday|saturday|sunday)\b/i, weekday);
    take(/\s(on\s+|next\s+)(mon|tue|tues|wed|thu|thur|thurs|fri|sat|sun)\b/i, weekday);
    take(/\s()(mon|tue|tues|wed|thu|thur|thurs|fri|sat|sun)(?=\s+(?:at\s+)?\d|\s*$)/i, weekday);
    take(/\s(?:on\s+)?(\d{1,2})\/(\d{1,2})(?:\/(\d{2,4}))?\b/, m => {
      const y = m[3] ? (m[3].length === 2 ? 2000 + +m[3] : +m[3]) : base.getFullYear();
      const d = new Date(y, +m[2] - 1, +m[1], 12); if (isNaN(d) || +m[2] > 12) return false;
      if (!m[3] && d < base && (base - d) > 864e5) d.setFullYear(y + 1);
      out.date = isoOf(d);
    });
    take(/\s(?:on\s+)?(\d{1,2})(?:st|nd|rd|th)?\s+(jan|feb|mar|apr|may|jun|jul|aug|sep|sept|oct|nov|dec)[a-z]*\b/i, m => {
      const mo = MONTHS.indexOf(m[2].toLowerCase().slice(0, 3)); const d = new Date(base.getFullYear(), mo, +m[1], 12);
      if (d < base && (base - d) > 864e5) d.setFullYear(d.getFullYear() + 1);
      out.date = isoOf(d);
    });
    // times
    const setT = (h, mi, ap) => {
      h = +h; mi = +(mi || 0);
      if (ap) { ap = ap.toLowerCase(); if (ap.startsWith('p') && h < 12) h += 12; if (ap.startsWith('a') && h === 12) h = 0; }
      else if (h >= 1 && h <= 6) h += 12; // "at 3" means the afternoon
      if (h > 23 || mi > 59) return false;
      out.start = pad(h) + ':' + pad(mi);
    };
    take(/\s(noon|midday)\b/i, () => { out.start = '12:00'; });
    take(/\shalf\s+(\d{1,2})\b/i, m => setT(m[1], 30));
    take(/\s(?:at\s+)?(\d{1,2})[:.](\d{2})\s*(am|pm|a\.m\.|p\.m\.)?(?=\s)/i, m => setT(m[1], m[2], m[3]));
    take(/\s(?:at\s+)?(\d{1,2})\s*(am|pm|a\.m\.|p\.m\.)(?=\s)/i, m => setT(m[1], 0, m[2]));
    take(/\sat\s+(\d{1,2})(?=\s)/i, m => setT(m[1], 0));
    if (out._evening && !out.start) out.start = '19:00';
    delete out._evening;
    // day off / sick day are all-day, quiet days
    const title = s.replace(/\s+/g, ' ').replace(/\s+(on|at|for)\s*$/i, '').trim();
    if (/\b(sick day|off sick|poorly day|medical)\b/i.test(title)) out.allday = 'sick';
    else if (/\b(in the office|office day|at the office|wfo)\b/i.test(title)) out.allday = 'office';
    else if (/\b(working from home|work from home|wfh|home day)\b/i.test(title)) out.allday = 'home';
    else if (/\b(day off|annual leave|holiday|bank holiday|time off)\b/i.test(title)) out.allday = 'off';
    if (out.allday) delete out.start;
    if (/^(wfh|work from home)$/i.test(title)) out.title = 'Working from home';
    else if (/^(wfo|office|office day)$/i.test(title)) out.title = 'In the office';
    else if (title) out.title = title.charAt(0).toUpperCase() + title.slice(1);
    return out;
  }

  G.PacelySmart = { guess, parse, RULES };
  if (typeof module !== 'undefined') module.exports = G.PacelySmart;
})(typeof window !== 'undefined' ? window : globalThis);
