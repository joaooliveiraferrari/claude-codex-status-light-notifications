// Agent Status Lights - local dashboard server.
// Zero dependencies (Node core only). Binds to 127.0.0.1 so no admin / firewall prompt.
'use strict';
const http = require('http');
const fs = require('fs');
const path = require('path');
const { spawn, spawnSync } = require('child_process');
const os = require('os');

const UI_DIR = __dirname;
const ROOT = path.resolve(UI_DIR, '..');
const CONFIG_PATH = path.join(ROOT, 'config', 'status-light.config.json');
const LIGHT = path.join(ROOT, 'status-light.ps1');
const TEST = path.join(ROOT, 'test-status.ps1');
const INSTALL = path.join(ROOT, 'install.ps1');
const UNINSTALL = path.join(ROOT, 'uninstall.ps1');
const STATE_DIR = path.join(os.tmpdir(), 'agent-status-lights');
const STATE_PATH = path.join(STATE_DIR, 'state.json');
const EVENTS_PATH = path.join(STATE_DIR, 'events.json');

function readConfig() {
  try { return JSON.parse(fs.readFileSync(CONFIG_PATH, 'utf8')); }
  catch (e) { return {}; }
}
function readJsonSafe(p) {
  try { return JSON.parse(fs.readFileSync(p, 'utf8')); } catch (e) { return null; }
}

const PORT = (readConfig().serverPort) || 8787;

// Run a PowerShell script, return {code, out, err}. Optionally async (fire & forget).
function runPs(scriptPath, args, cb) {
  const a = ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', scriptPath, ...args];
  const child = spawn('powershell', a, { windowsHide: true });
  let out = '', err = '';
  child.stdout.on('data', d => out += d);
  child.stderr.on('data', d => err += d);
  child.on('close', code => cb && cb({ code, out, err }));
  child.on('error', e => cb && cb({ code: -1, out, err: String(e) }));
}

function resolveOpenRgb(cfg) {
  if (cfg.openRgbPath && fs.existsSync(cfg.openRgbPath)) return cfg.openRgbPath;
  const guesses = [
    'C:\\Program Files\\OpenRGB\\OpenRGB.exe',
    'C:\\Program Files (x86)\\OpenRGB\\OpenRGB.exe',
    path.join(process.env.LOCALAPPDATA || '', 'OpenRGB\\OpenRGB.exe'),
    path.join(os.homedir(), 'scoop\\apps\\openrgb\\current\\OpenRGB.exe'),
  ];
  for (const g of guesses) { try { if (fs.existsSync(g)) return g; } catch (e) {} }
  // PATH lookup
  try {
    const r = spawnSync('where', ['OpenRGB'], { encoding: 'utf8' });
    if (r.status === 0 && r.stdout) return r.stdout.split(/\r?\n/)[0].trim();
  } catch (e) {}
  return null;
}

function listDevices(exe) {
  if (!exe) return { installed: false, devices: [] };
  try {
    const r = spawnSync(exe, ['--list-devices'], { encoding: 'utf8', timeout: 8000 });
    const devices = [];
    (r.stdout || '').split(/\r?\n/).forEach(line => {
      const m = line.match(/^\s*(\d+):\s*(.+?)\s*$/);
      if (m) devices.push({ index: Number(m[1]), name: m[2] });
    });
    return { installed: true, path: exe, devices };
  } catch (e) { return { installed: true, path: exe, devices: [], error: String(e) }; }
}

function sendJson(res, code, obj) {
  const body = JSON.stringify(obj);
  res.writeHead(code, { 'Content-Type': 'application/json', 'Cache-Control': 'no-store' });
  res.end(body);
}

function readBody(req) {
  return new Promise((resolve) => {
    let b = '';
    req.on('data', c => b += c);
    req.on('end', () => { try { resolve(b ? JSON.parse(b) : {}); } catch (e) { resolve({}); } });
  });
}

