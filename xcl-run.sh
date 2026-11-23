#!/usr/bin/env bash
# Run XCL on a game folder inside a bubblewrap sandbox (no network, no home directory,
# read-only system), wrapping xcl-run-unsandboxed.sh.
set -euo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/lib/common.sh"

usage() {
    cat <<EOF
Usage: ${0##*/} [options] GAME_DIR [-- GAME_ARGS...]

Runs xcl-run-unsandboxed.sh inside a bubblewrap sandbox:
  - no network (only a private loopback interface)
  - no access to /home or other user files: only the XCL environment, the Proton
    installation, the game folder and this script directory are visible
  - /usr (and /lib, /bin, ... links), Proton and the game folder are read-only
  - the wineprefix is overlaid with a throwaway layer: changes the game makes to it are
    discarded on exit, except XCL's title data (saves, logs) and the shader caches
  - GPU (/dev/dri, NVIDIA devices), display (X11; Wayland with --wayland), audio
    (PulseAudio/PipeWire) and gamepads (/dev/input, /dev/hidraw*) are available

Options:
  -e, --env DIR     XCL environment made by prefix-init.sh (default: $XCLENV_DEFAULT_DIR).
      --no-audio    Do not give the sandbox the PulseAudio/PipeWire socket.
      --no-gamepad  Do not give the sandbox input devices (/dev/input, /dev/hidraw*).
      --wayland     Also give it the Wayland socket (for Proton's Wayland driver,
                    e.g. GE-Proton with PROTON_ENABLE_WAYLAND=1).
      --shell       Start an interactive shell in the sandbox instead of XCL (debugging).
  -h, --help        Show this help.
EOF
}

dir= game= audio=1 gamepad=1 wayland=0 shell=0
while (($#)); do
    case $1 in
        -e|--env) [[ $# -ge 2 ]] || die "$1 needs an argument"; dir=$2; shift 2 ;;
        --no-audio) audio=0; shift ;;
        --no-gamepad) gamepad=0; shift ;;
        --wayland) wayland=1; shift ;;
        --shell) shell=1; shift ;;
        -h|--help) usage; exit 0 ;;
        --) shift; break ;;
        -*) die "unknown option: $1 (see --help)" ;;
        *) [[ -z $game ]] || die "only one GAME_DIR may be given (game arguments go after --)"; game=$1; shift ;;
    esac
done
[[ -n $game ]] || { usage >&2; exit 2; }
dir=$(resolve_env_dir "${dir:-$XCLENV_DEFAULT_DIR}")
[[ -d $game ]] || die "game folder not found: $game"
game=$(realpath -- "$game")

need_cmd bwrap python3 flock realpath
bwrap --help 2>&1 | grep -q -- '--tmp-overlay' || die "bubblewrap is too old (need --tmp-overlay, bwrap >= 0.10)"
load_conf "$dir"
[[ -f $(xclenv_xcl_dir "$dir")/xcl.exe ]] || die "XCL is not installed in $dir – run prefix-init.sh"
data_dir=$(xclenv_data_dir "$dir")
cache_dir=$(xclenv_cache "$dir")
mkdir -p -- "$data_dir" "$cache_dir/mesa" "$cache_dir/vkd3d" "$cache_dir/dxvk"
lock_env_dir "$dir"

uid=$(id -u)
args=(
    --die-with-parent
    --unshare-all          # net, ipc, pid, uts, cgroup (+ user)
    --unshare-user
    --disable-userns       # no nested user namespaces inside the sandbox
    --cap-drop ALL
    --new-session          # no TIOCSTI injection into the calling terminal
    --clearenv
)

# --- system: read-only (r+x), never writable --------------------------------------

args+=(--ro-bind /usr /usr)
for d in /bin /sbin /lib /lib32 /lib64; do
    if [[ -L $d ]]; then
        args+=(--symlink "$(readlink -- "$d")" "$d")
    elif [[ -d $d ]]; then
        args+=(--ro-bind "$d" "$d")
    fi
done
# Only the parts of /etc that the dynamic linker, fontconfig, Vulkan/Mesa and name
# lookups of the own user need.
for f in ld.so.cache ld.so.conf ld.so.conf.d fonts vulkan drirc alternatives \
         passwd group nsswitch.conf localtime locale.conf os-release; do
    [[ -e /etc/$f ]] && args+=(--ro-bind "/etc/$f" "/etc/$f")
done

args+=(
    --proc /proc
    --dev /dev
    --tmpfs /tmp
    --perms 0700 --dir "/run/user/$uid"
)

# GPU: DRM nodes, NVIDIA's device files, and the sysfs entries drivers probe.
[[ -d /dev/dri ]] && args+=(--dev-bind /dev/dri /dev/dri)
for f in /dev/nvidia* /dev/nvidia-caps; do
    [[ -e $f ]] && args+=(--dev-bind "$f" "$f")
done
# Wine's fast synchronisation primitives (GE-Proton 10+ / Proton-CachyOS).
[[ -e /dev/ntsync ]] && args+=(--dev-bind /dev/ntsync /dev/ntsync)
for d in /sys/dev /sys/devices /sys/bus /sys/class; do
    [[ -d $d ]] && args+=(--ro-bind "$d" "$d")
done

# --- the XCL environment, Proton, the game -------------------------------------------

