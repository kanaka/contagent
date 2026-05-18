#!/usr/bin/env node
/*
 * hostbridge.js
 *
 * Runs on the host. Listens for WebSocket connections from sandboxed
 * containers and runs a small opt-in list of commands on their behalf.
 *
 * One WebSocket = one command. Connection lifetime = process lifetime.
 * stdin/stdout/stderr and signals flow as JSON messages.
 *
 * Access control via .hostbridge.yaml (allow/deny/prompt rules).
 * Prompted commands show a native Glimpse dialog on the host.
 * Decisions persist back to .hostbridge.yaml (session or always scope).
 *
 * Library: require('./hostbridge.js').start({ configFile, logFile, ... })
 * Standalone: ./hostbridge.js [--config-file PATH] [--log-file PATH] ...
 *
 * Dependencies: ws, yaml, glimpseui (optional). Node 18+.
 */

const http = require('http');
const fs = require('fs');
const path = require('path');
const { spawn, spawnSync } = require('child_process');
const { WebSocketServer } = require('ws');
const YAML = require('yaml');

const HOST = '127.0.0.1';
const PLATFORM = process.platform;
const DEBUG = process.env.HOSTBRIDGE_DEBUG === '1';
const DEFAULTS = {
  portFile: '.hostbridge-port',
  configFile: '.hostbridge.yaml',
  timeout: 60_000,
  shutdownGrace: 2_000,
};

// ---------- argument validators ----------

function audioFile(args) {
  const pos = args.filter(a => !a.startsWith('-'));
  if (pos.length !== 1) throw new Error('expected one file path');
  return [pos[0]];
}

function ttsText(args) { return args.filter(a => !a.startsWith('-')); }

function notifyOsascript(args) {
  const pos = args.filter(a => !a.startsWith('-'));
  return ['-e', 'on run argv\n display notification (item 2 of argv) with title (item 1 of argv)\nend run',
    pos[0] || 'Notification', pos[1] || ''];
}

function notifyLinux(args) {
  const pos = args.filter(a => !a.startsWith('-'));
  return [pos[0] || 'Notification', pos[1] || ''];
}

