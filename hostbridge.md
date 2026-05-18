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
| `started` | — | Process spawned successfully. |
| `stdout` | `data` (base64) | Chunk of stdout output. |
| `stderr` | `data` (base64) | Chunk of stderr output. |
| `exit` | `code` | Process exited. Connection closes after this. |
| `error` | `message` | Pre-spawn error (bad command, validation, etc.). |

All `data` fields are base64-encoded to handle binary content (audio, images,
clipboard data).

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

Then add a symlink in `Dockerfile-parts/hostbridge`:

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

## Security

The hostbridge is a deliberate escape hatch from the container sandbox.
Security is enforced by:

1. **Command opt-in list** — only registered commands can be executed
2. **Argument validation** — each command's `transform` function sanitizes
   inputs (stripping flags, validating URLs, blocking clipboard reads)
3. **Localhost only** — the server binds to `127.0.0.1`
4. **Process isolation** — each command runs in its own process group;
   disconnect kills it
5. **Timeouts** — commands are killed after a configurable timeout (default
   60s, configurable per command, disabled for interactive commands like
   Glimpse)
