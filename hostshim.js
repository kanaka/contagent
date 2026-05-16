#!/usr/bin/env node
/*
 * hostshim.js
 *
 * Runs inside the container. Symlink this to the Linux tool names the host
 * should service:
 *
 *   for t in paplay aplay play notify-send xdg-open pbcopy wl-copy xclip xsel say; do
 *     ln -s hostshim.js /usr/local/bin/$t
 *   done
 *
 * When invoked, it reads argv[0] (the tool name), forwards argv + stdin to
 * the host bridge over HTTP, then replays the result's stdout/stderr/exitCode.
 * The shim has no knowledge of which commands are valid — the server enforces
 * the opt-in list.
 *
 * Job control: SIGINT/SIGTERM on the shim sends POST /cancel/:id to the
 * server using the X-Job-Id returned in the response headers. If the signal
 * lands before the job ID is known, the open socket is destroyed and the
 * server's socket-close backstop will terminate the job.
 *
 * No external dependencies. Node 18+.
 */

const http = require('http');
const fs = require('fs');
const path = require('path');

const HOST = process.env.HOSTBRIDGE_HOST || 'host.docker.internal';
const PORT_FILE = process.env.HOSTBRIDGE_PORT_FILE || '.contagent-hostbridge-port';
const REQUEST_TIMEOUT_MS = 65_000;

function getPort() {
  const src = process.env.HOSTBRIDGE_PORT || '';
  if (src) return parseInt(src, 10);
  try {
    return parseInt(fs.readFileSync(PORT_FILE, 'utf8').trim(), 10);
  } catch (err) {
    process.stderr.write(`${cmd}: hostbridge: cannot read port file ${PORT_FILE}: ${err.message}\n`);
    process.exit(1);
  }
}
const CANCEL_TIMEOUT_MS = 2_000;

const cmd = path.basename(process.argv[1]);
const args = process.argv.slice(2);
const DEBUG = process.env.HOSTBRIDGE_DEBUG === '1';

function dbg(...a) {
  if (DEBUG) console.error(`[hostshim:${cmd}:dbg]`, ...a);
}

let mainReq = null;
let jobId = null;
let cancelling = false;

function exitForSignal(sig) {
  // POSIX convention: 128 + signal number
  process.exit(128 + (sig === 'SIGINT' ? 2 : 15));
}

function cancel(signal) {
  dbg('cancel() called signal=', signal, 'cancelling=', cancelling, 'jobId=', jobId);
  if (cancelling) return;
  cancelling = true;

  if (!jobId) {
    // Race: signal landed before we got the job ID. Drop the socket; the
    // server will see the disconnect and kill the child via its backstop.
    dbg('no jobId yet, destroying main request socket');
    try { mainReq && mainReq.destroy(); } catch {}
    exitForSignal(signal);
    return;
  }

  dbg('sending POST /cancel/' + jobId + ' with signal', signal);
  const creq = http.request({
    method: 'POST',
    host: HOST,
    port: getPort(),
    path: `/cancel/${jobId}`,
    headers: { 'X-Signal': signal, 'Content-Length': 0 },
    timeout: CANCEL_TIMEOUT_MS,
  }, (cres) => {
    dbg('cancel response status=', cres.statusCode);
    cres.on('data', () => {});
    cres.on('end', () => {
      dbg('cancel response complete, exiting');
      exitForSignal(signal);
    });
  });
  creq.on('error',   (e) => { dbg('cancel request error:', e.message); exitForSignal(signal); });
  creq.on('timeout', () => { dbg('cancel request timeout'); creq.destroy(); exitForSignal(signal); });
  creq.end();
}

process.on('SIGINT',  () => { dbg('SIGINT received'); cancel('SIGINT'); });
process.on('SIGTERM', () => { dbg('SIGTERM received'); cancel('SIGTERM'); });

function readStdin() {
  return new Promise((resolve, reject) => {
    if (process.stdin.isTTY) { resolve(null); return; }
    const chunks = [];
    let hasData = false;
    let done = false;
    const finish = () => {
      if (done) return;
      done = true;
      resolve(chunks.length ? Buffer.concat(chunks) : null);
    };
    process.stdin.on('data', c => { hasData = true; chunks.push(c); });
    process.stdin.on('end', finish);
    process.stdin.on('close', finish);
    process.stdin.on('error', () => finish());
    process.stdin.resume();
    // If stdin is an open pipe with no data (e.g. spawned via execFile),
    // resolve on the next tick rather than hanging forever.
    setTimeout(() => { if (!hasData) finish(); }, 0);
  });
}

async function main() {
  let stdinBuf = null;
  try { stdinBuf = await readStdin(); }
  catch { /* fall through, send null stdin */ }
  dbg('stdin bytes=', stdinBuf ? stdinBuf.length : 0);

  const body = JSON.stringify({
    cmd,
    args,
    stdin: stdinBuf ? stdinBuf.toString('base64') : null,
  });

  const port = getPort();
  dbg('POST http://' + HOST + ':' + port + '/exec cmd=', cmd, 'args=', args);
  mainReq = http.request({
    method: 'POST',
    host: HOST,
    port: port,
    path: '/exec',
    headers: {
      'Content-Type': 'application/json',
      'Content-Length': Buffer.byteLength(body),
    },
    timeout: REQUEST_TIMEOUT_MS,
  }, (res) => {
    jobId = res.headers['x-job-id'] || null;
    dbg('response headers received status=', res.statusCode, 'jobId=', jobId);
    let buf = '';
    res.setEncoding('utf8');
    res.on('data', c => buf += c);
    res.on('end', () => {
      dbg('response body complete bytes=', buf.length, 'cancelling=', cancelling);
      if (cancelling) return; // cancel handler will call process.exit
      try {
        const r = JSON.parse(buf);
        if (r.stdout) process.stdout.write(r.stdout);
        if (r.stderr) process.stderr.write(r.stderr);
        process.exit(typeof r.exitCode === 'number' ? r.exitCode : 1);
      } catch {
        process.stderr.write(`${cmd}: hostbridge: malformed response\n`);
        process.exit(1);
      }
    });
  });

  mainReq.on('error', err => {
    dbg('main request error:', err.message, 'cancelling=', cancelling);
    if (cancelling) return;
    process.stderr.write(`${cmd}: hostbridge: ${err.message}\n`);
    process.exit(1);
  });
  mainReq.on('timeout', () => {
    mainReq.destroy();
    if (cancelling) return;
    process.stderr.write(`${cmd}: hostbridge: timeout\n`);
    process.exit(1);
  });

  mainReq.write(body);
  mainReq.end();
}

main();
