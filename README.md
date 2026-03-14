# contagent: quarantine your agents, not your workflow

Contagent is a containerized runtime for coding agents on your local machine.

It is built for one practical goal: let agents run with fewer interruptions while
keeping filesystem and credential exposure narrow and intentional.

## Why use it

- Run agents with high autonomy in a constrained environment.
- Keep execution focused on the current project path, not your full home directory.
- Preserve day-to-day workflows: interactive shell, SSH agent forwarding, Docker
  client access to host daemon.

## What it provides

- Runtime image with common CLI tools plus Claude Code, OpenCode, Pi, Codex, and Copilot.
- Host identity mapping (username, primary group name, UID, GID, home).
- Project mounted at the same absolute path inside the container.
- Minimal allowlist mounts for agent config/cache/state paths.
- Optional extra supplementary groups by host GID.
- Deterministic image tags from voom-style git versioning (`<voom>` and `latest`).

## Requirements

- Docker on host.
- Bash 4+ for `contagent.sh` and `build-contagent.sh`.
- `curl` and `jq` on host for resolving `latest` feature versions.

## Quick start

Build:

```bash
./build-contagent.sh
```

Build with feature flags:

```bash
./build-contagent.sh --build --docker --gh --psql --pi --claude --opencode --codex --copilot
```

Build composition is driven by `Dockerfile.yaml` and assembled from
`Dockerfile-parts/` into `Dockerfile.selected` on each build (`base` is always included).
Manifest parsing uses local `yq` when available, otherwise `mikefarah/yq` via Docker.

Launch interactive shell in current project:

```bash
./contagent.sh
```

Run one-shot command:

```bash
./contagent.sh opencode --help
```

Use a specific built tag:

```bash
CONTAGENT_IMAGE=contagent:<tag> ./contagent.sh
```

## Exec into a running container as mapped user

From another terminal:

```bash
docker exec -it <container-name> /entrypoint.sh
docker exec -it <container-name> /entrypoint.sh bash -lc 'id && whoami'
```

`/entrypoint.sh` handles direct invocation by re-entering the mapped user
environment (`HOME`/`USER`) instead of dropping you into root context.

## Configuration

Build-time environment:

- `CONTAGENT_IMAGE_NAME` (default: `contagent`)
- `CONTAGENT_FEATURES` (default: `pi`)
- `CLAUDE_CODE_VERSION` (default: `latest`)
- `OPENCODE_VERSION` (default: `latest`)
- `PI_VERSION` (default: `latest`)
- `CODEX_VERSION` (default: `latest`)
- `COPILOT_VERSION` (default: `latest`)
- `GH_VERSION` (default: `latest`)

Build-time feature flags:

- `--build` (alias: `--build-tools`)
- `--docker`
- `--gh` (aliases: `--github`, `--github-cli`, `--githubcli`)
- `--psql` (aliases: `--postgres`, `--postgresql`)
- `--pi`
- `--claude` (aliases: `--claude-code`, `--cc`, `--claudecode`)
- `--opencode`
- `--codex`
- `--copilot` (aliases: `--github-copilot`, `--githubcopilot`)

`CONTAGENT_FEATURES` sets the default enabled feature list; CLI flags add to it.
Both accept any token listed in a feature's `names` array in `Dockerfile.yaml`.

Runtime environment:

- `CONTAGENT_IMAGE` (default: `contagent:latest`)
- `CONTAGENT_EXTRA_GROUP_GIDS` (comma-separated numeric gids)

Examples:

```bash
CONTAGENT_FEATURES="pi codex" PI_VERSION=0.56.0 ./build-contagent.sh
./build-contagent.sh --claude --opencode --copilot
CONTAGENT_IMAGE=contagent:20260302_101530-gabc123 ./contagent.sh
CONTAGENT_EXTRA_GROUP_GIDS=970 ./contagent.sh docker ps
```

## Trust model and security boundaries

Contagent reduces exposure; it is not a hard security sandbox.

Mounted by default:

- Current project directory (same absolute path).
- Allowlisted agent directories under `$HOME`.
- Docker socket when detected.
- SSH agent socket when detected.

Not mounted by default:

- Arbitrary paths from `$HOME`.
- Other host directories outside project + allowlist.

Important implications:

- Docker socket access is powerful and can affect the host.
- SSH agent forwarding allows use of loaded keys via the socket.
- Run contagent only for projects and sessions where this trust model fits.

## Validation

Run smoke checks against a local image:

```bash
./smoketest.sh
```

## Versioning note (voom)

This repository includes `voom-like-version.sh` as a local adaptation of:

- `https://github.com/Viasat/voom-util/blob/master/voom-like-version.sh`

voom-util license:

- Eclipse Public License 2.0 (EPL-2.0)
- `https://github.com/Viasat/voom-util/blob/master/LICENSE`

## License

- Project license: MIT (`LICENSE`).
- `voom-like-version.sh` remains under its upstream EPL-2.0 terms.
