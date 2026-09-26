#!/bin/bash
# Copyright 2026, Rui Ribeiro
# Written with the assistance of Claude

#PATH=$PATH:~/.local/bin

set -Eeuo pipefail

# Private per-user directory for every transient file this script writes
# (downloaded installers, pid files, logs) — not /tmp: /tmp is
# world-writable and shared machine-wide, so a predictable /tmp path
# (e.g. /tmp/novnc-5901.pid, or /tmp/mt5setup.exe before it's handed to
# `wine`) is a symlink-attack target for any other local user, and
# stop_by_pidfile()'s `kill "$(cat ...)"` further down reads that file's
# content back on trust. $XDG_RUNTIME_DIR (when set, e.g. under a logind
# session) is already private (mode 0700) and per-user; $HOME/.cache is
# the fallback for a plain SSH session without one — chmod'd explicitly
# since umask isn't guaranteed restrictive enough on its own. Set up
# before the root/sudo checks below so it's always defined by the time
# the EXIT trap could fire, even on the earliest failure path.
RUNTIME_DIR="${XDG_RUNTIME_DIR:-$HOME/.cache}/mt5debian"
mkdir -p "$RUNTIME_DIR"
chmod 700 "$RUNTIME_DIR"

# Cleans up downloaded installer files on any exit — success, an early
# ERROR/exit 1, or an interrupt — rather than relying on rm -f calls
# scattered after each individual use, which only run if that point in
# the script is actually reached.
cleanup_temp_files() {
    rm -f "$RUNTIME_DIR/winehq.key" "$RUNTIME_DIR/python-installer.exe" "$RUNTIME_DIR/mt5setup.exe" "$RUNTIME_DIR/webview2.exe"
}
trap cleanup_temp_files EXIT

# This script must run as a normal user, not root: Wine explicitly
# refuses to run as root, and every path here ($HOME/.mt5,
# $HOME/.config/tigervnc, etc.) assumes a real user's home directory.
# It still needs sudo for the apt/dpkg/keyring steps, so check that
# up front too, rather than failing confusingly partway through.
if [ "$(id -u)" -eq 0 ]; then
    echo "ERROR: do not run this script as root or via sudo. Run it as a normal user with sudo privileges instead (see README: User & permissions)." >&2
    exit 1
fi

if ! sudo -v; then
    echo "ERROR: this user does not have sudo privileges, which this script needs for apt/dpkg steps (see README: User & permissions)." >&2
    exit 1
fi

usage() {
    cat << 'USAGE'
Usage: mt5debian.sh [-p|--password password] [-P|--viewonly-password password]
                    [-w|--wine-version stable|staging|devel] [--stock-wine]
                    [-n|--novnc-port port] [-b|--bridge-port port]
                    [-v|--vnc-port port]
                    [--purge] [-h|--help]
  -p, --password             VNC password. Sets it non-interactively,
                              overwriting any existing one. If omitted,
                              an existing password is left alone; if none
                              exists yet, you're prompted interactively
                              via vncpasswd (and asked whether to also set
                              a view-only password).
  -P, --viewonly-password    VNC view-only password. Only used together
                              with -p/--password.
  -w, --wine-version         Force the Wine channel (stable, staging, or
                              devel), overriding the default (staging).
                              Mutually exclusive with --stock-wine.
  --stock-wine               Install the distro's own "wine" package
                              instead of adding the WineHQ apt repo.
                              Mutually exclusive with -w/--wine-version.
  -n, --novnc-port           noVNC web port, overriding the default
                              (6080).
  -b, --bridge-port          pymt5linux bridge port, overriding the
                              default (8001).
  -v, --vnc-port             Raw VNC (RFB) port, overriding the default
                              (5901). Must be > 5900 — internally mapped
                              to a TigerVNC display number as port-5900,
                              e.g. 5901 is display :1. Also change
                              -n/--novnc-port if running a second copy on
                              the same host, since noVNC connects to this
                              port on localhost.
  --purge                    Kill any running Wine process for this
                              prefix and delete it ($HOME/.mt5), then
                              continue as a clean reinstall. Does not
                              touch the VNC password or apt/Wine package
                              installation.
  -h, --help                 Show this help and exit.
USAGE
}

PARSED_OPTS=$(getopt --options p:P:w:n:b:v:h --longoptions password:,viewonly-password:,wine-version:,stock-wine,novnc-port:,bridge-port:,vnc-port:,purge,help --name "mt5debian.sh" -- "$@") \
    || { usage; exit 1; }
eval set -- "$PARSED_OPTS"

