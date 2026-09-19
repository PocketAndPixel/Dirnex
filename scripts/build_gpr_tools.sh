#!/bin/sh

# Rebuild the bundled GoPro RAW decoder, `Packaging/Helpers/gpr_tools` (PLAN.md §M28).
#
# The binary is checked in because it has to be there for an ordinary `xcodebuild` — a developer
# building Dirnex should not need CMake, and a Debug run that silently lacked the helper would show
# every GPR as an empty preview rather than failing loudly. This script is what keeps that binary
# from being an opaque blob: it reproduces it from a pinned upstream commit, so anyone can check
# what is in the bundle.
#
# Why a bundled helper at all: macOS ships no VC-5 decoder, so a GPR cannot be decoded by ImageIO or
# Core Image at all (▸ `GoProRAW` in DirnexCore for the measurements). And why a separate *process*
# rather than a linked library: a truncated GPR makes the decoder call `abort()` — measured,
# `libc++abi: terminating due to uncaught exception of type dng_exception`, SIGABRT — which in
# process is Dirnex gone, on a file the cursor merely passed over.
#
# Universal because Dirnex ships universal (`lipo -archs` on the installed app reads
# `x86_64 arm64`), and pinned to macOS 14 to match MACOSX_DEPLOYMENT_TARGET.
#
# Env:
#   GPR_COMMIT   upstream commit to build (default: the pinned one below).
#   KEEP_BUILD   set to keep the checkout and build tree for inspection.

set -eu

ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
OUT="$ROOT_DIR/Packaging/Helpers/gpr_tools"
REPO="https://github.com/gopro/gpr.git"
# Pinned so the checked-in binary is reproducible. Bump deliberately, and re-run the live check in
# docs/NOTES.md (▸ GoPro RAW) afterwards.
GPR_COMMIT="${GPR_COMMIT:-446c736a38fb14f51343605c0780d347dc602f89}"

WORK=$(mktemp -d)
cleanup() {
    if [ -z "${KEEP_BUILD:-}" ]; then rm -rf "$WORK"; fi
}
trap cleanup EXIT

echo "Cloning $REPO at $GPR_COMMIT"
git clone --quiet "$REPO" "$WORK/gpr"
git -C "$WORK/gpr" checkout --quiet "$GPR_COMMIT"

# The upstream CMakeLists declares `cmake_minimum_required(VERSION 3.5)`, which CMake 4 removed
# compatibility for; the policy override is what lets a current CMake configure it unchanged, rather
# than patching a vendored file we would then have to keep patched.
mkdir -p "$WORK/build"
cd "$WORK/build"
cmake \
    -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_OSX_ARCHITECTURES="arm64;x86_64" \
    -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0 \
    "$WORK/gpr" > "$WORK/cmake.log" 2>&1
make -j"$(sysctl -n hw.ncpu)" > "$WORK/make.log" 2>&1

BUILT="$WORK/build/source/app/gpr_tools/gpr_tools"
[ -f "$BUILT" ] || { echo "build produced no gpr_tools; see $WORK/make.log" >&2; exit 1; }

mkdir -p "$(dirname "$OUT")"
cp "$BUILT" "$OUT"
strip -x "$OUT"
chmod 755 "$OUT"

echo "Wrote $OUT"
lipo -archs "$OUT"
shasum -a 256 "$OUT"
