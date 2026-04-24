#!/usr/bin/env node
const fs = require("fs");
const path = require("path");
const cp = require("child_process");
const USAGE = `Usage: ./contagent.js [options] [--] [command ...]

Options:
  --<name>                    Enable a volume group from image metadata
  --<name>=<dir>              Enable and replace '~' in that group's source paths with <dir>
  --no-<name>                 Disable a volume group from image metadata
  --show-options              Show image-defined --<name>/--no-<name> toggles and exit
  --extra-groups <gid[,gid]>  Append supplementary group GIDs for this run
  -h, --help                  Show this help
`;
const MANIFEST_LABEL = "io.contagent.manifest.json";
const FEATURES_LABEL = "io.contagent.manifest.features";
const SCHEMA_LABEL = "io.contagent.schema.version";
const SUPPORTED_SCHEMA = 2;
const die = (msg) => {
  console.error(`ERROR: ${msg}`);
  process.exit(1);
};
const warn = (msg) => console.error(`WARN: ${msg}`);
const idValue = (flag) => cp.execFileSync("id", [flag], { encoding: "utf8" }).trim();
const appendCsv = (csv, value) => (csv ? `${csv},${value}` : value);
const resolvePath = (v, home, cwd) => (
  v === "~" || v.startsWith("~/") ? home + v.slice(1) : (path.isAbsolute(v) ? v : path.join(cwd, v))
);
const parseJson = (text, msg) => { try { return JSON.parse(text); } catch { die(msg); } };
const isSocket = (sock) => { try { return fs.statSync(sock).isSocket(); } catch { return false; } };

function loadImageMeta(image) {
  const inspectProc = cp.spawnSync("docker", ["image", "inspect", image], { encoding: "utf8" });
  if (inspectProc.status !== 0) die(`image ${image} is not available locally; build it first with ./build-contagent.py`);
  const inspect = parseJson(inspectProc.stdout || "", "invalid manifest in image labels");
  const labels = (((inspect[0] || {}).Config || {}).Labels) || {};

  const schemaRaw = labels[SCHEMA_LABEL] || "";
  if (!schemaRaw) die("image is missing io.contagent.schema.version label; rebuild with ./build-contagent.py");
  const schemaVersion = Number(schemaRaw);
  if (!Number.isInteger(schemaVersion)) die("image label io.contagent.schema.version is invalid");
  if (schemaVersion !== SUPPORTED_SCHEMA) die(`unsupported schema version: ${schemaVersion}`);

  const manifestRaw = labels[MANIFEST_LABEL] || "";
  if (!manifestRaw) die("image is missing io.contagent.manifest.json label; rebuild with ./build-contagent.py");
  const manifest = parseJson(manifestRaw, "invalid manifest in image labels");
  const selectedRaw = parseJson(labels[FEATURES_LABEL] || "[]", "image label io.contagent.manifest.features is invalid");
  const selected = Array.isArray(selectedRaw) ? selectedRaw.map(String) : [];
  return { manifest, selected };
}

function volumeRows(featureName, volume) {
  const argName = String(volume.arg_name || "");
  if (!argName) die(`invalid volume entry in feature ${featureName}: arg_name is required`);

  const mountPath = volume.path;
  if (typeof mountPath !== "string" || !mountPath) {
    die(`invalid volume entry in feature ${featureName}, arg ${argName}: path is required`);
  }

  const hasSource = volume.source != null;
  const hasSources = volume.sources != null;
  if (hasSource && hasSources) {
    die(`invalid volume entry in feature ${featureName}, arg ${argName}: use source or sources, not both`);
  }

  let sources = [];
  let createIfMissing = true;
  if (hasSources) {
    if (!Array.isArray(volume.sources)) {
      die(`invalid volume entry in feature ${featureName}, arg ${argName}: sources is required`);
    }
    sources = volume.sources.map((v) => String(v || ""));
    if (!sources.length || sources.some((v) => !v)) {
      die(`invalid volume entry in feature ${featureName}, arg ${argName}: sources is required`);
    }
    createIfMissing = false;
  } else if (hasSource) {
    const source = String(volume.source || "");
    if (!source) die(`invalid volume entry in feature ${featureName}, arg ${argName}: source is required`);
    sources = [source];
  } else {
    sources = [mountPath];
  }

  return sources.map((source) => ({
    feature: featureName,
    argName,
    source,
    path: mountPath,
    safe: volume.default ?? true,
    file: volume.file ?? false,
    readOnly: volume.read_only ?? false,
    createIfMissing,
  }));
}


