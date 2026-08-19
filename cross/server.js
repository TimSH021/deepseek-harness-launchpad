#!/usr/bin/env node
/**
 * DSH Launcher — 跨平台版控制服务（macOS / Linux / Windows，零依赖）
 *
 * dsh 本身运行在 Node 上，所以这里用 Node 实现：凡能跑 dsh 的机器就能跑本启动器。
 * 界面：../shared/index.html（与 macOS 原生 App 共用同一套设计）。
 *
 * 用法：node server.js          （或用平台启动脚本拉起）
 * 端口：LAUNCHER_PORT 环境变量，默认 4899
 * dsh： DSH_PORT 环境变量，默认 3080
 */
'use strict';

const http = require('http');
const net = require('net');
const fs = require('fs');
const os = require('os');
const path = require('path');
const { spawn, execFile, execFileSync } = require('child_process');

const IS_WIN = process.platform === 'win32';
const IS_MAC = process.platform === 'darwin';
const LAUNCHER_PORT = Number(process.env.LAUNCHER_PORT || 4899);
const DSH_PORT = Number(process.env.DSH_PORT || 3080);
const DSH_HOST = '127.0.0.1';
const START_TIMEOUT_MS = 300_000;

const ROOT = __dirname;
const SHARED = path.join(ROOT, '..', 'shared');
const STATE_DIR = process.env.DSH_LAUNCHER_STATE_DIR
  ? path.resolve(process.env.DSH_LAUNCHER_STATE_DIR)
  : (IS_WIN ? path.join(os.homedir(), 'AppData', 'Local', 'DSH Launcher')
            : path.join(os.homedir(), '.local', 'state', 'dsh-launcher'));
fs.mkdirSync(STATE_DIR, { recursive: true });
const PID_FILE = path.join(STATE_DIR, 'child.pid');
const LOG_FILE = path.join(STATE_DIR, 'dsh-web.log');
const INDEX_FILE = path.join(SHARED, 'index.html');

// ---------------------------------------------------------------- 日志
let ring = [];
const RING_MAX = 800;
function log(line) {
  const ts = new Date().toISOString().replace('T', ' ').slice(0, 19);
  for (const l of String(line).split('\n')) {
    if (!l) continue;
    const entry = `[${ts}] ${l}`;
    ring.push(entry);
    if (ring.length > RING_MAX) ring.shift();
    try { fs.appendFileSync(LOG_FILE, entry + '\n'); } catch {}
  }
}

// ---------------------------------------------------------------- 状态
let child = null;            // { pid, spawn, startedAt, adopted }
let lastExit = null;

function pidAlive(pid) {
  if (!pid || pid <= 0) return false;
  try { process.kill(pid, 0); return true; }
  catch (e) { return e.code === 'EPERM'; }
}