VNC_PASSWORD=""
VNC_VIEWONLY_PASSWORD=""
WINE_VERSION_OVERRIDE=""
STOCK_WINE=""
NOVNC_PORT_OVERRIDE=""
MT5SERVER_PORT_OVERRIDE=""
VNC_PORT_OVERRIDE=""
PURGE=""
while true; do
    case "$1" in
        -p|--password) VNC_PASSWORD="$2"; shift 2 ;;
        -P|--viewonly-password) VNC_VIEWONLY_PASSWORD="$2"; shift 2 ;;
        -w|--wine-version) WINE_VERSION_OVERRIDE="$2"; shift 2 ;;
        --stock-wine) STOCK_WINE=1; shift ;;
        -n|--novnc-port) NOVNC_PORT_OVERRIDE="$2"; shift 2 ;;
        -b|--bridge-port) MT5SERVER_PORT_OVERRIDE="$2"; shift 2 ;;
        -v|--vnc-port) VNC_PORT_OVERRIDE="$2"; shift 2 ;;
        --purge) PURGE=1; shift ;;
        -h|--help) usage; exit 0 ;;
        --) shift; break ;;
        *) usage; exit 1 ;;
    esac
done

case "$WINE_VERSION_OVERRIDE" in
    ""|stable|staging|devel) ;;
    *)
        echo "ERROR: -w/--wine-version must be stable, staging, or devel (got: $WINE_VERSION_OVERRIDE)"
        exit 1
        ;;
esac

if [ -n "$STOCK_WINE" ] && [ -n "$WINE_VERSION_OVERRIDE" ]; then
    echo "ERROR: -w/--wine-version and --stock-wine are mutually exclusive"
    exit 1
fi

is_valid_port() {
    [[ "$1" =~ ^[0-9]+$ ]] && [ "$1" -ge 1 ] && [ "$1" -le 65535 ]
}

if [ -n "$NOVNC_PORT_OVERRIDE" ] && ! is_valid_port "$NOVNC_PORT_OVERRIDE"; then
    echo "ERROR: -n/--novnc-port must be a port number 1-65535 (got: $NOVNC_PORT_OVERRIDE)"
    exit 1
fi

if [ -n "$MT5SERVER_PORT_OVERRIDE" ] && ! is_valid_port "$MT5SERVER_PORT_OVERRIDE"; then
    echo "ERROR: -b/--bridge-port must be a port number 1-65535 (got: $MT5SERVER_PORT_OVERRIDE)"
    exit 1
fi

if [ -n "$VNC_PORT_OVERRIDE" ] && { ! is_valid_port "$VNC_PORT_OVERRIDE" || [ "$VNC_PORT_OVERRIDE" -le 5900 ]; }; then
    echo "ERROR: -v/--vnc-port must be a port number > 5900 (got: $VNC_PORT_OVERRIDE)"
    exit 1
fi

# Single source of truth for the Wine prefix path — every other spot in
# this script that needs it (purge, prefix creation, MT5_EXE/WEBVIEW2_DIR
# below) reads this instead of repeating the literal path.
WINEPREFIX="$HOME/.mt5"
export WINEPREFIX

if [ -n "$PURGE" ]; then
    echo "Purging existing Wine prefix ($WINEPREFIX)"
    wineserver -k 2>/dev/null || true
    rm -rf "$WINEPREFIX"
fi

# MetaTrader, WebView2, and Python-in-Wine download urls
URL_MT5="https://download.mql5.com/cdn/web/metaquotes.software.corp/mt5/mt5setup.exe"
# Microsoft's official "Get the Link" permalink for the Evergreen
# Bootstrapper — always resolves to the current installer, unlike a URL
# that embeds a specific CDN delivery GUID (see the old value below,
# which could go stale as Microsoft rotates those).
URL_WEBVIEW="https://go.microsoft.com/fwlink/p/?LinkId=2124703"
# URL_WEBVIEW="https://msedge.sf.dl.delivery.mp.microsoft.com/filestreamingservice/files/f2910a1e-e5a6-4f17-b52d-7faf525d17f8/MicrosoftEdgeWebview2Setup.exe"
# pymt5linux (PyPI) requires Python >=3.13 on both the Wine and Linux
# sides — using an older Windows Python here (e.g. 3.9.x) will make the
# Wine-side "pip install pymt5linux" fail with the exact same version
# error you'd see on Linux.
URL_PYTHON="https://www.python.org/ftp/python/3.13.15/python-3.13.15-amd64.exe"

# noVNC web port — browse to http://localhost:$NOVNC_PORT/vnc.html
# Override with -n/--novnc-port.
if [ -n "$NOVNC_PORT_OVERRIDE" ]; then
    NOVNC_PORT="$NOVNC_PORT_OVERRIDE"
else
    NOVNC_PORT="6080"
fi

# Raw VNC (RFB) port. Override with -v/--vnc-port. TigerVNC addresses
# displays, not ports directly — port 5900+N is display :N — so the
# display number used for vncserver/DISPLAY throughout is derived from
# this rather than hardcoded, letting a second copy of this script run
# under a different OS user on the same host without colliding on
# either the display number or the port.
if [ -n "$VNC_PORT_OVERRIDE" ]; then
    VNC_PORT="$VNC_PORT_OVERRIDE"
