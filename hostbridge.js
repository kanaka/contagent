#!/usr/bin/env node
/*
 * hostbridge.js
 *
 * Runs on the host (macOS or Linux). Listens for WebSocket connections from
 * sandboxed containers and runs a small opt-in list of commands on their behalf.
 *
 * Each WebSocket connection represents exactly one command execution. The
 * connection lifetime matches the process lifetime: stdin/stdout/stderr flow
 * as WebSocket messages, signals are forwarded via messages, and closing the
 * connection kills the process.
 *
 * See hostbridge.md for the full protocol specification.
 *
 * Dependencies: ws, glimpseui (optional)
 * Node 18+.
 */

const http = require('http');
const fs = require('fs');
const path = require('path');
const { spawn, spawnSync } = require('child_process');

let WebSocketServer;
try {
  ({ WebSocketServer } = require('ws'));
} catch {
  console.error('[hostbridge] Error: ws package not installed. Run: npm install');
  process.exit(1);
}

const HOST = '127.0.0.1';
const PORT_FILE = process.env.HOSTBRIDGE_PORT_FILE || '.hostbridge-port';
const DEFAULT_TIMEOUT_MS = 60_000;
const SHUTDOWN_GRACE_MS = 2_000;
const PLATFORM = process.platform;
const DEBUG = process.env.HOSTBRIDGE_DEBUG === '1';

function dbg(...args) {
  if (DEBUG) console.error('[hostbridge:dbg]', ...args);
}

// ---------- argument validators / transformers ----------

function audioFile(args) {
  const positional = args.filter(a => !a.startsWith('-'));
  if (positional.length !== 1) throw new Error('expected one file path');
  return [positional[0]];
}

function ttsText(args) {
  return args.filter(a => !a.startsWith('-'));
}

function notifyForOsascript(args) {
  const positional = args.filter(a => !a.startsWith('-'));
  const title = positional[0] || 'Notification';
  const body = positional[1] || '';
  return [
    '-e',
    'on run argv\n display notification (item 2 of argv) with title (item 1 of argv)\nend run',
    title,
    body,
  ];
}

function notifyForNotifySend(args) {
  const positional = args.filter(a => !a.startsWith('-'));
  return [positional[0] || 'Notification', positional[1] || ''];
}

