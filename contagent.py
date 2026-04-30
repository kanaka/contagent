#!/usr/bin/env python3

import json
import os
import re
import shutil
import stat
import subprocess
import sys
import tempfile
from pathlib import Path

USAGE = """Usage: ./contagent.py [options] [--] [command ...]

Options:
  -c, --config CONFIG         Runtime config path (default: .contagent.yaml)
  --<feature>                 Enable volume mounts for an image feature
  --no-<feature>              Disable volume mounts for an image feature
  --show-options              Show config-defined --<feature>/--no-<feature> toggles and exit
  --extra-groups <gid[,gid]>  Append supplementary group GIDs for this run
  -h, --help                  Show this help
"""

EMBEDDED_CONFIG = "/usr/local/share/contagent/contagent.yaml"


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


def resolve_path(raw: str, home: str, base: str) -> str:
    if raw == "~" or raw.startswith("~/"):
        return home + raw[1:]
    return raw if os.path.isabs(raw) else os.path.join(base, raw)


def bool_value(value: object, default: bool, feature: str, field: str) -> bool:
    if value is None:
        return default
    if not isinstance(value, bool):
        die(f"invalid volume entry in feature {feature}: {field} must be boolean")
    return value


def embedded_config(image: str) -> str:
    p = subprocess.run(
        ["docker", "run", "--rm", "--entrypoint", "cat", image, EMBEDDED_CONFIG],
        text=True,
        capture_output=True,
    )
    if p.returncode != 0:
        die(f"failed to extract default contagent config from {image}")
    return p.stdout


def yq_json(path: Path, image: str) -> dict:
    if shutil.which("yq"):
        attempts = [["yq", "-o=json", ".", str(path)], ["yq", ".", str(path)]]
        inputs = [None, None]
    else:
        warn(f"yq not found; falling back to yq from {image}")
        attempts = [
            ["docker", "run", "--rm", "-i", "--entrypoint", "yq", image, "-o=json", ".", "-"],
            ["docker", "run", "--rm", "-i", "--entrypoint", "yq", image, ".", "-"],
        ]
        inputs = [path.read_text(), path.read_text()]

    for cmd, data in zip(attempts, inputs):
        p = subprocess.run(cmd, input=data, text=True, capture_output=True)
        if p.returncode == 0:
            try:
                return json.loads(p.stdout)
            except Exception:
                pass
    die(f"failed to parse {path}")


def config_path(argv: list[str]) -> Path:
    config = ".contagent.yaml"
    i = 0
    while i < len(argv):
        arg = argv[i]
        if arg == "--":
            break
        if arg in ("-c", "--config"):
            if i + 1 >= len(argv):
                die(f"{arg} requires a value")
            config = argv[i + 1]
            i += 2
            continue
        if arg.startswith("--config="):
            config = arg.split("=", 1)[1]
        elif not arg.startswith("-"):
            break
        i += 1
    return Path(config)


def load_config(path: Path, image: str) -> tuple[dict, Path]:
    if not path.exists() or path.stat().st_size == 0:
        path.parent.mkdir(parents=True, exist_ok=True)
        data = embedded_config(image)
        if not data:
            die("embedded default contagent config is empty")
        path.write_text(data)

    config = yq_json(path, image)
    with tempfile.NamedTemporaryFile("w+", delete=False) as f:
        f.write(embedded_config(image))
        embedded_path = Path(f.name)
    try:
        embedded = yq_json(embedded_path, image)
    finally:
        embedded_path.unlink(missing_ok=True)

    config_id = config.get("image-hash")
    embedded_id = embedded.get("image-hash")
    if embedded_id and config_id != embedded_id:
        warn(f"{path} was not generated from {image}")
    return config, path.parent.resolve()


def build_model(config: dict) -> dict:
    options: dict[str, str] = {}
    rows: list[dict] = []
    env: list[tuple[str, str]] = []
    all_features: set[str] = set()

    for feature in config.get("features", []) if isinstance(config, dict) else []:
        name = str(feature.get("name") or "")
        volumes = feature.get("volumes") or []
        if not name:
            continue
        env.extend((str(k), str(v)) for k, v in (feature.get("environment") or {}).items())
        if not volumes:
            continue
        all_features.add(name)
        states: list[bool] = []

        for volume in volumes:
            target = volume.get("path")
            if not isinstance(target, str) or not target:
                die(f"invalid volume entry in feature {name}: path is required")
            source = volume.get("source") if volume.get("source") is not None else target
            if not isinstance(source, str) or not source:
                die(f"invalid volume entry in feature {name}: source is required")
            enabled = bool_value(volume.get("enabled"), True, name, "enabled")
            states.append(enabled)
            rows.append({
                "feature": name,
                "enabled": enabled,
                "source": source,
                "target": target,
                "file": bool_value(volume.get("file"), False, name, "file"),
                "read_only": bool_value(volume.get("read_only"), False, name, "read_only"),
                "create": source == "~" or source.startswith("~/") or not os.path.isabs(source),
            })
        options[name] = "mixed" if any(states) and not all(states) else ("on" if all(states) else "off")
    return {"all_features": all_features, "options": options, "rows": rows, "env": env}


def print_options(image: str, model: dict) -> None:
    if not model["options"]:
        print(f"Config for {image} exposes no volume toggles.")
        return
    print(f"Config volume toggles for {image}:")
    for name in sorted(model["options"]):
        print(f"  --{name} / --no-{name} (default: {model['options'][name]}; features: {name})")


def set_override(arg: str, name: str, state: bool, model: dict, overrides: dict) -> None:
    if name in model["options"]:
        overrides[name] = state
    elif name in model["all_features"]:
        flag = f"--{name}" if state else f"--no-{name}"
        die(f"option {flag} is known but not included in config (feature(s): {name})")
    else:
        die(f"unknown option: {arg}")


def parse_args(argv: list[str], model: dict) -> tuple[list[str], bool, bool, str, dict]:
    overrides: dict[str, bool] = {}
    extra_groups = os.environ.get("CONTAGENT_EXTRA_GROUP_GIDS", "")
    show_options = help_requested = False
    i = 0
    while i < len(argv):
        arg = argv[i]
        if arg == "--":
            return argv[i + 1:], show_options, help_requested, extra_groups, overrides
        if arg in ("-h", "--help"):
            return [], show_options, True, extra_groups, overrides
        if arg == "--show-options":
            show_options = True
        elif arg in ("-c", "--config"):
            if i + 1 >= len(argv):
                die(f"{arg} requires a value")
            i += 1
        elif arg.startswith("--config="):
            pass
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
            set_override(arg, arg[5:], False, model, overrides)
        elif arg.startswith("--"):
            if "=" in arg:
                die(f"unknown option: {arg}")
            set_override(arg, arg[2:], True, model, overrides)
        elif arg.startswith("-"):
            die(f"unknown option: {arg}")
        else:
            return argv[i:], show_options, help_requested, extra_groups, overrides
        i += 1
    return [], show_options, help_requested, extra_groups, overrides


def mount_specs(rows: list[dict], overrides: dict, home: str, base: str) -> list[str]:
    by_target: dict[str, list[dict]] = {}
    order: list[str] = []
    for row in rows:
        enabled = overrides.get(row["feature"], row["enabled"])
        if not enabled:
            continue
        src = resolve_path(row["source"], home, base)
        dst = resolve_path(row["target"], home, base)
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
    config, config_base = load_config(config_path(sys.argv[1:]), image)
    model = build_model(config)
    command, show, help_requested, groups, overrides = parse_args(sys.argv[1:], model)

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
    for spec in mount_specs(model["rows"], overrides, home, str(config_base)):
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
