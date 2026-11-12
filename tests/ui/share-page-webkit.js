// Checks the share link page works in Safari's engine (WebKit). Usage: node share-page-webkit.js <url>
const { webkit, devices } = require('playwright');
(async () => {
  const b = await webkit.launch(); const p = await b.newPage({ ...devices['iPhone 13'] }); const errs = [];
  p.on('pageerror', e => errs.push(e.message));
  await p.goto(process.argv[2]); await p.waitForTimeout(2500);
  const ok = await p.locator('#title').count() === 1 && (await p.textContent('body')).includes('Add something for');
  await p.fill('#title', 'Test from Safari tomorrow 3pm'); await p.dispatchEvent('#title', 'input');
  const hint = await p.textContent('#hint');
  await p.click('#send'); await p.waitForTimeout(1200);
  const toast = await p.textContent('#toast');
  console.log(JSON.stringify({ loaded: ok, hint, toast, errors: errs }));
  await b.close(); process.exit(ok && !errs.length && /Added/.test(toast) ? 0 : 1);
})();