const STATIC = {
  '/': ['index.html', 'text/html'],
  '/index.html': ['index.html', 'text/html'],
  '/app.js': ['app.js', 'application/javascript'],
  '/styles.css': ['styles.css', 'text/css'],
};

const server = http.createServer(async (req, res) => {
  const url = req.url.split('?')[0];

  // ---- static ----
  if (req.method === 'GET' && STATIC[url]) {
    const [file, type] = STATIC[url];
    try {
      const data = fs.readFileSync(path.join(UI_DIR, file));
      res.writeHead(200, { 'Content-Type': type });
      return res.end(data);
    } catch (e) { res.writeHead(404); return res.end('not found'); }
  }

  // ---- API ----
  try {
    if (req.method === 'GET' && url === '/api/state') {
      const cfg = readConfig();
      const exe = resolveOpenRgb(cfg);
      const orgb = exe ? { installed: true, path: exe } : { installed: false };
      return sendJson(res, 200, {
        config: cfg,
        state: readJsonSafe(STATE_PATH),
        events: readJsonSafe(EVENTS_PATH) || [],
        openrgb: orgb,
        provider: (readJsonSafe(STATE_PATH) || {}).provider || (exe ? 'openrgb?' : 'fallback'),
        env: { TERM_PROGRAM: process.env.TERM_PROGRAM || '', VSCODE_PID: process.env.VSCODE_PID || '' },
      });
    }

    if (req.method === 'GET' && url === '/api/devices') {
      const cfg = readConfig();
      return sendJson(res, 200, listDevices(resolveOpenRgb(cfg)));
    }

    if (req.method === 'POST' && url === '/api/status') {
      const body = await readBody(req);
      const valid = ['working', 'approval', 'done', 'error', 'idle', 'normal', 'off'];
      const status = valid.includes(body.status) ? body.status : 'idle';
      runPs(LIGHT, ['-Status', status, '-Source', 'ui'], (r) => {
        sendJson(res, 200, { ok: true, status, out: r.out, err: r.err });
      });
      return;
    }

    if (req.method === 'POST' && url === '/api/config') {
      const body = await readBody(req);
      if (!body || typeof body !== 'object') return sendJson(res, 400, { ok: false, error: 'bad config' });
      // backup then write
      try {
        if (fs.existsSync(CONFIG_PATH)) {
          fs.copyFileSync(CONFIG_PATH, CONFIG_PATH + '.' + Date.now() + '.bak');
        }
        fs.writeFileSync(CONFIG_PATH, JSON.stringify(body, null, 2), 'utf8');
        return sendJson(res, 200, { ok: true });
      } catch (e) { return sendJson(res, 500, { ok: false, error: String(e) }); }
    }

    if (req.method === 'POST' && url === '/api/test') {
      runPs(TEST, ['-DelaySeconds', '1'], (r) => sendJson(res, 200, { ok: true, out: r.out, err: r.err }));
      return;
    }

    if (req.method === 'POST' && url === '/api/install') {
      const body = await readBody(req);
      const target = ['all', 'claude', 'codex'].includes(body.target) ? body.target : 'all';
      const args = ['-Target', target];
      if (body.plan) args.push('-Plan');
      runPs(INSTALL, args, (r) => sendJson(res, 200, { ok: true, out: r.out, err: r.err }));
      return;
    }

    if (req.method === 'POST' && url === '/api/uninstall') {
      const body = await readBody(req);
      const target = ['all', 'claude', 'codex'].includes(body.target) ? body.target : 'all';
      const args = ['-Target', target];
      if (body.plan) args.push('-Plan');
      runPs(UNINSTALL, args, (r) => sendJson(res, 200, { ok: true, out: r.out, err: r.err }));
      return;
    }

    res.writeHead(404); res.end('not found');
  } catch (e) {
    sendJson(res, 500, { ok: false, error: String(e) });
  }
});

server.listen(PORT, '127.0.0.1', () => {
  console.log('Agent Status Lights UI running at  http://localhost:' + PORT);
  console.log('Project root: ' + ROOT);
  console.log('Press Ctrl+C to stop.');
});