# Everything is mounted at its real path: Proton records its own and the prefix's paths
# in the prefix and would otherwise rebuild it on every run.
args+=(
    --ro-bind "$PROTON_DIR" "$PROTON_DIR"
    # The whole environment dir gets a throwaway writable layer: wine can update its
    # registry and Proton its bookkeeping, but nothing the game does to the prefix (DLLs,
    # registry autostarts, ...) survives the run, so it cannot reach unsandboxed runs.
    --overlay-src "$dir" --tmp-overlay "$dir"
    # What should persist: XCL's title data and the shader caches.
    --bind "$data_dir" "$data_dir"
    --bind "$cache_dir" "$cache_dir"
    # The game folder: read-only (XCL redirects all writes to its overlay in data_dir).
    --ro-bind "$game" "$game"
    # The scripts that run inside.
    --ro-bind "$XCLENV_ROOT/lib" "$XCLENV_ROOT/lib"
    --ro-bind "$XCLENV_ROOT/xcl-run-unsandboxed.sh" "$XCLENV_ROOT/xcl-run-unsandboxed.sh"
)

# --- environment -------------------------------------------------------------------

args+=(
    --setenv PATH /usr/local/bin:/usr/bin:/bin
    --setenv HOME /tmp/home
    --dir /tmp/home
    --setenv USER "${USER:-user}"
    --setenv XDG_RUNTIME_DIR "/run/user/$uid"
    --setenv TERM "${TERM:-dumb}"
    --setenv MESA_SHADER_CACHE_DIR "$cache_dir/mesa"
    --setenv XCLENV_IN_SANDBOX 1
    --setenv XCLENV_LOCK_HELD 1
)
# Tuning / debugging variables pass through; nothing else from the caller's environment.
while IFS='=' read -r -d '' name value; do
    case $name in
        LANG|LANGUAGE|LC_*|TZ|\
        XCL_*|XCLENV_SHARED_FENCES|PROTON_*|DXVK_*|VKD3D_*|WINEDEBUG|WINEDLLOVERRIDES|WINEESYNC|WINEFSYNC|\
        MESA_*|RADV_*|AMD_*|ACO_*|__GL_*|__NV_*|VK_*|DISABLE_*|ENABLE_*|MANGOHUD*|SDL_*|DRI_PRIME)
            args+=(--setenv "$name" "$value") ;;
    esac
done < <(env -0)

# --- display --------------------------------------------------------------------------

have_display=0
if [[ -n ${DISPLAY:-} ]]; then
    # Only local displays: the abstract X11 socket is unreachable without the network
    # namespace, the socket file in /tmp/.X11-unix works.
    [[ $DISPLAY =~ ^(unix)?:([0-9]+)(\.[0-9]+)?$ ]] || die "unsupported DISPLAY '$DISPLAY' (only local X11 displays)"
    xsock="/tmp/.X11-unix/X${BASH_REMATCH[2]}"
    [[ -S $xsock ]] || die "X11 socket $xsock not found"
    args+=(--ro-bind "$xsock" "$xsock" --setenv DISPLAY "$DISPLAY")
    xauth=${XAUTHORITY:-$HOME/.Xauthority}
    if [[ -f $xauth ]]; then
        args+=(--ro-bind "$xauth" /tmp/.Xauthority --setenv XAUTHORITY /tmp/.Xauthority)
    fi
    have_display=1
fi
if ((wayland)) && [[ -n ${WAYLAND_DISPLAY:-} ]]; then
    wsock=$WAYLAND_DISPLAY
    [[ $wsock == /* ]] || wsock="${XDG_RUNTIME_DIR:-/run/user/$uid}/$wsock"
    [[ -S $wsock ]] || die "Wayland socket $wsock not found"
    args+=(--ro-bind "$wsock" "/run/user/$uid/wayland-0" --setenv WAYLAND_DISPLAY wayland-0)
    have_display=1
fi
((have_display)) || warn "no DISPLAY – the game will have no window"

# --- audio ----------------------------------------------------------------------------

if ((audio)); then
    psock=${PULSE_SERVER:-}
    psock=${psock#unix:}
    [[ -n $psock && $psock == /* ]] || psock="${XDG_RUNTIME_DIR:-/run/user/$uid}/pulse/native"
    if [[ -S $psock ]]; then
        args+=(--ro-bind "$psock" "/run/user/$uid/pulse/native"
               --setenv PULSE_SERVER "unix:/run/user/$uid/pulse/native")
    else
        warn "no PulseAudio/PipeWire socket at $psock – no audio"
    fi
fi

# --- gamepads ---------------------------------------------------------------------

if ((gamepad)); then
    [[ -d /dev/input ]] && args+=(--dev-bind /dev/input /dev/input)
    for f in /dev/hidraw*; do
        [[ -e $f ]] && args+=(--dev-bind "$f" "$f")
    done
    # udev's device database, so wine/SDL can enumerate (no hotplug: udev's netlink
    # events do not reach the separate network namespace).
    [[ -d /run/udev ]] && args+=(--ro-bind /run/udev /run/udev)
fi

# Nothing outside the binds above (and /tmp) is writable, not even the sandbox's own root.
args+=(--remount-ro /)

# --- run -----------------------------------------------------------------------------

if ((shell)); then
    msg "Sandbox shell (environment: $dir, game: $game)"
    bwrap "${args[@]}" --chdir /tmp/home -- /bin/bash -i
    exit $?
fi

msg "Running XCL in the sandbox – game: $game"
set +e
bwrap "${args[@]}" --chdir /tmp/home -- \
    "$XCLENV_ROOT/xcl-run-unsandboxed.sh" -e "$dir" "$game" ${1+-- "$@"}
rc=$?
set -e
exit "$rc"
