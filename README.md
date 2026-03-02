# contagent

Contagent is a containerized runtime for coding agents on your local machine.

It is built for one practical goal: let agents run with fewer interruptions while
keeping filesystem and credential exposure narrow and intentional.

## Why use it

- Run agents with high autonomy in a constrained environment.
- Keep execution focused on the current project path, not your full home directory.
- Preserve day-to-day workflows: interactive shell, SSH agent forwarding, Docker
  client access to host daemon.

## What it provides

- Runtime image with common CLI tools plus Claude Code and OpenCode.
- Host identity mapping (username, primary group name, UID, GID, home).
- Project mounted at the same absolute path inside the container.
- Minimal allowlist mounts for agent config/cache/state paths.
- Optional extra supplementary groups by host GID.
- Deterministic image tags from resolved CLI versions and voom-style git versioning.

## Requirements

- Docker on host.
- Bash 4+ for `contagent.sh` and `build-contagent.sh`.

## Quick start

Build:

```bash
./build-contagent.sh
```

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
- `CLAUDE_CODE_VERSION` (default: `latest`)
- `OPENCODE_VERSION` (default: `latest`)

Runtime environment:

- `CONTAGENT_IMAGE` (default: `contagent:latest`)
- `CONTAGENT_EXTRA_GROUP_GIDS` (comma-separated numeric gids)

Examples:

```bash
CLAUDE_CODE_VERSION=1.0.59 OPENCODE_VERSION=0.5.19 ./build-contagent.sh
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
