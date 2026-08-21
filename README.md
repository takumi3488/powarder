# powarder

`powarder` is a CLI that treats SSH local/remote port forwards (`ssh -L` /
`ssh -R`) as "named, managed objects" -- the same way Docker treats
containers -- backed by a daemon that keeps them alive in the background.

## What is this?

If you've ever used plain `ssh -N -L 8080:localhost:80 bastion`, you've
probably run into frustrations like these:

- Close the terminal (or let the SSH session drop) and the forward dies with it
- A brief network blip happens and it never reconnects on its own
- No way to see how many tunnels you currently have up, e.g. via `ps`
- Retyping the same long command every time (or digging through shell history)

`powarder` solves these problems the same way Docker solves process
management with the "container" abstraction: you name each tunnel and
declare it in `powarder.json`, a background daemon brings them all up
together via `powarder up` or at autostart, and if one dies it automatically
reconnects -- while you watch its state via `ps`, which reports statistics
(connection count, bytes transferred).

**How this differs from `autossh`**: `autossh` only does "keep-alive
monitoring for a single ssh connection." It has no way to list across
multiple tunnels, no name-based management, and no per-connection
statistics (run several `autossh` instances side by side and you just get
independent processes with no way to see the big picture). The essential
difference with `powarder` is that a single daemon centrally manages
multiple tunnels across multiple hosts, and `ps` / `hosts` / `inspect` let
you see the whole picture at a glance.

## Installation

### Quick install

`powarder` is distributed as prebuilt binaries via GitHub Releases. Install
(or upgrade) it with:

```bash
curl -fsSL https://raw.githubusercontent.com/takumi3488/powarder/main/install.sh | sh
```

The script detects your OS and architecture, downloads the matching release
asset, and installs the binary. Two environment variables control where it
puts things and which version it fetches:

| Variable | Description | Default |
|---|---|---|
| `POWARDER_INSTALL_DIR` | Directory to install the `powarder` binary into | `${XDG_BIN_HOME:-$HOME/.local/bin}` |
| `POWARDER_VERSION` | Release version to install, e.g. `v0.2.0` | the latest release |

For example, to install into a shared system location instead:

```bash
curl -fsSL https://raw.githubusercontent.com/takumi3488/powarder/main/install.sh | POWARDER_INSTALL_DIR=/usr/local/bin sh
```

Since `/usr/local/bin` typically isn't writable by a regular user, you may
need to run this with elevated privileges (e.g. via `sudo`) for the install
to succeed.

### Supported platforms

Prebuilt binaries are published for:

| OS | Architecture |
|---|---|
| macOS | Apple Silicon (arm64) |
| Linux | x86_64 |
| Linux | arm64 |

**No binary is published for Intel Macs (darwin x86_64).** If that's your
platform, see "Building from source" below.

Linux binaries are built on Ubuntu and dynamically linked against glibc, so
they may fail to run on distributions with a much older glibc.

### Manual download

If you'd rather not pipe a script into `sh`, download a release archive
directly from the
[releases page](https://github.com/takumi3488/powarder/releases). Each release publishes
`powarder-darwin-arm64.tar.gz`, `powarder-linux-x86_64.tar.gz`, and
`powarder-linux-arm64.tar.gz`, plus a `SHA256SUMS` file for verifying the
archive before you extract it and put the binary on your `$PATH`. The release
workflow also creates a GitHub artifact attestation for each binary.

After extracting an archive, verify the binary's attestation with the GitHub
CLI:

```bash
gh attestation verify powarder \
  -R takumi3488/powarder \
  --signer-workflow takumi3488/powarder/.github/workflows/release.yml
```

### Updating

`powarder update` fetches the latest release and replaces the running
binary in place, by re-invoking `install.sh` targeting the same directory
the current executable lives in.

```console
$ powarder update --check
update available: 0.1.0 -> 0.2.0 (run 'powarder update' to install it)

$ powarder update
==> Detected platform: darwin-arm64
==> Installing the latest powarder release
==> Downloading https://github.com/takumi3488/powarder/releases/latest/download/powarder-darwin-arm64.tar.gz
==> Checksum OK for powarder-darwin-arm64.tar.gz.
==> Installed /Users/you/.local/bin/powarder
powarder 0.2.0
✔ update complete
```

`--check` only queries the GitHub releases API and reports what it finds; it
never downloads or replaces anything. Everything after it is install.sh's own
output, since `powarder update` hands the download, checksum verification,
and atomic replacement over to the very same script a fresh install runs.
Pass `--to <VERSION>` (e.g. `powarder update --to v0.1.5`) to install a
specific release instead of the latest one.

If the daemon is currently running, it keeps the previously-loaded binary in
memory until restarted -- `powarder update` says so on completion, and
`powarder daemon restart` picks up the new version.

## Usage

First, with no config at all, let's bring up a single tunnel ad hoc (the
syntax is nearly identical to `ssh -L`).

```console
$ powarder run -L 8080:localhost:80 prod-bastion
✔ tunnel "web1" started (-L 127.0.0.1:8080 -> localhost:80 via prod-bastion)
```

