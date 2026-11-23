#!/usr/bin/env bash
# Run XCL on a game folder inside an environment made by prefix-init.sh – no sandbox.
set -euo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/lib/common.sh"

usage() {
    cat <<EOF
Usage: ${0##*/} [-e DIR] GAME_DIR [-- GAME_ARGS...]

Runs 'xcl.exe run GAME_DIR' with Proton in the XCL environment DIR
(default: $XCLENV_DEFAULT_DIR). GAME_DIR is the unpacked game folder (the one with
MicrosoftGame.config). XCL never writes to it; title data (saves, logs, report.json)
goes to %LOCALAPPDATA%\\XCL\\<title> inside the prefix:
  DIR/pfx/drive_c/users/steamuser/AppData/Local/XCL

This runs the game with your user's full access. Prefer xcl-run.sh (sandboxed).

Options:
  -e, --env DIR   XCL environment made by prefix-init.sh.
  -h, --help      Show this help.

Environment: XCL_*, PROTON_*, DXVK_*, VKD3D_*, WINEDEBUG, ... are passed through.
XCLENV_SHARED_FENCES=1 drops the default VKD3D_CONFIG=ignore_shared_fence.
EOF
}

dir= game=
while (($#)); do
    case $1 in
        -e|--env) [[ $# -ge 2 ]] || die "$1 needs an argument"; dir=$2; shift 2 ;;
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

need_cmd python3 flock realpath
load_conf "$dir"
[[ -f $(xclenv_xcl_dir "$dir")/xcl.exe ]] || die "XCL is not installed in $dir – run prefix-init.sh"
lock_env_dir "$dir"
proton_env "$dir"

# Proton maps Z: to /. "getcompatpath" also brings the prefix up to date first (after a
# Proton update), which "runinprefix" alone would not.
winpath=$(proton getcompatpath "$game" | tail -n 1 | tr -d '\r') || die "Proton could not translate $game"
[[ $winpath == [A-Za-z]:\\* ]] || die "unexpected path from Proton: '$winpath'"

xcl_args=(run "$winpath")
(($#)) && xcl_args+=(-- "$@")

if [[ ${XCLENV_IN_SANDBOX:-0} != 1 ]]; then
    msg "Running XCL (unsandboxed) – game: $game"
fi
set +e
proton runinprefix "$XCLENV_WIN_XCL_EXE" "${xcl_args[@]}"
rc=$?
set -e
# Let wineserver flush the registry and exit before the lock is released / the sandbox
# is torn down.
wineserver_wait "$dir"
exit "$rc"