else
    VNC_PORT="5901"
fi
VNC_DISPLAY="$((VNC_PORT - 5900))"

# Suffixed by VNC_PORT, not a fixed name: RUNTIME_DIR is already private
# per OS user, but two copies of this script run by the *same* user with
# different ports (e.g. for testing) would otherwise still collide on
# this path. NOVNC_PID/its log and PYMT5LINUX_LOG below use the same
# VNC_PORT suffix for the same reason.
MT5_TERMINAL_LOG="$RUNTIME_DIR/mt5-terminal-$VNC_PORT.log"

. /etc/os-release

# Wine channel to install: stable, staging, or devel. staging confirmed
# working on Debian and Ubuntu. Force a different channel with
# -w/--wine-version.
if [ -n "$WINE_VERSION_OVERRIDE" ]; then
    WINE_VERSION="$WINE_VERSION_OVERRIDE"
else
    WINE_VERSION="staging"
fi

# mt5linux bridge — lets external Python code drive the terminal via RPyC.
# Port matches the FreeBSD mt5jail bridge for consistency by default.
# Override with -b/--bridge-port.
if [ -n "$MT5SERVER_PORT_OVERRIDE" ]; then
    MT5SERVER_PORT="$MT5SERVER_PORT_OVERRIDE"
else
    MT5SERVER_PORT="8001"
fi

# Three independent services bound to three configured ports — a
# collision would mean one silently fails to bind (or worse, two
# services fighting over the same port), so catch it up front rather
# than as a confusing runtime failure later.
if [ "$NOVNC_PORT" = "$VNC_PORT" ] || [ "$NOVNC_PORT" = "$MT5SERVER_PORT" ] || [ "$VNC_PORT" = "$MT5SERVER_PORT" ]; then
    echo "ERROR: -n/--novnc-port, -v/--vnc-port, and -b/--bridge-port must all be different (got: $NOVNC_PORT, $VNC_PORT, $MT5SERVER_PORT)"
    exit 1
fi

# Suffixed by VNC_PORT (not MT5SERVER_PORT) for consistency with
# MT5_TERMINAL_LOG/NOVNC_PID above/below: same reason.
PYMT5LINUX_LOG="$RUNTIME_DIR/pymt5linux-server-$VNC_PORT.log"
# RPyC has no built-in auth, so don't bind wider than you need. Defaults to
# loopback only. If the mt5jail-side client (or anything else) needs to
# reach this bridge across the network, set this to this VM's specific
# homelab address (e.g. its vm.srv.bsd DHCP-assigned IP) — not 0.0.0.0 —
# and firewall the port to the intended source.
MT5SERVER_HOST="127.0.0.1"

# Silences Wine's very chatty fixme:/err: debug spam on stderr.
export WINEDEBUG=-all
# Silences "libEGL warning: DRI3 error..." — expected and harmless on a
# headless Xvnc session with no real GPU (software rendering via
# libosmesa6 is what's actually used). Log-level only, doesn't affect
# rendering.
export EGL_LOG_LEVEL=fatal

# Stops a background process this script previously started, using a PID
# file rather than `pkill -f <pattern>` — pattern matching against the
# process list can hit unrelated processes that happen to share the same
# command-line substring.
stop_by_pidfile() {
    local pidfile="$1"
    if [ -f "$pidfile" ] && kill -0 "$(cat "$pidfile")" 2>/dev/null; then
        kill "$(cat "$pidfile")" 2>/dev/null || true
    fi
    rm -f "$pidfile"
}

echo "OS: $NAME $VERSION_ID"

# Avoid apt/needrestart blocking on interactive dialogs (service-restart
# prompts, debconf questions) — this is the most common cause of a
# script that looks "hung" but is just waiting on a keypress with no tty.
export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a

# A Debian install from DVD/CD media leaves a "deb cdrom:[...]" line in
# sources.list pointing at that media. With no drive present, apt refuses
# to update from it (no Release file) and prints a scary-looking but
# harmless error/notice on every apt update — comment it out rather than
# leaving that to trip up an unattended run. Idempotent: already-commented
# lines don't match "^deb cdrom:" on a rerun.
if [ -f /etc/apt/sources.list ] && grep -q '^deb cdrom:' /etc/apt/sources.list; then
    echo "Disabling stale cdrom: apt source (no DVD/CD-ROM drive present)"
    sudo sed -i 's|^deb cdrom:|# Disabled by mt5debian.sh (no drive present): deb cdrom:|' /etc/apt/sources.list
fi