function urlOnly(args) {
  const pos = args.filter(a => !a.startsWith('-'));
  if (pos.length !== 1) throw new Error('expected one URL');
  if (!/^https?:\/\//i.test(pos[0])) throw new Error('only http(s) URLs');
  return [pos[0]];
}

function clipboardWrite(args) {
  if (args.some(a => ['-o', '-out', '--output'].includes(a)))
    throw new Error('clipboard read not exposed');
  return [];
}

function clipboardRead(args) {
  return [];
}

// ---------- registry ----------

const REGISTRY = {
  paplay: { darwin: [['afplay', audioFile]],
    linux: [['paplay', audioFile],
      ['ffplay', a => ['-nodisp', '-autoexit', '-loglevel', 'quiet', ...audioFile(a)]],
      ['mpv', a => ['--no-video', '--really-quiet', ...audioFile(a)]],
      ['aplay', a => ['-q', ...audioFile(a)]]] },
  say:    { darwin: [['say', ttsText]],
    linux: [['spd-say', ttsText], ['espeak', ttsText]] },
  'notify-send': { darwin: [['osascript', notifyOsascript]],
    linux: [['notify-send', notifyLinux]] },
  'xdg-open': { darwin: [['open', urlOnly]], linux: [['xdg-open', urlOnly]] },
  pbcopy: { darwin: [['pbcopy', clipboardWrite]],
    linux: [['wl-copy', clipboardWrite],
      ['xclip', a => ['-selection', 'clipboard', ...clipboardWrite(a)]],
      ['xsel', a => ['--clipboard', '--input', ...clipboardWrite(a)]]] },
  pbpaste: { darwin: [['pbpaste', clipboardRead]],
    linux: [['wl-paste', clipboardRead],
      ['xclip', a => ['-selection', 'clipboard', '-o', ...clipboardRead(a)]],
      ['xsel', a => ['--clipboard', '--output', ...clipboardRead(a)]]] },
};

const ALIASES = { aplay: 'paplay', play: 'paplay', 'wl-copy': 'pbcopy', 'wl-paste': 'pbpaste', xclip: 'pbcopy', xsel: 'pbcopy' };

// ---------- helpers ----------

function which(exec) {
  const r = spawnSync('sh', ['-c', 'command -v "$1"', 'sh', exec], { encoding: 'utf8' });
  return r.status === 0 && r.stdout.trim() || null;
}

function killGroup(child, sig) { try { process.kill(-child.pid, sig); } catch {} }

function readYamlRules(file, key) {
  try {
    const doc = YAML.parse(fs.readFileSync(file, 'utf8'));
    const src = key ? doc?.[key] : doc;
    return Array.isArray(src?.rules) ? src.rules : [];
  } catch { return []; }
}

function writeYamlRules(file, rules, log) {
  try {
    fs.writeFileSync(file,
      '# Hostbridge access rules — edit or delete entries to change behavior\n' +
      '# Session entries (with pid) expire when their hostbridge process exits\n' +
      '# Commands not listed default to: prompt\n\n' +
      YAML.stringify({ rules }, { lineWidth: 0 }));
  } catch (err) { log(`[hostbridge] WARN: write ${file}: ${err.message}`); }
}

function findMatchingRule(rules, cmd, args) {
  const myPid = process.pid;
  const ok = rules.filter(r => r.cmd === cmd && (r.scope !== 'session' || r.pid === myPid));
  // Specific args beat any-args
  const argsKey = JSON.stringify(args);
  return (ok.find(r => Array.isArray(r.args) && JSON.stringify(r.args) === argsKey)
       || ok.find(r => r.args === 'any'))?.access ?? null;
}

function resolveGlimpseBinary() {
  try {
    const entry = require.resolve('glimpseui');
    const bin = path.join(path.dirname(entry), 'glimpse');
    if (fs.existsSync(bin)) return bin;
  } catch {}
  return which('glimpse');
}

function esc(s) { return s.replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;').replace(/"/g,'&quot;'); }

// ---------- logging ----------

function createLogger(logFile) {
  const stream = logFile ? fs.createWriteStream(logFile, { flags: 'w' }) : null;
  let startup = true;
  const log = (msg) => {
    if (stream) stream.write(msg + '\n');
    if (startup || !stream) process.stderr.write(msg + '\n');
  };
  const dbg = (...a) => { if (DEBUG) log('[hostbridge:dbg] ' + a.join(' ')); };
  return { log, dbg,
    seal() { if (stream) log(`[hostbridge] logging to ${logFile}`); startup = false; },
    close() { if (stream) try { stream.end(); } catch {} } };
}

// ---------- access control ----------

function yamlHint(cmd, args) {
  const argsYaml = args.length
    ? JSON.stringify(args) + '  # or use "any" for any args'
    : 'any';
  return `To allow permanently, add to .hostbridge.yaml:\n` +
    `  - cmd: ${cmd}\n    access: allow\n    args: ${argsYaml}\n    scope: always`;
}

function getAccessLevel(cmd, rawArgs, configFile) {
  return findMatchingRule(readYamlRules(configFile), cmd, rawArgs) || 'prompt';
}

function saveRule(cfgFile, rule, log) {
  const rules = readYamlRules(cfgFile).filter(r => {
    if (r.cmd !== rule.cmd) return true;
    // Remove conflicting: same cmd + same args class
    if (rule.args === 'any' && r.args === 'any') return false;
    if (Array.isArray(rule.args) && Array.isArray(r.args) &&
        JSON.stringify(rule.args) === JSON.stringify(r.args)) return false;
    return true;
  });
  rules.push(rule);
  writeYamlRules(cfgFile, rules, log);
}

function cleanupStaleEntries(cfgFile, log) {
  const rules = readYamlRules(cfgFile);
  if (!rules.length) return;
  const live = rules.filter(r => {
    if (r.scope !== 'session') return true;
    try { process.kill(r.pid, 0); return true; } catch { return false; }
  });
  if (live.length < rules.length) {
    log(`[hostbridge] cleaned ${rules.length - live.length} stale session entry(s)`);
    writeYamlRules(cfgFile, live, log);
  }
}

// ---------- Glimpse prompt ----------

let _prompt = null;
async function showPrompt(cmd, args, log) {
  try {
    if (!_prompt) _prompt = (await import('glimpseui')).prompt;
    const cmdH = esc(cmd), argsH = args.length ? args.map(esc).join(' ') : '<em style="color:#666">none</em>';
    return await _prompt(`<!DOCTYPE html><html><head><meta charset="utf-8"></head>
<body style="margin:0;font-family:system-ui,-apple-system,sans-serif;background:#1c1c1e;color:#e5e5e7;-webkit-font-smoothing:antialiased">
<div style="padding:20px 24px;display:flex;flex-direction:column;height:100vh;box-sizing:border-box">
  <div style="display:flex;align-items:center;gap:8px;margin-bottom:14px">
    <span style="font-size:20px">🛡️</span>
    <span style="font-size:15px;font-weight:600;color:#fff">Host Command Approval</span></div>
  <div style="background:#2c2c2e;border-radius:8px;padding:12px 14px;margin-bottom:18px;font-family:'SF Mono',Menlo,Consolas,monospace;font-size:12px;line-height:1.6;word-break:break-all">
    <span style="color:#64d2ff;font-weight:600">${cmdH}</span> ${argsH}</div>
  <div style="display:flex;flex-direction:column;gap:10px;margin-bottom:18px">
    ${['Action|sel-a|allow:Allow,deny:Deny','Scope|sel-s|once:Once,session:This Session,always:Always',
       'Args|sel-r|these:Only These Args,any:Any Args'].map(r => {
      const [label, id, opts] = r.split('|');
      return `<div style="display:flex;align-items:center;gap:10px"><label style="width:50px;font-size:12px;color:#98989d;flex-shrink:0">${label}</label><select id="${id}" style="flex:1;padding:7px 10px;border:1px solid #48484a;border-radius:6px;background:#2c2c2e;color:#e5e5e7;font-size:13px;font-family:inherit">${opts.split(',').map((o,i) => { const [v,t] = o.split(':'); return `<option value="${v}"${i===0?' selected':''}>${t}</option>`; }).join('')}</select></div>`;
    }).join('\n    ')}
  </div>
  <div style="display:flex;gap:8px;margin-top:auto;justify-content:flex-end">
    <button onclick="window.glimpse.close()" style="padding:9px 20px;border:none;border-radius:8px;font-size:13px;cursor:pointer;background:#3a3a3c;color:#e5e5e7">Cancel</button>
    <button onclick="S()" style="padding:9px 20px;border:none;border-radius:8px;font-size:13px;cursor:pointer;background:#0a84ff;color:#fff;font-weight:600">Confirm</button></div>
</div>
<script>function S(){window.glimpse.send({action:document.getElementById('sel-a').value,scope:document.getElementById('sel-s').value,args:document.getElementById('sel-r').value})}
document.addEventListener('keydown',e=>{if(e.key==='Enter')S();if(e.key==='Escape')window.glimpse.close()})</script>
</body></html>`, { width: 440, height: 310, title: 'Hostbridge', frameless: true }) || null;
  } catch (err) { log(`[hostbridge] prompt error: ${err.message}`); return null; }
}

// ---------- start ----------

function start(opts = {}) {
  const portFile   = opts.portFile   || process.env.HOSTBRIDGE_PORT_FILE   || DEFAULTS.portFile;
  const configFile  = opts.configFile || process.env.HOSTBRIDGE_CONFIG_FILE || DEFAULTS.configFile;
  const { log, dbg, seal, close: closeLog } = createLogger(opts.logFile || null);

  // Resolve commands
  const COMMANDS = {};
  for (const [name, platforms] of Object.entries(REGISTRY)) {
    for (const [exec, transform] of (platforms[PLATFORM] || [])) {
      const found = which(exec);
      if (found) { COMMANDS[name] = { exec: found, transform }; break; }
    }
    log(`[hostbridge] ${name.padEnd(12)} -> ${COMMANDS[name]?.exec || `(no implementation on ${PLATFORM})`}`);
  }
  for (const [alias, target] of Object.entries(ALIASES))
    if (COMMANDS[target]) COMMANDS[alias] = COMMANDS[target];

  const glimpseBin = resolveGlimpseBinary();
  if (glimpseBin) COMMANDS.glimpse = { exec: glimpseBin, transform: a => a, timeout: 0 };
  log(`[hostbridge] ${'glimpse'.padEnd(12)} -> ${glimpseBin || '(not found; npm install glimpseui)'}`);

  log(`[hostbridge] access config: ${configFile}`);
  cleanupStaleEntries(configFile, log);

  const children = new Set();
  const httpServer = http.createServer((_req, res) => {
    res.writeHead(426).end('WebSocket connection required\n');
  });
  const wss = new WebSocketServer({ server: httpServer });

  wss.on('connection', (ws) => {
    let child = null, started = false, pending = false, timer = null;

    const send = (msg) => { if (ws.readyState === 1) ws.send(JSON.stringify(msg)); };
    const reject = (msg) => { send({ type: 'error', message: msg }); ws.close(); };

    ws.on('message', async (raw) => {
      let msg;
      try { msg = JSON.parse(raw); } catch { ws.close(1002); return; }

      if (!started) {
        if (pending) return;
        if (msg.type !== 'exec') return reject('first message must be exec');

        const { cmd, args: rawArgs = [] } = msg;
        const entry = COMMANDS[cmd];
        if (!entry) { log(`[hostbridge] reject ${cmd}: unknown`); return reject(`${cmd}: not allowed`); }

        let finalArgs;
        try { finalArgs = entry.transform(rawArgs); } catch (e) {
          log(`[hostbridge] reject ${cmd}: ${e.message}`);
          return reject(`${cmd}: ${e.message}`);
        }

        // Access control
        const level = getAccessLevel(cmd, rawArgs, configFile);
        dbg('access:', cmd, '->', level);

        if (level === 'deny') {
          log(`[hostbridge] deny ${cmd}`);
          return reject(`${cmd}: denied by access policy`);
        }

        if (level === 'prompt') {
          if (!glimpseBin) {
            log(`[hostbridge] deny ${cmd}: no UI for prompt`);
            return reject(`${cmd}: denied (no UI available for approval)\n${yamlHint(cmd, rawArgs)}`);
          }
          pending = true;
          const preview = [cmd, ...rawArgs].join(' ');
          log(`[hostbridge] prompt: ${preview}`);
          send({ type: 'pending', message: `Waiting for host approval: ${preview}` });

          const result = await showPrompt(cmd, rawArgs, log);
          pending = false;
          if (ws.readyState !== 1) return;

          if (!result) {
            log(`[hostbridge] ${cmd}: cancelled`);
            return reject(`${cmd}: denied by user\n${yamlHint(cmd, rawArgs)}`);
          }

          const { action, scope, args: argsChoice } = result;
          if (scope !== 'once') {
            const rule = { cmd, access: action, args: argsChoice === 'any' ? 'any' : rawArgs, scope };
            if (scope === 'session') rule.pid = process.pid;
            saveRule(configFile, rule, log);
          }
          log(`[hostbridge] ${cmd}: ${action} ${scope}`);
          if (action !== 'allow') return reject(`${cmd}: denied by user`);
        }

        // Spawn
        log(`[hostbridge] run ${entry.exec} ${finalArgs.map(a => JSON.stringify(a)).join(' ')}`);
        try {
          child = spawn(entry.exec, finalArgs, { stdio: ['pipe','pipe','pipe'], detached: true });
        } catch (err) { return reject(`spawn failed: ${err.message}`); }

        children.add(child);
        started = true;
        send({ type: 'started' });

        const timeoutMs = entry.timeout ?? DEFAULTS.timeout;
        if (timeoutMs > 0) timer = setTimeout(() => killGroup(child, 'SIGKILL'), timeoutMs);

        child.stdout.on('data', c => send({ type: 'stdout', data: c.toString('base64') }));
        child.stderr.on('data', c => send({ type: 'stderr', data: c.toString('base64') }));
        child.on('close', code => {
          if (timer) clearTimeout(timer);
          children.delete(child);
          send({ type: 'exit', code: code ?? 1 });
          ws.close();
        });
        child.on('error', err => {
          if (timer) clearTimeout(timer);
          children.delete(child);
          reject(err.message);
        });
        return;
      }

      // Post-start messages
      if (msg.type === 'stdin' && msg.data) try { child.stdin.write(Buffer.from(msg.data, 'base64')); } catch {}
      else if (msg.type === 'stdin-end') try { child.stdin.end(); } catch {}
      else if (msg.type === 'signal') {
        const sig = msg.signal || 'SIGTERM';
        log(`[hostbridge] signal ${sig} -> pid ${child.pid}`);
        killGroup(child, sig);
      }
    });

    ws.on('close', () => {
      if (timer) clearTimeout(timer);
      if (child && !child.killed) {
        log(`[hostbridge] client disconnected, killing pid ${child.pid}`);
        killGroup(child, 'SIGTERM');
        setTimeout(() => killGroup(child, 'SIGKILL'), DEFAULTS.shutdownGrace).unref();
      }
    });
    ws.on('error', e => dbg('ws error:', e.message));
  });

  return new Promise((resolve, reject) => {
    httpServer.on('error', reject);
    httpServer.listen(0, HOST, () => {
      const port = httpServer.address().port;
      fs.writeFileSync(portFile, String(port) + '\n');
      log(`[hostbridge] ${PLATFORM} listening on ws://${HOST}:${port} (written to ${portFile})`);
      seal();

      const shutdown = () => new Promise(res => {
        log('[hostbridge] shutting down');
        closeLog();
        for (const c of children) killGroup(c, 'SIGTERM');
        setTimeout(() => {
          for (const c of children) killGroup(c, 'SIGKILL');
          wss.close();
          httpServer.close(() => { try { fs.unlinkSync(portFile); } catch {} res(); });
        }, DEFAULTS.shutdownGrace).unref();
      });
      resolve({ port, portFile, shutdown });
    });
  });
}

module.exports = { start };

if (require.main === module) {
  const args = process.argv.slice(2), opts = {};
  let showConfig = false;
  for (let i = 0; i < args.length; i++) {
    if (args[i] === '--log-file'   && args[i+1]) opts.logFile   = args[++i];
    else if (args[i] === '--port-file'  && args[i+1]) opts.portFile  = args[++i];
    else if ((args[i] === '-c' || args[i] === '--config') && args[i+1]) opts.configFile = args[++i];
    else if (args[i] === '--show-config') showConfig = true;
    else if (args[i] === '-h' || args[i] === '--help') {
      console.log('Usage: hostbridge.js [-c PATH] [--log-file PATH] [--port-file PATH] [--show-config]');
      process.exit(0);
    }
  }
  if (showConfig) {
    // Print effective config: defaults for all resolved commands merged with existing config
    const configFile = opts.configFile || process.env.HOSTBRIDGE_CONFIG_FILE || DEFAULTS.configFile;
    const existing = readYamlRules(configFile);
    const defaults = [];
    for (const [name, platforms] of Object.entries(REGISTRY)) {
      for (const [exec] of (platforms[PLATFORM] || [])) {
        if (which(exec)) { defaults.push(name); break; }
      }
    }
    if (resolveGlimpseBinary()) defaults.push('glimpse');
    // Merge: default prompt for each command, then overlay existing rules
    const existingCmds = new Set(existing.map(r => r.cmd + '|' + (Array.isArray(r.args) ? JSON.stringify(r.args) : r.args)));
    const rules = [...existing];
    for (const cmd of defaults) {
      if (!existingCmds.has(cmd + '|any'))
        rules.push({ cmd, access: 'prompt', args: 'any', scope: 'always' });
    }
    process.stdout.write(YAML.stringify({ rules }, { lineWidth: 0 }));
    process.exit(0);
  }
  start(opts).then(({ shutdown }) => {
    const exit = () => shutdown().then(() => process.exit(0));
    process.on('SIGTERM', exit);
    process.on('SIGINT', exit);
  }).catch(e => { console.error(`[hostbridge] ${e.message}`); process.exit(1); });
}
