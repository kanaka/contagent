#!/usr/bin/env node
const fs = require("fs");
const path = require("path");
const cp = require("child_process");

const USAGE = `Usage: ./contagent.js [options] [--] [command ...]

Options:
  --<feature>                 Enable volume mounts for an image feature
  --no-<feature>              Disable volume mounts for an image feature
  --show-options              Show image-defined --<feature>/--no-<feature> toggles and exit
  --extra-groups <gid[,gid]>  Append supplementary group GIDs for this run
  -h, --help                  Show this help
`;

const die = (msg) => { console.error(`ERROR: ${msg}`); process.exit(1); };
const warn = (msg) => console.error(`WARN: ${msg}`);
const id = (flag) => cp.execFileSync("id", [flag], { encoding: "utf8" }).trim();
const parseJson = (text, msg) => { try { return JSON.parse(text); } catch { die(msg); } };
const isSocket = (p) => { try { return fs.statSync(p).isSocket(); } catch { return false; } };
const resolvePath = (raw, home, cwd) => raw === "~" || raw.startsWith("~/")
  ? home + raw.slice(1)
  : (path.isAbsolute(raw) ? raw : path.join(cwd, raw));

function loadImageMeta(image) {
  const proc = cp.spawnSync("docker", ["image", "inspect", image], { encoding: "utf8" });
  if (proc.status !== 0) die(`image ${image} is not available locally; build it first with ./build-contagent.py`);
  const inspect = parseJson(proc.stdout || "", "invalid manifest in image labels");
  const labels = (((inspect[0] || {}).Config || {}).Labels) || {};

  const schema = labels["io.contagent.schema.version"] || "";
  if (!schema) die("image is missing io.contagent.schema.version label; rebuild with ./build-contagent.py");
  if (!Number.isInteger(Number(schema))) die("image label io.contagent.schema.version is invalid");
  if (Number(schema) !== 2) die(`unsupported schema version: ${schema}`);

  const manifestRaw = labels["io.contagent.manifest.json"] || "";
  if (!manifestRaw) die("image is missing io.contagent.manifest.json label; rebuild with ./build-contagent.py");
  const selectedRaw = parseJson(
    labels["io.contagent.manifest.features"] || "[]",
    "image label io.contagent.manifest.features is invalid",
  );
  return {
    manifest: parseJson(manifestRaw, "invalid manifest in image labels"),
    selected: Array.isArray(selectedRaw) ? selectedRaw.map(String) : [],
  };
}

function buildModel(manifest, selectedFeatures) {
  const selected = new Set(selectedFeatures);
  const allFeatures = new Set();
  const options = new Map();
  const rows = [];
  const env = [];
  for (const feature of Array.isArray(manifest?.features) ? manifest.features : []) {
    const name = String(feature?.name || "");
    const volumes = Array.isArray(feature?.volumes) ? feature.volumes : [];
    if (!name || !volumes.length) continue;
    allFeatures.add(name);
    if (!selected.has(name)) continue;

    options.set(name, volumes[0].default ?? true);
    for (const [key, value] of Object.entries(feature.env || {})) env.push([String(key), String(value)]);
    for (const volume of volumes) {
      const target = volume.path;
      if (typeof target !== "string" || !target) die(`invalid volume entry in feature ${name}: path is required`);
      const source = volume.source == null ? target : volume.source;
      if (typeof source !== "string" || !source) die(`invalid volume entry in feature ${name}: source is required`);
      rows.push({
        feature: name,
        source,
        target,
        file: volume.file ?? false,
        readOnly: volume.read_only ?? false,
        create: source === "~" || source.startsWith("~/") || !path.isAbsolute(source),
      });
    }
  }
  return { allFeatures, options, rows, env };
}

function printOptions(image, model) {
  if (!model.options.size) return console.log(`Image ${image} exposes no volume toggles.`);
  console.log(`Image volume toggles for ${image}:`);
  for (const name of [...model.options.keys()].sort()) {
    console.log(`  --${name} / --no-${name} (default: ${model.options.get(name) ? "on" : "off"}; features: ${name})`);
  }
}

function applyOption(arg, name, state, model, enabled) {
  if (model.options.has(name)) {
    enabled.set(name, state);
  } else if (model.allFeatures.has(name)) {
    die(`option ${state ? `--${name}` : `--no-${name}`} is known but not included in image (feature(s): ${name})`);
  } else {
    die(`unknown option: ${arg}`);
  }
}

