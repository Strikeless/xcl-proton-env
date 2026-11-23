#!/usr/bin/env bash
# Create (or update) a Proton wineprefix with XCL built and installed in it.
set -euo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/lib/common.sh"

# Microsoft's DirectX Shader Compiler (XCL compiles translated shaders with it at run time).
DXC_URL='https://github.com/microsoft/DirectXShaderCompiler/releases/download/v1.9.2609/dxc_2026_09_29.zip'
DXC_SHA256='ad31b1fc8443175d204f77a611fdb3ef2ec42759bdc2f1167368de24a4a7e7f1'
XCL_TARGET='x86_64-pc-windows-msvc'

usage() {
    cat <<EOF
Usage: ${0##*/} [options] [DIR]

Creates an XCL environment in DIR (default: $XCLENV_DEFAULT_DIR):
a Proton wineprefix (DIR/pfx), XCL cross-compiled from ./xcl with cargo-xwin and
installed to C:\\xcl, Microsoft's DXC next to it, and XCL's test title in C:\\xcl\\testgame.
Running it again on an existing DIR updates the source copy, rebuilds and reinstalls.

Options:
  -p, --proton PATH   Proton directory to use (GE-Proton, Proton-CachyOS, ...); prompts if
                      not given (for a new DIR) and defaults to the one used before.
  -y, --yes           Do not prompt: use the first Proton found (unless --proton) and accept
                      the license prompts (see below).
      --debug         Build XCL in debug instead of release mode.
  -h, --help          Show this help.

cargo-xwin downloads the MSVC CRT and Windows SDK from Microsoft; using them means
accepting Microsoft's license terms, which ${0##*/} asks about before the first build.
EOF
}

proton_arg= dir= profile=release
while (($#)); do
    case $1 in
        -p|--proton) [[ $# -ge 2 ]] || die "$1 needs an argument"; proton_arg=$2; shift 2 ;;
        -y|--yes) export XCLENV_ASSUME_YES=1; shift ;;
        --debug) profile=debug; shift ;;
        -h|--help) usage; exit 0 ;;
        --) shift; break ;;
        -*) die "unknown option: $1 (see --help)" ;;
        *) [[ -z $dir ]] || die "only one DIR may be given"; dir=$1; shift ;;
    esac
