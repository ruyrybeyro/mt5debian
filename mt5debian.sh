#!/bin/bash
# Copyright 2026, Rui Ribeiro
# Written with the assistance of Claude

set -Eeuo pipefail

# Cleans up downloaded installer files on any exit — success, an early
# ERROR/exit 1, or an interrupt — rather than relying on rm -f calls
# scattered after each individual use, which only run if that point in
# the script is actually reached.
cleanup_temp_files() {
    rm -f /tmp/winehq.key /tmp/python-installer.exe mt5setup.exe webview2.exe
}
trap cleanup_temp_files EXIT

usage() {
    cat << 'USAGE'
Usage: mt5debian.sh [-p|--password password] [-P|--viewonly-password password]
                    [-w|--wine-version stable|staging|devel] [--purge] [-h|--help]
  -p, --password             VNC password. Sets it non-interactively,
                              overwriting any existing one. If omitted,
                              an existing password is left alone; if none
                              exists yet, vncserver prompts interactively
                              as usual (and asks whether to also set a
                              view-only password).
  -P, --viewonly-password    VNC view-only password. Only used together
                              with -p/--password.
  -w, --wine-version         Force the Wine channel (stable, staging, or
                              devel), overriding the default (staging).
  --purge                    Kill any running Wine process for this
                              prefix and delete it ($HOME/.mt5), then
                              continue as a clean reinstall. Does not
                              touch the VNC password or apt/Wine package
                              installation.
  -h, --help                 Show this help and exit.
USAGE
}

PARSED_OPTS=$(getopt --options p:P:w:h --longoptions password:,viewonly-password:,wine-version:,purge,help --name "mt5debian.sh" -- "$@") \
    || { usage; exit 1; }
eval set -- "$PARSED_OPTS"

VNC_PASSWORD=""
VNC_VIEWONLY_PASSWORD=""
WINE_VERSION_OVERRIDE=""
PURGE=""
while true; do
    case "$1" in
        -p|--password) VNC_PASSWORD="$2"; shift 2 ;;
        -P|--viewonly-password) VNC_VIEWONLY_PASSWORD="$2"; shift 2 ;;
        -w|--wine-version) WINE_VERSION_OVERRIDE="$2"; shift 2 ;;
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

if [ -n "$PURGE" ]; then
    echo "Purging existing Wine prefix ($HOME/.mt5)"
    WINEPREFIX="$HOME/.mt5" wineserver -k 2>/dev/null || true
    rm -rf "$HOME/.mt5"
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
NOVNC_PORT="6080"

. /etc/os-release

# Wine channel to install: stable, staging, or devel. staging confirmed
# working on Debian. Force a different channel with -w/--wine-version.
if [ -n "$WINE_VERSION_OVERRIDE" ]; then
    WINE_VERSION="$WINE_VERSION_OVERRIDE"
else
    WINE_VERSION="staging"
fi

# mt5linux bridge — lets external Python code drive the terminal via RPyC.
# Port matches the FreeBSD mt5jail bridge for consistency.
MT5SERVER_PORT="8001"
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
# Initialized empty so `set -u` doesn't trip below when Wine is already
# installed and the dpkg check on the right of `||` never runs.
WINE_MISSING=""
is_pkg_installed "winehq-$WINE_VERSION" || WINE_MISSING=1

if [ "${#APT_MISSING[@]}" -eq 0 ] && [ -z "$WINE_MISSING" ]; then
    echo "All required packages already installed, skipping apt entirely"
