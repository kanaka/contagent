#!/usr/bin/env -S uv run --script
# /// script
# dependencies = ["pyyaml"]
# ///
from __future__ import annotations

import hashlib
import json
import os
import shutil
import subprocess
import sys
from pathlib import Path

import yaml

USAGE = """Usage: ./build-contagent.py [--<feature> ...]

Features, aliases, order, snippets, and version rules come from build-contagent.yaml.
Default features come from CONTAGENT_FEATURES.
"""


def die(msg: str) -> None:
    print(f"ERROR: {msg}", file=sys.stderr)
    raise SystemExit(1)


def sh(*cmd: str, env: dict[str, str] | None = None, capture: bool = True) -> str:
    try:
        p = subprocess.run(cmd, text=True, capture_output=capture, env=env, check=True)
    except subprocess.CalledProcessError as e:
        die(f"command failed: {' '.join(cmd)}\n{(e.stderr or '').strip()}")
    return p.stdout.strip() if capture else ""


def resolve(label: str, feature: dict, env: dict[str, str]) -> tuple[str, list[str]]:
    version = feature.get("version")
    if not isinstance(version, dict):
        return "builtin", []
    env_name = version.get("env") or ""
    value = env.get(env_name, version.get("default") or "latest") if env_name else (version.get("default") or "latest")
    if value == "latest":
        cmd = version.get("resolve") or ""
        if not cmd:
            die(f"{label} requested latest but has no resolve command")
        value = sh("sh", "-lc", cmd)
        if not value or value == "null":
            die(f"failed to resolve latest for {label}")
    return value, (["--build-arg", f"{env_name}={value}"] if env_name else [])


def escape_docker_label_value(value: str) -> str:
    return json.dumps(value).replace("$", r"\$")