# All apt packages the script needs, checked up front. If every one of
# these plus wine is already present, the whole apt update / repo setup /
# install block below is skipped entirely — no needless network calls or
# apt runs on a rerun where nothing changed.
APT_PKGS=(
    wget
    curl
    gnupg
    iproute2
    tigervnc-standalone-server
    novnc
    websockify
    x11-utils
    libgl1
    libglx-mesa0
    libegl1
    libosmesa6
    python3-pip
)
# Bare package names become ambiguous to dpkg once a package is
# installed under multiple architectures (which wine32:i386 causes for
# some of these — libgl1, libglx-mesa0) — dpkg then exits 2, not 0/1,
# even though the package genuinely is installed. Try bare first (needed
# for Architecture:all packages like gnupg/novnc/python3-pip, which
# dpkg records as :all and won't match an explicit :$NATIVE_ARCH
# qualifier), falling back to the qualified form only if that fails —
# which is exactly the ambiguous-multiarch case.
NATIVE_ARCH="$(dpkg --print-architecture)"
is_pkg_installed() {
    dpkg -s "$1" >/dev/null 2>&1 || dpkg -s "$1:$NATIVE_ARCH" >/dev/null 2>&1
}

APT_MISSING=()
for pkg in "${APT_PKGS[@]}"; do
    is_pkg_installed "$pkg" || APT_MISSING+=("$pkg")
done
# WINE_PKG is "wine" (distro stock, no WineHQ repo added) with
# --stock-wine, otherwise the WineHQ channel package as before.
if [ -n "$STOCK_WINE" ]; then
    WINE_PKG="wine"
else
    WINE_PKG="winehq-$WINE_VERSION"
fi
# Initialized empty so `set -u` doesn't trip below when Wine is already
# installed and the dpkg check on the right of `||` never runs.
WINE_MISSING=""
is_pkg_installed "$WINE_PKG" || WINE_MISSING=1

if [ "${#APT_MISSING[@]}" -eq 0 ] && [ -z "$WINE_MISSING" ]; then
    echo "All required packages already installed, skipping apt entirely"
else
    if [ "${#APT_MISSING[@]}" -gt 0 ]; then
        echo "Missing packages: ${APT_MISSING[*]}"
        echo "Update package index"
        sudo apt update
        echo "Installing: ${APT_MISSING[*]}"
        sudo apt install -y "${APT_MISSING[@]}"
    fi

    if [ -n "$WINE_MISSING" ]; then
        echo "Missing package: $WINE_PKG"

        # The distro's stock wine package and every WineHQ channel all
        # tend to register the same wine/wineserver binaries via
        # update-alternatives — having more than one installed at once
        # risks a genuinely inconsistent "which one actually runs" state
        # (not just a hard apt conflict), so refuse rather than silently
        # installing on top of whichever one is already there. Covers
        # both stock-vs-WineHQ and switching between WineHQ channels
        # (e.g. winehq-stable already installed, now defaulting to
        # winehq-staging). Deliberately not auto-removed: which one to
        # keep is a call for whoever's running this, not the script.
        CONFLICTING_WINE_PKGS=()
        for other_pkg in wine winehq-stable winehq-staging winehq-devel; do
            if [ "$other_pkg" != "$WINE_PKG" ] && is_pkg_installed "$other_pkg"; then
                CONFLICTING_WINE_PKGS+=("$other_pkg")
            fi
        done
        if [ "${#CONFLICTING_WINE_PKGS[@]}" -gt 0 ]; then
            echo "ERROR: ${CONFLICTING_WINE_PKGS[*]} already installed from a different Wine source than the one requested ($WINE_PKG). Remove the existing package(s) first: sudo apt remove ${CONFLICTING_WINE_PKGS[*]}"
            exit 1
        fi

        if [ -n "$STOCK_WINE" ]; then
            echo "Installing Wine from the distro's own repos (no WineHQ repo added)"
            # Same reasoning as the WineHQ path below: even the distro's
            # own "wine" package depends on wine32:i386 for 64-bit apps
            # like MT5.
            sudo dpkg --add-architecture i386
            sudo apt update
            sudo apt install --install-recommends -y wine
        else
            echo "Choose Wine repo"

            # $ID doubles as the path component WineHQ's own repo layout
            # uses below (dl.winehq.org/wine-builds/debian/... vs
            # .../ubuntu/...), since /etc/os-release's ID is literally
            # "debian" or "ubuntu".
            if [ "$ID" != "debian" ] && [ "$ID" != "ubuntu" ]; then
                echo "ERROR: unsupported distro: $PRETTY_NAME (this script targets Debian and Ubuntu only)"
                exit 1
            fi

            # Exact filenames only — a wildcard here would delete anything
            # unrelated in that directory that happened to start with
            # "winehq", not just what this script manages. winehq.list
            # covers the older pre-deb822 WineHQ setup instructions, in
            # case that was used here before this script existed.
            # winehq-$VERSION_CODENAME.sources covers the current distro's
            # codename dynamically, not just the ones in the case
            # statement below. The rest are exact fallbacks for a stale
            # file left over from a prior OS upgrade (e.g. bookworm ->
            # trixie) on a earlier run of this script.
            sudo rm -f "/etc/apt/sources.list.d/winehq-$VERSION_CODENAME.sources"
            sudo rm -f /etc/apt/sources.list.d/winehq-trixie.sources
            sudo rm -f /etc/apt/sources.list.d/winehq-bookworm.sources
            sudo rm -f /etc/apt/sources.list.d/winehq.list
            sudo rm -f /etc/apt/keyrings/winehq-archive.key

            # winehq-staging depends on wine32:i386 even for 64-bit apps like MT5.
            sudo dpkg --add-architecture i386
            sudo mkdir -pm755 /etc/apt/keyrings

            # NOTE: download to a plain file first, so curl's own exit code
            # tells us if the fetch failed, rather than piping into gpg
            # where a failed download and a failed gpg import both just
            # leave no keyring file with no clear reason why.
            echo "Download WineHQ signing key"
            if ! curl -fsSL https://dl.winehq.org/wine-builds/winehq.key -o "$RUNTIME_DIR/winehq.key" || [ ! -s "$RUNTIME_DIR/winehq.key" ]; then
                echo "ERROR: failed to download WineHQ signing key from dl.winehq.org. Aborting."
                exit 1
            fi

            if ! sudo gpg --batch --yes --dearmor -o /etc/apt/keyrings/winehq-archive.key "$RUNTIME_DIR/winehq.key" || [ ! -s /etc/apt/keyrings/winehq-archive.key ]; then
                echo "ERROR: failed to import WineHQ signing key into keyring. Aborting."
                exit 1
            fi

            echo "$PRETTY_NAME found ($VERSION_CODENAME)"
            case "$VERSION_CODENAME" in
                trixie | bookworm | resolute)
                    ;;
                *)
                    echo "WARNING: OS release not tested with this script: $PRETTY_NAME — attempting anyway"
                    ;;
            esac
            sudo wget -NP /etc/apt/sources.list.d/ \
                "https://dl.winehq.org/wine-builds/$ID/dists/$VERSION_CODENAME/winehq-$VERSION_CODENAME.sources"

            echo "Install Wine and Wine Mono"
            sudo apt update
            sudo apt install --install-recommends -y "winehq-$WINE_VERSION"
        fi
    fi
