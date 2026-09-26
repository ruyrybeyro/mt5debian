# Security Notes

## Isolation between OS users running separate copies

Running multiple copies of `mt5debian.sh` for different people on the same
box (see [Running multiple copies](README.md#running-multiple-copies))
gives each one its own OS user, home directory, and Wine prefix, with its
own set of ports — but that's process/filesystem separation by
convention, not a hard security boundary.

`/proc` is visible across users on a default Debian or Ubuntu install
(`hidepid=0`), so e.g. the script's own `pgrep`-based "is MT5 already
running" checks can in principle see another user's process, not just
your own.

This is fine for cooperating/trusted users sharing a box. If you ever need
to run this for **mutually untrusted** users, revisit that assumption:

- mount `/proc` with `hidepid=2`, or
- move to real isolation — a Linux namespace/container per user, or
  `systemd-nspawn` — rather than relying on OS-user separation alone.

Neither is implemented by this script.
