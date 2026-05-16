#!/usr/bin/env node
/*
 * hostbridge-server.js
 *
 * Runs on the host (macOS or Linux). Listens on 127.0.0.1:7283 for POST /exec
 * from sandboxed containers and runs a small opt-in list of commands on their
 * behalf. Each entry in the registry maps a Linux-style tool name (paplay,
 * notify-send, xdg-open, pbcopy, say) to one or more candidate host
 * executables. At startup, the first available candidate for the current
 * platform is selected.
 *
 * Job control: each /exec spawns a process in its own process group and is
 * registered under a sequential job ID returned to the client in the
 * X-Job-Id response header. POST /cancel/:id signals the job's process group.
 * Closing the request socket also kills the job (backstop for the race where
 * SIGINT lands before the client has the job ID).
 *
 * No external dependencies. Node 18+.
 */

const http = require('http');
const fs = require('fs');
const path = require('path');
const { spawn, spawnSync } = require('child_process');

const HOST = '127.0.0.1';
const PORT_FILE = process.env.HOSTBRIDGE_PORT_FILE || '.contagent-hostbridge-port';
const TIMEOUT_MS = 60_000;
const SHUTDOWN_GRACE_MS = 2_000;
const MAX_BODY = 25 * 1024 * 1024;
const PLATFORM = process.platform; // 'darwin' or 'linux'
const DEBUG = process.env.HOSTBRIDGE_DEBUG === '1';

function dbg(...args) {
  if (DEBUG) console.error('[hostbridge:dbg]', ...args);
}

// ---------- argument validators / transformers ----------
//
// Each validator takes the raw argv from the shim (everything after the tool
// name) and returns the argv that should be passed to the host executable.
// Validators are responsible for stripping anything that would enable a shell
// escape, arbitrary file write, or other escalation.

function audioFile(args) {
  // afplay / paplay / aplay all accept: <tool> <path>. We discard every flag
  // and require exactly one positional path. None of these decoders shell out.
  const positional = args.filter(a => !a.startsWith('-'));
  if (positional.length !== 1) throw new Error('expected one file path');
  return [positional[0]];
}

function ttsText(args) {
  // `say -o FILE` (macOS) and `espeak -w FILE` (Linux) both let you write
  // audio to an arbitrary path. Strip ALL flags and pass through positional
  // text only. Multiple positionals are fine — every TTS tool here joins
  // positional args into a single utterance.
  const positional = args.filter(a => !a.startsWith('-'));
  return positional;
}

function notifyForOsascript(args) {
  // Constant AppleScript; title/body arrive as `argv` items the script reads
  // as data. Do NOT interpolate user input into AppleScript source.
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
  // Strip flags (avoids -i ICON path leaks, -h hint shenanigans, etc.) and
  // pass through TITLE [BODY]. notify-send doesn't shell out on its own.
  const positional = args.filter(a => !a.startsWith('-'));
  return [positional[0] || 'Notification', positional[1] || ''];
}

function urlOnly(args) {
  // `open` (macOS) will happily launch apps via -a, -b, or file:// URLs that
  // point at .app bundles. `xdg-open` will follow whatever handler is
  // registered for the URL scheme. Lock both to http(s)://.
  const positional = args.filter(a => !a.startsWith('-'));
  if (positional.length !== 1) throw new Error('expected one URL');
  if (!/^https?:\/\//i.test(positional[0])) throw new Error('only http(s) URLs');
  return [positional[0]];
}

function clipboardWrite(args) {
  // Refuse paste/read mode so we never leak host clipboard contents back.
  if (args.some(a => a === '-o' || a === '-out' || a === '--output')) {
    throw new Error('clipboard read not exposed');
  }
  return [];
}

// ---------- registry ----------
//
// Each entry: { stdin?, candidates: { darwin: [...], linux: [...] } }
// Each candidate: { exec, transform }
//   - exec: host executable to run
//   - transform: (rawArgs) => finalArgs passed to exec

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
    stdin: true,
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
    stdin: true,
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

// Linux tool names the shim might send that should resolve to the same
// capability as one of the canonical entries above.
const ALIASES = {
  aplay: 'paplay',
  play: 'paplay',
  'wl-copy': 'pbcopy',
  xclip: 'pbcopy',
  xsel: 'pbcopy',
};

// ---------- startup resolution ----------

function which(exec) {
  // Use `command -v` so we don't depend on the `which` binary being installed.
  // Passing exec as $1 (not via interpolation) avoids any shell quoting issues.
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
      if (found) { picked = { ...c, path: found }; break; }
    }
    if (picked) {
      resolved[name] = {
        exec: picked.exec,
        transform: picked.transform,
        stdin: !!entry.stdin,
      };
      console.log(`[hostbridge] ${name.padEnd(12)} -> ${picked.path}`);
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

// ---------- job tracking ----------

let jobCounter = 0;
const JOBS = new Map(); // jobId (string) -> child process

function killGroup(child, signal) {
  // Negative pid signals the entire process group (which we own because we
  // spawned with detached: true). Catches helpers spawned by mpv/ffplay too.
  try { process.kill(-child.pid, signal); } catch { /* already gone */ }
}

// ---------- server ----------

function readBody(req) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    let bytes = 0;
    req.on('data', c => {
      bytes += c.length;
      if (bytes > MAX_BODY) {
        req.destroy();
        reject(new Error('body too large'));
        return;
      }
      chunks.push(c);
    });
    req.on('end', () => resolve(Buffer.concat(chunks)));
    req.on('error', reject);
  });
}

function reply(res, status, obj) {
  if (!res.hasHeader('Content-Type')) {
    res.setHeader('Content-Type', 'application/json');
  }
  res.writeHead(status);
  res.end(JSON.stringify(obj));
}