else
    if [ "${#APT_MISSING[@]}" -gt 0 ]; then
        echo "Missing packages: ${APT_MISSING[*]}"
    fi
    if [ -n "$WINE_MISSING" ]; then
        echo "Missing package: winehq-$WINE_VERSION"
    fi
    echo "Update package index"
    sudo apt update

    if [ "${#APT_MISSING[@]}" -gt 0 ]; then
        echo "Installing: ${APT_MISSING[*]}"
        sudo apt install -y "${APT_MISSING[@]}"
    fi

    if [ -n "$WINE_MISSING" ]; then
        echo "Choose Wine repo"

        if [ "$ID" != "debian" ]; then
            echo "ERROR: unsupported distro: $PRETTY_NAME (this script targets Debian only)"
            exit 1
        fi

        # Exact filenames only — a wildcard here would delete anything
        # unrelated in that directory that happened to start with
        # "winehq", not just what this script manages. winehq.list
        # covers the older pre-deb822 WineHQ setup instructions, in
        # case that was used here before this script existed.
        # winehq-$VERSION_CODENAME.sources covers the current distro's
        # codename dynamically, not just the ones in the case statement
        # below. The rest are exact fallbacks for a stale file left over
        # from a prior OS upgrade (e.g. bookworm -> trixie) on a earlier
        # run of this script.
        sudo rm -f "/etc/apt/sources.list.d/winehq-$VERSION_CODENAME.sources"
        sudo rm -f /etc/apt/sources.list.d/winehq-trixie.sources
        sudo rm -f /etc/apt/sources.list.d/winehq-bookworm.sources
        sudo rm -f /etc/apt/sources.list.d/winehq.list
        sudo rm -f /etc/apt/keyrings/winehq-archive.key

        # winehq-staging depends on wine32:i386 even for 64-bit apps like MT5.
        sudo dpkg --add-architecture i386
        sudo mkdir -pm755 /etc/apt/keyrings

        # NOTE: download to a plain file first, so curl's own exit code tells
        # us if the fetch failed, rather than piping into gpg where a failed
        # download and a failed gpg import both just leave no keyring file
        # with no clear reason why.
        echo "Download WineHQ signing key"
        if ! curl -fsSL https://dl.winehq.org/wine-builds/winehq.key -o /tmp/winehq.key || [ ! -s /tmp/winehq.key ]; then
            echo "ERROR: failed to download WineHQ signing key from dl.winehq.org. Aborting."
            exit 1
        fi

        if ! sudo gpg --batch --yes --dearmor -o /etc/apt/keyrings/winehq-archive.key /tmp/winehq.key || [ ! -s /etc/apt/keyrings/winehq-archive.key ]; then
            echo "ERROR: failed to import WineHQ signing key into keyring. Aborting."
            exit 1
        fi

        echo "Debian Linux found: $NAME $VERSION_ID ($VERSION_CODENAME)"
        case "$VERSION_CODENAME" in
            trixie | bookworm)
                ;;
            *)
                echo "WARNING: Debian release not tested with this script: $PRETTY_NAME — attempting anyway"
                ;;
        esac
        sudo wget -NP /etc/apt/sources.list.d/ \
            "https://dl.winehq.org/wine-builds/debian/dists/$VERSION_CODENAME/winehq-$VERSION_CODENAME.sources"

        echo "Install Wine and Wine Mono"
        sudo apt update
        sudo apt install --install-recommends -y "winehq-$WINE_VERSION"
    fi
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
fi

echo "Start Xvnc on display :1 (no window manager)"
# -kill legitimately fails (nonzero) when no prior session is running —
# that's the common case on a fresh box, not an error.
# -depth 24, not 16: costs +2MB, not worth banding risk on MT5 charts.
# -xstartup and -PasswordFile explicit: TigerVNC's auto-discovered paths
# for both have changed across versions/distros, and some packaged
# versions disagree with each other about the default — passing both
# explicitly sidesteps all of that.
vncserver -kill :1 2>/dev/null || true
vncserver :1 -geometry 1280x800 -depth 24 -localhost no -xstartup "$XSTARTUP" -PasswordFile "$VNC_PASSWD_FILE"
export DISPLAY=:1
export WINEPREFIX="$HOME/.mt5"

echo "Start noVNC on port $NOVNC_PORT"
NOVNC_DIR="/usr/share/novnc"
NOVNC_PID="/tmp/novnc.pid"
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
    nohup websockify --web="$NOVNC_DIR" "$NOVNC_BIND" localhost:5901 >/tmp/novnc.log 2>&1 &
    echo "$!" > "$NOVNC_PID"
else
    echo "WARNING: novnc web assets not found at $NOVNC_DIR, adjust path"
fi

MT5_EXE="$HOME/.mt5/drive_c/Program Files/MetaTrader 5/terminal64.exe"
WEBVIEW2_DIR="$HOME/.mt5/drive_c/Program Files (x86)/Microsoft/EdgeWebView/Application"

echo "Download MetaTrader and WebView2 Runtime"
if [ ! -f "$MT5_EXE" ]; then
    if ! curl -fsSL "$URL_MT5" -o mt5setup.exe || [ ! -s mt5setup.exe ]; then
        echo "ERROR: failed to download mt5setup.exe from $URL_MT5. Aborting."
        exit 1
    fi
else
    echo "mt5setup.exe already present, skipping download"
fi

# MT5's terminal embeds a Chromium view (Market tab, news, signals) via
# WebView2 — without it those panels fail to render.
if [ ! -d "$WEBVIEW2_DIR" ]; then
    if ! curl -fsSL "$URL_WEBVIEW" -o webview2.exe || [ ! -s webview2.exe ]; then
        echo "ERROR: failed to download webview2.exe from $URL_WEBVIEW. Aborting."
        exit 1
    fi
else
    echo "webview2.exe already present, skipping download"
fi