fi

# Created once here, before Xvnc/DISPLAY even exist — wineboot --init
# doesn't need a display to build the prefix's directory/registry
# structure, and running it fully headless (falling back to Wine's null
# driver) avoids ever re-touching an already-initialized prefix on a
# rerun, which is what caused prefix corruption ("could not load
# kernel32.dll") in practice. Guarded on the directory rather than
# unconditional for the same reason: leave a working prefix alone.
if [ ! -d "$WINEPREFIX" ]; then
    echo "Creating 64-bit Wine prefix"
    # Unset explicitly rather than trusting no DISPLAY is inherited from
    # the invoking shell (an SSH -X session, a desktop terminal, etc.) —
    # this guarantees the headless/null-driver fallback the comment above
    # is relying on, instead of possibly trying to reach some unrelated
    # display.
    unset DISPLAY
    WINEARCH=win64 wineboot --init
else
    echo "Wine prefix already exists, leaving it as-is"
fi

echo "Configure minimal xstartup (no window manager, keep X session alive)"
mkdir -p "$HOME/.config/tigervnc"
XSTARTUP="$HOME/.config/tigervnc/xstartup"
cat > "$XSTARTUP" << 'EOF'
#!/bin/sh
exec sleep infinity
EOF
chmod +x "$XSTARTUP"

# Same version-dependent-default problem as xstartup (~/.vnc/passwd vs
# ~/.config/tigervnc/passwd) — pin it explicitly rather than relying on
# vncpasswd/vncserver's own auto-discovery, which disagreed with each
# other on at least one observed TigerVNC build.
VNC_PASSWD_FILE="$HOME/.config/tigervnc/passwd"
if [ -n "$VNC_PASSWORD" ]; then
    echo "Setting VNC password non-interactively"
    if [ -n "$VNC_VIEWONLY_PASSWORD" ]; then
        printf '%s\n%s\ny\n%s\n%s\n' \
            "$VNC_PASSWORD" "$VNC_PASSWORD" \
            "$VNC_VIEWONLY_PASSWORD" "$VNC_VIEWONLY_PASSWORD" | vncpasswd "$VNC_PASSWD_FILE"
    else
        printf '%s\n%s\nn\n' "$VNC_PASSWORD" "$VNC_PASSWORD" | vncpasswd "$VNC_PASSWD_FILE"
    fi
elif [ ! -f "$VNC_PASSWD_FILE" ]; then
    # vncserver is given -PasswordFile explicitly below (see comment
    # there), which bypasses its own auto-prompt-to-create logic — that
    # logic only triggers for its auto-discovered default path, not one
    # passed explicitly. Without this, a first run with no -p/--password
    # would hand vncserver a password file that doesn't exist yet, and
    # -SecurityTypes VncAuth would then fail (or worse, run without real
    # auth) instead of prompting like the old default behavior did.
    echo "No existing VNC password found, prompting to set one"
    vncpasswd "$VNC_PASSWD_FILE"
