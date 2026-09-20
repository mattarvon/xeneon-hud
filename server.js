'use strict';
// USCM TAC-NET telemetry server for the Xeneon Edge HUD.
// Zero dependencies. Collects rig / process / Ollama / K3s / ISS telemetry and
// pushes one JSON snapshot per second to the page over SSE. Read-only.

const http = require('http');
const os = require('os');
const fs = require('fs');
const path = require('path');
const { spawn, execFile } = require('child_process');

const ROOT = __dirname;

function readJson(file) {
  try { return JSON.parse(fs.readFileSync(file, 'utf8')); } catch { return null; }
}

const cfg = Object.assign({
  port: 1986,
  kubeconfig: path.join(os.homedir(), '.kube', 'turing-config'),
  ollama: 'http://127.0.0.1:11434',
  disks: ['C', 'D', 'E', 'F'],
}, readJson(path.join(ROOT, 'config.local.json')) || {});

const T = {
  ts: 0,
  host: os.hostname().toUpperCase(),
  uptime: 0,
  gpu: null,
  cpu: { model: os.cpus()[0].model.trim(), load: 0, cores: [] },
  mem: { total: os.totalmem(), used: 0 },
  net: { rx: 0, tx: 0 },
  disks: [],
  ollama: { up: false, installed: 0, loaded: [] },
  k3s: { up: false, nodes: [], pods: { total: 0, running: 0, bad: [], restarts: [] }, argo: { total: 0, ok: 0, bad: [] }, warnings: { count: 0, recent: [] } },
  procs: { n: 0, cpu: [], ram: [] },
  iss: { conn: 'connecting', pct: null, updated: null },
  log: [],
};

function log(msg, lvl = 'info') {
  T.log.unshift({ t: Date.now(), msg, lvl });
  T.log.length = Math.min(T.log.length, 12);
}

// ---------------------------------------------------------------- GPU
const GPU_FIELDS = 'name,temperature.gpu,utilization.gpu,utilization.memory,memory.used,memory.total,power.draw,power.limit,fan.speed,clocks.gr,clocks.mem';

function startGpu() {
  let restarted = false;
  const restart = () => {
    if (restarted) return;
    restarted = true;
    T.gpu = null;
    setTimeout(startGpu, 3000);
  };
  const p = spawn('nvidia-smi', [`--query-gpu=${GPU_FIELDS}`, '--format=csv,noheader,nounits', '-l', '1'], { windowsHide: true });
  let buf = '';
  p.stdout.on('data', (d) => {
    buf += d;
    let i;
    while ((i = buf.indexOf('\n')) >= 0) {
      parseGpu(buf.slice(0, i));
      buf = buf.slice(i + 1);
    }
  });
  p.on('error', restart);
  p.on('exit', restart);
}

function parseGpu(line) {
  const f = line.split(',').map((s) => s.trim());
  if (f.length < 11) return;
  const n = (s) => { const v = parseFloat(s); return Number.isFinite(v) ? v : null; };
  T.gpu = {
    name: f[0].replace(/^NVIDIA\s+/i, ''),
    temp: n(f[1]), util: n(f[2]), memUtil: n(f[3]),
    memUsed: n(f[4]), memTotal: n(f[5]),
    power: n(f[6]), powerLimit: n(f[7]),
    fan: n(f[8]), clock: n(f[9]), memClock: n(f[10]),
  };
}

// ---------------------------------------------------------------- CPU / RAM
let prevCpu = os.cpus().map((c) => c.times);

function sampleCpu() {
  const now = os.cpus().map((c) => c.times);
  const cores = now.map((t, i) => {
    const p = prevCpu[i] || t;
    const idle = t.idle - p.idle;
    const total = (t.user - p.user) + (t.nice - p.nice) + (t.sys - p.sys) + (t.irq - p.irq) + idle;
    return total > 0 ? Math.max(0, Math.min(100, Math.round(100 * (1 - idle / total)))) : 0;
  });
  prevCpu = now;
  T.cpu.cores = cores;
  T.cpu.load = cores.length ? Math.round(cores.reduce((a, b) => a + b, 0) / cores.length) : 0;
  T.mem.used = os.totalmem() - os.freemem();
  T.uptime = os.uptime();
}

