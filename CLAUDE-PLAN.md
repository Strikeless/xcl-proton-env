# CLAUDE-PLAN.md – research notes and implementation plan

Notes for whoever implements `PLAN.md`. Written 2026-11-23 against the XCL submodule at
`956a476`, which was upstream `main` HEAD at the time.

## 0. User decisions (2026-11-23) – these override the proposals below

- **Build:** cross-compile for MSVC with **cargo-xwin** (option 3 in section 4). The user has
  installed `cargo-xwin` 0.24.1 (`~/.cargo/bin`) and the `x86_64-pc-windows-msvc` target.
- **No own DXVK/vkd3d installs.** Assume **GE-Proton or Proton-CachyOS**; both ship
  vkd3d-proton and DXVK. Plain system wine is not a target. Do not work on the vkd3d vtable
  problem (section 2); the user expects it to be fixed externally within days. Keep it in mind
  when interpreting test results, and keep `VKD3D_CONFIG=ignore_shared_fence` as the default
  workaround.
  - Consequence: let Proton set up the prefix itself, so its DXVK/vkd3d and extras land there.
    Use the `proton` script (`proton run …` with `STEAM_COMPAT_DATA_PATH=<dir>` and
    `STEAM_COMPAT_CLIENT_INSTALL_PATH`), not `files/bin/wine` directly. The real wineprefix
    is then `<dir>/pfx`.
  - Proton-CachyOS is usually at `/usr/share/steam/compatibilitytools.d/proton-cachyos*` (the
    package) or in `compatibilitytools.d`. It is not installed on this machine; GE-Proton
    10-32, 10-34, 11-3 and 11-12 are.
- **Sandbox:** audio (PipeWire/Pulse) and gamepads (`/dev/input`, `/dev/hidraw*`,
  `/run/udev`) are **allowed by default**, with flags to disable them.
- **Shell:** a `#!/usr/bin/env bash` shebang; bash-only is fine.

## 1. What XCL is, from a build/run standpoint

- Rust workspace: `crates/xcl` (the `xcl.exe` binary plus a lib), `tests/testtitle` (a fake
  console title, `xcl_testtitle.exe`), `tests/testgamedll` (a fake middleware DLL,
  `testgame_mw.dll`). There is no `build.rs`, `.cargo/config` or `rust-toolchain` file.
- Only upstream-supported build: Windows with `stable-x86_64-pc-windows-msvc`, using
  `cargo build --release --workspace`.
- One dependency compiles C code: `retour` → `libudis86-sys` (through `cc`). So a **Windows C
  compiler is required** (mingw gcc or clang-cl), not just rustc.
- The design spec says Wine is not a target, but upstream has merged Wine fixes: #92 (GNU-build
  TLS clobbering GetLastError) and #93 (PEB.ImageBaseAddress under Wine). The code detects Wine
  through `wine_get_version` (`crates/xcl/src/loader.rs:332`).

### Runtime requirements (from README and `crates/xcl/src/preflight.rs`)

`xcl run` prints a preflight check list.