Declare tunnels in `~/.config/powarder/config.json` (or `./powarder.json`)
and you can start/stop them all at once.

```console
$ powarder up
✔ tunnel "web1" started
✔ tunnel "db1" started

$ powarder ps
NAME  TYPE  BIND             TARGET           HOST          CONNS  RX/TX      LAST  UPTIME  STATUS
web1  -L    127.0.0.1:18001  localhost:8001   localhost     0      83B/204B   1s    3s      active
db1   -L    127.0.0.1:15432  db.internal:5432 prod-bastion  2      1.2kB/512B 5s    3s      active

$ powarder hosts
HOST          STATE        TUNNELS  PID    UPTIME  RETRIES
prod-bastion  hsConnected  2        41213  3s      0

$ powarder logs -f web1
# tail -f the ssh master's -v log as-is (Ctrl-C to exit)

$ powarder down
✔ tunnel "web1" stopped
✔ tunnel "db1" stopped
```

Use `prune` when you want to clean up stopped tunnels in one go (regardless
of `-a`, it looks at every stopped tunnel and removes them all).

```console
$ powarder prune
✔ tunnel "web1" removed
```

See `powarder help` for the full list of subcommands, and
`powarder help <command>` for the options of an individual command.

### Registering as a background service

If you want the daemon to keep running independently of any terminal or
login session, you can register it with your OS's service manager.

```console
$ powarder daemon install
✔ installed "dev.powarder.daemon" -> /Users/you/Library/LaunchAgents/dev.powarder.daemon.plist (running)

$ powarder daemon uninstall
✔ uninstalled "dev.powarder.daemon"
```

- macOS: generates `~/Library/LaunchAgents/dev.powarder.daemon.plist` and
  registers it with `launchctl bootstrap`.
- Linux: generates `~/.config/systemd/user/powarder.service` and registers
  it with `systemctl --user enable --now`. **If you haven't run
  `loginctl enable-linger $USER`, the systemd user manager -- and your
  tunnels along with it -- will stop as soon as you log out** (`daemon
  install` / `daemon status` print this warning for you).

macOS release binaries are Developer ID signed and notarized before
publication. The release workflow requires the repository secrets
`APPLE_CERTIFICATE_BASE64`, `APPLE_CERTIFICATE_PASSWORD`,
`APPLE_SIGNING_IDENTITY`, `APPLE_NOTARY_APPLE_ID`,
`APPLE_NOTARY_PASSWORD`, and `APPLE_TEAM_ID`. Unsigned or ad-hoc binaries
may run from a shell but can be rejected by launchd.

`powarder daemon install` waits for the service manager to report the daemon
as running and returns a failure status if startup does not complete.

## Config file

Example of `~/.config/powarder/config.json` (overridable via
`POWARDER_CONFIG`; a `powarder.json` in the current directory takes
priority if one exists):

```jsonc
{
  "version": 1,
  "tunnels": [
    {
      "name": "prod-db",
      "host": "prod-bastion",
      "type": "L",
      "forward": "15432:db.internal:5432",
      "autostart": true,
      "profile": "prod"
    },
    {
      "name": "webhook",
      "host": "dev-box",
      "type": "R",
      "forward": "8443:localhost:3000"
    }
  ]
}
```

| Field | Description |
|---|---|
| `name` | Unique tunnel name, referenced by `ps` / `start` / `stop` / `rm`, etc. |
| `host` | A `Host` alias from `~/.ssh/config` |
| `type` | `"L"` (local forward) or `"R"` (remote forward) |
| `forward` | ssh-compatible `[bind_address:]port:host:hostport` |
| `autostart` | Whether to start automatically with `powarder up` (defaults to `false` if omitted) |
| `profile` | A tag used to selectively start tunnels via `powarder up --profile X` |
| `sshExtraArgs` | Extra ssh options to pass when starting the master (optional) |
| `retry` | Reconnect backoff settings (optional) |

**Profiles persist across daemon restarts**: the set of profiles activated
with `powarder up --profile X` is remembered by the daemon and persisted
in its state file, so it is restored when the daemon restarts (at login
via launchd/systemd, or after `powarder daemon restart`) -- tunnels tagged
with an active profile and `autostart: true` come back on their own.
Each `powarder up --profile X` replaces the remembered set rather than
adding to it, and a bare `powarder up` leaves the remembered set alone.
Passing `--profile` to `powarder daemon` wins over whatever was remembered
(the two are never merged) and, like `powarder up --profile X`, replaces
the remembered set from then on -- a daemon started with `--profile prod`
leaves `prod` in the state file for later bare restarts.

**Division of responsibility with `~/.ssh/config`**: `powarder.json`
deliberately has no fields equivalent to `user` / `port` / `identityFile` /
`proxyJump`. The schema enforces this split at the type level: connection
routing and authentication (username, port number, key file, `ProxyJump`
through a bastion) are the responsibility of `~/.ssh/config`, while
`powarder.json` is responsible only for the forwarding topology -- which
local port gets forwarded where. Including these keys won't cause a fatal
error, but you'll get a warning telling you to move them into
`~/.ssh/config` instead.

