#!/usr/bin/env node
const fs = require("fs");
const os = require("os");
const path = require("path");
const cp = require("child_process");

const USAGE = `Usage: ./contagent.js [options] [--] [command ...]

Options:
  -c, --config CONFIG         Runtime config path (default: .contagent.yaml)
  --<feature>                 Enable volume mounts for an image feature
  --no-<feature>              Disable volume mounts for an image feature
  --show-options              Show config-defined --<feature>/--no-<feature> toggles and exit
  --extra-groups <gid[,gid]>  Append supplementary group GIDs for this run
  -h, --help                  Show this help
`;

const EMBEDDED_CONFIG = "/usr/local/share/contagent/contagent.yaml";
const die = (msg) => { console.error(`ERROR: ${msg}`); process.exit(1); };
const warn = (msg) => console.error(`WARN: ${msg}`);
const id = (flag) => cp.execFileSync("id", [flag], { encoding: "utf8" }).trim();
const hasCmd = (cmd) => cp.spawnSync("sh", ["-lc", `command -v ${cmd}`], { stdio: "ignore" }).status === 0;
const parseJson = (text, msg) => { try { return JSON.parse(text); } catch { die(msg); } };
const isSocket = (p) => { try { return fs.statSync(p).isSocket(); } catch { return false; } };
const resolvePath = (raw, home, base) => raw === "~" || raw.startsWith("~/")
  ? home + raw.slice(1)
  : (path.isAbsolute(raw) ? raw : path.join(base, raw));

function boolValue(value, fallback, feature, field) {
  if (value == null) return fallback;
  if (typeof value !== "boolean") die(`invalid volume entry in feature ${feature}: ${field} must be boolean`);
  return value;
}

function embeddedConfig(image) {
  const proc = cp.spawnSync("docker", ["run", "--rm", "--entrypoint", "cat", image, EMBEDDED_CONFIG], { encoding: "utf8" });
  if (proc.status !== 0) die(`failed to extract default contagent config from ${image}`);
  return proc.stdout;
}

function yqJson(file, image) {
  const attempts = hasCmd("yq")
    ? [["yq", ["-o=json", ".", file], null], ["yq", [".", file], null]]
    : [
        ["docker", ["run", "--rm", "-i", "--entrypoint", "yq", image, "-o=json", ".", "-"], fs.readFileSync(file)],
        ["docker", ["run", "--rm", "-i", "--entrypoint", "yq", image, ".", "-"], fs.readFileSync(file)],
      ];
  if (!hasCmd("yq")) warn(`yq not found; falling back to yq from ${image}`);
  for (const [cmd, args, input] of attempts) {
    const proc = cp.spawnSync(cmd, args, { input, encoding: "utf8" });
    if (proc.status === 0) {
      try { return JSON.parse(proc.stdout); } catch { /* try next form */ }
    }
  }
  die(`failed to parse ${file}`);
}

function configPath(argv) {
  let config = ".contagent.yaml";
  for (let i = 0; i < argv.length; i++) {
    const arg = argv[i];
    if (arg === "--") break;
    if (arg === "-c" || arg === "--config") {
      if (i + 1 >= argv.length) die(`${arg} requires a value`);
      config = argv[++i];
    } else if (arg.startsWith("--config=")) {
      config = arg.split("=", 2)[1];
    } else if (!arg.startsWith("-")) {
      break;
    }
  }
  return config;
}

function loadConfig(file, image) {
  if (!fs.existsSync(file) || fs.statSync(file).size === 0) {
    fs.mkdirSync(path.dirname(file), { recursive: true });
    const data = embeddedConfig(image);
    if (!data) die("embedded default contagent config is empty");
    fs.writeFileSync(file, data);
  }
  const config = yqJson(file, image);
  const tmp = path.join(os.tmpdir(), `contagent-embedded-${process.pid}.yaml`);
  fs.writeFileSync(tmp, embeddedConfig(image));
  const embedded = yqJson(tmp, image);
  fs.rmSync(tmp, { force: true });
  const configId = config["image-hash"] || "";
  const embeddedId = embedded["image-hash"] || "";
  if (embeddedId && configId !== embeddedId) warn(`${file} was not generated from ${image}`);
  return { config, base: path.resolve(path.dirname(file)) };
}

function buildModel(config) {
  const allFeatures = new Set();
  const options = new Map();
  const rows = [];
  const env = [];
  for (const feature of Array.isArray(config?.features) ? config.features : []) {
    const name = String(feature?.name || "");
    const volumes = Array.isArray(feature?.volumes) ? feature.volumes : [];
    if (!name) continue;
    for (const [key, value] of Object.entries(feature.environment || {})) env.push([String(key), String(value)]);
    if (!volumes.length) continue;
    allFeatures.add(name);

    const states = [];
    for (const volume of volumes) {
      const target = volume.path;
      if (typeof target !== "string" || !target) die(`invalid volume entry in feature ${name}: path is required`);
      const source = volume.source == null ? target : volume.source;
      if (typeof source !== "string" || !source) die(`invalid volume entry in feature ${name}: source is required`);
      const enabled = boolValue(volume.enabled, true, name, "enabled");
      states.push(enabled);
      rows.push({
        feature: name,
        enabled,
        source,
        target,
        file: boolValue(volume.file, false, name, "file"),
        readOnly: boolValue(volume.read_only, false, name, "read_only"),
        create: source === "~" || source.startsWith("~/") || !path.isAbsolute(source),
      });
    }
    options.set(name, states.some(Boolean) && !states.every(Boolean) ? "mixed" : (states.every(Boolean) ? "on" : "off"));
  }
  return { allFeatures, options, rows, env };
}

