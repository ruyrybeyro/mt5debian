# Security Notes

## Transient files live outside /tmp

Downloaded installers, the noVNC pid file, and the terminal/bridge logs
are all written under a private per-user directory —
`$XDG_RUNTIME_DIR/mt5debian` when set, otherwise `$HOME/.cache/mt5debian`,
created with mode `700` — rather than `/tmp`.

`/tmp` is world-writable and shared machine-wide, so a predictable `/tmp`
path (e.g. `/tmp/novnc-5901.pid`, or `/tmp/mt5setup.exe` in the window
before it's handed to `wine`) is a symlink-attack target for any other
local user: `stop_by_pidfile()`'s `kill "$(cat "$pidfile")"` trusts that
file's content, and a downloaded installer redirected through a
pre-planted symlink can be made to overwrite an arbitrary file the
invoking user can write to. A private, mode-`700` directory that only
this user can write into removes that attack surface entirely.

## Isolation between OS users running separate copies

Running multiple copies of `mt5debian.sh` for different people on the same
box (see [Running multiple copies](README.md#running-multiple-copies))
gives each one its own OS user, home directory, and Wine prefix, with its
own set of ports — but that's process/filesystem separation by
convention, not a hard security boundary.

`/proc` is visible across users on a default Debian or Ubuntu install
(`hidepid=0`), so any user can inspect another's running processes (via
`ps aux`, or reading `/proc/<pid>/cmdline` directly) — a general
information-disclosure exposure that isn't something this script can fix
on its own. The script's own process checks (is MT5 already running,
stopping a stale `pymt5linux` bridge) are scoped to the current user via
`pgrep -u "$UID"`/`pkill -u "$UID"`, so they specifically don't get
confused by another user's same-named process — but that's a correctness
fix for this script's own logic, not a change to `/proc`'s underlying
visibility.

This is fine for cooperating/trusted users sharing a box. If you ever need
to run this for **mutually untrusted** users, revisit that assumption:

- mount `/proc` with `hidepid=2`, or
- move to real isolation — a Linux namespace/container per user, or
  `systemd-nspawn` — rather than relying on OS-user separation alone.

Neither is implemented by this script.