## How it works

`powarder` doesn't implement the SSH protocol itself. It launches the
`ssh` binary directly as a **ControlMaster**, and each individual forward
is attached to the already-running master afterward via `ssh -O forward`.

- **One host = one long-lived master.** Multiple tunnels that point at the
  same `Host` in `~/.ssh/config` share a single master connection. "Same
  host" isn't decided by comparing host name strings -- it's decided by a
  fingerprint built from the resolved output of `ssh -G <host>` (every
  setting that actually ends up in effect). So even if `ProxyJump` or
  `IdentityFile` changes through `Host` block inheritance, tunnels that
  genuinely resolve to the same destination are still correctly
  consolidated into a single connection.
- **Authentication, keys, and key exchange are left entirely to OpenSSH.**
  The master is started with a plain `ssh -M -N ...`, so anything your
  local `ssh` already supports -- `ProxyJump`, certificate authentication,
  FIDO2/security keys, the latest key-exchange algorithms -- works with
  powarder too. powarder never has to build its own logic for "how do we
  make authentication work."
- **For `-L`, powarder inserts a thin TCP proxy.** powarder itself listens
  on the local port you specified, and the actual forward runs over a Unix
  domain socket that ssh sets up, with powarder relaying between the two.
  The reason is simple: the ssh mux protocol has no way to report
  connection counts or bytes transferred. By putting its own proxy between
  the client and itself, powarder can actually measure the `CONNS` /
  `RX/TX` statistics shown in `ps`.
- **`-R` can't get statistics at all.** Because the remote side does the
  listening in this configuration, powarder has no way to sit in the data
  path, so it fundamentally has no way to know connection counts or byte
  counts (these columns show `-` in `ps`). Health checking for `-R` can
  only rely on "is the master still alive."
- **Health checks mostly piggyback on real traffic (Tier 3).** Periodic
  active probing (Tier 2, opt-in via `--probe`) always forces a real
  connection to the destination and adds noise to the destination's logs,
  so it's disabled by default. Instead, powarder tracks how many times a
  real client connection failed to reach upstream and uses that to judge
  unhealthiness. The upside is that the busier a forward's traffic, the
  faster it detects problems.

## Troubleshooting

- **Non-interactive authentication is assumed.** The daemon has no TTY and
  always connects with `BatchMode=yes`. It can't be used with hosts that
  require password authentication or interactive MFA. Set up your keys in
  advance and make sure they're already unlocked in `ssh-agent`.
- **`SSH_AUTH_SOCK` is not inherited when launched via launchd/systemd.**
  Environment variables from your interactive shell session (including
  `PATH`) are not passed down to a daemon started as an OS service. `PATH`
  is given a minimal explicit value in the plist/unit file, but
  `SSH_AUTH_SOCK` (the ssh-agent socket path) fundamentally cannot be
  resolved that way. If your keys are managed by an agent, authentication
  may fail when the daemon is started via `daemon install`. On macOS, you
  can work around this by setting `UseKeychain yes` in `~/.ssh/config` and
  storing the key in the macOS Keychain instead.
- **`powarder logs <name>` gives you the corresponding ssh master's raw
  `-v` log, unfiltered.** This is the last resort for debugging. Even
  while the daemon is stopped, the log files themselves remain under
  `~/.local/state/powarder/logs/` and can be read directly.
- **Error messages are localized based on your locale, but the raw ssh
  output is always included alongside them.** This is a safety net for
  cases where the localized text alone isn't enough to diagnose the
  problem.
- **`-R` health checks are weak.** Because the remote side does the
  listening in this configuration, powarder has no way to check from its
  own side whether that listener is actually still alive. Use it knowing
  that the only guarantee available is "the master connection is alive" --
  nothing stronger.

## Known limitations

- Assumes a non-privileged user (macOS LaunchAgent, Linux
  `systemctl --user`). Binding to privileged ports below 1024, or sharing
  a single daemon across multiple OS users, is out of scope.
- After editing `~/.ssh/config`, run `powarder daemon reload` (the daemon
  caches the config it read at startup).
- macOS's `sockaddr_un.sun_path` has a 104-byte limit, so the runtime
  directory (where IPC sockets and ControlPath live) can't be nested too
  deeply. If it is, specify a shorter path explicitly with
  `POWARDER_RUNTIME_DIR`.

## Building from source

If you're on a platform without a prebuilt binary (Intel Macs, for
instance) or want to hack on `powarder` itself, you can build it directly
with Nim instead of using the prebuilt binaries described above.

`powarder` is written in Nim 2.2.10 and has **zero external nimble package
dependencies** (only `std/*`), so the Nim toolchain is the only thing you
need.

If you use [mise](https://mise.jdx.dev/):

```bash
mise plugins install nim https://github.com/mise-plugins/mise-nim
mise install nim@2.2.10
```

Then clone and build:

```bash
git clone https://github.com/takumi3488/powarder.git
cd powarder
mise exec -- nimble build -y
```

This produces the `./powarder` binary. Put it somewhere on your `$PATH`
(e.g. `mv powarder ~/.local/bin/`).