function printOptions(image, model) {
  if (!model.options.size) return console.log(`Config for ${image} exposes no volume toggles.`);
  console.log(`Config volume toggles for ${image}:`);
  for (const name of [...model.options.keys()].sort()) {
    console.log(`  --${name} / --no-${name} (default: ${model.options.get(name)}; features: ${name})`);
  }
}

function setOverride(arg, name, state, model, overrides) {
  if (model.options.has(name)) overrides.set(name, state);
  else if (model.allFeatures.has(name)) {
    die(`option ${state ? `--${name}` : `--no-${name}`} is known but not included in config (feature(s): ${name})`);
  } else {
    die(`unknown option: ${arg}`);
  }
}

function parseArgs(argv, model) {
  const overrides = new Map();
  let extraGroups = process.env.CONTAGENT_EXTRA_GROUP_GIDS || "";
  let show = false;
  let help = false;
  let command = [];
  for (let i = 0; i < argv.length; i++) {
    const arg = argv[i];
    if (arg === "--") { command = argv.slice(i + 1); break; }
    if (arg === "-h" || arg === "--help") { help = true; break; }
    if (arg === "--show-options") { show = true; continue; }
    if (arg === "-c" || arg === "--config") {
      if (i + 1 >= argv.length) die(`${arg} requires a value`);
      i += 1;
      continue;
    }
    if (arg.startsWith("--config=")) continue;
    if (arg === "--extra-groups" || arg.startsWith("--extra-groups=")) {
      if (arg === "--extra-groups" && i + 1 >= argv.length) die("--extra-groups requires a value");
      const value = arg === "--extra-groups" ? argv[++i] : arg.split("=", 2)[1];
      extraGroups = extraGroups ? `${extraGroups},${value}` : value;
      continue;
    }
    if (arg.startsWith("--no-")) {
      if (arg.includes("=")) die(`unknown option: ${arg}`);
      setOverride(arg, arg.slice(5), false, model, overrides);
      continue;
    }
    if (arg.startsWith("--")) {
      if (arg.includes("=")) die(`unknown option: ${arg}`);
      setOverride(arg, arg.slice(2), true, model, overrides);
      continue;
    }
    if (arg.startsWith("-")) die(`unknown option: ${arg}`);
    command = argv.slice(i);
    break;
  }
  return { command, show, help, extraGroups, overrides };
}

function mountPlan(rows, overrides, home, base) {
  const byTarget = new Map();
  for (const row of rows) {
    const enabled = overrides.has(row.feature) ? overrides.get(row.feature) : row.enabled;
    if (!enabled) continue;
    const source = resolvePath(row.source, home, base);
    const target = resolvePath(row.target, home, base);
    const candidates = byTarget.get(target) || [];
    const candidate = { source, file: row.file, readOnly: row.readOnly, create: row.create };
    if (!candidates.some((c) => JSON.stringify(c) === JSON.stringify(candidate))) candidates.push(candidate);
    byTarget.set(target, candidates);
  }

  const specs = [];
  const gids = [];
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
    try {
      const st = fs.statSync(chosen.source);
      const gid = String(st.gid);
      if (st.isSocket() && !gids.includes(gid)) gids.push(gid);
    } catch { /* ignore */ }
    specs.push(`${chosen.source}:${target}${chosen.readOnly ? ":ro" : ""}`);
  }
  return { specs, gids };
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
  const { config, base } = loadConfig(configPath(process.argv.slice(2)), image);
  const model = buildModel(config);
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
  const mounts = mountPlan(model.rows, parsed.overrides, home, base);
  for (const spec of mounts.specs) args.push("--volume", spec);
  const sshSock = process.env.SSH_AUTH_SOCK || "";
  if (sshSock && isSocket(sshSock)) args.push("--volume", `${sshSock}:${sshSock}`, "--env", `SSH_AUTH_SOCK=${sshSock}`);
  else warn("SSH agent not available; SSH auth forwarding disabled");
  const groupCsv = [parsed.extraGroups, ...mounts.gids].filter(Boolean).join(",");
  const groups = extraGroupSpecs(groupCsv);
  if (groups) args.push("--env", `CONTAGENT_EXTRA_GROUP_SPECS=${groups}`);

  const run = cp.spawnSync("docker", [...args, image, ...parsed.command], { stdio: "inherit" });
  if (run.error) die(run.error.message);
  process.exit(typeof run.status === "number" ? run.status : 1);
}

main();
