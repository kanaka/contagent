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
- node/npm for `contagent` and `build-contagent`.
- `curl`, `jq`, and `gzip` for resolving `latest` feature versions.

## Quick start

Install npm deps basic operation (yaml) and for hostbridge support (ws, glimpse):
```bash
npm install
```

Build container image with selected features/tools/agents:

```bash
./build-contagent --docker --gh --psql --pi --claude
```

Launch interactive shell in current project:

```bash
./contagent
```

Run one-shot command:

```bash
./contagent pi --help
```

Use a specific built tag:

```bash
CONTAGENT_IMAGE=contagent:<tag> ./contagent
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
  - `--aws` (aliases: `--aws-cli`, `--awscli`, `--amazon`, `--amazon-web-services`) + `AWS_CLI_VERSION`
  - `--mise` + `MISE_VERSION`
  - `--uv` (alias: `--uvx`) + `UV_VERSION`
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
Both accept a feature `name` or any token listed in a feature's `aliases` array in `build-contagent.yaml`.
Feature mounts are defined in each feature's `volumes` list. Build embeds a default runtime config at `/usr/local/share/contagent/contagent.yaml`.

Build implementation notes:

- Build composition is driven by `build-contagent.yaml` and assembled from
  `Dockerfile-parts/` into `.Dockerfile.generated` on each build (`base` is always included).
- Manifest parsing uses local `yq` when available, otherwise `mikefarah/yq` via Docker.
- The generated image contains the default runtime config for the selected features.

## Runtime config

Three layers are merged in order: the default config embedded in the image at
build time, the optional per-project `.contagent.yaml` override file, and any
CLI feature flags. Later layers win.

```
embedded defaults → .contagent.yaml (if present) → CLI flags
```

### Command-line flags

- `-c CONFIG`, `--config CONFIG` — config file path; overrides `CONTAGENT_CONFIG`
- `--show-config` — print the fully merged effective config and exit
- `--update-config` — apply feature flags to the config file and write it back; requires at least one flag
- `--<feature>` / `--no-<feature>` — enable or disable a feature for this run
- `--extra-groups <gid[,gid]>` — supplementary group GIDs; overrides `CONTAGENT_EXTRA_GROUP_GIDS`
- `--docker-args <args>` — extra `docker run` arguments (shell-quoted string); overrides `CONTAGENT_DOCKER_ARGS`

Environment variables:

- `CONTAGENT_IMAGE` — image to run (default: `contagent:latest`)
- `CONTAGENT_CONFIG` — config file path (default: `.contagent.yaml`)
- `CONTAGENT_DOCKER_ARGS` — extra `docker run` arguments (shell-quoted string)
- `CONTAGENT_EXTRA_GROUP_GIDS` — comma-separated supplementary GIDs applied at container startup
- `CONTAGENT_CWD` — injected absolute container workdir; reserved for contagent

### `.contagent.yaml`

Only include features you want to change from the embedded defaults; omitted
features inherit their embedded values unchanged. `--update-config` writes
only the diff from defaults, keeping the file minimal. When the image is
rebuilt with new defaults, only your explicit overrides persist.

```yaml
version: 2

features:
  - name: docker            # must match a feature name in the embedded config
    enabled: false          # overrides the feature's default enabled state

  - name: claude
    volumes:                # replaces the feature's entire embedded volume list
      - path: ~/.claude     # container path and default host path; ~ expands to $HOME
        source: ~/work/.claude  # host path when different from path
        read_only: true     # mount read-only (default: false)
        file: false         # true if the path is a file rather than a directory
    environment:
      CLAUDE_CONFIG_DIR: ~/.claude  # leading ~ and ${HOME}/${PWD}/${USER}/${CONTAGENT_*} expand

  - name: hostbridge
    enabled: true
    environment:            # env vars injected into the container; replaces the embedded map
      BROWSER: /usr/local/bin/xdg-open
    ports:                  # docker --publish entries; replaces the embedded list
      - "7284:7284"