fi

echo "Start Xvnc on display :$VNC_DISPLAY (no window manager)"
# -kill legitimately fails (nonzero) when no prior session is running —
# that's the common case on a fresh box, not an error.
# -depth 24, not 16: costs +2MB, not worth banding risk on MT5 charts.
# -xstartup and -PasswordFile explicit: TigerVNC's auto-discovered paths
# for both have changed across versions/distros, and some packaged
# versions disagree with each other about the default — passing both
# explicitly sidesteps all of that.
vncserver -kill ":$VNC_DISPLAY" 2>/dev/null || true
vncserver ":$VNC_DISPLAY" -geometry 1280x800 -depth 24 -localhost no -xstartup "$XSTARTUP" -PasswordFile "$VNC_PASSWD_FILE" -SecurityTypes VncAuth
export DISPLAY=":$VNC_DISPLAY"

echo "Start noVNC on port $NOVNC_PORT"
NOVNC_DIR="/usr/share/novnc"
# Suffixed by VNC_PORT (not just a fixed name) — see the RUNTIME_DIR
# comment at the top of the script for why this lives outside /tmp; the
# VNC_PORT suffix on top of that is so multiple copies run by the same
# user (each with their own -v/-n/-b ports) don't clobber each other's
# pidfile/log.
NOVNC_PID="$RUNTIME_DIR/novnc-$VNC_PORT.pid"
NOVNC_LOG="$RUNTIME_DIR/novnc-$VNC_PORT.log"
stop_by_pidfile "$NOVNC_PID"
if [ -d "$NOVNC_DIR" ]; then
    # [::] gives dual-stack (v4+v6 on one socket) where IPv6 is available;
    # falls back to IPv4-only rather than failing outright where it isn't.
    # /proc/net/if_inet6 only exists when the kernel has IPv6 enabled.
    if [ -f /proc/net/if_inet6 ]; then
        NOVNC_BIND="[::]:$NOVNC_PORT"
    else
        NOVNC_BIND="$NOVNC_PORT"
    fi
    nohup websockify --web="$NOVNC_DIR" "$NOVNC_BIND" "localhost:$VNC_PORT" >"$NOVNC_LOG" 2>&1 &
    echo "$!" > "$NOVNC_PID"
else
    echo "WARNING: novnc web assets not found at $NOVNC_DIR, adjust path"
fi

MT5_EXE="$WINEPREFIX/drive_c/Program Files/MetaTrader 5/terminal64.exe"
WEBVIEW2_DIR="$WINEPREFIX/drive_c/Program Files (x86)/Microsoft/EdgeWebView/Application"

echo "Download MetaTrader and WebView2 Runtime"
if [ ! -f "$MT5_EXE" ]; then
    if ! curl -fsSL "$URL_MT5" -o "$RUNTIME_DIR/mt5setup.exe" || [ ! -s "$RUNTIME_DIR/mt5setup.exe" ]; then
        echo "ERROR: failed to download mt5setup.exe from $URL_MT5. Aborting."
        exit 1
    fi
else
    echo "MetaTrader 5 already installed, skipping download"
fi

# MT5's terminal embeds a Chromium view (Market tab, news, signals) via
# WebView2 — without it those panels fail to render.
if [ ! -d "$WEBVIEW2_DIR" ]; then
    if ! curl -fsSL "$URL_WEBVIEW" -o "$RUNTIME_DIR/webview2.exe" || [ ! -s "$RUNTIME_DIR/webview2.exe" ]; then
        echo "ERROR: failed to download webview2.exe from $URL_WEBVIEW. Aborting."
        exit 1
    fi
else
    echo "WebView2 Runtime already installed, skipping download"
fi

# Confirms display :$VNC_DISPLAY actually answers before running a Wine
# step. If Xvnc was killed or crashed (e.g. someone restarted VNC in
# another terminal mid-run), this restarts it once rather than letting
# the following Wine command fail silently against a dead display.
wait_for_display() {
    local max_wait=30
    local waited=0
    while ! xdpyinfo >/dev/null 2>&1; do
        waited=$((waited + 2))
        if [ "$waited" -ge "$max_wait" ]; then
            echo "WARNING: display :$VNC_DISPLAY not responding, restarting Xvnc"
            vncserver -kill ":$VNC_DISPLAY" 2>/dev/null || true
            vncserver ":$VNC_DISPLAY" -geometry 1280x800 -depth 24 -localhost no -xstartup "$XSTARTUP" -PasswordFile "$VNC_PASSWD_FILE" -SecurityTypes VncAuth || true
            sleep 3
            if ! xdpyinfo >/dev/null 2>&1; then
                echo "ERROR: display :$VNC_DISPLAY still not responding after restart"
                return 1
            fi
            return
        fi
        sleep 2
    done
}