| Need | Source under Wine | Required? |
|---|---|---|
| D3D12 with SM 6.6, mesh shaders, wave64 or wave32 | vkd3d-proton (`d3d12.dll`, `d3d12core.dll`) on host Vulkan (RADV here) | yes |
| DXGI / D3D11 / D3D10core | **DXVK**, not Wine's own. With Wine's dxgi, `PresentX` crashes in wined3d (issue #175) | yes |
| DXC: `dxcompiler.dll` + `dxil.dll` | Microsoft release zip, `bin/x64/`. Latest: v1.9.2609, `https://github.com/microsoft/DirectXShaderCompiler/releases/download/v1.9.2609/dxc_2026_09_29.zip`. Looked up in `%XCL_DXC_DIR%`, then next to `xcl.exe`, then Windows Kits | yes (without it, nothing is drawn) |
| `System32\xgameruntime.dll` (Gaming Services) | not obtainable without the MS Store; XCL warns and uses its own partial implementation | no (warning) |
| XAudio2.9 | Wine builtin (FAudio) | yes for audio |
| `mfplat.dll` (Media Foundation) | Wine/Proton builtin | partly (movies) |
| `MSOpusDecoder.dll` | Windows-only; Opus audio is not decoded without it | optional |
| VC++ runtime (`msvcp140`, `vcruntime140`, …) imported by games | Wine builtins; `winetricks vcrun2022` would be safer for real games | likely needed for real games |

Title data goes to `%LOCALAPPDATA%\XCL\<title>\` inside the prefix (or `%XCL_DATA_ROOT%`). XCL
**never writes to the game folder**; writes go to an overlay. So a read-only game dir is fine.

Other environment variables: `XCL_ADAPTER`, `XCL_DXC_DIR`, `XCL_D3D12_DIR`, `XCL_DATA_ROOT`,
`XCL_SPLIT_WAVE64`. Command line: `xcl run <GameDir> [-- game args]`.

## 2. Upstream Linux status – read issue #175 (opened 2026-11-23)

Someone (ozimchuk) ran XCL under Wine 11.21 Staging with vkd3d-proton and DXVK. Their
setup:

- **Build:** cross-compiled on Linux. They used mingw-w64 and
  `rustup target add x86_64-pc-windows-gnu`, with
  `CARGO_TARGET_X86_64_PC_WINDOWS_GNU_LINKER=x86_64-w64-mingw32-gcc-posix`, then
  `cargo build --release --workspace --target x86_64-pc-windows-gnu`. Unmodified `main` builds
  this way.
- **Run:** vkd3d-proton as d3d12/d3d12core, DXVK's dxgi/d3d11/d3d10core, DXC next to `xcl.exe`.

**Blocking XCL-side problem (a non-goal for us, so report it to the user):** XCL replaces the
vtable pointers of host D3D12 objects. vkd3d-proton identifies its objects by vtable pointer:

- `assert(iface->lpVtbl == &…_vtbl)` aborts in builds that keep assertions. Valve's Proton 11.0
  `d3d12core.dll` contains 28 such assertion strings. GE-Proton11-12's contains **0**, so it
  was probably built with NDEBUG.
- Even without assertions, `d3d12_command_list_from_iface` and
  `d3d12_command_allocator_from_iface` return NULL for foreign vtables, which leads to an
  access violation in `ExecuteCommandLists`.
- Shared fences (`D3D12_FENCE_FLAG_SHARED`, used by retail games) deadlock. The workaround is
  `VKD3D_CONFIG=ignore_shared_fence` (present in GE-Proton11-12's vkd3d-proton).
- Result with stock vkd3d-proton: the test title gets 6 PASS, then aborts. With a locally
  relaxed vkd3d-proton build: 47 PASS, 2 FAIL. Upstream fix proposed: proxy objects (not done
  yet).

Other Linux notes from #175:

- **`userfaultfd` must work** (Wine write-watch, needed for GPU/CPU shared title memory).
  Without it, the GPU reads zeros (40 PASS / 9 FAIL). On this machine,
  `vm.unprivileged_userfaultfd = 0` and `/dev/userfaultfd` is root-only. It works only if
  Wine uses `UFFD_USER_MODE_ONLY` (kernel ≥ 5.11 allows that unprivileged). **Verify during
  implementation.** bwrap has no seccomp filter by default, so it does not block the syscall.
- No audio device makes the test title end in xaudio2_9 at its last check.
- A known Wine difference: `GetModuleHandle(NULL)` returns xcl.exe, not the title.

## 3. This machine

- CachyOS, zsh is the login shell, bash 5.3, bwrap 0.13.1, Wine 10.0 (system), winetricks,
  protontricks, rustup/cargo (no Windows targets installed), clang + lld-link, 7z, cabextract,
  curl.
- No mingw-w64 installed (`mingw-w64-gcc` is in the repos). No cargo-xwin.
- Proton: `~/.steam/steam/steamapps/common/Proton {10.0,11.0}`,
  `~/.steam/steam/compatibilitytools.d/GE-Proton{10-32,10-34,11-3,11-12-x86_64}`. Same tree at
  `~/.local/share/Steam/compatibilitytools.d`.
- Proton layout: `<dir>/proton` (python script), `<dir>/files/bin/wine`,
  `<dir>/files/lib/wine/{dxvk,vkd3d-proton}/x86_64-windows/*.dll`.
- GPU: AMD RX 6700 XT (Navi 22, RDNA2, RADV): wave32 and wave64, mesh shaders.
  `/dev/dri/card1` and `/dev/dri/renderD128`.

## 4. Proposed design

### Common: `lib.sh` (sourced helper) and a per-prefix config file

`prefix-init.sh` writes `<prefix-dir>/xcl-env.conf` with the resolved wine binary, its kind
(proton/wine), and paths. The run scripts source that file, so the user only passes
`<prefix-dir>` (default `./pfx`) and the game dir.

### Wine/Proton selection

**Proposed:** accept either a wine binary or a Proton directory, and **always run Proton's
`files/bin/wine` directly** with `WINEPREFIX`. Lutris does the same; it avoids the `proton`
python script, steam.exe, and the nested `pfx/pfx` layout. Auto-detect candidates (system
wine, Steam Proton dirs, compatibilitytools.d) and offer a numbered menu, with a free-form path
as fallback.

- DXVK and vkd3d-proton come from Proton's `files/lib/wine/{dxvk,vkd3d-proton}`. Copy them
  into `system32` and set `DllOverrides` to `native` in the registry, as Proton itself does.
  For system wine, use `winetricks -q dxvk vkd3d` or a user-supplied directory.
- **Do not** put vkd3d-proton in a `D3D12\` folder next to `xcl.exe`. XCL treats that folder as
  the Agility SDK location.
- Option: `--vkd3d-dir DIR` to use a user-provided (for example relaxed/patched) vkd3d-proton
  build. Given section 2, this is the only way XCL can currently get past D3D12 init under
  Wine.

### Building XCL (decided: option 3, cargo-xwin – see section 0)

`PLAN.md` says "install components to the wineprefix required for building XCL and build
XCL". The options:

1. **Cross-compile on the host (recommended).** Needs `mingw-w64-gcc` (pacman) and
   `rustup target add x86_64-pc-windows-gnu`. Copy `xcl/` to `<prefix>/drive_c/xcl/src`, run
   `cargo build --release --workspace --target x86_64-pc-windows-gnu` there, and install the
   artifacts to `drive_c/xcl/bin`. This path is proven by #175 and is fast. Downside: host
   packages instead of prefix components; it is a GNU build, which upstream does not test
   (#92 was a GNU-only bug).
2. **Build inside the prefix with Windows tools under Wine:** rustup-init.exe (gnu host),
   plus a full mingw such as llvm-mingw or w64devkit for `cc`. Matches PLAN.md literally, but
   is slow and fragile (cargo/rustc under Wine), and not proven.
3. **Cross-compile with the MSVC target via cargo-xwin** (clang-cl + lld-link, downloads
   MSVC CRT + Windows SDK, needs Microsoft license acceptance). This is the same ABI as the
   upstream-tested build. Needs `cargo install cargo-xwin` and
   `rustup target add x86_64-pc-windows-msvc`.

Isolate cargo with `CARGO_TARGET_DIR` inside the prefix's build dir. Copy, don't symlink, so
the submodule stays clean.

### Prefix components (prefix-init.sh)

1. `wineboot -u` with `WINEPREFIX`, `WINEARCH=win64`, `WINEDEBUG=-all`; then `wineserver -w`.
2. DXVK (`dxgi`, `d3d11`, `d3d10core`) and vkd3d-proton (`d3d12`, `d3d12core`) as above.
3. DXC: download the zip (pinned version plus sha256), extract `bin/x64/{dxcompiler,dxil}.dll`
   next to `xcl.exe`. Extract in a fresh empty dir; it is untrusted download data.
4. Optional: `winetricks vcrun2022` (prompt), for real games.
5. Build and install XCL as above. Also assemble a **test game** for a smoke test:
   `tests/data/testgame/` plus `xcl_testtitle.exe` plus `testgame_mw.dll` →
   `drive_c/xcl/testgame`. Run with `xcl run <testgame> -- --hello`. Success line:
   `xcl_testtitle: done, failures: 0` (see `crates/xcl/tests/e2e.rs`). This lets us test all
   three scripts without any game files.

### xcl-run-unsandboxed.sh

`xcl-run-unsandboxed.sh [-p PREFIX] GAME_DIR [-- game args]` sources the conf, exports
`WINEPREFIX` and `WINEDLLOVERRIDES`, and runs `wine C:\xcl\bin\xcl.exe run Z:<gamedir> -- …`
(`winepath -w` for conversion). `VKD3D_CONFIG=ignore_shared_fence` is on by default, with an
opt-out. The script passes through `XCL_*` env vars.

### xcl-run.sh (bwrap)

It runs `xcl-run-unsandboxed.sh` inside bwrap. Planned arguments:

- `--unshare-all` (net, ipc, pid, uts, cgroup, user), `--die-with-parent`, `--new-session`,
  `--cap-drop ALL`, `--clearenv` plus a whitelist of env vars.
- `--ro-bind /usr /usr` and the usual `/lib`, `/lib64`, `/bin`, `/sbin` symlinks (CachyOS has
  a merged /usr). `--ro-bind /etc` should be limited to needed files: ld.so.cache, fonts,
  `vulkan/` ICDs, passwd/group, localtime, `machine-id`(?). `/usr/share/vulkan` ICDs are
  under /usr. Read-only binds allow read and exec, never write.
- `--proc /proc`, `--dev /dev`, `--dev-bind /dev/dri /dev/dri` (plus `/dev/nvidia*` if
  present), `--ro-bind /sys` subsets needed by Mesa/udev (`/sys/dev/char`,
  `/sys/devices/pci*`, `/sys/bus/pci`), `--tmpfs /tmp`.
- Prefix dir: read-write (Wine needs registry writes, XCL writes title data). Hardening: the
  XCL install dir (`drive_c/xcl`) and the scripts are re-bound read-only on top.
- Wine/Proton install dir: read-only. Game dir: read-only, mounted at a fixed path, for
  example `/game`.
- Display: X11 socket file `/tmp/.X11-unix/X$N` plus Xauthority, read-only. The abstract
  X11 socket is unreachable with `--unshare-net`; the filesystem socket works. Wayland socket
  only if the Wine Wayland driver is wanted. (decided: on by default – see section 0) audio and gamepads:
  by default:
  - audio: `$XDG_RUNTIME_DIR/pulse/native` (pipewire-pulse) socket;
  - gamepads: `/dev/input/event*`, `/dev/hidraw*`, `/run/udev` read-only.
- No D-Bus, no home, no network.
- `--unshare-ipc` breaks X11 MIT-SHM. Wine copes, but verify there are no errors or slowdowns.
- Only one wineserver per prefix: the sandbox has a private `/tmp`, so its wineserver cannot
  see one running outside. Refuse to start (or `wineserver -k`) if a wineserver for the prefix
  is running outside the sandbox.

### Shell compatibility (decided: bash – see section 0)

Proposal: `#!/usr/bin/env bash` scripts that also work when invoked as `zsh script.sh`
(no arrays/indexing tricks that differ, or detect zsh and `emulate -L sh`/`setopt KSH_ARRAYS`).
Simplest honest option: bash shebang and bash-only, which works from a zsh login shell.

## 5. Verification plan

1. `prefix-init.sh` with GE-Proton11-12 into a scratch dir, then the build succeeds and the
   preflight (`xcl run` prints checks) shows GPU, DXC, SM 6.6 and mesh.
2. Test title via the unsandboxed script, then via the sandboxed one; compare PASS/FAIL
   counts. Expect a vkd3d-proton vtable failure unless a relaxed vkd3d-proton is supplied.
3. Sandbox checks inside bwrap: no network (`curl` fails / no interfaces besides lo), `/home`
   absent, writing to `/usr` fails, the game dir is read-only.

## 6. Implementation findings (2026-11-23) – what the scripts actually do and why

- **cargo-xwin + libudis86-sys:** its build.rs passes the gcc flag `-includestring.h`,
  which clang-cl ignores, so the build fails on an implicit `memset`. cargo-xwin
  *overwrites* `CFLAGS_x86_64_pc_windows_msvc`, so the fix is
  `CC_x86_64-pc-windows-msvc=clang-cl /FIstring.h`. cc-rs ranks the hyphenated variable
  above the underscore one that cargo-xwin sets. A full release build takes about 30 s.
- **Proton verbs:**
  - Any verb except `runinprefix` (re)builds the prefix, so `getcompatpath <path>` is used
    for "create / update the prefix and translate a path".
  - `run` goes through `steam.exe`, except on GE-Proton with `UMU_ID` set; avoid it.
  - XCL runs with `runinprefix`. That verb does **not** set Proton's DXVK / vkd3d-proton
    DLL overrides (they are set inside `setup_prefix`), so without our own
    `WINEDLLOVERRIDES=dxgi,d3d9,d3d10core,d3d11,d3d12,d3d12core=n`, Wine's builtin
    vkd3d is used ("Feature level 0xc000 is not supported", WARP fallback).
  - Env vars set: `SteamAppId=0` / `SteamGameId=0` / `STEAM_COMPAT_APP_ID=0`. GE's
    protonfixes needs a game id, otherwise it does a regex on the compat path.
    `STEAM_COMPAT_CLIENT_INSTALL_PATH` points at an empty `<dir>/steam`.
  - Proton records the Proton, compat-data and Steam paths in `<dir>/config_info`. The
    sandbox mounts everything at its real path so the prefix is not rebuilt on every run.
- **vkd3d-proton shader cache** defaults to the cwd, which is the game folder. XCL's VFS
  then redirects the write into its overlay. `VKD3D_SHADER_CACHE_PATH` points it to
  `<dir>/cache`.
- **GE-Proton11-12** on this machine fails to create a prefix: "unimplemented function
  win32u.NtGdiDdDDIQueryFSEBlock / ole32.CoInitialize". This is a Proton build or
  installation problem. GE-Proton11-3 and 10-34 work, and testing used GE-Proton11-3.
- **GE-Proton protonfixes** fetches an upscaler manifest from the network (FSR4 is on by
  default). In the sandbox this fails with a harmless `CRIT ... name resolution` line.
- The user has the lsfg-vk implicit Vulkan layer. It prints "Invalid enum name: none"
  errors, which are harmless; `DISABLE_LSFGVK=1` silences it.
- **Test title results (GE-Proton11-3, RX 6700 XT):** 36 PASS / 14 FAIL on the first run.
  The fails are D3D12.X "Invalid parameter" (vkd3d vtable issue, #175), the XAudio2 XMA2
  check, xmem working-set statistics, and the window not being cloaked. All are XCL / Wine
  side. Later runs fail one more check (the overlay delete check) because XCL's overlay
  keeps the earlier deletion.
- **Sandbox:** `--overlay-src DIR --tmp-overlay DIR` works for the environment dir on ext4
  and tmpfs. The rw binds of the XCL data dir and the cache dir go on top of it and
  persist. `--remount-ro /` comes last. Verified from inside: only `lo`, no `/home`
  contents, `/usr`, the game and `/etc` read-only, prefix writes discarded, nested
  userns refused, X11 and PipeWire-pulse reachable.