done
if (($#)); then
    [[ -z $dir && $# == 1 ]] || die "too many arguments (see --help)"
    dir=$1
fi
dir=$(resolve_env_dir "${dir:-$XCLENV_DEFAULT_DIR}")

need_cmd python3 cargo rustup rsync curl unzip sha256sum flock realpath clang-cl lld-link
cargo xwin --version >/dev/null 2>&1 || die "cargo-xwin is not installed (cargo install --locked cargo-xwin)"
rustup target list --installed 2>/dev/null | grep -qx "$XCL_TARGET" \
    || die "Rust target $XCL_TARGET is not installed (rustup target add $XCL_TARGET)"
[[ -f $XCLENV_ROOT/xcl/Cargo.toml ]] \
    || die "XCL submodule is missing – run: git -C '$XCLENV_ROOT' submodule update --init"

# --- 1. choose Proton --------------------------------------------------------------

choose_proton() {
    local -a cands
    mapfile -t cands < <(find_proton_candidates)
    if [[ ${XCLENV_ASSUME_YES:-0} == 1 ]]; then
        ((${#cands[@]})) || die "no Proton installation found – pass one with --proton"
        PROTON_DIR=${cands[0]}
        return
    fi
    [[ -r /dev/tty ]] || die "no terminal to prompt on – pass --proton PATH (or -y)"
    local i ans
    {
        echo "Choose the Proton build to use (GE-Proton or Proton-CachyOS recommended):"
        for i in "${!cands[@]}"; do
            printf '  %2d) %s\n      %s\n' "$((i + 1))" "$(proton_label "${cands[i]}")" "${cands[i]}"
        done
        echo "   p) enter a path"
    } >&2
    while :; do
        read -r -p "Selection: " ans </dev/tty || die "aborted"
        if [[ $ans =~ ^[0-9]+$ ]] && ((ans >= 1 && ans <= ${#cands[@]})); then
            PROTON_DIR=${cands[ans - 1]}
            return
        elif [[ $ans == p ]]; then
            read -r -p "Proton directory (containing the 'proton' script): " ans </dev/tty || die "aborted"
            ans=${ans/#\~/$HOME}
            if is_proton_dir "$ans"; then PROTON_DIR=$(realpath -- "$ans"); return; fi
            warn "not a Proton directory: $ans"
        else
            warn "invalid selection"
        fi
    done
}

PROTON_DIR=
if [[ -n $proton_arg ]]; then
    is_proton_dir "$proton_arg" || die "not a Proton directory (no proton script / files/bin/wine): $proton_arg"
    PROTON_DIR=$(realpath -- "$proton_arg")
elif [[ -f $dir/$XCLENV_CONF_NAME ]]; then
    load_conf "$dir"
else
    choose_proton
fi

msg "Environment: $dir"
info "Proton: $(proton_label "$PROTON_DIR") – $PROTON_DIR"
case $(basename -- "$PROTON_DIR") in
    *GE-Proton*|*[Cc]achy*) ;;
    *) warn "this is neither GE-Proton nor Proton-CachyOS; other Proton builds are untested" ;;
esac

mkdir -p -- "$dir"
lock_env_dir "$dir"

# --- 2. create / update the wineprefix ---------------------------------------------

msg "Creating / updating the wineprefix with Proton (DXVK, vkd3d-proton, ...)"
proton_env "$dir"
# Any verb but "runinprefix" makes Proton (re)build the prefix; "getcompatpath" does
# nothing else of note. Proton logs to stderr.
proton getcompatpath "$dir" >/dev/null || die "Proton failed to set up the prefix"
wineserver_wait "$dir"
[[ -f $(xclenv_pfx "$dir")/system.reg ]] || die "Proton did not create a prefix in $(xclenv_pfx "$dir")"
write_conf "$dir" "$PROTON_DIR"

# --- 3. build XCL ------------------------------------------------------------------

msg "Copying XCL source to $dir/build/src"
xcl_rev=$(git -C "$XCLENV_ROOT/xcl" describe --always --dirty 2>/dev/null || echo unknown)
info "XCL revision: $xcl_rev"
mkdir -p -- "$dir/build/src"
rsync -a --delete --exclude=/target --exclude=.git -- "$XCLENV_ROOT/xcl/" "$dir/build/src/"

xwin_cache=${XWIN_CACHE_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/cargo-xwin}
if [[ ! -d $xwin_cache/xwin ]]; then
    {
        echo
        echo "cargo-xwin will now download the MSVC CRT and the Windows SDK from Microsoft"
        echo "(into $xwin_cache). Their use is subject to Microsoft's license terms:"
        echo "  https://go.microsoft.com/fwlink/?LinkId=2086102"
        echo
    } >&2
    ask_yes_no "Do you accept Microsoft's license terms?" n || die "license not accepted – cannot build XCL"
fi

msg "Building XCL ($profile, $XCL_TARGET) with cargo-xwin"
build_flags=(--workspace --locked --target "$XCL_TARGET")
[[ $profile == release ]] && build_flags+=(--release)
(
    cd -- "$dir/build/src"
    # libudis86-sys (via retour) passes the gcc-style "-includestring.h", which clang-cl
    # ignores; force-include string.h the MSVC way. The hyphenated variable outranks
    # the underscore one that cargo-xwin sets, so cargo-xwin's own flags stay intact.
    env CARGO_TARGET_DIR="$dir/build/target" \
        XWIN_ARCH=x86_64 \
        "CC_${XCL_TARGET}=clang-cl /FIstring.h" \
        cargo xwin build "${build_flags[@]}"
) || die "XCL build failed"

out="$dir/build/target/$XCL_TARGET/$profile"
for f in xcl.exe xcl_testtitle.exe testgame_mw.dll; do
    [[ -f $out/$f ]] || die "build output missing: $out/$f"
done

# --- 4. install XCL, DXC and the test title -----------------------------------------

xcl_dir=$(xclenv_xcl_dir "$dir")
msg "Installing XCL to $XCLENV_WIN_XCL_DIR ($xcl_dir)"
mkdir -p -- "$xcl_dir"
install -m 0755 -- "$out/xcl.exe" "$xcl_dir/xcl.exe"
[[ -f $out/xcl.pdb ]] && install -m 0644 -- "$out/xcl.pdb" "$xcl_dir/xcl.pdb"
printf '%s\n' "$xcl_rev" >"$xcl_dir/XCL_REVISION"

msg "Installing DXC (dxcompiler.dll, dxil.dll)"
dl="$dir/downloads/${DXC_URL##*/}"
mkdir -p -- "$dir/downloads"
if ! { [[ -f $dl ]] && sha256sum --quiet -c <<<"$DXC_SHA256  $dl" 2>/dev/null; }; then
    info "downloading $DXC_URL"
    curl -fL --proto '=https' --retry 3 -o "$dl.part" -- "$DXC_URL" || die "DXC download failed"
    sha256sum --quiet -c <<<"$DXC_SHA256  $dl.part" || { rm -f -- "$dl.part"; die "DXC checksum mismatch"; }
    mv -f -- "$dl.part" "$dl"
fi
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT
# The zip stores Windows paths ("bin\x64\..."); '?' matches the backslash.
unzip -q -j -d "$tmp" -- "$dl" 'bin?x64?dxcompiler.dll' 'bin?x64?dxil.dll' 2>/dev/null \
    || [[ -f $tmp/dxcompiler.dll && -f $tmp/dxil.dll ]] || die "could not extract DXC from $dl"
install -m 0644 -- "$tmp/dxcompiler.dll" "$tmp/dxil.dll" "$xcl_dir/"

msg "Installing XCL's test title to $XCLENV_WIN_XCL_DIR\\testgame"
rm -rf -- "$xcl_dir/testgame"
mkdir -p -- "$xcl_dir/testgame"
cp -r -- "$dir/build/src/tests/data/testgame/." "$xcl_dir/testgame/"
install -m 0755 -- "$out/xcl_testtitle.exe" "$out/testgame_mw.dll" "$xcl_dir/testgame/"

# The sandbox (xcl-run.sh) keeps only these writable; they must exist beforehand.
mkdir -p -- "$(xclenv_data_dir "$dir")" "$(xclenv_cache "$dir")/mesa"

wineserver_wait "$dir"

msg "Done."
envopt=
[[ $dir == "$XCLENV_DEFAULT_DIR" ]] || envopt="-e '$dir' "
cat >&2 <<EOF

    Run a game (sandboxed):    ./xcl-run.sh ${envopt}/path/to/GameFolder [-- game args]
    Run without the sandbox:   ./xcl-run-unsandboxed.sh ${envopt}/path/to/GameFolder
    Smoke test (test title):   ./xcl-run.sh ${envopt}'$xcl_dir/testgame' -- --hello

EOF