# Waits until MetaTrader 5 has actually started before proceeding to the
# pymt5linux bridge, which needs a running terminal to attach to — a fixed
# sleep can't tell startup-in-progress apart from startup-failed.
# -u "$UID": pgrep -f alone matches process command lines machine-wide,
# not just this user's — without it, another user's own MT5 (see Running
# multiple copies) would read as "started" here.
wait_for_mt5() {
    local timeout=60
    local elapsed=0

    while ! pgrep -u "$UID" -f '[/\\]terminal64\.exe([[:space:]]|$)' >/dev/null 2>&1; do
        if (( elapsed >= timeout )); then
            echo "ERROR: MetaTrader 5 did not start within ${timeout}s"
            return 1
        fi
        sleep 2
        elapsed=$((elapsed + 2))
    done
}

# Polls for the pymt5linux bridge port rather than a fixed sleep, and —
# since Wine may detach the real server from this launcher PID — treats an
# early launcher exit only as a hint to check the log, not definitive proof
# the bridge is down; the port check remains the authoritative signal.
start_pymt5linux() {
    local timeout=30
    local elapsed=0

    while (( elapsed < timeout )); do
        if timeout 2 bash -c "</dev/tcp/$MT5SERVER_HOST/$MT5SERVER_PORT" 2>/dev/null; then
            echo "pymt5linux bridge is running on TCP port $MT5SERVER_PORT"
            return 0
        fi

        if ! kill -0 "$MT5SERVER_PID" 2>/dev/null; then
            echo "ERROR: pymt5linux launcher exited before the port opened"
            tail -50 "$PYMT5LINUX_LOG"
            return 1
        fi

        sleep 1
        elapsed=$((elapsed + 1))
    done

    echo "ERROR: pymt5linux bridge did not open port $MT5SERVER_PORT within ${timeout}s"
    tail -50 "$PYMT5LINUX_LOG"
    return 1
}

echo "Set environment to Windows 11"
wait_for_display
if ! winecfg -v=win11; then
    echo "WARNING: winecfg exited with an error, continuing anyway"
fi

echo "Install WebView2 Runtime"
if [ ! -d "$WEBVIEW2_DIR" ]; then
    wait_for_display
    # Exit code ignored deliberately: WebView2's bootstrapper can return
    # non-zero on a benign condition (e.g. reboot-suggested) even when
    # the install actually succeeded. Check the real outcome below instead.
    wine "$RUNTIME_DIR/webview2.exe" /silent /install || true
    if [ ! -d "$WEBVIEW2_DIR" ]; then
        echo "WARNING: WebView2 install did not produce $WEBVIEW2_DIR, continuing anyway"
    fi
else
    echo "Already installed: WebView2 Runtime"
fi

echo "Install MetaTrader 5"
if [ ! -f "$MT5_EXE" ]; then
    wait_for_display
    # Same reasoning as WebView2 above: mt5setup.exe is a bootstrapper
    # that can exit non-zero on a benign condition even when the actual
    # install succeeded. Check whether $MT5_EXE actually exists instead.
    wine "$RUNTIME_DIR/mt5setup.exe" /auto || true
    if [ ! -f "$MT5_EXE" ]; then
        echo "WARNING: MetaTrader 5 install did not produce $MT5_EXE, continuing anyway"
    fi
else
    echo "Already installed: MetaTrader 5"
fi

echo "Launch MetaTrader 5"
if pgrep -u "$UID" -f '[/\\]terminal64\.exe([[:space:]]|$)' >/dev/null 2>&1; then
    echo "MetaTrader 5 already running, not launching another copy"
else
    wait_for_display
    nohup wine "C:\Program Files\MetaTrader 5\terminal64.exe" >"$MT5_TERMINAL_LOG" 2>&1 &
fi
wait_for_mt5
# Only reached on success — wait_for_mt5 aborts the script otherwise.
# MT5 keeps running and writing to this path after deletion (safe on
# Linux, but you lose the ability to tail it and the space isn't freed
# until MT5 exits).
rm -f "$MT5_TERMINAL_LOG"

# ------------------------------------------------------------------
# pymt5linux bridge: Python-in-Wine + MetaTrader5/pymt5linux libraries,
# so external code (Linux-side Python) can drive the terminal via RPyC.
#
# Why Wine-side, not Linux-side: MT5's MetaTrader5 Python package talks
# to the terminal via Windows-only IPC, so it only works from inside the
# same Windows process space MT5 runs in. It cannot be installed or
# called from Linux-side Python directly — hence a Python interpreter
# running inside Wine, with pymt5linux bridging calls to it over RPyC.
#
# We deliberately use pymt5linux rather than the current mt5linux package.
# pymt5linux keeps the original RPyC architecture where the bridge server
# runs inside Wine using Windows Python, while Linux-side Python connects
# to it as a client.
#
# Current mt5linux uses mt5server.exe instead, so don't switch packages
# casually: the two projects now have different architectures.
# ------------------------------------------------------------------