const server = http.createServer(async (req, res) => {
  // POST /cancel/:id
  const cancelMatch = req.url.match(/^\/cancel\/(\d+)$/);
  if (req.method === 'POST' && cancelMatch) {
    const id = cancelMatch[1];
    dbg('cancel request for job', id);
    const child = JOBS.get(id);
    if (!child) {
      dbg('cancel: job', id, 'not found, known jobs:', [...JOBS.keys()]);
      res.writeHead(404).end();
      return;
    }
    const sig = (req.headers['x-signal'] || 'SIGTERM').toString();
    console.log(`[hostbridge] [job ${id}] cancel with ${sig}`);
    killGroup(child, sig);
    res.writeHead(204).end();
    return;
  }

  // POST /exec
  if (req.method !== 'POST' || req.url !== '/exec') {
    res.writeHead(404).end();
    return;
  }

  let payload;
  try {
    payload = JSON.parse((await readBody(req)).toString());
  } catch {
    reply(res, 400, { exitCode: 1, stdout: '', stderr: 'bad json\n' });
    return;
  }

  const { cmd, args = [], stdin = null } = payload;
  const entry = COMMANDS[cmd];
  if (!entry) {
    console.log(`[hostbridge] reject ${cmd}: not opt-in listed or no implementation`);
    reply(res, 403, { exitCode: 127, stdout: '', stderr: `${cmd}: not allowed\n` });
    return;
  }

  let finalArgs;
  try {
    finalArgs = entry.transform(args);
  } catch (err) {
    console.log(`[hostbridge] reject ${cmd}: ${err.message}`);
    reply(res, 400, { exitCode: 1, stdout: '', stderr: `${cmd}: ${err.message}\n` });
    return;
  }

  const jobId = String(++jobCounter);
  console.log(`[hostbridge] [job ${jobId}] run ${entry.exec} ${finalArgs.map(a => JSON.stringify(a)).join(' ')}`);

  let child;
  try {
    child = spawn(entry.exec, finalArgs, {
      stdio: ['pipe', 'pipe', 'pipe'],
      detached: true, // new process group; lets us signal the whole subtree
    });
  } catch (err) {
    reply(res, 200, { exitCode: 1, stdout: '', stderr: `${cmd}: ${err.message}\n` });
    return;
  }
  JOBS.set(jobId, child);
  dbg('[job', jobId, '] spawned pid', child.pid);
  res.setHeader('X-Job-Id', jobId);
  res.setHeader('Content-Type', 'application/json');
  // Flush headers NOW so the client learns the job ID before the child exits.
  // Without this, headers (including X-Job-Id) wait for res.end() and the
  // shim has no jobId to cancel against while the job is actually running.
  res.flushHeaders();
  dbg('[job', jobId, '] flushed headers');

  const hardTimer = setTimeout(() => {
    dbg('[job', jobId, '] hard timeout, SIGKILL');
    killGroup(child, 'SIGKILL');
  }, TIMEOUT_MS);

  // Backstop: if the client disconnects before we respond, kill the child.
  // Handles the race where SIGINT in the shim fires before X-Job-Id is read.
  let clientGone = false;
  req.on('close', () => {
    dbg('[job', jobId, '] req close event, writableEnded=', res.writableEnded);
    if (res.writableEnded) return;
    clientGone = true;
    console.log(`[hostbridge] [job ${jobId}] client gone, terminating`);
    killGroup(child, 'SIGTERM');
    setTimeout(() => killGroup(child, 'SIGKILL'), SHUTDOWN_GRACE_MS).unref();
  });

  if (entry.stdin && stdin) {
    try { child.stdin.end(Buffer.from(stdin, 'base64')); }
    catch { child.stdin.end(); }
  } else {
    child.stdin.end();
  }

  let stdout = '', stderr = '';
  child.stdout.on('data', c => stdout += c);
  child.stderr.on('data', c => stderr += c);

  child.on('error', err => {
    dbg('[job', jobId, '] child error:', err.message);
    clearTimeout(hardTimer);
    JOBS.delete(jobId);
    if (!res.writableEnded && !clientGone) {
      res.end(JSON.stringify({ exitCode: 1, stdout: '', stderr: err.message + '\n' }));
    }
  });
  child.on('close', code => {
    dbg('[job', jobId, '] child closed, code=', code, 'clientGone=', clientGone);
    clearTimeout(hardTimer);
    JOBS.delete(jobId);
    if (!res.writableEnded && !clientGone) {
      // Headers already flushed; just write the body and end.
      res.end(JSON.stringify({ exitCode: code ?? 1, stdout, stderr }));
    } else if (!res.writableEnded) {
      // Client gave up but socket still open from our side; close it.
      try { res.end(); } catch {}
    }
  });
});

// Port 0 = let the OS pick a free ephemeral port
server.listen(0, HOST, () => {
  const port = server.address().port;
  fs.writeFileSync(PORT_FILE, String(port) + '\n');
  console.log(`[hostbridge] ${PLATFORM} listening on http://${HOST}:${port} (written to ${PORT_FILE})`);
});

function shutdown() {
  console.log('[hostbridge] shutting down, terminating jobs');
  for (const child of JOBS.values()) killGroup(child, 'SIGTERM');
  setTimeout(() => {
    for (const child of JOBS.values()) killGroup(child, 'SIGKILL');
    server.close(() => {
      try { fs.unlinkSync(PORT_FILE); } catch {}
      process.exit(0);
    });
  }, SHUTDOWN_GRACE_MS).unref();
}
process.on('SIGTERM', shutdown);
process.on('SIGINT',  shutdown);