function pidIsDsh(pid) {
  try {
    const out = execFileSync(IS_WIN ? 'tasklist' : '/bin/ps',
      IS_WIN ? ['/FI', `PID eq ${pid}`, '/FO', 'CSV'] : ['-p', String(pid), '-o', 'command='],
      { encoding: 'utf8', timeout: 3000 });
    return /dsh( |"|$)/i.test(out) || /@deepseek-ai[\\/]dsh/.test(out);
  } catch { return false; }
}

function adoptFromPidFile() {
  try {
    const pid = Number(fs.readFileSync(PID_FILE, 'utf8').trim());
    if (pidAlive(pid) && pidIsDsh(pid)) {
      child = { pid, adopted: true, startedAt: 0 };
      log(`认领上次拉起的 dsh 进程 pid=${pid}`);
    } else if (pid) {
      try { fs.unlinkSync(PID_FILE); } catch {}
    }
  } catch {}
}

// ---------------------------------------------------------------- dsh 来源（全局 vs npx 缓存）
let _globalDshCache;
function globalDshInfo(force) {
    if (_globalDshCache && !force) return _globalDshCache || {};
    const fs2 = fs, os2 = os;
    let bin = null;
    const candidates = [
        path.join(os2.homedir(), '.npm-global', 'bin', IS_WIN ? 'dsh.cmd' : 'dsh'),
        '/opt/homebrew/bin/dsh', '/usr/local/bin/dsh',
    ];
    for (const c of candidates) { try { fs2.accessSync(c, fs2.constants.X_OK); bin = c; break; } catch {} }
    if (!bin) {
        try {
            const out = require('child_process').execFileSync(
                IS_WIN ? 'cmd.exe' : '/bin/zsh',
                IS_WIN ? ['/c', 'where', 'dsh'] : ['-lc', 'command -v dsh'],
                { encoding: 'utf8', timeout: 5000 });
            const first = out.split('\n')[0].trim();
            if (first && fs2.existsSync(first)) bin = first;
        } catch {}
    }
    _globalDshCache = null;
    if (bin) {
        const real = fs2.realpathSync(bin);
        let dir = path.dirname(real);
        for (let i = 0; i < 5; i++) {
            try {
                const v = JSON.parse(fs2.readFileSync(path.join(dir, 'package.json'), 'utf8')).version;
                if (v) { _globalDshCache = { path: bin, version: v }; break; }
            } catch {}
            const parent = path.dirname(dir);
            if (parent === dir) break;
            dir = parent;
        }
    }
    return _globalDshCache || {};
}

function runShellLogged(cmdLine, timeoutSec) {
    return new Promise((resolve) => {
        const shell = IS_WIN ? 'cmd.exe' : (process.env.SHELL || '/bin/bash');
        const args = IS_WIN ? ['/c', cmdLine] : ['-lc', `exec ${cmdLine}`];
        const proc = spawn(shell, args, { stdio: ['ignore', 'pipe', 'pipe'], windowsHide: true });
        const onData = (tag) => (d) => {
            for (const l of d.toString().split('\n')) if (l.trim()) log(`${tag} ${l.trim()}`);
        };
        proc.stdout.on('data', onData('[npm]'));
        proc.stderr.on('data', onData('[npm err]'));
        const killer = setTimeout(() => { try { proc.kill('SIGTERM'); } catch {} }, timeoutSec * 1000);
        proc.on('error', () => { clearTimeout(killer); resolve(-1); });
        proc.on('exit', (code) => { clearTimeout(killer); resolve(code ?? -1); });
    });
}

// ---------------------------------------------------------------- 探测
function probeDsh(timeoutMs = 1500) {
  return new Promise((resolve) => {
    const sock = net.connect({ host: DSH_HOST, port: DSH_PORT });
    let buf = '';
    const done = (ok) => { try { sock.destroy(); } catch {} resolve(ok); };
    const timer = setTimeout(() => done(false), timeoutMs);
    sock.on('connect', () => sock.write(`GET / HTTP/1.1\r\nHost: ${DSH_HOST}:${DSH_PORT}\r\nConnection: close\r\n\r\n`));
    sock.on('data', (d) => {
      buf += d.toString('utf8');
      if (buf.includes('__DSH_BOOT__')) { clearTimeout(timer); done(true); }
      else if (buf.length > 8192) { clearTimeout(timer); done(false); }
    });
    sock.on('error', () => { clearTimeout(timer); done(false); });
    sock.on('close', () => { clearTimeout(timer); done(buf.includes('__DSH_BOOT__')); });
  });
}

// ---------------------------------------------------------------- 浏览器
function openBrowser(url) {
  const cmd = IS_MAC ? 'open' : IS_WIN ? 'cmd' : 'xdg-open';
  const args = IS_WIN ? ['/c', 'start', '', url] : [url];
  execFile(cmd, args, (err) => { if (err) log('打开浏览器失败: ' + err.message); });
}

// ---------------------------------------------------------------- 启动 / 停止
function startDsh({ autoOpen = true } = {}) {
  if (child && pidAlive(child.pid)) return { ok: false, error: 'starting' };

  let proc;
  const g = globalDshInfo();
  if (g.path) {
    // 优先全局安装的 dsh：与终端 dsh 命令同源同版本
    proc = IS_WIN
      ? spawn('cmd.exe', ['/c', g.path, 'web', '--port', String(DSH_PORT)],
          { detached: true, stdio: ['ignore', 'pipe', 'pipe'], windowsHide: true })
      : spawn(g.path, ['web', '--port', String(DSH_PORT)],
          { detached: true, stdio: ['ignore', 'pipe', 'pipe'] });
  } else if (IS_WIN) {
    proc = spawn('cmd.exe', ['/c', 'npx', '-y', '@deepseek-ai/dsh', 'web', '--port', String(DSH_PORT)],
      { detached: true, stdio: ['ignore', 'pipe', 'pipe'], windowsHide: true });
  } else {
    // 登录 shell 拿到用户 PATH（homebrew / nvm 等）；detached 使子进程自成进程组，可整组停止
    const shell = process.env.SHELL && fs.existsSync(process.env.SHELL) ? process.env.SHELL : '/bin/bash';
    proc = spawn(shell, ['-lc', `exec npx -y @deepseek-ai/dsh web --port ${DSH_PORT}`],
      { detached: true, stdio: ['ignore', 'pipe', 'pipe'] });
  }

  child = { pid: proc.pid, spawn: proc, startedAt: Date.now(), adopted: false };
  lastExit = null;
  try { fs.writeFileSync(PID_FILE, String(proc.pid)); } catch {}

  const prefix = `[dsh ${proc.pid}]`;
  proc.stdout.on('data', (d) => log(prefix + ' ' + d.toString().trim()));
  proc.stderr.on('data', (d) => log(prefix + ' [err] ' + d.toString().trim()));
  proc.on('exit', (code, signal) => {
    log(`${prefix} 退出 code=${code} signal=${signal}`);
    if (child && child.pid === proc.pid) {
      lastExit = { code, signal, at: Date.now() };
      child = null;
      try { fs.unlinkSync(PID_FILE); } catch {}
    }
  });
  proc.on('error', (e) => log(`${prefix} 启动失败: ${e.message}`));

  log(`正在启动 dsh web（预期端口 ${DSH_PORT}）…`);

  const deadline = Date.now() + START_TIMEOUT_MS;
  (async () => {
    while (Date.now() < deadline) {
      await new Promise((r) => setTimeout(r, 1000));
      if (!child || child.pid !== proc.pid) return;
      if (!pidAlive(proc.pid)) return;
      if (await probeDsh(800)) {
        log(`dsh web 已就绪: http://${DSH_HOST}:${DSH_PORT}`);
        if (autoOpen) openBrowser(`http://${DSH_HOST}:${DSH_PORT}`);
        return;
      }
    }
    log('等待就绪超时（300s）。若刚执行过更新，dsh 需重新下载，请稍后再看日志。');
  })();

  return { ok: true, pid: proc.pid };
}

function killTree(pid) {
  if (IS_WIN) {
    execFile('taskkill', ['/PID', String(pid), '/T', '/F'], () => {});
    return;
  }
  try { process.kill(-pid, 'SIGTERM'); }        // 进程组（spawn 用 detached 建组）
  catch {
    try { process.kill(pid, 'SIGTERM'); } catch {}
  }
  setTimeout(() => { if (pidAlive(pid)) { try { process.kill(-pid, 'SIGKILL'); } catch {} } }, 5000);
}

function pidByPort(cb) {
  if (IS_WIN) {
    execFile('netstat', ['-ano', '-p', 'TCP'], (e, out) => {
      let pid = null;
      for (const line of String(out || '').split('\n')) {
        if (line.includes(':' + DSH_PORT + ' ') && /LISTENING/i.test(line)) {
          const cols = line.trim().split(/\s+/);
          const v = Number(cols[cols.length - 1]);
          if (v > 0) { pid = v; break; }
        }
      }
      cb(pid);
    });
  } else {
    execFile('lsof', ['-nP', `-tiTCP:${DSH_PORT}`, '-sTCP:LISTEN'], (e, out) => {
      const v = Number(String(out || '').split('\n')[0]);
      cb(v > 0 ? v : null);
    });
  }
}

function treeOf(pid, cb) {
  const all = [];
  (function walk(p, done) {
    execFile('pgrep', ['-P', String(p)], (e, out) => {
      const kids = String(out || '').split('\n').map(Number).filter((v) => v > 0);
      let left = kids.length;
      if (!left) { all.push(p); return done(); }
      for (const k of kids) walk(k, () => { if (--left === 0) { all.push(p); done(); } });
    });
  })(pid, () => cb(all));
}
function killTreeByPid(pid) {
  if (IS_WIN) { execFile('taskkill', ['/PID', String(pid), '/T', '/F'], () => {}); return; }
  treeOf(pid, (tree) => {
    for (const t of tree) { if (t !== pid) { try { process.kill(t, 'SIGTERM'); } catch {} } }
    try { process.kill(pid, 'SIGTERM'); } catch {}
    setTimeout(() => { for (const t of tree) { try { process.kill(t, 0); process.kill(t, 'SIGKILL'); } catch {} } }, 5000);
  });
}

function stopDsh() {
  if (!child || !pidAlive(child.pid)) { child = null; return { ok: true, already: true }; }
  log(`停止 dsh web（pid ${child.pid}）…`);
  killTree(child.pid);
  try { fs.unlinkSync(PID_FILE); } catch {}
  child = null;
  return { ok: true };
}

// ---------------------------------------------------------------- 更新检测
function npxDshInfo() {
  const npxDir = path.join(os.homedir(), '.npm', '_npx');
  const dirs = [], versions = [];
  try {
    for (const ent of fs.readdirSync(npxDir)) {
      const pj = path.join(npxDir, ent, 'node_modules', '@deepseek-ai', 'dsh', 'package.json');
      try {
        const v = JSON.parse(fs.readFileSync(pj, 'utf8')).version;
        if (v) { dirs.push(path.join(npxDir, ent)); versions.push(v); }
      } catch {}
    }
  } catch {}
  versions.sort((a, b) => a.localeCompare(b, undefined, { numeric: true }));
  return { current: versions[versions.length - 1] || '', dirs };
}

function registryBase() {
  try {
    const txt = fs.readFileSync(path.join(os.homedir(), '.npmrc'), 'utf8');
    for (const line of txt.split('\n')) {
      const t = line.trim();
      if (t.startsWith('registry=')) {
        let v = t.slice('registry='.length).replace(/\/+$/, '');
        if (v) return v;
      }
    }
  } catch {}
  return 'https://registry.npmjs.org';
}

function fetchLatest(cb) {
  const base = registryBase();
  const mod = base.startsWith('https:') ? require('https') : require('http');
  const url = `${base}/@deepseek-ai/dsh/latest`;
  const req = mod.get(url, { timeout: 12000, headers: { 'User-Agent': 'dsh-launcher' } }, (res) => {
    if (res.statusCode !== 200) { res.resume(); return cb(null, `registry HTTP ${res.statusCode}`); }
    let buf = '';
    res.on('data', (d) => { buf += d; if (buf.length > 1e6) req.destroy(); });
    res.on('end', () => {
      try { cb(JSON.parse(buf).version || null, null); }
      catch { cb(null, 'registry 响应解析失败'); }
    });
  });
  req.on('timeout', () => { req.destroy(); cb(null, '请求超时'); });
  req.on('error', (e) => cb(null, e.message));
}

// ---------------------------------------------------------------- HTTP 服务
async function buildStatus() {
  const alive = await probeDsh();
  const ours = !!(child && pidAlive(child.pid));
  return {
    dsh: {
      alive, host: DSH_HOST, port: DSH_PORT,
      url: `http://${DSH_HOST}:${DSH_PORT}`,
      ours, pid: ours ? child.pid : null,
      startedAt: ours && child.startedAt ? child.startedAt : null,
      adopted: ours ? !!child.adopted : false,
    },
    lastExit,
  };
}

const server = http.createServer(async (req, res) => {
  const send = (code, body, type = 'application/json; charset=utf-8') => {
    res.writeHead(code, { 'Content-Type': type, 'Cache-Control': 'no-store' });
    if (Buffer.isBuffer(body)) return res.end(body);
    res.end(typeof body === 'string' ? body : JSON.stringify(body));
  };
  const url = new URL(req.url, `http://127.0.0.1:${LAUNCHER_PORT}`);

  if (req.method === 'GET' && (url.pathname === '/' || url.pathname === '/index.html')) {
    try { return send(200, fs.readFileSync(INDEX_FILE), 'text/html; charset=utf-8'); }
    catch { return send(500, { error: 'shared/index.html 缺失' }); }
  }
  if (req.method === 'GET' && url.pathname === '/api/status') return send(200, await buildStatus());
  if (req.method === 'POST' && url.pathname === '/api/logs-clear') {
    ring = [];
    return send(200, { cleared: true });
  }
  if (req.method === 'GET' && url.pathname === '/api/logs') {
    const n = Math.min(Number(url.searchParams.get('lines') || 200), RING_MAX);
    return send(200, { lines: ring.slice(-n) });
  }
  if (req.method === 'GET' && url.pathname === '/api/dsh-sources') {
    const g = globalDshInfo();
    const npx = npxDshInfo();
    return send(200, { global: g.path ? g : null, npxVersion: npx.current, active: g.path ? 'global' : 'npx' });
  }
  if (req.method === 'POST' && url.pathname === '/api/dsh-install-global') {
    log('安装全局 dsh 命令（npm install -g）');
    const rc = await runShellLogged('npm install -g @deepseek-ai/dsh', 300);
    const g = globalDshInfo(true);
    if (rc !== 0 && !g.path) return send(500, { error: 'npm install -g 失败，请看日志' });
    return send(200, { installed: !!g.path, version: g.version || '?' });
  }
  if (req.method === 'GET' && url.pathname === '/api/update-check') {
    const info = npxDshInfo();
    const g = globalDshInfo();
    return fetchLatest((latest, err) => {
      if (err) return send(502, { error: '检查更新失败: ' + err });
      send(200, {
        current: g.path ? g.version : info.current,
        source: g.path ? 'global' : 'npx',
        latest: latest || '', dirs: info.dirs,
      });
    });
  }

  let body = '';
  for await (const c of req) body += c;
  let json = {};
  try { json = JSON.parse(body || '{}'); } catch {}

  if (req.method === 'POST' && url.pathname === '/api/start') {
    const st = await buildStatus();
    if (st.dsh.alive) {
      openBrowser(st.dsh.url);
      return send(200, { status: 'already-running', opened: true });
    }
    const r = startDsh({ autoOpen: json.autoOpen !== false });
    if (!r.ok) return send(409, { status: 'starting', error: '已有实例正在启动' });
    return send(200, { status: 'starting', pid: r.pid });
  }
  if (req.method === 'POST' && url.pathname === '/api/open') {
    const st = await buildStatus();
    if (!st.dsh.alive) return send(409, { error: 'dsh web 未在运行' });
    openBrowser(st.dsh.url);
    return send(200, { opened: st.dsh.url });
  }
  if (req.method === 'POST' && url.pathname === '/api/stop') {
    const st = await buildStatus();
    if (!st.dsh.alive && !(child && pidAlive(child.pid))) return send(200, { stopped: true, already: true });
    if (st.dsh.ours) {
      stopDsh();
      return send(200, { stopped: true });
    }
    if (json.force) {
      return pidByPort((pid) => {
        if (!pid) return send(409, { error: `端口 ${DSH_PORT} 上没有发现进程` });
        log(`强制停止外部实例 pid=${pid}（端口 ${DSH_PORT}）`);
        killTreeByPid(pid);
        return send(200, { stopped: true, forced: true, pid });
      });
    }
    return send(409, { error: `端口 ${DSH_PORT} 上的实例不是本启动台拉起的。强制停止外部实例需要二次确认（force）。` });
  }
  if (req.method === 'POST' && url.pathname === '/api/update-apply') {
    const dirs = Array.isArray(json.dirs) ? json.dirs : [];
    const npxRoot = path.join(os.homedir(), '.npm', '_npx');
    let removed = 0;
    for (const d of dirs) {
      if (path.resolve(d).startsWith(npxRoot)) {
        try { fs.rmSync(d, { recursive: true, force: true }); removed++; } catch {}
      }
    }
    const g = globalDshInfo();
    if (g.path) {
      log('更新全局 dsh（npm install -g @deepseek-ai/dsh@latest）');
      const rc = await runShellLogged('npm install -g @deepseek-ai/dsh@latest', 300);
      globalDshInfo(true);
      log(`更新完成：全局升级 rc=${rc}，npx 缓存清理 ${removed} 处`);
      return send(200, { ok: rc === 0, removed });
    }
    log(`更新完成：清理 npx 缓存 ${removed} 处`);
    return send(200, { ok: removed > 0, removed });
  }
  return send(404, { error: 'not found' });
});

server.on('error', (e) => {
  if (e.code === 'EADDRINUSE') {
    console.log(`启动台已在运行（端口 ${LAUNCHER_PORT}），直接打开页面`);
    openBrowser(`http://127.0.0.1:${LAUNCHER_PORT}/`);
    process.exit(0);
  }
  console.error(e.message);
  process.exit(1);
});

adoptFromPidFile();
server.listen(LAUNCHER_PORT, '127.0.0.1', () => {
  const url = `http://127.0.0.1:${LAUNCHER_PORT}/`;
  console.log(`DeepSeek Harness 启动台（${process.platform}）: ${url}  (dsh 目标 ${DSH_HOST}:${DSH_PORT})`);
  if (process.env.DSH_LAUNCHER_NO_OPEN !== '1') openBrowser(url);
});