is_wine_python_package_installed() {
    wine python -c \
        "import importlib.metadata; importlib.metadata.version('$1')" \
        >/dev/null 2>&1
}

is_python_package_installed() {
    python3 -c \
        "import importlib.metadata; importlib.metadata.version('$1')" \
        >/dev/null 2>&1
}

echo "Install Python in Wine"
if ! wine python --version >/dev/null 2>&1; then
    wait_for_display
    if ! curl -fsSL "$URL_PYTHON" -o "$RUNTIME_DIR/python-installer.exe" || [ ! -s "$RUNTIME_DIR/python-installer.exe" ]; then
        echo "WARNING: failed to download Python-in-Wine installer, skipping pymt5linux bridge setup"
    else
        wine "$RUNTIME_DIR/python-installer.exe" /quiet InstallAllUsers=1 PrependPath=1 \
            || echo "WARNING: Python-in-Wine installer exited with an error, continuing anyway"
    fi
else
    echo "Already installed: Python in Wine"
fi

if wine python --version >/dev/null 2>&1; then
    echo "Install Python libraries in Wine"
    # --progress-bar off: pip's redraw-in-place progress bar garbles the
    # screen through Wine's console layer under nohup/non-TTY capture.
    wine python -m pip install --upgrade --no-cache-dir --progress-bar off pip \
        || echo "WARNING: pip upgrade in Wine Python failed, continuing anyway"

    if ! is_wine_python_package_installed "MetaTrader5"; then
        wine python -m pip install --no-cache-dir --progress-bar off MetaTrader5 \
            || echo "WARNING: MetaTrader5 (Wine Python) install failed, continuing anyway"
    else
        echo "Already installed: MetaTrader5 (Wine Python)"
    fi

    if ! is_wine_python_package_installed "pymt5linux"; then
        wine python -m pip install --no-cache-dir --progress-bar off pymt5linux \
            || echo "WARNING: pymt5linux (Wine Python) install failed, continuing anyway"
    else
        echo "Already installed: pymt5linux (Wine Python)"
    fi

    echo "Install pymt5linux on Linux"
    if ! is_python_package_installed "pymt5linux"; then
        pip install --break-system-packages --no-cache-dir --progress-bar off pymt5linux \
            || echo "WARNING: pymt5linux (Linux Python) install failed, continuing anyway"
    else
        echo "Already installed: pymt5linux (Linux Python)"
    fi

    echo "Start pymt5linux bridge server"
    # pkill -f here rather than a PID file: this process runs under
    # `wine`, and Wine can detach the actual server from the launcher
    # PID `$!` would capture, so a PID file isn't reliable for it.
    # -u "$UID": without it, this would match (and kill) any user's
    # process with this command line, not just this one's — same
    # reasoning as the pgrep -u "$UID" fixes elsewhere in this script.
    # Fails (nonzero) when no prior server was running — not an error.
    pkill -u "$UID" -f "pymt5linux --host $MT5SERVER_HOST --port $MT5SERVER_PORT" 2>/dev/null || true
    sleep 1
    wait_for_display

    nohup wine python.exe -m pymt5linux --host "$MT5SERVER_HOST" --port "$MT5SERVER_PORT" python.exe >"$PYMT5LINUX_LOG" 2>&1 &
    MT5SERVER_PID="$!"
    if start_pymt5linux; then
        # Bridge keeps running and writing to this path after deletion
        # (safe on Linux, but no longer tail-able, space freed only on
        # bridge exit). Kept on failure — that's what tail -50 above reads.
        rm -f "$PYMT5LINUX_LOG"
    else
        echo "WARNING: pymt5linux bridge did not come up cleanly, continuing anyway"
    fi
else
    echo "WARNING: Wine Python not available, skipping pymt5linux bridge setup"
fi

MT5_HOST="$(hostname -f 2>/dev/null || hostname)"
echo "noVNC available at http://$MT5_HOST:$NOVNC_PORT/vnc.html (VNC on :$VNC_PORT)"

# noVNC has only the VNC password for access control (see SECURITY.md) —
# printing every address it's reachable on is operationally useful, but
# worth a reminder here that this is exactly what's exposed.
echo "WARNING: noVNC is reachable on all addresses below with only the VNC password for access control. Do not expose these ports directly to the Internet — see SECURITY.md."
echo "Also reachable on these network addresses:"
while read -r ip; do
    echo "  http://$ip:$NOVNC_PORT/vnc.html"
done < <(ip -o -4 addr show | awk '$2 != "lo" {print $4}' | cut -d/ -f1)
while read -r ip; do
    echo "  http://[$ip]:$NOVNC_PORT/vnc.html"
done < <(ip -o -6 addr show | awk '$2 != "lo" {print $4}' | cut -d/ -f1 | grep -vi '^fe80:')
exit 0