// ---------------------------------------------------------------- Network
let prevNet = null;

function sampleNet() {
  execFile('netstat', ['-e'], { windowsHide: true, timeout: 5000 }, (err, out) => {
    if (err) return;
    const m = out.match(/^Bytes\s+(\d+)\s+(\d+)/m);
    if (!m) return;
    const cur = { t: Date.now(), rx: Number(m[1]), tx: Number(m[2]) };
    if (prevNet) {
      const dt = (cur.t - prevNet.t) / 1000;
      const drx = cur.rx - prevNet.rx;
      const dtx = cur.tx - prevNet.tx;
      // counters can wrap; skip the sample rather than show a spike
      if (dt > 0 && drx >= 0 && dtx >= 0) T.net = { rx: drx / dt, tx: dtx / dt };
    }
    prevNet = cur;
  });
}

// ---------------------------------------------------------------- Disks
function sampleDisks() {
  const out = [];
  let pending = cfg.disks.length;
  if (!pending) return;
  cfg.disks.forEach((letter) => {
    fs.statfs(`${letter}:\\`, (err, s) => {
      if (!err && s.blocks > 0) out.push({ name: letter, total: s.blocks * s.bsize, free: s.bfree * s.bsize });
      if (--pending === 0) T.disks = out.sort((a, b) => a.name.localeCompare(b.name));
    });
  });
}

// ---------------------------------------------------------------- Ollama
async function getJson(url, opts = {}) {
  const r = await fetch(url, { signal: AbortSignal.timeout(5000), ...opts });
  if (!r.ok) { const e = new Error(`http ${r.status}`); e.status = r.status; throw e; }
  return r.json();
}

let ollamaNames = null;

async function sampleOllama() {
  try {
    const ps = await getJson(`${cfg.ollama}/api/ps`);
    const loaded = (ps.models || []).map((m) => ({
      name: m.name, vram: m.size_vram || 0, size: m.size || 0,
      expires: m.expires_at ? Date.parse(m.expires_at) : null,
      params: m.details && m.details.parameter_size, quant: m.details && m.details.quantization_level,
    }));
    const names = new Set(loaded.map((m) => m.name));
    if (ollamaNames) {
      for (const n of names) if (!ollamaNames.has(n)) log(`BISHOP: ${n} LOADED INTO MEMORY`);
      for (const n of ollamaNames) if (!names.has(n)) log(`BISHOP: ${n} RELEASED`);
    }
    ollamaNames = names;
    if (!T.ollama.up) log('BISHOP ONLINE');
    T.ollama.up = true;
    T.ollama.loaded = loaded;
  } catch {
    if (T.ollama.up) log('BISHOP NOT RESPONDING', 'crit');
    T.ollama.up = false;
    T.ollama.loaded = [];
    ollamaNames = null;
  }
}

async function sampleOllamaTags() {
  try {
    const models = (await getJson(`${cfg.ollama}/api/tags`)).models || [];
    T.ollama.installed = models.length;
    T.ollama.models = models.map((m) => ({ name: m.name, size: m.size || 0 })).sort((a, b) => b.size - a.size);
  } catch { /* keep last */ }
}

// ---------------------------------------------------------------- K3s
function kubectl(args) {
  return new Promise((resolve) => {
    execFile('kubectl', [...args, '--request-timeout=8s'], {
      env: { ...process.env, KUBECONFIG: cfg.kubeconfig },
      windowsHide: true, maxBuffer: 32 << 20, timeout: 15000,
    }, (err, out) => resolve(err ? null : out));
  });
}

let nodeReady = null;

