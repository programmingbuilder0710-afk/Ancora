import assert from 'node:assert/strict';
import { spawn, execFileSync } from 'node:child_process';
import { mkdir, writeFile, copyFile, mkdtemp, rm } from 'node:fs/promises';
import { createWriteStream } from 'node:fs';
import { tmpdir } from 'node:os';
import { fileURLToPath } from 'node:url';
import path from 'node:path';
import puppeteer from 'puppeteer-core';
import { startMock } from './mock-llm.mjs';
const root = fileURLToPath(new URL('../', import.meta.url));
const out = path.join(root, '.context/shots/final');
await mkdir(out, { recursive: true });
const wait = ms => new Promise(resolve => setTimeout(resolve, ms));
const pass = name => console.log(`PASS ${name}`);
let mock, worker, browser, page, stopped = false;
const profile = await mkdtemp(path.join(tmpdir(), 'doer-e2e-'));
const consoleErrors = [];
async function text() { return page.evaluate(() => (document.body.innerText + '\n' + [...document.querySelectorAll('[aria-label]')].map(e => e.getAttribute('aria-label')).join('\n'))); }
async function has(value) { return (await text()).includes(value); }
async function until(value) { await page.waitForFunction(value => (document.body.innerText + '\n' + [...document.querySelectorAll('[aria-label]')].map(e => e.getAttribute('aria-label')).join('\n')).includes(value), { timeout: 30000 }, value); }
async function click(label) {
  const selector = `::-p-aria(${label})`;
  const element = await page.waitForSelector(selector, { timeout: 15000 });
  await element.click(); await wait(500);
}
async function clickContaining(value) {
  // Flutter exposes cards with nested action buttons as tappable groups.
  // Keep the DOM handle: an ARIA name lookup can return a virtual AX node.
  const handle = await page.evaluateHandle(value => [...document.querySelectorAll('[role="button"], [flt-tappable][aria-label]')]
    .find(e => (e.getAttribute('aria-label') || e.innerText).includes(value)), value);
  try {
    const element = handle.asElement();
    assert(element, `Missing tappable element containing ${value}`);
    await element.click(); await wait(500);
  } finally {
    await handle.dispose();
  }
}
async function scrollTo(label) {
  for (let i = 0; i < 15; i++) {
    if (await page.$(`::-p-aria(${label})`)) return;
    await page.mouse.move(215, 650); await page.mouse.wheel({ deltaY: 550 }); await wait(300);
  }
  throw new Error(`Could not scroll to ${label}`);
}
async function fill(label, value) {
  const el = await page.waitForSelector(`input[aria-label="${label}"],textarea[aria-label="${label}"]`);
  // Flutter creates its DOM input on focus; typing before that drops keystrokes.
  await el.click(); await page.waitForFunction(() => ['INPUT', 'TEXTAREA'].includes(document.activeElement?.tagName)); await wait(300);
  // Clear prefilled text with Backspace; Flutter web ignores synthetic select-all.
  const existing = await page.evaluate(() => document.activeElement.value.length);
  // The caret lands where we clicked, so clear both sides of it.
  for (let i = 0; i < existing; i++) { await page.keyboard.press('Backspace'); await page.keyboard.press('Delete'); }
  await page.keyboard.type(value, { delay: 15 }); await wait(300);
  assert.equal(await page.evaluate(() => document.activeElement?.value), value, `typed ${label}`);
}
async function semantics() {
  await page.waitForSelector('flutter-view');
  await wait(1500);
  await page.evaluate(() => document.querySelector('flt-semantics-placeholder')?.click());
  await wait(700);
}
async function shot(name, fullPage = false) {
  await page.mouse.move(1, 1); await wait(500);
  await page.screenshot({ path: path.join(out, `${name}.png`), fullPage });
}
async function selectFirstDay() {
  if (await has('Next:')) await clickContaining('Next:');
}
async function newGoal(title) {
  await click('Goals'); await wait(500);
  await clickContaining('New goal');
  await fill('What do you want to achieve?', title);
}
try {
  // Refuse to reuse somebody else's server or profile.
  try { await fetch('http://localhost:8787'); throw new Error('Port 8787 is occupied; stop that server first.'); }
  catch (e) { if (!e.cause) throw e; }
  mock = await startMock();
  execFileSync('npm', ['run', 'build'], { cwd: path.join(root, 'server'), stdio: 'pipe' });
  const log = createWriteStream(path.join(out, 'wrangler.log'));
  worker = spawn(path.join(root, 'server/node_modules/.bin/wrangler'), ['dev', '--port', '8787', '--env-file', '../e2e/.dev.vars.e2e'],
    { cwd: path.join(root, 'server'), detached: true, stdio: ['ignore', 'pipe', 'pipe'], env: { ...process.env, WRANGLER_SEND_METRICS: 'false' } });
  worker.stdout.pipe(log); worker.stderr.pipe(log);
  let ready = false;
  for (let i = 0; i < 80; i++) {
    try { ready = (await fetch('http://localhost:8787')).ok; } catch {}
    if (ready) break;
    if (worker.exitCode !== null) throw new Error('Wrangler failed; see wrangler.log');
    await wait(250);
  }
  assert(ready, 'Wrangler did not start');
  browser = await puppeteer.launch({ executablePath: process.env.CHROME_PATH || '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',
    userDataDir: profile, headless: true, args: ['--force-renderer-accessibility'],
    defaultViewport: { width: 1280, height: 900, deviceScaleFactor: 2 } });
  page = (await browser.pages())[0];
  await page.evaluateOnNewDocument(() => {
    const RealDate = Date;
    const offset = () => Number(localStorage.getItem('e2e_clock_offset_ms') || 0);
    class TestDate extends RealDate {
      constructor(...args) { super(...(args.length ? args : [RealDate.now() + offset()])); }
      static now() { return RealDate.now() + offset(); }
    }
    window.Date = TestDate;
  });
  page.on('pageerror', error => consoleErrors.push(error.message));
  page.on('console', message => { if (message.type() === 'error') consoleErrors.push(message.text()); });
  await page.goto('http://localhost:8787', { waitUntil: 'networkidle0' });
  assert.equal(await page.$eval('h1', el => el.textContent), 'Big goals, broken into your actual week.');
  assert.equal(await page.$eval('nav a.button', el => el.getAttribute('href')), '/app/');
  pass('Landing headline and Open app link');
  // Screenshots are captured after the app supplies fresh light/dark images.
  await page.click('nav a.button'); await semantics();
  assert.equal(new URL(page.url()).pathname, '/app/');
  await page.setViewport({ width: 430, height: 932, deviceScaleFactor: 2 });
  await until('What are you working toward?'); await shot('onboarding_1');
  await click('Run a half marathon'); await click('Next');
  await until('When can you work on it?'); await click('Evenings'); await shot('onboarding_2'); await click('Next');
  await until('Keep your existing plans free'); await shot('onboarding_3'); await click('Plan my week');
  await until('Set your training baseline');
  assert(mock.requests.length >= 1); assert.equal(mock.requests[0].model, 'qwen/qwen3.8-27b:free');
  assert(await has('sessions')); pass('Onboarding → demo Worker proxy → scheduled agenda');
  await wait(5000); await shot('agenda');
  await page.emulateMediaFeatures([{ name: 'prefers-color-scheme', value: 'dark' }]); await shot('agenda_dark');
  await page.emulateMediaFeatures([{ name: 'prefers-color-scheme', value: 'light' }]);
  await clickContaining('Set your training baseline');
  await until('Rename'); await shot('task_sheet');
  const sessionFacts = await text();
  const timeMatch = sessionFacts.match(/([A-Z][a-z]{2}, [A-Z][a-z]{2} \d{1,2}) · ([\d:]+(?:\s*[AP]M)?) –/);
  assert(timeMatch, `Missing session time: ${sessionFacts}`);
  const planningContext = JSON.parse(mock.requests[0].messages.find(m => m.role === 'user').content);
  const year = planningContext.today.slice(0, 4);
  const clockOffset = await page.evaluate(({ date, time, year }) => {
    const start = new Date(`${date} ${year} ${time}`).getTime();
    if (!Number.isFinite(start)) throw new Error('Cannot parse session start');
    return start + 10 * 60 * 1000 - Date.now();
  }, { date: timeMatch[1], time: timeMatch[2], year });
  await click('Rename'); await fill('Session title', 'Check my running baseline');
  await page.keyboard.press('Enter'); await until('Renamed');
  await until('Check my running baseline'); pass('Session details → Rename → updated Agenda');
  await page.evaluate(offset => localStorage.setItem('e2e_clock_offset_ms', String(offset)), clockOffset);
  await page.reload({ waitUntil: 'domcontentloaded' }); await semantics(); await selectFirstDay();
  await click("Didn't start"); await until('Moved to'); pass("Browser clock advance → Didn't start moves a session");
  await click('Done'); await until('Marked done'); await click('Undo');
  assert.equal((await page.$$('::-p-aria(Completed)')).length, 0); pass('Done → Undo restores pending');
  await click('Done'); await wait(6500); await page.reload({ waitUntil: 'domcontentloaded' }); await semantics();
  await selectFirstDay(); await until('Completed'); pass('Done persists after timeout and reload');
  await newGoal('Learn conversational Spanish'); await click('Plan tasks');
  await until('Learn everyday greetings'); assert(page.url().endsWith('#/agenda'), page.url()); pass('New P2 goal → Plan tasks → Agenda');
  await click('Re-plan'); await click('Continue'); await until('Keep easy runs easy'); await wait(4500); await shot('replan');
  await scrollTo('Back to agenda'); await click('Back to agenda'); pass('Re-plan shows tips and returns to agenda');
  await click('Goals'); await until('Learn conversational Spanish'); await shot('goals');
  await click('Settings'); await until('Free (built-in)'); await shot('settings');
  await page.reload({ waitUntil: 'domcontentloaded' }); await semantics(); await until('Free (built-in)');
  assert(page.url().endsWith('#/settings'), page.url()); pass('Built-in provider and Settings hash survive reload');
  await page.goBack({ waitUntil: 'domcontentloaded' }); await until('New goal');
  await page.goForward({ waitUntil: 'domcontentloaded' }); await until('Free (built-in)');
  pass('Browser Back/Forward preserve the selected tab');
  await mock.close(); stopped = true;
  await newGoal('Build a reading habit'); await click('Plan tasks');
  await until('Free planning is unavailable right now'); await shot('error');
  assert(!(await text()).includes('Exception:'));
  await click('Back'); await until('Open Settings'); await click('Open Settings'); await until('Free (built-in)');
  pass('Unavailable upstream → friendly error → Settings banner');
  for (const name of ['agenda', 'agenda_dark']) {
    await copyFile(path.join(out, `${name}.png`), path.join(root, `server/landing/images/${name}.png`));
    await copyFile(path.join(out, `${name}.png`), path.join(root, `server/dist/images/${name}.png`));
  }
  await wait(1500);
  // Verify landing with the screenshots generated by this run, without JavaScript.
  await page.setJavaScriptEnabled(false);
  await page.setViewport({ width: 1280, height: 900, deviceScaleFactor: 2 });
  await page.goto('http://localhost:8787', { waitUntil: 'networkidle0' });
  await shot('landing', true);
  await page.setViewport({ width: 360, height: 932, deviceScaleFactor: 2 });
  assert(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth));
  await page.setViewport({ width: 390, height: 932, deviceScaleFactor: 2 }); await shot('landing_mobile', true);
  assert(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth));
  await page.setViewport({ width: 1280, height: 900, deviceScaleFactor: 2 });
  await page.emulateMediaFeatures([{ name: 'prefers-color-scheme', value: 'dark' }]); await shot('landing_dark', true);
  const unexpected = consoleErrors.filter(s => !s.includes('status of 503') && !s.includes('status of 502'));
  assert.deepEqual(unexpected, []);
  pass('Landing links, responsive light/dark layout, no JavaScript or console errors');
  pass('All screenshots saved, including task_sheet.png');
} catch (error) {
  console.error(`FAIL ${error.stack}`); process.exitCode = 1;
  if (page) {
    await shot('failure').catch(() => {});
    await writeFile(path.join(out, 'failure.html'), await page.content()).catch(() => {});
    await writeFile(path.join(out, 'failure.txt'), `${error.stack}\n${await text()}\nConsole: ${consoleErrors.join('\n')}`).catch(() => {});
  }
} finally {
  await browser?.close();
  if (worker?.pid) { try { process.kill(-worker.pid, 'SIGTERM'); } catch {} }
  if (mock && !stopped) await mock.close();
  await rm(profile, { recursive: true, force: true });
}
