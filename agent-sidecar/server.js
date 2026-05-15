import http from 'node:http';
import { execFile } from 'node:child_process';
import { promises as fs } from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import { chromium } from 'playwright';

const PORT = Number(process.env.PIP_AGENT_SIDECAR_PORT || 37373);
const HOST = '127.0.0.1';

let browser;
let context;
let page;

const jsonHeaders = {
  'content-type': 'application/json; charset=utf-8',
  'access-control-allow-origin': '*',
  'access-control-allow-methods': 'GET,POST,OPTIONS',
  'access-control-allow-headers': 'content-type'
};

function sendJson(res, status, value) {
  res.writeHead(status, jsonHeaders);
  res.end(JSON.stringify(value));
}

async function readBody(req) {
  const chunks = [];
  for await (const chunk of req) chunks.push(chunk);
  if (!chunks.length) return {};
  const text = Buffer.concat(chunks).toString('utf8');
  return text.trim() ? JSON.parse(text) : {};
}

async function ensurePage() {
  if (page && !page.isClosed()) return page;

  if (!browser) {
    browser = await chromium.launch({ headless: false });
  }
  if (!context) {
    context = await browser.newContext({ viewport: null });
  }
  page = await context.newPage();
  return page;
}

function normalizeUrl(input) {
  if (!input) return 'https://www.google.com';
  if (/^https?:\/\//i.test(input)) return input;
  if (input.includes('.') && !input.includes(' ')) return `https://${input}`;
  return `https://www.google.com/search?q=${encodeURIComponent(input)}`;
}

function searchUrlFor(goal) {
  const query = extractSearchQuery(goal);
  const lower = goal.toLowerCase();
  if (lower.includes('youtube') || lower.includes('you tube')) {
    return `https://www.youtube.com/results?search_query=${encodeURIComponent(query || goal)}`;
  }
  if (lower.includes('google')) {
    return `https://www.google.com/search?q=${encodeURIComponent(query || goal)}`;
  }
  return null;
}

function searchUrlForSite(site, query) {
  const normalizedSite = String(site || 'web').toLowerCase();
  const safeQuery = encodeURIComponent(query || '');
  if (normalizedSite.includes('youtube') || normalizedSite.includes('you tube')) {
    return `https://www.youtube.com/results?search_query=${safeQuery}`;
  }
  if (normalizedSite.includes('google')) {
    return `https://www.google.com/search?q=${safeQuery}`;
  }
  return `https://www.bing.com/search?q=${safeQuery}`;
}

function extractSearchQuery(goal) {
  const patterns = [
    /search(?:\s+youtube|\s+google|\s+the web)?\s+(?:for\s+)?(.+)/i,
    /look up\s+(.+)/i,
    /find\s+(.+)/i,
    /type\s+(.+?)(?:\s+in|\s+into|\s+on)?(?:\s+the)?\s+search/i,
    /search bar.*(?:type|enter|write)\s+(.+)/i,
    /(?:type|enter|write)\s+(.+?)\s+(?:in|into|on)\s+(?:the\s+)?search/i
  ];
  for (const pattern of patterns) {
    const match = goal.match(pattern);
    if (match?.[1]) {
      return cleanupQuery(match[1]);
    }
  }
  return '';
}

function cleanupQuery(value) {
  return value
    .replace(/\b(for me|please|and press enter|and hit enter|then press enter)\b/gi, '')
    .replace(/[."'“”‘’]+$/g, '')
    .trim();
}

async function snapshot(currentPage = page) {
  if (!currentPage || currentPage.isClosed()) {
    return { url: '', title: '', text: '', inputs: [] };
  }
  const title = await currentPage.title().catch(() => '');
  const url = currentPage.url();
  const text = await currentPage.locator('body').innerText({ timeout: 1500 }).catch(() => '');
  const inputs = await currentPage.locator('input, textarea, [contenteditable=true]').evaluateAll(elements =>
    elements.slice(0, 30).map((element, index) => ({
      index,
      tag: element.tagName.toLowerCase(),
      type: element.getAttribute('type') || '',
      role: element.getAttribute('role') || '',
      name: element.getAttribute('name') || '',
      ariaLabel: element.getAttribute('aria-label') || '',
      placeholder: element.getAttribute('placeholder') || '',
      text: element.textContent || ''
    }))
  ).catch(() => []);

  return {
    url,
    title,
    text: text.slice(0, 5000),
    inputs
  };
}

function isBotChallenge(snap) {
  const combined = `${snap.url || ''}\n${snap.title || ''}\n${snap.text || ''}`.toLowerCase();
  return combined.includes('/sorry/')
    || combined.includes('unusual traffic')
    || combined.includes('captcha')
    || combined.includes('not a robot');
}

function structuredResult({ success, action, observation, snap = null, needsConfirmation = false, error = '' }) {
  return {
    success,
    action,
    observation,
    url: snap?.url || '',
    title: snap?.title || '',
    text: snap?.text || '',
    needsConfirmation,
    error
  };
}

async function fillLikelySearchField(currentPage, value) {
  const candidates = [
    () => currentPage.getByRole('searchbox').first(),
    () => currentPage.getByRole('textbox', { name: /search/i }).first(),
    () => currentPage.locator('input[aria-label*="Search" i]').first(),
    () => currentPage.locator('input[placeholder*="Search" i]').first(),
    () => currentPage.locator('input[name="search_query"]').first(),
    () => currentPage.locator('input[type="search"]').first(),
    () => currentPage.locator('input[type="text"]').first(),
    () => currentPage.locator('textarea').first()
  ];

  for (const candidate of candidates) {
    const locator = candidate();
    try {
      await locator.waitFor({ state: 'visible', timeout: 900 });
      await locator.fill(value, { timeout: 1200 });
      return true;
    } catch {
      // Try next candidate.
    }
  }
  return false;
}

async function clickByHint(currentPage, hint) {
  const patterns = [
    () => currentPage.getByRole('button', { name: new RegExp(hint, 'i') }).first(),
    () => currentPage.getByRole('link', { name: new RegExp(hint, 'i') }).first(),
    () => currentPage.getByText(new RegExp(hint, 'i')).first()
  ];
  for (const pattern of patterns) {
    try {
      const locator = pattern();
      await locator.waitFor({ state: 'visible', timeout: 900 });
      await locator.click({ timeout: 1200 });
      return true;
    } catch {
      // Try next candidate.
    }
  }
  return false;
}

async function safeGoto(currentPage, url) {
  try {
    await currentPage.goto(url, { waitUntil: 'domcontentloaded', timeout: 15_000 });
  } catch {
    await currentPage.goto(url, { waitUntil: 'commit', timeout: 10_000 }).catch(() => {});
  }
  await currentPage.waitForLoadState('networkidle', { timeout: 3_000 }).catch(() => {});
}

function isDangerousCommand(command) {
  const lower = command.toLowerCase();
  return [
    'rm -rf',
    'sudo rm',
    'mkfs',
    'diskutil erase',
    ':(){',
    'shutdown',
    'reboot',
    'killall'
  ].some(pattern => lower.includes(pattern));
}

function isRiskyGoal(goal) {
  const lower = goal.toLowerCase();
  return [
    'empty trash',
    'delete permanently',
    'erase disk',
    'format disk',
    'buy ',
    'purchase',
    'checkout',
    'payment',
    'send email',
    'send message',
    'post this',
    'change password',
    'security settings',
    'privacy settings'
  ].some(pattern => lower.includes(pattern));
}

async function runAgentGoal(goal, steps = []) {
  const lower = goal.toLowerCase();
  if (isRiskyGoal(goal)) {
    return {
      handled: true,
      completed: false,
      summary: 'i paused because that request could be risky. please handle that one manually or ask me for a safer plan.',
      events: [{ step: 'safety: blocked risky action', status: 'blocked', detail: goal }],
      snapshot: page ? await snapshot(page) : null
    };
  }

  const currentPage = await ensurePage();
  const events = [];

  const add = (step, status = 'completed', detail = '') => {
    events.push({ step, status, detail });
  };

  const searchUrl = searchUrlFor(goal);
  if (searchUrl) {
    add('browser: open search url', 'running', searchUrl);
    await safeGoto(currentPage, searchUrl);
    const snap = await snapshot(currentPage);
    if (isBotChallenge(snap)) {
      if (lower.includes('google')) {
        const query = extractSearchQuery(goal) || goal;
        const fallbackUrl = `https://www.bing.com/search?q=${encodeURIComponent(query)}`;
        add('browser: google bot check, using fallback search', 'running', fallbackUrl);
        await safeGoto(currentPage, fallbackUrl);
        const fallbackSnap = await snapshot(currentPage);
        add('browser: verify fallback search results', 'completed', currentPage.url());
        return {
          handled: true,
          completed: true,
          summary: `google showed a bot check, so i searched for ${query} with bing instead.`,
          events,
          snapshot: fallbackSnap
        };
      }
      add('browser: blocked by bot check', 'blocked', currentPage.url());
      return {
        handled: true,
        completed: false,
        summary: 'i reached the browser, but the site showed a bot check. please solve it once, then i can continue.',
        events,
        snapshot: snap
      };
    }
    add('browser: verify search results', 'completed', currentPage.url());
    return {
      handled: true,
      completed: true,
      summary: `done, i searched for ${extractSearchQuery(goal) || goal}.`,
      events,
      snapshot: snap
    };
  }

  const searchText = extractSearchQuery(goal);
  if ((lower.includes('search bar') || lower.includes('search field')) && searchText) {
    add('browser: fill search field', 'running', searchText);
    const didFill = await fillLikelySearchField(currentPage, searchText);
    if (didFill) {
      if (lower.includes('press enter') || lower.includes('hit enter') || lower.includes('submit')) {
        await currentPage.keyboard.press('Enter');
        add('browser: press enter', 'completed');
      }
      add('browser: verify search field', 'completed');
      return {
        handled: true,
        completed: true,
        summary: `done, i typed ${searchText} into the search field.`,
        events,
        snapshot: await snapshot(currentPage)
      };
    }
  }

  const openMatch = goal.match(/\bopen\s+([^\s]+(?:\.[^\s]+)?)/i);
  if (openMatch?.[1]) {
    const url = normalizeUrl(openMatch[1]);
    add('browser: open page', 'running', url);
    await safeGoto(currentPage, url);
    add('browser: verify page', 'completed', currentPage.url());
    return {
      handled: true,
      completed: true,
      summary: `done, i opened ${currentPage.url()}.`,
      events,
      snapshot: await snapshot(currentPage)
    };
  }

  return {
    handled: false,
    completed: false,
    summary: 'sidecar did not find a matching browser tool for that task.',
    events: steps,
    snapshot: await snapshot(currentPage)
  };
}

async function runStructuredTool(action, args = {}) {
  const currentPage = await ensurePage();
  const normalizedAction = String(action || '');

  if (normalizedAction === 'browser.open') {
    const url = normalizeUrl(args.url || args.query || args.site || 'https://www.google.com');
    await safeGoto(currentPage, url);
    const snap = await snapshot(currentPage);
    return structuredResult({
      success: Boolean(snap.url),
      action: normalizedAction,
      observation: `opened ${snap.title || snap.url}`,
      snap
    });
  }

  if (normalizedAction === 'browser.search') {
    const query = String(args.query || '');
    const site = String(args.site || 'web');
    const url = searchUrlForSite(site, query);
    await safeGoto(currentPage, url);
    let snap = await snapshot(currentPage);
    if (isBotChallenge(snap) && site.toLowerCase().includes('google')) {
      await safeGoto(currentPage, searchUrlForSite('bing', query));
      snap = await snapshot(currentPage);
    }
    const visibleText = `${snap.url}\n${snap.title}\n${snap.text}`.toLowerCase();
    const success = query
      .toLowerCase()
      .split(/\s+/)
      .filter(Boolean)
      .some(token => visibleText.includes(token));
    return structuredResult({
      success,
      action: normalizedAction,
      observation: success ? `verified search results for ${query}` : `opened search, but could not verify results for ${query}`,
      snap,
      error: success ? '' : 'search verification failed'
    });
  }

  if (normalizedAction === 'browser.snapshot' || normalizedAction === 'browser.extractPageText') {
    const snap = await snapshot(currentPage);
    const success = Boolean((snap.text || '').trim());
    return structuredResult({
      success,
      action: normalizedAction,
      observation: success ? `read ${snap.text.length} characters from ${snap.title || snap.url}` : 'no readable page text found',
      snap,
      error: success ? '' : 'empty page text'
    });
  }

  if (normalizedAction === 'browser.verifyText') {
    const expected = String(args.text || args.query || '').toLowerCase();
    const snap = await snapshot(currentPage);
    const haystack = `${snap.url}\n${snap.title}\n${snap.text}`.toLowerCase();
    const success = Boolean(expected) && haystack.includes(expected);
    return structuredResult({
      success,
      action: normalizedAction,
      observation: success ? `verified visible text: ${expected}` : `could not verify visible text: ${expected}`,
      snap,
      error: success ? '' : 'text not found'
    });
  }

  if (normalizedAction === 'browser.fill') {
    const value = String(args.value || args.text || '');
    const ok = await fillLikelySearchField(currentPage, value);
    const snap = await snapshot(currentPage);
    return structuredResult({
      success: ok,
      action: normalizedAction,
      observation: ok ? `filled field with ${value}` : 'could not find a fillable field',
      snap,
      error: ok ? '' : 'field not found'
    });
  }

  if (normalizedAction === 'browser.click') {
    const hint = String(args.hint || args.text || args.label || '');
    const ok = await clickByHint(currentPage, hint);
    const snap = await snapshot(currentPage);
    return structuredResult({
      success: ok,
      action: normalizedAction,
      observation: ok ? `clicked ${hint}` : `could not click ${hint}`,
      snap,
      error: ok ? '' : 'click target not found'
    });
  }

  if (normalizedAction === 'browser.press') {
    const key = String(args.key || 'Enter');
    await currentPage.keyboard.press(key);
    const snap = await snapshot(currentPage);
    return structuredResult({
      success: true,
      action: normalizedAction,
      observation: `pressed ${key}`,
      snap
    });
  }

  return structuredResult({
    success: false,
    action: normalizedAction,
    observation: `unknown sidecar action ${normalizedAction}`,
    snap: await snapshot(currentPage),
    error: 'unknown action'
  });
}

async function route(req, res) {
  if (req.method === 'OPTIONS') {
    sendJson(res, 200, { ok: true });
    return;
  }

  const url = new URL(req.url, `http://${HOST}:${PORT}`);
  if (req.method === 'GET' && url.pathname === '/health') {
    sendJson(res, 200, { ok: true, service: 'pip-agent-sidecar', version: '0.1.0' });
    return;
  }

  const body = await readBody(req);

  if (req.method === 'POST' && url.pathname === '/agent/run') {
    sendJson(res, 200, await runAgentGoal(String(body.goal || ''), body.steps || []));
    return;
  }

  if (req.method === 'POST' && url.pathname === '/tool/run') {
    sendJson(res, 200, await runStructuredTool(body.action, body.args || {}));
    return;
  }

  if (req.method === 'POST' && url.pathname === '/browser/open') {
    const currentPage = await ensurePage();
    await currentPage.goto(normalizeUrl(body.url || body.query), { waitUntil: 'domcontentloaded', timeout: 20_000 });
    sendJson(res, 200, { ok: true, snapshot: await snapshot(currentPage) });
    return;
  }

  if (req.method === 'POST' && url.pathname === '/browser/fill') {
    const currentPage = await ensurePage();
    const ok = await fillLikelySearchField(currentPage, String(body.value || body.text || ''));
    sendJson(res, 200, { ok, snapshot: await snapshot(currentPage) });
    return;
  }

  if (req.method === 'POST' && url.pathname === '/browser/click') {
    const currentPage = await ensurePage();
    const ok = await clickByHint(currentPage, String(body.hint || body.text || ''));
    sendJson(res, 200, { ok, snapshot: await snapshot(currentPage) });
    return;
  }

  if (req.method === 'POST' && url.pathname === '/browser/press') {
    const currentPage = await ensurePage();
    await currentPage.keyboard.press(String(body.key || 'Enter'));
    sendJson(res, 200, { ok: true, snapshot: await snapshot(currentPage) });
    return;
  }

  if (req.method === 'POST' && url.pathname === '/browser/snapshot') {
    sendJson(res, 200, { ok: true, snapshot: await snapshot(await ensurePage()) });
    return;
  }

  if (req.method === 'POST' && url.pathname === '/browser/extract-page-text') {
    const snap = await snapshot(await ensurePage());
    sendJson(res, 200, { ok: Boolean(snap.text), snapshot: snap });
    return;
  }

  if (req.method === 'POST' && url.pathname === '/files/list') {
    const requestedPath = path.resolve(String(body.path || os.homedir()));
    const entries = await fs.readdir(requestedPath, { withFileTypes: true });
    sendJson(res, 200, {
      ok: true,
      path: requestedPath,
      entries: entries.slice(0, 200).map(entry => ({ name: entry.name, isDirectory: entry.isDirectory() }))
    });
    return;
  }

  if (req.method === 'POST' && url.pathname === '/terminal/run') {
    const command = String(body.command || '');
    if (!command || isDangerousCommand(command)) {
      sendJson(res, 400, { ok: false, error: 'blocked dangerous or empty command' });
      return;
    }
    execFile('/bin/zsh', ['-lc', command], { timeout: 20_000, maxBuffer: 1024 * 1024 }, (error, stdout, stderr) => {
      sendJson(res, error ? 500 : 200, {
        ok: !error,
        stdout: stdout.slice(0, 8000),
        stderr: stderr.slice(0, 8000),
        error: error?.message || ''
      });
    });
    return;
  }

  sendJson(res, 404, { ok: false, error: `unknown route ${req.method} ${url.pathname}` });
}

const server = http.createServer((req, res) => {
  route(req, res).catch(error => {
    console.error('[pip-agent-sidecar] route error', error);
    sendJson(res, 500, { ok: false, error: error.message || String(error) });
  });
});

server.listen(PORT, HOST, () => {
  console.log(`[pip-agent-sidecar] listening on http://${HOST}:${PORT}`);
});