function normalizeManifest(manifest, selectedFeatures) {
  const selected = new Set(selectedFeatures);
  const allOptions = new Map();
  const includedOptions = new Map();
  const includedRows = [];
  const envPairs = [];
  const upsert = (store, row) => {
    const current = store.get(row.argName);
    if (!current) return void store.set(row.argName, { safe: row.safe, features: [row.feature] });
    if (!current.features.includes(row.feature)) current.features.push(row.feature);
  };
  for (const feature of Array.isArray(manifest?.features) ? manifest.features : []) {
    const featureName = String(feature?.name || "");
    if (!featureName) continue;
    const includeFeature = selected.has(featureName);
    for (const volume of Array.isArray(feature?.volumes) ? feature.volumes : []) {
      for (const row of volumeRows(featureName, volume)) {
        upsert(allOptions, row);
        if (includeFeature) {
          upsert(includedOptions, row);
          includedRows.push(row);
        }
      }
    }
    if (includeFeature) {
      for (const [key, value] of Object.entries(feature?.env || {})) envPairs.push([String(key), String(value)]);
    }
  }
  return { allOptions, includedOptions, optionOrder: [...includedOptions.keys()].sort(), includedRows, envPairs };
}

function printOptions(image, model) {
  if (!model.optionOrder.length) {
    console.log(`Image ${image} exposes no volume toggles.`);
    return;
  }
  console.log(`Image volume toggles for ${image}:`);
  for (const name of model.optionOrder) {
    const opt = model.includedOptions.get(name);
    const state = opt.safe ? "on" : "off";
    console.log(`  --${name} / --no-${name} (default: ${state}; features: ${opt.features.join(",")})`);
  }
}

function parseCli(argv, model, initialExtraGroupsCsv) {
  const enabledByArg = new Map(model.optionOrder.map((name) => [name, model.includedOptions.get(name).safe]));
  const sourceRootByArg = new Map();
  let showOptions = false;
  let extraGroupsCsv = initialExtraGroupsCsv;
  let command = [];
  let helpRequested = false;

  const applyOption = (arg, name, nextState, sourceRoot = null) => {
    if (model.includedOptions.has(name)) {
      enabledByArg.set(name, nextState);
      if (!nextState || sourceRoot == null) sourceRootByArg.delete(name);
      else sourceRootByArg.set(name, sourceRoot);
      return;
    }
    if (model.allOptions.has(name)) {
      const features = model.allOptions.get(name).features.join(",");
      const flag = nextState ? `--${name}` : `--no-${name}`;
      die(`option ${flag} is known but not included in image (feature(s): ${features})`);
    }
    die(`unknown option: ${arg}`);
  };

  let i = 0;
  while (i < argv.length) {
    const arg = argv[i];
    if (arg === "--") { command = argv.slice(i + 1); break; }
    if (arg === "-h" || arg === "--help") { helpRequested = true; break; }
    if (arg === "--show-options") { showOptions = true; i += 1; continue; }

    if (arg === "--extra-groups" || arg.startsWith("--extra-groups=")) {
      if (arg === "--extra-groups" && i + 1 >= argv.length) die("--extra-groups requires a value");
      const value = arg === "--extra-groups" ? argv[i + 1] : arg.split("=", 2)[1];
      extraGroupsCsv = appendCsv(extraGroupsCsv, value);
      i += arg === "--extra-groups" ? 2 : 1;
      continue;
    }

    if (arg.startsWith("--no-")) {
      if (arg.includes("=")) die(`unknown option: ${arg}`);
      applyOption(arg, arg.slice(5), false);
      i += 1;
      continue;
    }

    if (arg.startsWith("--")) {
      const body = arg.slice(2);
      const eq = body.indexOf("=");
      if (eq < 0) applyOption(arg, body, true);
      else {
        const name = body.slice(0, eq);
        const sourceRoot = body.slice(eq + 1);
        if (!sourceRoot) die(`option --${name} requires a value`);
        applyOption(arg, name, true, sourceRoot);
      }
      i += 1;
      continue;
    }

    if (arg.startsWith("-")) die(`unknown option: ${arg}`);
    command = argv.slice(i);
    break;
  }

  return { command, showOptions, helpRequested, extraGroupsCsv, enabledByArg, sourceRootByArg };
}