async function sampleK3s() {
  const [nodesRaw, topRaw] = await Promise.all([
    kubectl(['get', 'nodes', '-o', 'json']),
    kubectl(['top', 'nodes', '--no-headers']),
  ]);
  if (!nodesRaw) {
    if (T.k3s.up) log('CLUSTER UPLINK LOST', 'crit');
    T.k3s.up = false;
    return;
  }
  const top = {};
  for (const line of (topRaw || '').split('\n')) {
    const f = line.trim().split(/\s+/);
    if (f.length >= 5) top[f[0]] = { cpu: parseInt(f[2], 10), mem: parseInt(f[4], 10) };
  }
  let items;
  try { items = JSON.parse(nodesRaw).items; } catch { return; }
  const nodes = items.map((n) => {
    const name = n.metadata.name;
    const labels = n.metadata.labels || {};
    const ready = (n.status.conditions || []).some((c) => c.type === 'Ready' && c.status === 'True');
    const roles = Object.keys(labels).filter((k) => k.startsWith('node-role.kubernetes.io/')).map((k) => k.split('/')[1]);
    const ip = ((n.status.addresses || []).find((a) => a.type === 'InternalIP') || {}).address;
    const t = top[name] || {};
    return {
      name, ready, ip,
      cp: roles.includes('control-plane'),
      arch: n.status.nodeInfo.architecture,
      gpu: !!(n.status.capacity && n.status.capacity['nvidia.com/gpu']),
      cpuPct: Number.isFinite(t.cpu) ? t.cpu : null,
      memPct: Number.isFinite(t.mem) ? t.mem : null,
    };
  }).sort((a, b) => a.name.localeCompare(b.name));

  const readyNow = Object.fromEntries(nodes.map((n) => [n.name, n.ready]));
  if (nodeReady) {
    for (const n of nodes) {
      if (nodeReady[n.name] === true && !n.ready) log(`${n.name} SIGNAL LOST // NOTREADY`, 'crit');
      if (nodeReady[n.name] === false && n.ready) log(`${n.name} SIGNAL REACQUIRED // READY`);
    }
  }
  nodeReady = readyNow;
  if (!T.k3s.up) log(`CLUSTER UPLINK ESTABLISHED // ${nodes.length} CONTACTS`);
  T.k3s.up = true;
  T.k3s.nodes = nodes;
}

async function sampleK3sPods() {
  const raw = await kubectl(['get', 'pods', '-A', '--no-headers']);
  if (!raw) return;
  let total = 0; let running = 0; const bad = []; const restarts = [];
  for (const line of raw.split('\n')) {
    const f = line.trim().split(/\s+/);
    if (f.length < 5) continue;
    total++;
    if (f[3] === 'Running') running++;
    else if (f[3] !== 'Completed') bad.push({ ns: f[0], name: f[1], status: f[3] });
    const r = parseInt(f[4], 10); // RESTARTS column reads "6 (3d ago)"
    if (r > 0) restarts.push({ ns: f[0], name: f[1], n: r });
  }
  restarts.sort((a, b) => b.n - a.n);
  T.k3s.pods = { total, running, bad: bad.slice(0, 8), restarts: restarts.slice(0, 6) };
}

// ---------------------------------------------------------------- K3s trouble board
let argoBadNames = null;

async function sampleArgo() {
  const raw = await kubectl(['get', 'applications.argoproj.io', '-A', '-o', 'json']);
  if (!raw) return;
  let items;
  try { items = JSON.parse(raw).items; } catch { return; }
  const apps = items.map((a) => ({
    name: a.metadata.name,
    sync: (a.status && a.status.sync && a.status.sync.status) || 'Unknown',
    health: (a.status && a.status.health && a.status.health.status) || 'Unknown',
  }));
  // Progressing is a normal rollout state, not a casualty
  const bad = apps.filter((a) => a.sync !== 'Synced' || !['Healthy', 'Progressing'].includes(a.health));
  const names = new Set(bad.map((a) => a.name));
  if (argoBadNames) {
    for (const a of bad) if (!argoBadNames.has(a.name)) log(`ARGO ${a.name} ${a.sync} / ${a.health}`, 'crit');
    for (const n of argoBadNames) if (!names.has(n)) log(`ARGO ${n} RECOVERED`);
  }
  argoBadNames = names;
  T.k3s.argo = { total: apps.length, ok: apps.length - bad.length, bad: bad.slice(0, 6) };
}

