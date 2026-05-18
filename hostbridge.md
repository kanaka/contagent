# Hostbridge

Hostbridge lets sandboxed containers run a curated set of host commands —
audio playback, notifications, clipboard, browser, and GUI dialogs — without
giving the container direct host access.

It has two parts:

- **hostbridge.js** — runs on the host, listens for WebSocket
  connections, spawns opt-in listed commands
- **hostbridge-client.js** — runs inside the container, symlinked as tool names
  (`paplay`, `pbcopy`, `glimpse`, etc.), connects to the server

## Architecture

```
┌─────────────────────────────────────────────┐
│  Container                                  │
│                                             │
│  agent / extension                          │
│    └─ execFile("paplay", ["f.mp3"])         │
│         └─ /usr/local/bin/paplay            │
│            (symlink → hostbridge-client.js) │
│            │                                │
│            │  WebSocket                     │
│            │  ws://host:PORT/               │
└────────────┼────────────────────────────────┘
             │
┌────────────┼────────────────────────────┐
│  Host      │                            │
│            ▼                            │
│  hostbridge.js                          │
│    └─ spawn("afplay", ["f.mp3"])        │
│                                         │
└─────────────────────────────────────────┘
```

Each command invocation creates one WebSocket connection. The connection
lifetime matches the process lifetime. When the connection closes, the
process is killed.

## Protocol

All messages are JSON text frames over WebSocket.

### Client → Server

| Message | Fields | Description |
|---------|--------|-------------|
| `exec` | `cmd`, `args` | **First message.** Start the command. |
| `stdin` | `data` (base64) | Write data to the process stdin. |
| `stdin-end` | — | Close the process stdin (EOF). |
| `signal` | `signal` | Send a signal (`SIGINT`, `SIGTERM`, etc.). |

### Server → Client

| Message | Fields | Description |
|---------|--------|-------------|
| `pending` | `message` | Command requires host approval; waiting for user. |
| `started` | — | Process spawned successfully. |
| `stdout` | `data` (base64) | Chunk of stdout output. |
| `stderr` | `data` (base64) | Chunk of stderr output. |
| `exit` | `code` | Process exited. Connection closes after this. |
| `error` | `message` | Pre-spawn error (bad command, validation, denied, etc.). |

All `data` fields are base64-encoded to handle binary content (audio, images,
clipboard data).

### Example: prompted command (xdg-open)

```
Client                              Server
  │                                   │
  ├─ {type:"exec",                    │
  │   cmd:"xdg-open",                 │
  │   args:["https://..."]}          ─►│ access check → prompt
  │                                   │
  │◄── {type:"pending",                │ show Glimpse dialog
  │     message:"Waiting for..."}      │
  │                                   │
  │    ... user clicks Allow ...       │
  │                                   │
  │◄── {type:"started"}               │ spawn open https://...
  │                                   │
  │◄── {type:"exit", code:0}          │
```

### Example: fire-and-forget (paplay)

```
Client                              Server
  │                                   │
  ├─ {type:"exec",                    │
  │   cmd:"paplay",                   │
  │   args:["music.mp3"]}          ──►│ spawn afplay music.mp3
  │                                   │
  │◄── {type:"started"}               │
  │                                   │
  ├─ {type:"stdin-end"}            ──►│ close stdin
  │                                   │
  │    ... audio plays ...            │
  │                                   │
  │◄── {type:"exit", code:0}          │
  │◄── [connection close]             │
```

### Example: stdin piping (pbcopy)

```
Client                              Server
  │                                   │
  ├─ {type:"exec",                    │
  │   cmd:"pbcopy", args:[]}       ──►│ spawn pbcopy
  │                                   │
  │◄── {type:"started"}               │
  │                                   │
  ├─ {type:"stdin",                   │
  │   data:"SGVsbG8="}             ──►│ write "Hello" to stdin
  ├─ {type:"stdin-end"}            ──►│ close stdin
  │                                   │
  │◄── {type:"exit", code:0}          │
```

### Example: bidirectional streaming (glimpse)

```
Client                              Server
  │                                   │
  ├─ {type:"exec",                    │
  │   cmd:"glimpse",                  │
  │   args:["--width","400"]}      ──►│ spawn glimpse --width 400
  │                                   │
  │◄── {type:"started"}               │
  │                                   │
  │◄── {type:"stdout",                │ glimpse binary sends ready
  │     data:"eyJ0eXBlIjoi..."}       │
  │                                   │
  ├─ {type:"stdin",                   │ send HTML to render
  │   data:"eyJ0eXBlIjoi..."}      ──►│
  │                                   │
  │◄── {type:"stdout",                │ user clicks button
  │     data:"eyJ0eXBlIjoi..."}       │
  │                                   │
  │    ... window stays open ...      │
  │                                   │
  ├─ {type:"stdin",                   │ close command
  │   data:"eyJ0eXBlIjoi..."}      ──►│
  │                                   │
  │◄── {type:"exit", code:0}          │
```

