#!/usr/bin/env python3

import json
import os
import re
import shutil
import stat
import subprocess
import sys
from pathlib import Path

USAGE = """Usage: ./contagent.py [options] [--] [command ...]

Options:
  --<feature>                 Enable volume mounts for an image feature
  --no-<feature>              Disable volume mounts for an image feature
  --show-options              Show image-defined --<feature>/--no-<feature> toggles and exit
  --extra-groups <gid[,gid]>  Append supplementary group GIDs for this run
  -h, --help                  Show this help
"""

MANIFEST_LABEL = "io.contagent.manifest.json"
FEATURES_LABEL = "io.contagent.manifest.features"
SCHEMA_LABEL = "io.contagent.schema.version"


def die(msg: str) -> None:
    print(f"ERROR: {msg}", file=sys.stderr)
    raise SystemExit(1)


def warn(msg: str) -> None:
    print(f"WARN: {msg}", file=sys.stderr)


def is_socket(path: str) -> bool:
    try:
        return stat.S_ISSOCK(os.stat(path).st_mode)
    except OSError:
        return False


def resolve_path(raw: str, home: str, cwd: str) -> str:
    if raw == "~" or raw.startswith("~/"):
        return home + raw[1:]
    return raw if os.path.isabs(raw) else os.path.join(cwd, raw)


def load_image_meta(image: str) -> tuple[dict, list[str]]:
    p = subprocess.run(["docker", "image", "inspect", image], text=True, capture_output=True)
    if p.returncode != 0:
        die(f"image {image} is not available locally; build it first with ./build-contagent.py")
    try:
        labels = (json.loads(p.stdout)[0].get("Config") or {}).get("Labels") or {}
    except Exception:
        die("invalid manifest in image labels")

    schema = labels.get(SCHEMA_LABEL, "")
    if not schema:
        die("image is missing io.contagent.schema.version label; rebuild with ./build-contagent.py")
    try:
        if int(float(schema)) != 2 or float(schema) != int(float(schema)):
            die(f"unsupported schema version: {schema}")
    except Exception:
        die("image label io.contagent.schema.version is invalid")

    try:
        manifest = json.loads(labels.get(MANIFEST_LABEL, ""))
    except Exception:
        die("invalid manifest in image labels")
    if not manifest:
        die("image is missing io.contagent.manifest.json label; rebuild with ./build-contagent.py")

    try:
        selected = json.loads(labels.get(FEATURES_LABEL, "[]"))
    except Exception:
        die("image label io.contagent.manifest.features is invalid")
    return manifest, [str(x) for x in selected] if isinstance(selected, list) else []


def as_bool(value: object, default: bool) -> bool:
    return default if value is None else bool(value)


def build_model(manifest: dict, selected_features: list[str]) -> dict:
    selected = set(selected_features)
    all_features: set[str] = set()
    options: dict[str, bool] = {}
    rows: list[dict] = []
    env: list[tuple[str, str]] = []

    for feature in manifest.get("features", []) if isinstance(manifest, dict) else []:
        name = str(feature.get("name") or "")
        volumes = feature.get("volumes") or []
        if not name or not volumes:
            continue
        all_features.add(name)

        if name not in selected:
            continue
        options[name] = as_bool(volumes[0].get("default"), True)
        env.extend((str(k), str(v)) for k, v in (feature.get("env") or {}).items())

        for volume in volumes:
            target = volume.get("path")
            if not isinstance(target, str) or not target:
                die(f"invalid volume entry in feature {name}: path is required")
            source = volume.get("source") if volume.get("source") is not None else target
            if not isinstance(source, str) or not source:
                die(f"invalid volume entry in feature {name}: source is required")
            rows.append({
                "feature": name,
                "source": source,
                "target": target,
                "file": as_bool(volume.get("file"), False),
                "read_only": as_bool(volume.get("read_only"), False),
                "create": source == "~" or source.startswith("~/") or not os.path.isabs(source),
            })

    return {"all_features": all_features, "options": options, "rows": rows, "env": env}


def print_options(image: str, model: dict) -> None:
    if not model["options"]:
        print(f"Image {image} exposes no volume toggles.")
        return
    print(f"Image volume toggles for {image}:")
    for name in sorted(model["options"]):
        state = "on" if model["options"][name] else "off"
        print(f"  --{name} / --no-{name} (default: {state}; features: {name})")


def add_option(arg: str, name: str, state: bool, model: dict, enabled: dict) -> None:
    if name in model["options"]:
        enabled[name] = state
    elif name in model["all_features"]:
        flag = f"--{name}" if state else f"--no-{name}"
        die(f"option {flag} is known but not included in image (feature(s): {name})")
    else:
        die(f"unknown option: {arg}")


