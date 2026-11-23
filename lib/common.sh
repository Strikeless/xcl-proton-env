# shellcheck shell=bash
# Shared helpers for prefix-init.sh, xcl-run-unsandboxed.sh and xcl-run.sh.
# Sourced, not executed.

XCLENV_ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
XCLENV_DEFAULT_DIR="$XCLENV_ROOT/pfx"
XCLENV_CONF_NAME="xcl-env.conf"

# Where XCL lives inside the wineprefix (C:\xcl).
XCLENV_WIN_XCL_DIR='C:\xcl'
XCLENV_WIN_XCL_EXE='C:\xcl\xcl.exe'

msg()  { printf '\033[1;34m==>\033[0m %s\n' "$*" >&2; }
info() { printf '    %s\n' "$*" >&2; }
warn() { printf '\033[1;33mwarning:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

need_cmd() {
    local c
    for c in "$@"; do
        command -v "$c" >/dev/null 2>&1 || die "required command not found: $c"
    done
}

# ask_yes_no PROMPT [DEFAULT(y|n)] – reads from the terminal; honours XCLENV_ASSUME_YES=1.
ask_yes_no() {
    local prompt=$1 def=${2:-n} ans hint
    [[ ${XCLENV_ASSUME_YES:-0} == 1 ]] && return 0
    [[ $def == y ]] && hint='[Y/n]' || hint='[y/N]'
    [[ -r /dev/tty ]] || die "cannot prompt (no terminal): $prompt – rerun with -y"
    read -r -p "$prompt $hint " ans </dev/tty || ans=
    ans=${ans:-$def}
    [[ $ans == [yY]* ]]
}

# --- the environment directory ("compat data" dir in Proton terms) -----------------
#
# <dir>/xcl-env.conf     settings written by prefix-init.sh (PROTON_DIR=...)
# <dir>/pfx/             the wineprefix, created and managed by Proton
# <dir>/pfx/drive_c/xcl  xcl.exe, DXC, testgame/
# <dir>/build/           XCL source copy + cargo target dir
# <dir>/cache/           vkd3d-proton / DXVK / Mesa shader caches
# <dir>/downloads/       downloaded archives (DXC)
# <dir>/steam/           empty stand-in for STEAM_COMPAT_CLIENT_INSTALL_PATH

xclenv_pfx()      { printf '%s/pfx' "$1"; }
xclenv_xcl_dir()  { printf '%s/pfx/drive_c/xcl' "$1"; }
xclenv_cache()    { printf '%s/cache' "$1"; }
# XCL keeps title data (saves, overlay, logs, shader caches) in %LOCALAPPDATA%\XCL.
# Proton's prefix user is always "steamuser".
xclenv_data_dir() { printf '%s/pfx/drive_c/users/steamuser/AppData/Local/XCL' "$1"; }

# Is DIR a Proton installation we can use?
is_proton_dir() {
    [[ -f $1/proton && -x $1/files/bin/wine ]]
}

# Print candidate Proton directories (one per line, resolved, de-duplicated).
find_proton_candidates() {
    local -a roots=(
        "$HOME/.steam/steam/compatibilitytools.d"
        "$HOME/.local/share/Steam/compatibilitytools.d"
        "$HOME/.steam/root/compatibilitytools.d"
        "$HOME/.var/app/com.valvesoftware.Steam/data/Steam/compatibilitytools.d"
        /usr/share/steam/compatibilitytools.d
        /usr/local/share/steam/compatibilitytools.d
        /opt/steam/compatibilitytools.d
    )
    local -a commons=(
        "$HOME/.steam/steam/steamapps/common"
        "$HOME/.local/share/Steam/steamapps/common"
    )
    local IFS=:
    # STEAM_EXTRA_COMPAT_TOOLS_PATHS is a colon-separated list (Steam's own variable).
    # shellcheck disable=SC2206
    [[ -n ${STEAM_EXTRA_COMPAT_TOOLS_PATHS:-} ]] && roots+=($STEAM_EXTRA_COMPAT_TOOLS_PATHS)
    unset IFS
    {
        local r d
        for r in "${roots[@]}"; do
            for d in "$r"/*/; do
                d=${d%/}
                is_proton_dir "$d" && realpath -- "$d"
            done
        done
        for r in "${commons[@]}"; do
            for d in "$r"/Proton*/; do
                d=${d%/}
                is_proton_dir "$d" && realpath -- "$d"
            done
        done
    } 2>/dev/null | awk '!seen[$0]++' | {
        # GE-Proton / Proton-CachyOS first, newest version first.
        local d b r
        while IFS= read -r d; do
            b=${d##*/}
            case $b in *GE-Proton*|*[Cc]achy*) r=0 ;; *) r=1 ;; esac
            printf '%s\t%s\t%s\n' "$r" "$b" "$d"
        done | sort -t $'\t' -k1,1n -k2,2Vr | cut -f3-
    }
}