### Signal handling (Ctrl+C)

```
Client                              Server
  │                                   │
  │  SIGINT received                  │
  ├─ {type:"signal",                  │
  │   signal:"SIGINT"}             ──►│ kill(-pgid, SIGINT)
  │                                   │
  │◄── {type:"exit", code:130}        │
```

No job IDs, no separate cancel endpoint, no race conditions.

### Client disconnect

If the WebSocket closes unexpectedly (shim crash, network drop), the server
kills the process with SIGTERM, then SIGKILL after 2 seconds.

## Command Registry

Commands are opt-in listed in the `REGISTRY` object. Each entry maps a Linux
tool name to one or more host-side candidates with argument
validators/transformers.

| Command | Host candidates | Purpose |
|---------|----------------|---------|
| `paplay` / `aplay` / `play` | afplay, paplay, ffplay, mpv, aplay | Audio playback |
| `say` | say, spd-say, espeak | Text-to-speech |
| `notify-send` | osascript, notify-send | Desktop notifications |
| `xdg-open` | open, xdg-open | Open URLs in browser |
| `pbcopy` / `wl-copy` / `xclip` / `xsel` | pbcopy, wl-copy, xclip, xsel | Clipboard write |
| `glimpse` | glimpse (from glimpseui) | Native GUI dialogs/windows |

### Argument validation

Each command has a `transform` function that sanitizes arguments before
passing them to the host executable:

- **Audio**: accepts exactly one file path, strips all flags
- **TTS**: strips flags, passes positional text only
- **Notifications**: strips flags, passes title and body only
- **URLs**: requires exactly one `http(s)://` URL
- **Clipboard**: blocks read/output flags
- **Glimpse**: passes all args through (Glimpse validates internally)

### Adding a new command

Add an entry to `REGISTRY` in `hostbridge.js`:

```javascript
'my-tool': {
  timeout: 30_000,  // optional, default: 60s, 0 = no timeout
  candidates: {
    darwin: [
      { exec: 'host-tool-name', transform: (args) => {
        // validate and transform args
        return args;
      }},
    ],
    linux: [
      { exec: 'linux-tool-name', transform: (args) => args },
    ],
  },
},
```

Then add a symlink in `Dockerfile-parts/runtime`:

```dockerfile
for t in ... my-tool; do \
  ln -s hostbridge-client.js /usr/local/bin/$t; \
done
```

At startup, the server resolves each command to the first available candidate
on the current platform using `command -v`.

## Setup

### Host (macOS)

```bash
cd /path/to/hostbridge

# Install dependencies (ws + glimpseui)
npm install

# Start the bridge
./hostbridge.js
```

The server picks a random ephemeral port and writes it to
`.hostbridge-port`. The container reads this file to discover the
port.

### Container

The container image includes `hostbridge-client.js` symlinked as each tool name.
No container-side setup is needed beyond building the image.

For Glimpse support, set `GLIMPSE_BINARY_PATH=/usr/local/bin/glimpse` in the
container environment (done automatically by the Dockerfile). This tells the
`glimpseui` Node.js wrapper to use the hostbridge shim instead of looking for
a native binary.

### Glimpse

Glimpse (`glimpseui`) is included as a host-side dependency. After
`npm install`, the postinstall hook compiles the native binary for the host
platform. The hostbridge server finds it automatically.

Inside the container, install `glimpseui` normally (`npm install glimpseui`).
The postinstall will skip the native build (no Swift/Cocoa in Linux) — that's
expected. The `GLIMPSE_BINARY_PATH` env var routes all Glimpse calls through
the hostbridge shim.

## Environment Variables

### Server (host)

| Variable | Default | Description |
|----------|---------|-------------|
| `HOSTBRIDGE_PORT_FILE` | `.hostbridge-port` | Path to write the listening port |
| `HOSTBRIDGE_CONFIG_FILE` | *(none)* | YAML config with `hostbridge` key |
| `HOSTBRIDGE_STATE_FILE` | `.hostbridge-state.yaml` | Persistent access state |
| `HOSTBRIDGE_DEBUG` | `0` | Set to `1` for debug logging |

### Shim (container)

| Variable | Default | Description |
|----------|---------|-------------|
| `HOSTBRIDGE_HOST` | `host.docker.internal` | Hostname of the bridge server |
| `HOSTBRIDGE_PORT` | *(from port file)* | Override port (skips port file) |
| `HOSTBRIDGE_PORT_FILE` | `.hostbridge-port` | Path to read the server port |
| `HOSTBRIDGE_DEBUG` | `0` | Set to `1` for debug logging |
| `GLIMPSE_BINARY_PATH` | *(not set)* | Path to Glimpse shim for glimpseui wrapper |

