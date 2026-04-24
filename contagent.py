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
  --<name>                    Enable a volume group from image metadata
  --no-<name>                 Disable a volume group from image metadata
  --show-options              Show image-defined --<name>/--no-<name> toggles and exit
  --extra-groups <gid[,gid]>  Append supplementary group GIDs for this run
  -h, --help                  Show this help
"""

MANIFEST_LABEL = "io.contagent.manifest.json"
FEATURES_LABEL = "io.contagent.manifest.features"
SCHEMA_LABEL = "io.contagent.schema.version"
SUPPORTED_SCHEMA = 2


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


def resolve_path(path: str, home: str, cwd: str) -> str:
    if path == "~" or path.startswith("~/"):
        return home + path[1:]
    return path if os.path.isabs(path) else os.path.join(cwd, path)


def load_labels(image: str) -> tuple[dict, list[str]]:
    p = subprocess.run(["docker", "image", "inspect", image], text=True, capture_output=True)
    if p.returncode != 0:
        die(f"image {image} is not available locally; build it first with ./build-contagent.py")
    try:
        inspect = json.loads(p.stdout)
        labels = ((inspect[0] if isinstance(inspect, list) and inspect else {}).get("Config") or {}).get("Labels") or {}
    except Exception:
        die("invalid manifest in image labels")

    schema_raw = labels.get(SCHEMA_LABEL, "")
    if not schema_raw:
        die("image is missing io.contagent.schema.version label; rebuild with ./build-contagent.py")
    try:
        schema_num = float(schema_raw)
    except Exception:
        die("image label io.contagent.schema.version is invalid")
    if not schema_num.is_integer():
        die("image label io.contagent.schema.version is invalid")
    schema_version = int(schema_num)
    if schema_version != SUPPORTED_SCHEMA:
        die(f"unsupported schema version: {schema_version}")

    manifest_label = labels.get(MANIFEST_LABEL, "")
    if not manifest_label:
        die("image is missing io.contagent.manifest.json label; rebuild with ./build-contagent.py")
    try:
        manifest = json.loads(manifest_label)
    except Exception:
        die("invalid manifest in image labels")

    try:
        selected_raw = json.loads(labels.get(FEATURES_LABEL, "[]"))
    except Exception:
        die("image label io.contagent.manifest.features is invalid")
    selected = [str(x) for x in selected_raw] if isinstance(selected_raw, list) else []
    return manifest, selected


def volume_rows(feature_name: str, volume: dict) -> list[dict]:
    arg_name = str(volume.get("arg_name") or "")
    use_sources = volume.get("sources") is not None
    sources = volume.get("sources") if use_sources else [volume.get("source")]
    target = str(volume.get("target") or "")
    rows: list[dict] = []

    for raw_source in sources or []:
        source = str(raw_source or "")
        if not arg_name or not source:
            continue
        rows.append({
            "feature": feature_name,
            "arg_name": arg_name,
            "source": source,
            "target": target or source,
            "safe": volume.get("default", True),
            "file": volume.get("file", False),
            "read_only": volume.get("read_only", False),
            "create_if_missing": not use_sources,
        })
    return rows


def build_meta(manifest: dict, selected_features: list[str]) -> dict:
    selected = set(selected_features)
    all_opts: dict[str, dict] = {}
    included_opts: dict[str, dict] = {}
    included_rows: list[dict] = []
    env_rows: list[tuple[str, str]] = []

    def add_opt(target: dict[str, dict], row: dict) -> None:
        current = target.get(row["arg_name"])
        if current is None:
            target[row["arg_name"]] = {"safe": row["safe"], "features": [row["feature"]]}
            return
        if row["feature"] not in current["features"]:
            current["features"].append(row["feature"])

    features = manifest.get("features", []) if isinstance(manifest, dict) else []
    for feature in features:
        feature_name = str(feature.get("name") or "")
        if not feature_name:
            continue

        include_feature = feature_name in selected
        for volume in feature.get("volumes") or []:
            for row in volume_rows(feature_name, volume):
                add_opt(all_opts, row)
                if include_feature:
                    add_opt(included_opts, row)
                    included_rows.append(row)

        if include_feature:
            env_rows.extend((str(k), str(v)) for k, v in (feature.get("env") or {}).items())

    return {
        "all_opts": all_opts,
        "included_opts": included_opts,
        "option_order": sorted(included_opts),
        "rows": included_rows,
        "env": env_rows,
    }


def print_options(image: str, meta: dict) -> None:
    if not meta["option_order"]:
        print(f"Image {image} exposes no volume toggles.")
        return
    print(f"Image volume toggles for {image}:")
    for name in meta["option_order"]:
        opt = meta["included_opts"][name]
        state = "on" if opt["safe"] else "off"
        features = ",".join(opt["features"])
        print(
            f"  --{name} / --no-{name} "
            f"(default: {state}; features: {features})"
        )


def main() -> None:
    if shutil.which("docker") is None:
        die("docker is required")
    image = os.environ.get("CONTAGENT_IMAGE", "contagent:latest")
    extra_groups_csv = os.environ.get("CONTAGENT_EXTRA_GROUP_GIDS", "")
    host_home = os.environ.get("HOME")
    if not host_home:
        die("HOME must be set")
    host_user = os.environ.get("USER") or subprocess.check_output(
        ["id", "-un"],
        text=True,
    ).strip()
    host_group = subprocess.check_output(["id", "-gn"], text=True).strip()
    host_uid = subprocess.check_output(["id", "-u"], text=True).strip()
    host_gid = subprocess.check_output(["id", "-g"], text=True).strip()
    workdir = os.getcwd()
    manifest, selected = load_labels(image)
    meta = build_meta(manifest, selected)
    enabled = {name: meta["included_opts"][name]["safe"] for name in meta["option_order"]}
    show_options = False
    argv = sys.argv[1:]
    i = 0
    while i < len(argv):
        arg = argv[i]
        if arg == "--":
            i += 1
            break
        if arg in ("-h", "--help"):
            print(USAGE, end="")
            print()
            print_options(image, meta)
            return
        if arg == "--show-options":
            show_options = True
        elif arg == "--extra-groups":
            if i + 1 >= len(argv):
                die("--extra-groups requires a value")
            extra_groups_csv = f"{extra_groups_csv},{argv[i + 1]}" if extra_groups_csv else argv[i + 1]
            i += 1
        elif arg.startswith("--extra-groups="):
            value = arg.split("=", 1)[1]
            extra_groups_csv = f"{extra_groups_csv},{value}" if extra_groups_csv else value
        elif arg.startswith("--"):
            is_neg = arg.startswith("--no-")
            name = arg[5:] if is_neg else arg[2:]
            new_state = not is_neg
            if name in meta["included_opts"]:
                enabled[name] = new_state
            elif name in meta["all_opts"]:
                features = ",".join(meta["all_opts"][name]["features"])
                flag = f"--{name}" if new_state else f"--no-{name}"
                die(
                    f"option {flag} is known but not included in image "
                    f"(feature(s): {features})"
                )
            else:
                die(f"unknown option: {arg}")
        elif arg.startswith("-"):
            die(f"unknown option: {arg}")
        else:
            break
        i += 1

    if show_options:
        print_options(image, meta)
        return
    docker_args = ["--rm", "--workdir", workdir, "--volume", f"{workdir}:{workdir}"]
    if sys.stdin.isatty() and sys.stdout.isatty():
        docker_args += ["--interactive", "--tty"]
    docker_args += [
        "--env", f"CONTAGENT_USERNAME={host_user}",
        "--env", f"CONTAGENT_GROUPNAME={host_group}",
        "--env", f"CONTAGENT_UID={host_uid}",
        "--env", f"CONTAGENT_GID={host_gid}",
        "--env", f"CONTAGENT_HOME={host_home}",
    ]
    if os.environ.get("TERM"):
        docker_args += ["--env", f"TERM={os.environ['TERM']}"]
    if os.environ.get("COLORTERM"):
        docker_args += ["--env", f"COLORTERM={os.environ['COLORTERM']}"]
    for k, v in meta["env"]:
        if k:
            docker_args += ["--env", f"{k}={v}"]
    target_candidates: dict[str, list[dict]] = {}
    target_order: list[str] = []
    for row in meta["rows"]:
        if not enabled.get(row["arg_name"], False):
            continue
        src = resolve_path(row["source"], host_home, workdir)
        dst = resolve_path(row["target"], host_home, workdir)
        if dst not in target_candidates:
            target_candidates[dst] = []
            target_order.append(dst)
        target_candidates[dst].append({
            "source": src,
            "read_only": row["read_only"],
            "file": row["file"],
            "create_if_missing": row.get("create_if_missing", False),
        })

    for dst in target_order:
        candidates = target_candidates[dst]
        chosen = next((c for c in candidates if os.path.exists(c["source"])), None)
        if chosen is None:
            chosen = next((c for c in candidates if c.get("create_if_missing")), None)
            if chosen is None:
                die(f"no existing source found for target {dst} among {len(candidates)} candidates")
            src = chosen["source"]
            if chosen["file"]:
                os.makedirs(os.path.dirname(src) or ".", exist_ok=True)
                Path(src).touch(exist_ok=True)
            else:
                os.makedirs(src, exist_ok=True)

        spec = f"{chosen['source']}:{dst}" + (":ro" if chosen["read_only"] else "")
        docker_args += ["--volume", spec]
    ssh_sock = os.environ.get("SSH_AUTH_SOCK", "")
    if ssh_sock and is_socket(ssh_sock):
        docker_args += ["--volume", f"{ssh_sock}:{ssh_sock}", "--env", f"SSH_AUTH_SOCK={ssh_sock}"]
    else:
        warn("SSH agent not available; SSH auth forwarding disabled")
    gids: list[str] = []
    for token in extra_groups_csv.split(",") if extra_groups_csv else []:
        gid = token.strip()
        if not gid:
            continue
        if not re.fullmatch(r"\d+", gid):
            warn(f"ignoring non-numeric extra group gid: {gid}")
            continue
        if gid not in gids:
            gids.append(gid)
    if gids:
        specs = ",".join(f"g{gid}:{gid}" for gid in gids)
        docker_args += ["--env", f"CONTAGENT_EXTRA_GROUP_SPECS={specs}"]
    os.execvp("docker", ["docker", "run", *docker_args, image, *argv[i:]])

if __name__ == "__main__":
    main()