proton_label() {
    local d=$1 v=
    [[ -r $d/version ]] && read -r _ v <"$d/version"
    printf '%s%s' "$(basename -- "$d")" "${v:+ ($v)}"
}

# write_conf DIR PROTON_DIR
write_conf() {
    local f="$1/$XCLENV_CONF_NAME"
    {
        printf '# Written by prefix-init.sh – read (not sourced) by the xcl-run scripts.\n'
        printf 'PROTON_DIR=%s\n' "$2"
    } >"$f.tmp" && mv -f -- "$f.tmp" "$f"
}

# load_conf DIR – sets PROTON_DIR. The file is parsed, never sourced: the sandbox can
# write next to it, so it must not be able to inject code into an unsandboxed run.
load_conf() {
    local f="$1/$XCLENV_CONF_NAME" line key val
    [[ -f $f ]] || die "$1 is not an XCL environment (no $XCLENV_CONF_NAME) – run prefix-init.sh first"
    PROTON_DIR=
    while IFS= read -r line || [[ -n $line ]]; do
        [[ $line == '#'* || -z $line ]] && continue
        key=${line%%=*} val=${line#*=}
        case $key in
            PROTON_DIR) PROTON_DIR=$val ;;
            *) warn "$f: ignoring unknown key '$key'" ;;
        esac
    done <"$f"
    [[ -n $PROTON_DIR ]] || die "$f: PROTON_DIR is not set"
    is_proton_dir "$PROTON_DIR" || die "Proton not found at '$PROTON_DIR' (from $f) – rerun prefix-init.sh with --proton"
}

# resolve_env_dir PATH – absolute, symlink-free path (the dir may not exist yet).
resolve_env_dir() {
    realpath -m -- "$1"
}

# --- running Proton ------------------------------------------------------------

# proton_env DIR – export what Proton's script needs to manage <DIR>/pfx outside Steam.
proton_env() {
    local dir=$1 cache
    cache=$(xclenv_cache "$dir")
    export STEAM_COMPAT_DATA_PATH="$dir"
    # Proton copies Steam client DLLs from here; an empty dir makes it skip them.
    export STEAM_COMPAT_CLIENT_INSTALL_PATH="$dir/steam"
    # A non-Steam title: app id 0 keeps Proton's and protonfixes' per-game tweaks off.
    export SteamAppId=0 SteamGameId=0 STEAM_COMPAT_APP_ID=0
    export PYTHONDONTWRITEBYTECODE=1
    export WINEDEBUG="${WINEDEBUG:--all}"
    # Proton sets its DXVK / vkd3d-proton overrides only while (re)building the prefix,
    # not for "runinprefix": set them here so D3D12 / DXGI come from Proton's builds.
    export WINEDLLOVERRIDES="dxgi,d3d9,d3d10core,d3d11,d3d12,d3d12core=n${WINEDLLOVERRIDES:+;$WINEDLLOVERRIDES}"
    # Keep shader caches out of the game folder (vkd3d-proton defaults to the cwd).
    export VKD3D_SHADER_CACHE_PATH="${VKD3D_SHADER_CACHE_PATH:-$cache/vkd3d}"
    export DXVK_STATE_CACHE_PATH="${DXVK_STATE_CACHE_PATH:-$cache/dxvk}"
    mkdir -p -- "$dir/steam" "$VKD3D_SHADER_CACHE_PATH" "$DXVK_STATE_CACHE_PATH" 2>/dev/null || true
    # Retail games create shared fences, which vkd3d-proton mishandles on objects XCL has
    # modified (ivall/xcl#175). XCLENV_SHARED_FENCES=1 turns the workaround off.
    if [[ ${XCLENV_SHARED_FENCES:-0} != 1 && ${VKD3D_CONFIG:-} != *ignore_shared_fence* ]]; then
        export VKD3D_CONFIG="${VKD3D_CONFIG:+$VKD3D_CONFIG,}ignore_shared_fence"
    fi
}

proton() {
    "$PROTON_DIR/proton" "$@"
}

wineserver_wait() {
    WINEPREFIX="$(xclenv_pfx "$1")" "$PROTON_DIR/files/bin/wineserver" -w 2>/dev/null || true
}

# --- locking -------------------------------------------------------------------
#
# One prefix must never be used by two wineservers at once. A sandboxed run has a
# private /tmp, so its wineserver is invisible to wine outside the sandbox; the lock file
# keeps the two apart. xcl-run.sh holds the lock and tells its inner script so.

lock_env_dir() {
    local dir=$1
    [[ ${XCLENV_LOCK_HELD:-0} == 1 ]] && return 0
    exec {XCLENV_LOCK_FD}>>"$dir/.xcl-env.lock" || die "cannot create $dir/.xcl-env.lock"
    flock -n "$XCLENV_LOCK_FD" || die "$dir is in use by another prefix-init / xcl-run (lock: $dir/.xcl-env.lock)"
}
