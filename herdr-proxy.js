#!/usr/bin/env node
"use strict";
const net = require("net");
const fs = require("fs");
const os = require("os");
const path = require("path");

const debug = process.env.HERDR_PROXY_DEBUG === "1";
const log = debug ? (...a) => console.error("[herdr-proxy]", ...a) : () => {};

const BLOCKED = ["workspace.", "worktree.", "plugin."];

function isBlocked(method) {
  return typeof method === "string" && BLOCKED.some((p) => method.startsWith(p));
}

function errorResponse(id, message) {
  return JSON.stringify({ id, error: { code: "bad_request", message } }) + "\n";
}

function start({ upstreamSocket }) {
  const proxyPath = path.join(os.tmpdir(), `herdr-proxy-${process.pid}.sock`);
  try { fs.unlinkSync(proxyPath); } catch {}

  let containerId = null;
  const setContainerId = (id) => { containerId = id; };

  const server = net.createServer((client) => {
    log("client connected");
    const upstream = net.createConnection(upstreamSocket);

    let clientBuf = "";
    let upstreamBuf = "";
    const pendingSplits = new Set();

    client.on("data", (chunk) => {
      clientBuf += chunk.toString();
      let nl;
      while ((nl = clientBuf.indexOf("\n")) !== -1) {
        const line = clientBuf.slice(0, nl + 1);
        clientBuf = clientBuf.slice(nl + 1);
        let msg;
        try { msg = JSON.parse(line); } catch {}
        if (msg && isBlocked(msg.method)) {
          log("blocked method", msg.method);
          client.write(errorResponse(msg.id, `method not available: ${msg.method}`));
        } else {
          if (msg?.method === "pane.split" || msg?.method === "tab.create") pendingSplits.add(msg.id);
          upstream.write(line);
        }
      }
    });

    upstream.on("data", (chunk) => {
      upstreamBuf += chunk.toString();
      let nl;
      while ((nl = upstreamBuf.indexOf("\n")) !== -1) {
        const line = upstreamBuf.slice(0, nl + 1);
        upstreamBuf = upstreamBuf.slice(nl + 1);
        let msg;
        try { msg = JSON.parse(line); } catch {}
        client.write(line);
        const newPaneId = msg?.result?.pane?.pane_id ?? msg?.result?.root_pane?.pane_id;
        if (msg && pendingSplits.has(msg.id) && newPaneId) {
          pendingSplits.delete(msg.id);
          log("split succeeded, new pane", newPaneId, "sending docker exec");
          const text = `exec docker exec -it ${containerId} /entrypoint.sh || exit\n`;
          const conn = net.createConnection(upstreamSocket);
          conn.write(JSON.stringify({ id: "_proxy_split", method: "pane.send_text", params: { pane_id: newPaneId, text } }) + "\n");
          conn.on("error", (e) => log("send_text error", e.message));
        }
      }
    });

    client.on("error", (e) => { log("client error", e.message); upstream.destroy(); });
    upstream.on("error", (e) => { log("upstream error", e.message); client.destroy(); });
    client.on("close", () => upstream.destroy());
    upstream.on("close", () => client.destroy());
  });

  return new Promise((resolve, reject) => {
    server.on("error", reject);
    server.listen(proxyPath, () => {
      log(`listening at ${proxyPath}, proxying to ${upstreamSocket}`);
      resolve({
        socketPath: proxyPath,
        setContainerId,
        shutdown: () => new Promise((res) => {
          server.close(() => {
            try { fs.unlinkSync(proxyPath); } catch {}
            res();
          });
        }),
      });
    });
  });
}

module.exports = { start };