# Confirms display :1 actually answers before running a Wine step. If Xvnc
# was killed or crashed (e.g. someone restarted VNC in another terminal
# mid-run), this restarts it once rather than letting the following Wine
# command fail silently against a dead display.
wait_for_display() {
    local max_wait=30
    local waited=0
    while ! xdpyinfo >/dev/null 2>&1; do
        waited=$((waited + 2))
        if [ "$waited" -ge "$max_wait" ]; then
            echo "WARNING: display :1 not responding, restarting Xvnc"
            vncserver -kill :1 2>/dev/null || true
            vncserver :1 -geometry 1280x800 -depth 24 -localhost no -xstartup "$XSTARTUP" -PasswordFile "$VNC_PASSWD_FILE" -SecurityTypes VncAuth || true
            sleep 3
            if ! xdpyinfo >/dev/null 2>&1; then
                echo "WARNING: display :1 still not responding after restart, proceeding anyway"
            fi
            return
        fi
        sleep 2
    done
}

# Waits until MetaTrader 5 has actually started before proceeding to the
# pymt5linux bridge, which needs a running terminal to attach to — a fixed
# sleep can't tell startup-in-progress apart from startup-failed.
wait_for_mt5() {
    local timeout=60
    local elapsed=0

    while ! pgrep -f '[/\\]terminal64\.exe([[:space:]]|$)' >/dev/null 2>&1; do
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
            tail -50 /tmp/pymt5linux-server.log
            return 1
        fi

        sleep 1
        elapsed=$((elapsed + 1))
    done

    echo "ERROR: pymt5linux bridge did not open port $MT5SERVER_PORT within ${timeout}s"
    tail -50 /tmp/pymt5linux-server.log
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
    wine webview2.exe /silent /install || true
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
    wine mt5setup.exe /auto || true
    if [ ! -f "$MT5_EXE" ]; then
        echo "WARNING: MetaTrader 5 install did not produce $MT5_EXE, continuing anyway"
    fi
else
    echo "Already installed: MetaTrader 5"
fi

echo "Launch MetaTrader 5"
if pgrep -f '[/\\]terminal64\.exe([[:space:]]|$)' >/dev/null 2>&1; then
    echo "MetaTrader 5 already running, not launching another copy"
else
    wait_for_display
    nohup wine "C:\Program Files\MetaTrader 5\terminal64.exe" >/tmp/mt5-terminal.log 2>&1 &
fi
wait_for_mt5
# Only reached on success — wait_for_mt5 aborts the script otherwise.
# MT5 keeps running and writing to this path after deletion (safe on
# Linux, but you lose the ability to tail it and the space isn't freed
# until MT5 exits).
rm -f /tmp/mt5-terminal.log

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
    if ! curl -fsSL "$URL_PYTHON" -o /tmp/python-installer.exe || [ ! -s /tmp/python-installer.exe ]; then
        echo "WARNING: failed to download Python-in-Wine installer, skipping pymt5linux bridge setup"
    else
        wine /tmp/python-installer.exe /quiet InstallAllUsers=1 PrependPath=1 \
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
    # Fails (nonzero) when no prior server was running — not an error.
    pkill -f "pymt5linux --host $MT5SERVER_HOST --port $MT5SERVER_PORT" 2>/dev/null || true
    sleep 1
    wait_for_display

    nohup wine python.exe -m pymt5linux --host "$MT5SERVER_HOST" --port "$MT5SERVER_PORT" python.exe >/tmp/pymt5linux-server.log 2>&1 &
    MT5SERVER_PID="$!"
    if start_pymt5linux; then
        # Bridge keeps running and writing to this path after deletion
        # (safe on Linux, but no longer tail-able, space freed only on
        # bridge exit). Kept on failure — that's what tail -50 above reads.
        rm -f /tmp/pymt5linux-server.log
    else
        echo "WARNING: pymt5linux bridge did not come up cleanly, continuing anyway"
    fi
else
    echo "WARNING: Wine Python not available, skipping pymt5linux bridge setup"
fi

MT5_HOST="$(hostname -f 2>/dev/null || hostname)"
echo "noVNC available at http://$MT5_HOST:$NOVNC_PORT/vnc.html (VNC on :5901)"

echo "Also reachable at:"
while read -r ip; do
    echo "  http://$ip:$NOVNC_PORT/vnc.html"
done < <(ip -o -4 addr show | awk '$2 != "lo" {print $4}' | cut -d/ -f1)
while read -r ip; do
    echo "  http://[$ip]:$NOVNC_PORT/vnc.html"
done < <(ip -o -6 addr show | awk '$2 != "lo" {print $4}' | cut -d/ -f1 | grep -vi '^fe80:')
exit 0