function planRuntime(model, parsed, host) {
  const dockerFlags = ["--rm", "--workdir", host.cwd, "--volume", `${host.cwd}:${host.cwd}`];
  if (host.interactiveTty) dockerFlags.push("--interactive", "--tty");
  const envPairs = [
    ["CONTAGENT_USERNAME", host.user],
    ["CONTAGENT_GROUPNAME", host.group],
    ["CONTAGENT_UID", host.uid],
    ["CONTAGENT_GID", host.gid],
    ["CONTAGENT_HOME", host.home],
    ...(host.term ? [["TERM", host.term]] : []),
    ...(host.colorTerm ? [["COLORTERM", host.colorTerm]] : []),
    ...model.envPairs,
  ];
  const byTarget = new Map();
  for (const row of model.includedRows) {
    if (!parsed.enabledByArg.get(row.argName)) continue;
    const sourceRoot = parsed.sourceRootByArg.get(row.argName);
    const sourceValue = sourceRoot == null ? row.source : row.source.split("~").join(sourceRoot);
    const source = resolvePath(sourceValue, host.home, host.cwd);
    const mountPath = resolvePath(row.path, host.home, host.cwd);
    const list = byTarget.get(mountPath) || [];
    list.push({ source, file: row.file, readOnly: row.readOnly, createIfMissing: row.createIfMissing });
    byTarget.set(mountPath, list);
  }
  const seenGids = new Set();
  const extraGroupSpecs = [];
  for (const token of parsed.extraGroupsCsv ? parsed.extraGroupsCsv.split(",") : []) {
    const gid = token.trim();
    if (!gid) continue;
    if (!/^\d+$/.test(gid)) {
      warn(`ignoring non-numeric extra group gid: ${gid}`);
      continue;
    }
    if (!seenGids.has(gid)) {
      seenGids.add(gid);
      extraGroupSpecs.push(`g${gid}:${gid}`);
    }
  }
  return {
    dockerFlags,
    envPairs,
    mountRequests: [...byTarget.entries()].map(([target, candidates]) => ({ target, candidates })),
    extraGroupSpecs,
    command: parsed.command,
  };
}

function resolveChosenMounts(mountRequests, sshSock) {
  const mountSpecs = [];
  for (const { target, candidates } of mountRequests) {
    let chosen = candidates.find((candidate) => fs.existsSync(candidate.source));
    if (!chosen) {
      chosen = candidates.find((candidate) => candidate.createIfMissing);
      if (!chosen) die(`no existing source found for target ${target} among ${candidates.length} candidates`);
      if (chosen.file) {
        fs.mkdirSync(path.dirname(chosen.source), { recursive: true });
        fs.closeSync(fs.openSync(chosen.source, "a"));
      } else {
        fs.mkdirSync(chosen.source, { recursive: true });
      }
    }
    mountSpecs.push(`${chosen.source}:${target}${chosen.readOnly ? ":ro" : ""}`);
  }
  if (sshSock && isSocket(sshSock)) return { mountSpecs, sshForward: sshSock };
  warn("SSH agent not available; SSH auth forwarding disabled");
  return { mountSpecs, sshForward: "" };
}

function assembleDockerArgs(plan, image) {
  const args = ["run", ...plan.dockerFlags];
  for (const [key, value] of plan.envPairs) {
    if (key) args.push("--env", `${key}=${value}`);
  }
  for (const spec of plan.mountSpecs) args.push("--volume", spec);
  if (plan.sshForward) {
    args.push("--volume", `${plan.sshForward}:${plan.sshForward}`, "--env", `SSH_AUTH_SOCK=${plan.sshForward}`);
  }
  if (plan.extraGroupSpecs.length) {
    args.push("--env", `CONTAGENT_EXTRA_GROUP_SPECS=${plan.extraGroupSpecs.join(",")}`);
  }
  args.push(image, ...plan.command);
  return args;
}

function main() {
  if (cp.spawnSync("docker", ["--version"], { stdio: "ignore" }).error) die("docker is required");
  const image = process.env.CONTAGENT_IMAGE || "contagent:latest";
  const home = process.env.HOME;
  if (!home) die("HOME must be set");
  const host = {
    home,
    cwd: process.cwd(),
    user: process.env.USER || idValue("-un"),
    group: idValue("-gn"),
    uid: idValue("-u"),
    gid: idValue("-g"),
    term: process.env.TERM || "",
    colorTerm: process.env.COLORTERM || "",
    sshSock: process.env.SSH_AUTH_SOCK || "",
    interactiveTty: Boolean(process.stdin.isTTY && process.stdout.isTTY),
  };
  const { manifest, selected } = loadImageMeta(image);
  const model = normalizeManifest(manifest, selected);
  const parsed = parseCli(process.argv.slice(2), model, process.env.CONTAGENT_EXTRA_GROUP_GIDS || "");
  if (parsed.helpRequested || parsed.showOptions) {
    if (parsed.helpRequested) {
      process.stdout.write(USAGE);
      process.stdout.write("\n");
    }
    printOptions(image, model);
    return;
  }
  const runtimePlan = planRuntime(model, parsed, host);
  const { mountSpecs, sshForward } = resolveChosenMounts(runtimePlan.mountRequests, host.sshSock);
  const dockerArgs = assembleDockerArgs({ ...runtimePlan, mountSpecs, sshForward }, image);
  const run = cp.spawnSync("docker", dockerArgs, { stdio: "inherit" });
  if (run.error) die(run.error.message);
  process.exit(typeof run.status === "number" ? run.status : 1);
}

main();