function parseArgs(argv, model) {
  const enabled = new Map(model.options);
  let extraGroups = process.env.CONTAGENT_EXTRA_GROUP_GIDS || "";
  let show = false;
  let help = false;
  let command = [];
  for (let i = 0; i < argv.length; i++) {
    const arg = argv[i];
    if (arg === "--") { command = argv.slice(i + 1); break; }
    if (arg === "-h" || arg === "--help") { help = true; break; }
    if (arg === "--show-options") { show = true; continue; }
    if (arg === "--extra-groups" || arg.startsWith("--extra-groups=")) {
      if (arg === "--extra-groups" && i + 1 >= argv.length) die("--extra-groups requires a value");
      const value = arg === "--extra-groups" ? argv[++i] : arg.split("=", 2)[1];
      extraGroups = extraGroups ? `${extraGroups},${value}` : value;
      continue;
    }
    if (arg.startsWith("--no-")) {
      if (arg.includes("=")) die(`unknown option: ${arg}`);
      applyOption(arg, arg.slice(5), false, model, enabled);
      continue;
    }
    if (arg.startsWith("--")) {
      if (arg.includes("=")) die(`unknown option: ${arg}`);
      applyOption(arg, arg.slice(2), true, model, enabled);
      continue;
    }
    if (arg.startsWith("-")) die(`unknown option: ${arg}`);
    command = argv.slice(i);
    break;
  }
  return { command, show, help, extraGroups, enabled };
}

function mountSpecs(rows, enabled, home, cwd) {
  const byTarget = new Map();
  for (const row of rows) {
    if (!enabled.get(row.feature)) continue;
    const source = resolvePath(row.source, home, cwd);
    const target = resolvePath(row.target, home, cwd);
    const candidates = byTarget.get(target) || [];
    const candidate = { source, file: row.file, readOnly: row.readOnly, create: row.create };
    if (!candidates.some((c) => JSON.stringify(c) === JSON.stringify(candidate))) candidates.push(candidate);
    byTarget.set(target, candidates);
  }

  const specs = [];
  for (const [target, candidates] of byTarget.entries()) {
    let chosen = candidates.find((c) => fs.existsSync(c.source));
    if (!chosen) {
      chosen = candidates.find((c) => c.create);
      if (!chosen) die(`no existing source found for target ${target} among ${candidates.length} candidates`);
      if (chosen.file) {
        fs.mkdirSync(path.dirname(chosen.source), { recursive: true });
        fs.closeSync(fs.openSync(chosen.source, "a"));
      } else {
        fs.mkdirSync(chosen.source, { recursive: true });
      }
    }
    specs.push(`${chosen.source}:${target}${chosen.readOnly ? ":ro" : ""}`);
  }
  return specs;
}

function extraGroupSpecs(csv) {
  const gids = [];
  for (const token of csv ? csv.split(",") : []) {
    const gid = token.trim();
    if (!gid) continue;
    if (!/^\d+$/.test(gid)) warn(`ignoring non-numeric extra group gid: ${gid}`);
    else if (!gids.includes(gid)) gids.push(gid);
  }
  return gids.map((gid) => `g${gid}:${gid}`).join(",");
}

function main() {
  if (cp.spawnSync("docker", ["--version"], { stdio: "ignore" }).error) die("docker is required");
  const image = process.env.CONTAGENT_IMAGE || "contagent:latest";
  const home = process.env.HOME || die("HOME must be set");
  const cwd = process.cwd();
  const { manifest, selected } = loadImageMeta(image);
  const model = buildModel(manifest, selected);
  const parsed = parseArgs(process.argv.slice(2), model);
  if (parsed.help || parsed.show) {
    if (parsed.help) process.stdout.write(`${USAGE}\n`);
    printOptions(image, model);
    return;
  }

  const args = ["run", "--rm", "--workdir", cwd, "--volume", `${cwd}:${cwd}`];
  if (process.stdin.isTTY && process.stdout.isTTY) args.push("--interactive", "--tty");
  const env = [
    ["CONTAGENT_USERNAME", process.env.USER || id("-un")],
    ["CONTAGENT_GROUPNAME", id("-gn")],
    ["CONTAGENT_UID", id("-u")],
    ["CONTAGENT_GID", id("-g")],
    ["CONTAGENT_HOME", home],
    ...(process.env.TERM ? [["TERM", process.env.TERM]] : []),
    ...(process.env.COLORTERM ? [["COLORTERM", process.env.COLORTERM]] : []),
    ...model.env,
  ];
  for (const [key, value] of env) if (key) args.push("--env", `${key}=${value}`);
  for (const spec of mountSpecs(model.rows, parsed.enabled, home, cwd)) args.push("--volume", spec);
  const sshSock = process.env.SSH_AUTH_SOCK || "";
  if (sshSock && isSocket(sshSock)) args.push("--volume", `${sshSock}:${sshSock}`, "--env", `SSH_AUTH_SOCK=${sshSock}`);
  else warn("SSH agent not available; SSH auth forwarding disabled");
  const groups = extraGroupSpecs(parsed.extraGroups);
  if (groups) args.push("--env", `CONTAGENT_EXTRA_GROUP_SPECS=${groups}`);

  const run = cp.spawnSync("docker", [...args, image, ...parsed.command], { stdio: "inherit" });
  if (run.error) die(run.error.message);
  process.exit(typeof run.status === "number" ? run.status : 1);
}

main();