## Debugging

Enable debug logging on both sides:

```bash
# Host
HOSTBRIDGE_DEBUG=1 ./hostbridge.js

# Container
HOSTBRIDGE_DEBUG=1 paplay file.mp3
```

The server logs each command execution, signal, and lifecycle event. The shim
logs connection state and message flow.

## Access Control

Commands are classified into three access levels:

| Level | Behavior |
|-------|----------|
| `allow` | Run immediately, no prompt |
| `deny` | Reject immediately |
| `prompt` | Show a native Glimpse dialog on the host asking the user |

### Config: `hostbridge.rules` in YAML config

Access rules live under `hostbridge.rules` in the YAML config file
(passed via `--config-file`). Rules use the same format as the state file.
Commands not matched default to `prompt`.

```yaml
hostbridge:
  rules:
    - cmd: notify-send
      access: allow
      args: any
      scope: always
    - cmd: paplay
      access: allow
      args: any
      scope: always
    - cmd: xdg-open
      access: prompt
      args: any
      scope: always
```

The config is **re-read on every command invocation**, so changes take effect
immediately without restarting hostbridge.

Config rules support the same arg-specific matching as state rules — you can
allow specific URLs while prompting for others.

Aliases (e.g., `aplay` → `paplay`) are not resolved in config rules; list
each command name you want to match.

### State file: `.hostbridge-state.yaml`

Re-read on every access check. Stores user decisions from the prompt dialog.

```yaml
# Hostbridge access decisions
# Edit or delete entries to change behavior
# Session entries (with pid) expire when their hostbridge process exits

rules:
  # Always allow paplay with any arguments
  - cmd: paplay
    access: allow
    args: any
    scope: always

  # Allow this specific URL always
  - cmd: xdg-open
    access: allow
    args:
      - "https://docs.example.com"
    scope: always

  # Deny pbcopy for this session only
  - cmd: pbcopy
    access: deny
    args: any
    scope: session
    pid: 12345
```

Each rule has:

| Field | Values | Description |
|-------|--------|-------------|
| `cmd` | command name | The invoked command |
| `access` | `allow` / `deny` | Whether to permit the command |
| `args` | `any` or `[...]` | Match any args, or only this specific arg list |
| `scope` | `always` / `session` | `always` persists across restarts; `session` expires with the PID |
| `pid` | number | Only for `session` scope: the hostbridge PID |

Specific-args rules take priority over any-args rules for the same command.

At startup, stale session entries (from dead PIDs) are automatically cleaned
up. Delete the file to reset all decisions.

### Resolution order

1. Re-read config rules (`hostbridge.rules` from the config file)
2. Find matching rule (specific args first, then any-args)
3. If config match says `allow` or `deny` → immediate answer
4. Otherwise (`prompt` or no match → default `prompt`):
   a. Re-read `.hostbridge-state.yaml`
   b. Find matching rule (specific args first, then any-args)
   c. If found → use it
   d. Otherwise → show interactive prompt dialog

### Prompt dialog

When a command requires approval, a native Glimpse dialog appears on the host
showing the command and arguments with three dropdowns:

| Dropdown | Options | Description |
|----------|---------|-------------|
| **Action** | Allow, Deny | Permit or reject |
| **Scope** | Once, This Session, Always | How long the decision lasts |
| **Args** | Only These Args, Any Args | Match this specific invocation or any |

Keyboard: Enter = Confirm, Escape = Cancel (deny once).

| Scope | Behavior |
|-------|----------|
| Once | No state saved. Applies to this invocation only. |
| This Session | Saved to state file with the hostbridge PID. Expires on restart. |
| Always | Saved to state file permanently. Survives restarts. |

If Glimpse is not available and a command requires prompting, it is denied.

While waiting for the user, the client receives a `pending` message so it can
show a status indicator.

## Security

The hostbridge is a deliberate escape hatch from the container sandbox.
Security is enforced by:

1. **Command opt-in list** — only registered commands can be executed
2. **Access control** — commands can be auto-allowed, auto-denied, or
   prompted via native dialog
3. **Argument validation** — each command's `transform` function sanitizes
   inputs (stripping flags, validating URLs, blocking clipboard reads)
4. **Localhost only** — the server binds to `127.0.0.1`
5. **Process isolation** — each command runs in its own process group;
   disconnect kills it
6. **Timeouts** — commands are killed after a configurable timeout (default
   60s, configurable per command, disabled for interactive commands like
   Glimpse)