async function sampleWarnings() {
  const raw = await kubectl(['get', 'events', '-A', '--field-selector', 'type=Warning', '-o', 'json']);
  if (!raw) return;
  let items;
  try { items = JSON.parse(raw).items; } catch { return; }
  const cutoff = Date.now() - 3600 * 1000;
  const recent = items.map((e) => ({
    t: Date.parse(e.lastTimestamp || e.eventTime || e.metadata.creationTimestamp),
    reason: e.reason, obj: `${e.involvedObject.kind}/${e.involvedObject.name}`, ns: e.involvedObject.namespace || e.metadata.namespace,
  })).filter((e) => e.t >= cutoff).sort((a, b) => b.t - a.t);
  T.k3s.warnings = { count: recent.length, recent: recent.slice(0, 4) };
}

// ---------------------------------------------------------------- Top processes
// One long-lived PowerShell child emits a JSON line every few seconds; far cheaper than spawning per sample.
function startProcs() {
  let restarted = false;
  const restart = () => { if (!restarted) { restarted = true; setTimeout(startProcs, 5000); } };
  const p = spawn('powershell.exe', ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', path.join(ROOT, 'procs.ps1')], { windowsHide: true });
  let buf = '';
  p.stdout.on('data', (d) => {
    buf += d;
    let i;
    while ((i = buf.indexOf('\n')) >= 0) {
      try { T.procs = JSON.parse(buf.slice(0, i)); } catch { /* partial or noise */ }
      buf = buf.slice(i + 1);
    }
  });
  p.on('error', restart);
  p.on('exit', restart);
}

// ---------------------------------------------------------------- ISS urine tank
// Port of E:\projects\iss-piss-o-meter: NASA's public ISS telemetry over Lightstreamer
// (TLCP-2.1.0, adapter set ISSLIVE, item NODE3000005 = "Urine Tank Qty", percent).
const LS_SERVER = 'https://push.lightstreamer.com';
const LS_CID = 'mgQkwtwdysogQz2BJ4Ji kOj2Bg'; // standard public client id
const LS_ITEM = 'NODE3000005';
const LS_FORM = { 'content-type': 'application/x-www-form-urlencoded' };

// Lightstreamer MERGE delta decoding for the "a|b|..." value payload
function lsApplyDelta(last, payload) {
  let idx = 0;
  for (const f of payload.split('|')) {
    if (idx >= last.length) break;
    if (f === '') { idx++; continue; }               // unchanged
    if (f[0] === '^') { idx += parseInt(f.slice(1), 10) || 0; continue; }
    if (f === '#') last[idx] = null;
    else if (f === '$') last[idx] = '';
    else { try { last[idx] = decodeURIComponent(f); } catch { last[idx] = f; } }
    idx++;
  }
}

async function issSession() {
  const ac = new AbortController();
  // the stream sends PROBE keepalives; silence this long means the socket is dead
  let watchdog = setTimeout(() => ac.abort(), 60000);
  const feed = () => { clearTimeout(watchdog); watchdog = setTimeout(() => ac.abort(), 60000); };
  try {
    const res = await fetch(`${LS_SERVER}/lightstreamer/create_session.txt?LS_protocol=TLCP-2.1.0`, {
      method: 'POST', headers: LS_FORM, signal: ac.signal,
      body: `LS_cid=${encodeURIComponent(LS_CID)}&LS_adapter_set=ISSLIVE&LS_send_sync=false&LS_polling=false`,
    });
    if (!res.ok || !res.body) throw new Error(`http ${res.status}`);
    const reader = res.body.getReader();
    const dec = new TextDecoder();
    const fields = [null, null]; // TimeStamp, Value
    let buf = '';
    let subscribed = false;
    for (;;) {
      const { value, done } = await reader.read();
      if (done) return;
      feed();
      buf += dec.decode(value, { stream: true });
      let i;
      while ((i = buf.indexOf('\n')) >= 0) {
        const line = buf.slice(0, i).trim();
        buf = buf.slice(i + 1);
        if (line.startsWith('CONOK,') && !subscribed) {
          subscribed = true;
          const p = line.split(',');
          const control = p[4] && p[4] !== '*' ? `https://${p[4]}` : LS_SERVER;
          const r = await fetch(`${control}/lightstreamer/control.txt?LS_protocol=TLCP-2.1.0`, {
            method: 'POST', headers: LS_FORM, signal: AbortSignal.timeout(15000),
            body: `LS_session=${encodeURIComponent(p[1])}&LS_op=add&LS_subId=1&LS_reqId=1&LS_mode=MERGE&LS_group=${LS_ITEM}`
              + `&LS_schema=${encodeURIComponent('TimeStamp Value')}&LS_data_adapter=DEFAULT&LS_snapshot=true&LS_requested_max_frequency=1`,
          });
          await r.text();
          T.iss.conn = 'live';
        } else if (line.startsWith('CONERR')) {
          throw new Error(`refused ${line}`);
        } else if (line.startsWith('U,')) {
          const parts = line.split(',');
          lsApplyDelta(fields, parts.slice(3).join(','));
          const v = parseFloat(fields[1]);
          if (Number.isFinite(v)) {
            const pct = Math.max(0, Math.min(100, v));
            if (T.iss.pct !== null && T.iss.pct < 95 && pct >= 95) log('ISS URINE TANK CRITICAL // FLUSH', 'crit');
            if (T.iss.pct !== null && pct < T.iss.pct - 20) log(`ISS URINE TANK DUMPED // NOW ${Math.round(pct)} PCT`);
            T.iss.pct = pct;
            T.iss.updated = Date.now();
          }
        } else if (line.startsWith('LOOP') || line.startsWith('END')) {
          return;
        }
      }
    }
  } finally {
    clearTimeout(watchdog);
    ac.abort();
  }
}

async function issLoop() {
  let backoff = 2;
  for (;;) {
    try { T.iss.conn = 'connecting'; await issSession(); backoff = 2; } catch { /* reconnect below */ }
    T.iss.conn = 'offline';
    await new Promise((r) => setTimeout(r, backoff * 1000));
    backoff = Math.min(backoff * 2, 30);
  }
}

// ---------------------------------------------------------------- HTTP + SSE
const clients = new Set();

const server = http.createServer((req, res) => {
  const url = req.url.split('?')[0];
  if (url === '/api/stream') {
    res.writeHead(200, { 'content-type': 'text/event-stream', 'cache-control': 'no-cache', connection: 'keep-alive' });
    res.write(`data: ${JSON.stringify(T)}\n\n`);
    clients.add(res);
    req.on('close', () => clients.delete(res));
    return;
  }
  if (url === '/api/telemetry') {
    res.writeHead(200, { 'content-type': 'application/json', 'cache-control': 'no-store' });
    res.end(JSON.stringify(T));
    return;
  }
  if (url === '/' || url === '/index.html') {
    fs.readFile(path.join(ROOT, 'index.html'), (err, data) => {
      if (err) { res.writeHead(500); res.end('index.html missing'); return; }
      res.writeHead(200, { 'content-type': 'text/html; charset=utf-8', 'cache-control': 'no-store' });
      res.end(data);
    });
    return;
  }
  res.writeHead(404);
  res.end();
});

function every(ms, fn) {
  const run = () => Promise.resolve().then(fn).catch(() => {});
  run();
  setInterval(run, ms);
}

log('TAC-NET UPLINK ESTABLISHED');
startGpu();
every(1000, sampleCpu);
every(2000, sampleNet);
every(30000, sampleDisks);
every(3000, sampleOllama);
every(60000, sampleOllamaTags);
every(15000, sampleK3s);
every(30000, sampleK3sPods);
every(30000, sampleArgo);
every(30000, sampleWarnings);
startProcs();
issLoop();

setInterval(() => {
  T.ts = Date.now();
  const msg = `data: ${JSON.stringify(T)}\n\n`;
  for (const c of clients) c.write(msg);
}, 1000);

server.listen(cfg.port, '127.0.0.1', () => {
  console.log(`TAC-NET listening on http://127.0.0.1:${cfg.port}/`);
});