def main() -> None:
    argv = sys.argv[1:]
    if any(a in ("-h", "--help") for a in argv):
        print(USAGE, end="")
        return

    if shutil.which("docker") is None:
        die("docker is required")
    if shutil.which("gzip") is None:
        die("gzip is required")

    env = os.environ
    image_name = env.get("CONTAGENT_IMAGE_NAME", "contagent")
    wanted = {t[2:] if t.startswith("--") else t for t in [*env.get("CONTAGENT_FEATURES", "").split(), *argv] if t}
    unknown = set(wanted)

    root = Path(__file__).resolve().parent
    manifest_file = root / "build-contagent.yaml"
    dockerfile = root / ".Dockerfile.generated"
    motd_file = root / ".contagent-motd.generated"
    default_config_file = root / ".contagent-default.yaml.generated"

    if not manifest_file.exists():
        die(f"missing manifest: {manifest_file}")
    manifest = yaml.safe_load(manifest_file.read_text()) or {}
    features = manifest.get("features") or []
    if not features:
        die("manifest has no features")
    schema_version = manifest.get("version", 2)

    docker_args: list[str] = []
    motd: list[str] = []
    labels: list[str] = []
    parts: list[str] = []
    runtime_features: list[dict] = []
    print("Building image with selected features:")
    for f in features:
        label = str(f.get("name") or "")
        aliases = [str(a) for a in (f.get("aliases") or [])]
        names = [label, *aliases] if label else []
        path = f.get("path") or ""
        if not label or not path:
            die("invalid manifest row")

        for n in names:
            unknown.discard(n)
        if not (f.get("required", False) or any(n in wanted for n in names)):
            continue

        runtime_feature: dict = {"name": label}
        if f.get("required", False):
            runtime_feature["required"] = True

        for volume in f.get("volumes") or []:
            mount_path = volume.get("path")
            if not isinstance(mount_path, str) or not mount_path:
                die(f"invalid volume entry in feature {label}: path is required")

            source = volume.get("source")
            if source is not None and (not isinstance(source, str) or not source):
                die(f"invalid volume entry in feature {label}: source is required")

            raw_default = volume.get("default", True)
            if not isinstance(raw_default, bool):
                die(f"invalid volume entry in feature {label}: default must be boolean")
            for key in ("file", "read_only"):
                value = volume.get(key)
                if value is not None and not isinstance(value, bool):
                    die(f"invalid volume entry in feature {label}: {key} must be boolean")

        volumes = f.get("volumes") or []
        if volumes:
            runtime_volumes: list[dict] = []
            for volume in volumes:
                runtime_volume = {"enabled": True if f.get("required", False) else volume.get("default", True)}
                for key in ("path", "source", "file", "read_only"):
                    if key in volume:
                        runtime_volume[key] = volume[key]
                runtime_volumes.append(runtime_volume)
            runtime_feature["volumes"] = runtime_volumes

        env_map = f.get("env")
        if env_map is not None and not isinstance(env_map, dict):
            die(f"invalid env entry in feature {label}: env must be a map")
        if env_map:
            runtime_feature["environment"] = env_map
        if "volumes" in runtime_feature or "environment" in runtime_feature:
            runtime_features.append(runtime_feature)

        part = root / path
        if not part.exists():
            die(f"missing Dockerfile part: {path}")
        parts.append(part.read_text())

        value, build_args = resolve(label, f, env)
        docker_args += build_args
        if value != "builtin":
            motd.append(f"{label} {value}")
            print(f"  {label}={value}")
        else:
            print(f"  {label}")

        volumes = f.get("volumes") or []
        if volumes:
            mount_rows: list[str] = []
            seen_mount_rows: set[str] = set()
            for v in volumes:
                mount_path = str(v.get("path") or "")
                source = str(v.get("source") or mount_path)
                row = f"{source}:{mount_path}"
                if row not in seen_mount_rows:
                    mount_rows.append(row)
                    seen_mount_rows.add(row)
            mounts = ",".join(mount_rows)
        else:
            mounts = ",".join(f.get("mounts") or [])

        esc_value = escape_docker_label_value(str(value))
        esc_mounts = escape_docker_label_value(mounts)
        labels.append(f'io.contagent.component.{label}.version={esc_value}')
        labels.append(f'io.contagent.component.{label}.mounts={esc_mounts}')

    if unknown:
        die(f"unknown feature(s): {','.join(sorted(unknown))}")
    if not parts:
        die("no features selected")

    runtime_config = {"version": schema_version, "features": runtime_features}
    runtime_config_id = hashlib.sha256(
        yaml.safe_dump(runtime_config, sort_keys=False).encode()
    ).hexdigest()
    runtime_config = {
        "version": schema_version,
        "image-hash": runtime_config_id,
        "features": runtime_features,
    }
    default_config_file.write_text(yaml.safe_dump(runtime_config, sort_keys=False))

    dockerfile.write_text(
        "\n".join(parts)
        + "\nRUN mkdir -p /usr/local/share/contagent\n"
        + "COPY .contagent-default.yaml.generated /usr/local/share/contagent/contagent.yaml\n"
        + ("LABEL " + " ".join(labels) + "\n" if labels else "")
    )
    motd_file.write_text("contagent tool versions:\n" + "\n".join(f"  - {x}" for x in motd) + ("\n" if motd else ""))

    voom_env = dict(env)
    voom_env["REPO_ROOT_VOOM"] = "1"
    image_ref = f"{image_name}:{sh(str(root / 'voom-like-version.sh'), env=voom_env)}"
    latest_ref = f"{image_name}:latest"

    print("Producing tags:")
    print(f"  {image_ref}")
    print(f"  {latest_ref}")
    sh("docker", "build", *docker_args, "-t", image_ref, "-f", str(dockerfile), str(root), capture=False)
    sh("docker", "tag", image_ref, latest_ref, capture=False)

    print("Run with:")
    print(f"  CONTAGENT_IMAGE={image_ref} ./contagent.sh")


if __name__ == "__main__":
    main()