function urlOnly(args) {
  const positional = args.filter(a => !a.startsWith('-'));
  if (positional.length !== 1) throw new Error('expected one URL');
  if (!/^https?:\/\//i.test(positional[0])) throw new Error('only http(s) URLs');
  return [positional[0]];
}

function clipboardWrite(args) {
  if (args.some(a => a === '-o' || a === '-out' || a === '--output')) {
    throw new Error('clipboard read not exposed');
  }
  return [];
}

function passthrough(args) {
  return args;
}

// ---------- registry ----------

const REGISTRY = {
  paplay: {
    candidates: {
      darwin: [
        { exec: 'afplay', transform: audioFile },
      ],
      linux: [
        { exec: 'paplay', transform: audioFile },
        { exec: 'ffplay', transform: a => ['-nodisp', '-autoexit', '-loglevel', 'quiet', ...audioFile(a)] },
        { exec: 'mpv',    transform: a => ['--no-video', '--really-quiet', ...audioFile(a)] },
        { exec: 'aplay',  transform: a => ['-q', ...audioFile(a)] },
      ],
    },
  },
  say: {
    candidates: {
      darwin: [{ exec: 'say', transform: ttsText }],
      linux: [
        { exec: 'spd-say', transform: ttsText },
        { exec: 'espeak',  transform: ttsText },
      ],
    },
  },
  'notify-send': {
    candidates: {
      darwin: [{ exec: 'osascript',   transform: notifyForOsascript }],
      linux:  [{ exec: 'notify-send', transform: notifyForNotifySend }],
    },
  },
  'xdg-open': {
    candidates: {
      darwin: [{ exec: 'open',     transform: urlOnly }],
      linux:  [{ exec: 'xdg-open', transform: urlOnly }],
    },
  },
  pbcopy: {
    candidates: {
      darwin: [{ exec: 'pbcopy', transform: clipboardWrite }],
      linux: [
        { exec: 'wl-copy', transform: clipboardWrite },
        { exec: 'xclip',   transform: a => ['-selection', 'clipboard', ...clipboardWrite(a)] },
        { exec: 'xsel',    transform: a => ['--clipboard', '--input',  ...clipboardWrite(a)] },
      ],
    },
  },
};

const ALIASES = {
  aplay: 'paplay',
  play: 'paplay',
  'wl-copy': 'pbcopy',
  xclip: 'pbcopy',
  xsel: 'pbcopy',
};

// ---------- startup resolution ----------

function which(exec) {
  const r = spawnSync('sh', ['-c', 'command -v "$1"', 'sh', exec], { encoding: 'utf8' });
  return r.status === 0 && r.stdout.trim() ? r.stdout.trim() : null;
}

function resolveRegistry() {
  const resolved = {};
  for (const [name, entry] of Object.entries(REGISTRY)) {
    const cands = (entry.candidates && entry.candidates[PLATFORM]) || [];
    let picked = null;
    for (const c of cands) {
      const found = which(c.exec);
      if (found) { picked = { ...c, resolvedPath: found }; break; }
    }
    if (picked) {
      resolved[name] = {
        exec: picked.resolvedPath,
        transform: picked.transform,
      };
      console.log(`[hostbridge] ${name.padEnd(12)} -> ${picked.resolvedPath}`);
    } else {
      console.log(`[hostbridge] ${name.padEnd(12)} -> (no implementation on ${PLATFORM})`);
    }
  }
  for (const [alias, target] of Object.entries(ALIASES)) {
    if (resolved[target]) resolved[alias] = resolved[target];
  }
  return resolved;
}

const COMMANDS = resolveRegistry();

// ---------- glimpse resolution ----------

function resolveGlimpseBinary() {
  // First: check glimpseui npm package
  try {
    const mainEntry = require.resolve('glimpseui');
    const candidate = path.join(path.dirname(mainEntry), 'glimpse');
    if (fs.existsSync(candidate)) return candidate;
  } catch {}
  // Fallback: search PATH
  return which('glimpse');
}

const glimpseBinary = resolveGlimpseBinary();
if (glimpseBinary) {
  COMMANDS.glimpse = {
    exec: glimpseBinary,
    transform: passthrough,
    timeout: 0, // no timeout — lifetime controlled by user
  };
  console.log(`[hostbridge] ${'glimpse'.padEnd(12)} -> ${glimpseBinary}`);
} else {
  console.log(`[hostbridge] ${'glimpse'.padEnd(12)} -> (not found; npm install glimpseui)`);
}

// ---------- process management ----------

const children = new Set();

function killGroup(child, signal) {
  try { process.kill(-child.pid, signal); } catch {}
}

// ---------- WebSocket server ----------

const httpServer = http.createServer((_req, res) => {
  res.writeHead(426, { 'Content-Type': 'text/plain' });
  res.end('WebSocket connection required\n');
});

const wss = new WebSocketServer({ server: httpServer });

wss.on('connection', (ws) => {
  let child = null;
  let started = false;
  let timer = null;

  function send(msg) {
    if (ws.readyState === 1) { // OPEN
      ws.send(JSON.stringify(msg));
    }
  }

  ws.on('message', (raw) => {
    let msg;
    try { msg = JSON.parse(raw); } catch { ws.close(1002, 'invalid json'); return; }

    // First message must be exec
    if (!started) {
      if (msg.type !== 'exec') {
        send({ type: 'error', message: 'first message must be exec' });
        ws.close();
        return;
      }

      const { cmd, args: rawArgs = [] } = msg;
      const entry = COMMANDS[cmd];
      if (!entry) {
        console.log(`[hostbridge] reject ${cmd}: not opt-in listed or no implementation`);
        send({ type: 'error', message: `${cmd}: not allowed` });
        ws.close();
        return;
      }

      let finalArgs;
      try { finalArgs = entry.transform(rawArgs); } catch (err) {
        console.log(`[hostbridge] reject ${cmd}: ${err.message}`);
        send({ type: 'error', message: `${cmd}: ${err.message}` });
        ws.close();
        return;
      }

      console.log(`[hostbridge] run ${entry.exec} ${finalArgs.map(a => JSON.stringify(a)).join(' ')}`);

      try {
        child = spawn(entry.exec, finalArgs, {
          stdio: ['pipe', 'pipe', 'pipe'],
          detached: true,
        });
      } catch (err) {
        send({ type: 'error', message: `${cmd}: ${err.message}` });
        ws.close();
        return;
      }

      children.add(child);
      started = true;
      dbg('spawned pid', child.pid);
      send({ type: 'started' });

      // Timeout (0 = disabled)
      const timeoutMs = entry.timeout ?? DEFAULT_TIMEOUT_MS;
      if (timeoutMs > 0) {
        timer = setTimeout(() => {
          dbg('timeout, killing process');
          killGroup(child, 'SIGKILL');
        }, timeoutMs);
      }

      child.stdout.on('data', (chunk) => {
        send({ type: 'stdout', data: chunk.toString('base64') });
      });

      child.stderr.on('data', (chunk) => {
        send({ type: 'stderr', data: chunk.toString('base64') });
      });

      child.on('close', (code) => {
        dbg('child exited, code=', code);
        if (timer) clearTimeout(timer);
        children.delete(child);
        send({ type: 'exit', code: code ?? 1 });
        ws.close();
      });

      child.on('error', (err) => {
        dbg('child error:', err.message);
        if (timer) clearTimeout(timer);
        children.delete(child);
        send({ type: 'error', message: err.message });
        ws.close();
      });

      return;
    }

    // Post-start messages
    switch (msg.type) {
      case 'stdin':
        if (msg.data) {
          try { child.stdin.write(Buffer.from(msg.data, 'base64')); } catch {}
        }
        break;
      case 'stdin-end':
        try { child.stdin.end(); } catch {}
        break;
      case 'signal': {
        const sig = msg.signal || 'SIGTERM';
        console.log(`[hostbridge] signal ${sig} -> pid ${child.pid}`);
        killGroup(child, sig);
        break;
      }
    }
  });

  // Client disconnect → kill process
  ws.on('close', () => {
    if (timer) clearTimeout(timer);
    if (child && !child.killed) {
      console.log(`[hostbridge] client disconnected, killing pid ${child.pid}`);
      killGroup(child, 'SIGTERM');
      setTimeout(() => killGroup(child, 'SIGKILL'), SHUTDOWN_GRACE_MS).unref();
    }
  });

  ws.on('error', (err) => {
    dbg('ws error:', err.message);
  });
});

// ---------- startup ----------

httpServer.listen(0, HOST, () => {
  const port = httpServer.address().port;
  fs.writeFileSync(PORT_FILE, String(port) + '\n');
  console.log(`[hostbridge] ${PLATFORM} listening on ws://${HOST}:${port} (written to ${PORT_FILE})`);
});

// ---------- shutdown ----------

function shutdown() {
  console.log('[hostbridge] shutting down');
  for (const child of children) killGroup(child, 'SIGTERM');
  setTimeout(() => {
    for (const child of children) killGroup(child, 'SIGKILL');
    wss.close();
    httpServer.close(() => {
      try { fs.unlinkSync(PORT_FILE); } catch {}
      process.exit(0);
    });
  }, SHUTDOWN_GRACE_MS).unref();
}

process.on('SIGTERM', shutdown);
process.on('SIGINT',  shutdown);
