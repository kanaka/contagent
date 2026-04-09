# contagent: quarantine your agents, not your workflow

Contagent is a containerized runtime for coding agents on your local machine.

It is built for one practical goal: let agents run with fewer interruptions while
keeping filesystem and credential exposure narrow and intentional.

## Why use it

- Run agents with high autonomy in a constrained environment.
- Keep execution focused on the current project path, not your full home directory.
- Preserve day-to-day workflows: interactive shell, SSH agent forwarding, Docker
  client access to host daemon (if enabled).

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
- `curl`, `jq`, and `gzip` on host for resolving `latest` feature versions and image-label mount metadata.

## Quick start

Build container image with selected features/tools/agents:

```bash
./build-contagent.sh --docker --gh --psql --pi --claude
```

Launch interactive shell in current project:

```bash
./contagent.sh
```

Run one-shot command:

```bash
./contagent.sh pi --help
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

Build-time options:

- Global:
  - `CONTAGENT_IMAGE_NAME` (default: `contagent`)
  - `CONTAGENT_FEATURES` (default: ``)
- Features (flag + version env):
  - `--build` (alias: `--build-tools`) + `BUILD_ESSENTIAL_VERSION`
  - `--docker` + `DOCKER_VERSION`
  - `--gh` (aliases: `--github`, `--github-cli`, `--githubcli`) + `GH_VERSION`
  - `--mise` + `MISE_VERSION`
  - `--psql` (aliases: `--postgres`, `--postgresql`) + `PSQL_VERSION`
  - `--go` (alias: `--golang`) + `GO_VERSION`
  - `--java` (aliases: `--jdk`, `--clojure`, `--clj`, `--clojurescript`, `--cljs`) + `JAVA_VERSION`
  - `--clojure` (alias: `--clj`) + `CLOJURE_VERSION`
  - `--clojurescript` (alias: `--cljs`) + `CLOJURESCRIPT_VERSION`
  - `--rust` + `RUST_VERSION`
  - `--claude` (aliases: `--claude-code`, `--cc`, `--claudecode`) + `CLAUDE_CODE_VERSION`
  - `--opencode` + `OPENCODE_VERSION`
  - `--pi` (alias: `--pi-agent`) + `PI_VERSION`
  - `--codex` + `CODEX_VERSION`
  - `--copilot` (aliases: `--github-copilot`, `--githubcopilot`) + `COPILOT_VERSION`
- Aggregates:
  - `--all-tools` (all non-agent tool features)
  - `--all-agents` (all agent features)
  - `--all` (all tool + agent features)

`CONTAGENT_FEATURES` sets the default enabled feature list; CLI flags add to it.
Both accept any token listed in a feature's `names` array in `Dockerfile.yaml`.
Feature mounts are defined in each feature's `mounts` list and propagated into image labels at build time (`io.contagent.component.<name>.mounts`).
Feature versions are also labeled (`io.contagent.component.<name>.version`).

Build implementation notes:

- Build composition is driven by `Dockerfile.yaml` and assembled from
  `Dockerfile-parts/` into `.Dockerfile` on each build (`base` is always included).
- Manifest parsing uses local `yq` when available, otherwise `mikefarah/yq` via Docker.

Runtime environment:

- `CONTAGENT_IMAGE` (default: `contagent:latest`)
- `CONTAGENT_DOCKER_SOCKET` (non-empty enables docker socket mount; empty disables)
- `CONTAGENT_GH_CONFIG` (non-empty enables `~/.config/gh` mount when available; empty disables)
- `CONTAGENT_EXTRA_GROUP_GIDS` (non-empty comma-separated gid list applies supplementary groups; empty disables)
- CLI options:
  - `--docker-socket` / `--no-docker-socket`
  - `--gh-config` / `--no-gh-config`
  - `--extra-groups <gid[,gid]>` (appends to `CONTAGENT_EXTRA_GROUP_GIDS`)

Examples:

```bash
CONTAGENT_FEATURES="pi codex" PI_VERSION=0.56.0 ./build-contagent.sh
./contagent.sh pi --version

./build-contagent.sh --claude --opencode --copilot
CONTAGENT_IMAGE=contagent:20260302_101530-gabc123 ./contagent.sh

CONTAGENT_DOCKER_SOCKET=1 ./contagent.sh docker ps
./contagent.sh --docker-socket docker ps

CONTAGENT_GH_CONFIG=1 ./contagent.sh gh auth status
./contagent.sh --gh-config gh auth status

CONTAGENT_EXTRA_GROUP_GIDS=970 ./contagent.sh
./contagent.sh --extra-groups 970,971
```

## Trust model and security boundaries

Contagent reduces exposure; it is not a hard security sandbox.

Mounted by default:

- Current project directory (same absolute path).
- Feature-specific mounts (except `gh` config mount)
- Base feature mounts include:
  - `~/.local/state/contagent` -> `~/.local/state/contagent`
  - `~/.cache/contagent` -> `/var/cache/contagent`
- SSH agent socket when detected.

Mounted only when enabled:

- Docker socket (`CONTAGENT_DOCKER_SOCKET=1` or `--docker-socket`) when detected.
- `~/.config/gh` (`CONTAGENT_GH_CONFIG=1` or `--gh-config`) when `gh` feature is present.

Not mounted by default:

- Arbitrary paths from `$HOME`.
- Other host directories apart from project / feature mounts.

Important implications:

- Docker socket access is powerful and can affect the host.
- `~/.config/gh` may contain high-privilege GitHub credentials/tokens.
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