def parse_args(argv: list[str], model: dict) -> tuple[list[str], bool, bool, str, dict]:
    enabled = dict(model["options"])
    extra_groups = os.environ.get("CONTAGENT_EXTRA_GROUP_GIDS", "")
    show_options = help_requested = False
    i = 0
    while i < len(argv):
        arg = argv[i]
        if arg == "--":
            return argv[i + 1:], show_options, help_requested, extra_groups, enabled
        if arg in ("-h", "--help"):
            return [], show_options, True, extra_groups, enabled
        if arg == "--show-options":
            show_options = True
        elif arg == "--extra-groups":
            if i + 1 >= len(argv):
                die("--extra-groups requires a value")
            extra_groups = f"{extra_groups},{argv[i + 1]}" if extra_groups else argv[i + 1]
            i += 1
        elif arg.startswith("--extra-groups="):
            value = arg.split("=", 1)[1]
            extra_groups = f"{extra_groups},{value}" if extra_groups else value
        elif arg.startswith("--no-"):
            if "=" in arg:
                die(f"unknown option: {arg}")
            add_option(arg, arg[5:], False, model, enabled)
        elif arg.startswith("--"):
            if "=" in arg:
                die(f"unknown option: {arg}")
            add_option(arg, arg[2:], True, model, enabled)
        elif arg.startswith("-"):
            die(f"unknown option: {arg}")
        else:
            return argv[i:], show_options, help_requested, extra_groups, enabled
        i += 1
    return [], show_options, help_requested, extra_groups, enabled


def mount_specs(rows: list[dict], enabled: dict, home: str, cwd: str) -> list[str]:
    by_target: dict[str, list[dict]] = {}
    order: list[str] = []
    for row in rows:
        if not enabled.get(row["feature"]):
            continue
        src = resolve_path(row["source"], home, cwd)
        dst = resolve_path(row["target"], home, cwd)
        candidate = {"source": src, **{k: row[k] for k in ("file", "read_only", "create")}}
        if dst not in by_target:
            by_target[dst] = []
            order.append(dst)
        if candidate not in by_target[dst]:
            by_target[dst].append(candidate)

    specs: list[str] = []
    for dst in order:
        candidates = by_target[dst]
        chosen = next((c for c in candidates if os.path.exists(c["source"])), None)
        if chosen is None:
            chosen = next((c for c in candidates if c["create"]), None)
            if chosen is None:
                die(f"no existing source found for target {dst} among {len(candidates)} candidates")
            if chosen["file"]:
                os.makedirs(os.path.dirname(chosen["source"]) or ".", exist_ok=True)
                Path(chosen["source"]).touch(exist_ok=True)
            else:
                os.makedirs(chosen["source"], exist_ok=True)
        specs.append(f"{chosen['source']}:{dst}" + (":ro" if chosen["read_only"] else ""))
    return specs


def extra_group_specs(csv: str) -> str:
    gids: list[str] = []
    for token in csv.split(",") if csv else []:
        gid = token.strip()
        if not gid:
            continue
        if not re.fullmatch(r"\d+", gid):
            warn(f"ignoring non-numeric extra group gid: {gid}")
        elif gid not in gids:
            gids.append(gid)
    return ",".join(f"g{gid}:{gid}" for gid in gids)


def main() -> None:
    if shutil.which("docker") is None:
        die("docker is required")
    image = os.environ.get("CONTAGENT_IMAGE", "contagent:latest")
    home = os.environ.get("HOME") or die("HOME must be set")
    cwd = os.getcwd()
    manifest, selected = load_image_meta(image)
    model = build_model(manifest, selected)
    command, show, help_requested, groups, enabled = parse_args(sys.argv[1:], model)

    if help_requested or show:
        if help_requested:
            print(USAGE)
        print_options(image, model)
        return

    args = ["run", "--rm", "--workdir", cwd, "--volume", f"{cwd}:{cwd}"]
    if sys.stdin.isatty() and sys.stdout.isatty():
        args += ["--interactive", "--tty"]
    env = {
        "CONTAGENT_USERNAME": os.environ.get("USER") or subprocess.check_output(["id", "-un"], text=True).strip(),
        "CONTAGENT_GROUPNAME": subprocess.check_output(["id", "-gn"], text=True).strip(),
        "CONTAGENT_UID": subprocess.check_output(["id", "-u"], text=True).strip(),
        "CONTAGENT_GID": subprocess.check_output(["id", "-g"], text=True).strip(),
        "CONTAGENT_HOME": home,
    }
    for key in ("TERM", "COLORTERM"):
        if os.environ.get(key):
            env[key] = os.environ[key]
    env.update(dict(model["env"]))
    for key, value in env.items():
        args += ["--env", f"{key}={value}"]
    for spec in mount_specs(model["rows"], enabled, home, cwd):
        args += ["--volume", spec]
    ssh_sock = os.environ.get("SSH_AUTH_SOCK", "")
    if ssh_sock and is_socket(ssh_sock):
        args += ["--volume", f"{ssh_sock}:{ssh_sock}", "--env", f"SSH_AUTH_SOCK={ssh_sock}"]
    else:
        warn("SSH agent not available; SSH auth forwarding disabled")
    group_specs = extra_group_specs(groups)
    if group_specs:
        args += ["--env", f"CONTAGENT_EXTRA_GROUP_SPECS={group_specs}"]
    os.execvp("docker", ["docker", *args, image, *command])


if __name__ == "__main__":
    main()
