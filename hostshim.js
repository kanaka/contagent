#!/usr/bin/env node
/*
 * hostshim.js
 *
 * Runs inside the container. Symlinked to Linux tool names the host should
 * service (paplay, aplay, pbcopy, glimpse, etc.).
 *
 * When invoked, it connects to the host bridge via WebSocket, sends the
 * command and args, then bridges stdin/stdout/stderr and signals over the
 * connection for the lifetime of the command.
 *
 * See hostbridge.md for the full protocol specification.
 *
 * No external dependencies. Node 22+ (uses built-in WebSocket API).
 */

const fs = require('fs');
const path = require('path');

const HOST = process.env.HOSTBRIDGE_HOST || 'host.docker.internal';
const PORT_FILE = process.env.HOSTBRIDGE_PORT_FILE || '.hostbridge-port';
const CONNECT_TIMEOUT_MS = 10_000;
const DEBUG = process.env.HOSTBRIDGE_DEBUG === '1';

const cmd = path.basename(process.argv[1]);
const args = process.argv.slice(2);

function dbg(...a) {
  if (DEBUG) console.error(`[hostshim:${cmd}:dbg]`, ...a);
}

// ---------- port resolution ----------

function getPort() {
  const envPort = process.env.HOSTBRIDGE_PORT;
  if (envPort) return parseInt(envPort, 10);
  try {
    return parseInt(fs.readFileSync(PORT_FILE, 'utf8').trim(), 10);
  } catch (err) {
    process.stderr.write(`${cmd}: hostbridge: cannot read port file ${PORT_FILE}: ${err.message}\n`);
    process.exit(1);
  }
}

// ---------- connect ----------

const port = getPort();
const url = `ws://${HOST}:${port}/`;
dbg('connecting to', url);

const ws = new WebSocket(url);

const connectTimer = setTimeout(() => {
  process.stderr.write(`${cmd}: hostbridge: connection timeout\n`);
  try { ws.close(); } catch {}
  process.exit(1);
}, CONNECT_TIMEOUT_MS);

// ---------- connection open ----------

ws.addEventListener('open', () => {
  clearTimeout(connectTimer);
  dbg('connected, sending exec');
  ws.send(JSON.stringify({ type: 'exec', cmd, args }));
});

// ---------- message handling ----------

ws.addEventListener('message', (event) => {
  let msg;
  try { msg = JSON.parse(event.data); } catch { return; }
  dbg('received:', msg.type);

  switch (msg.type) {
    case 'started':
      dbg('process started, setting up stdin');
      setupStdin();
      break;

    case 'stdout':
      if (msg.data) {
        try { process.stdout.write(Buffer.from(msg.data, 'base64')); } catch {}
      }
      break;

    case 'stderr':
      if (msg.data) {
        try { process.stderr.write(Buffer.from(msg.data, 'base64')); } catch {}
      }
      break;

    case 'exit':
      dbg('exit code:', msg.code);
      process.exitCode = msg.code ?? 1;
      try { ws.close(); } catch {}
      break;

    case 'error':
      process.stderr.write(`${cmd}: hostbridge: ${msg.message}\n`);
      process.exitCode = 1;
      try { ws.close(); } catch {}
      break;
  }
});

// ---------- stdin forwarding ----------

function setupStdin() {
  if (process.stdin.isTTY) {
    // No stdin to forward — but don't send stdin-end.
    // The server will close the child's stdin when the connection closes.
    // Sending stdin-end here would prematurely kill commands like glimpse
    // that stay alive as long as stdin is open.
    return;
  }

  process.stdin.on('data', (chunk) => {
    sendMsg({ type: 'stdin', data: chunk.toString('base64') });
  });

  process.stdin.on('end', () => {
    sendMsg({ type: 'stdin-end' });
  });

  process.stdin.on('close', () => {
    sendMsg({ type: 'stdin-end' });
  });

  process.stdin.on('error', () => {
    sendMsg({ type: 'stdin-end' });
  });

  process.stdin.resume();
}

function sendMsg(msg) {
  if (ws.readyState === WebSocket.OPEN) {
    ws.send(JSON.stringify(msg));
  }
}

// ---------- signal forwarding ----------

function forwardSignal(signal) {
  dbg('forwarding signal:', signal);
  if (ws.readyState === WebSocket.OPEN) {
    ws.send(JSON.stringify({ type: 'signal', signal }));
  } else {
    // Not connected yet — just exit
    process.exit(128 + (signal === 'SIGINT' ? 2 : 15));
  }
}

process.on('SIGINT',  () => forwardSignal('SIGINT'));
process.on('SIGTERM', () => forwardSignal('SIGTERM'));

// ---------- connection lifecycle ----------

ws.addEventListener('error', () => {
  clearTimeout(connectTimer);
  process.stderr.write(`${cmd}: hostbridge: connection error\n`);
  process.exitCode = 1;
});

ws.addEventListener('close', () => {
  dbg('connection closed, exitCode=', process.exitCode);
  if (process.exitCode == null) process.exitCode = 1;
  try { process.stdin.destroy(); } catch {}
  // Safety net: force exit after allowing output to flush
  setTimeout(() => process.exit(process.exitCode), 50).unref();
});