```

**Field reference:**

Volume `path`/`source` and `environment` values share one expansion rule: a
leading `~` expands to the mapped home, and `${HOME}`, `${PWD}`, `${USER}`,
and the injected `${CONTAGENT_*}` identity vars expand to their launch
values. Unknown `${...}` tokens pass through unchanged; host environment
variables are never expanded.

- **`name`** *(required)* — must match a feature name in the embedded config.
- **`enabled`** — `true`/`false`; overrides the feature default. CLI `--<feature>`/`--no-<feature>` overrides this further.
- **`volumes`** — replaces the embedded volume list entirely when present.
  - **`path`** *(required)* — container mount target and default host source. Relative paths resolve against the launcher's working directory.
  - **`source`** — host path when it differs from `path`. Missing sources under the mapped home or the project directory are created at launch; other sources must already exist.
  - **`read_only`** — mount read-only (default: `false`).
  - **`file`** — `true` if the path is a file; a zero-byte file is created if it doesn't exist (default: `false`).
- **`environment`** — map of env vars injected when the feature is enabled; replaces the embedded map for that feature. Values are expanded but never path-resolved: a leading `./` passes through literally (with a warning), since it may be meant relative to the consumer's runtime cwd — use `${PWD}/...` for launch-dir-relative. Non-string values are skipped with a warning (unquoted `~` is YAML null — quote it).
- **`ports`** — list of `docker --publish` port specs; replaces the embedded list for that feature.

## Hostbridge

Hostbridge lets code inside the container run a curated set of host commands —
audio playback, notifications, clipboard, browser, and GUI dialogs — without
giving the container direct host access. Enable it with `--hostbridge`
(or set `enabled: true` for the hostbridge feature in `.contagent.yaml`):

```bash
./contagent --hostbridge
```

This launches a WebSocket server on the host that the container connects to.
Each command invocation (e.g. `paplay`, `pbcopy`, `xdg-open`, `glimpse`)
creates one WebSocket connection whose lifetime matches the spawned process.

Supported commands: `paplay`/`aplay` (audio), `say` (TTS), `notify-send`
(notifications), `xdg-open` (URLs), `pbcopy`/`pbpaste` (clipboard), `glimpse`
(native GUI dialogs).

### Access control

Every command must be explicitly allowed or goes through an interactive prompt.
Access rules live in `.hostbridge.yaml`:

```yaml
rules:
  - cmd: notify-send
    access: allow
    args: any
    scope: always
  - cmd: paplay
    access: allow
    args: any
    scope: always
```

Commands not listed default to `prompt`. When a command is prompted, a native
[Glimpse](https://github.com/HazAT/glimpse) dialog appears on the host with
three choices:

- **Action**: Allow or Deny
- **Scope**: Once, This Session (lost on restart), or Always (persisted)
- **Args**: Only These Args (exact match) or Any Args

Decisions are stored back to `.hostbridge.yaml`. Session decisions are tagged
with the hostbridge PID and expire automatically. Delete entries to reset.

To see all available commands with their current access level:

```bash
./hostbridge.js --show-config
```

If Glimpse is unavailable (headless host), prompted commands are denied with a
YAML snippet you can paste into your config to allow them permanently.

See [hostbridge.md](hostbridge.md) for the full protocol, registry, and
configuration reference.

Examples:

```bash
CONTAGENT_FEATURES="pi codex" PI_VERSION=0.56.0 ./build-contagent
./contagent pi --version

./build-contagent --claude --opencode --copilot
CONTAGENT_IMAGE=contagent:20260302_101530-gabc123 ./contagent

./contagent --docker docker ps

./contagent --gh gh auth status

./contagent --aws aws sts get-caller-identity

CONTAGENT_EXTRA_GROUP_GIDS=970 ./contagent
./contagent --extra-groups 970,971
```

## Trust model and security boundaries

Contagent reduces exposure; it is not a hard security sandbox.

Mounted by default:

- Current project directory (same absolute path).
- Feature-specific mounts whose feature volume toggle defaults to on.
- Runtime feature mounts include:
  - `~/.contagent` -> `~/.contagent`
  - `~/.local/state/contagent` -> `~/.local/state/contagent`
  - `~/.cache/contagent` -> `/var/cache/contagent`
- SSH agent socket when detected.

Mounted only when enabled:

- Docker socket (`--docker`) when the `docker` feature is present.
- `~/.config/gh` (`--gh`) when the `gh` feature is present.
- `~/.aws` (`--aws`) when the `aws` feature is present.

Not mounted by default:

- Arbitrary paths from `$HOME`.
- Other host directories apart from project / feature mounts.

Important implications:

- Docker socket access is powerful and can affect the host.
- `~/.config/gh` may contain high-privilege GitHub credentials/tokens.
- `~/.aws` may contain high-privilege AWS credentials, profiles, and SSO cache data.
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
