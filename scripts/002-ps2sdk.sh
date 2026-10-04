#!/bin/bash
# 002-ps2sdk.sh by ps2dev developers (Android-host variant)
#
# Two different kinds of code are built here, and they need DIFFERENT compilers:
#   * PS2 code (EE/IOP libraries, startup files, IRX modules): must be compiled by
#     an x86_64 cross compiler that can run on this Ubuntu machine. The Android
#     (aarch64) compiler built earlier cannot be executed here ("Syntax error: ')'
#     unexpected" is what the shell says when it tries).
#   * Host tools (bin2c, ps2-irxgen, romimg, srxfixup, ...): must be Android
#     binaries, because they are what ships in the package.
# So: PHASE 1 builds/installs everything with x86_64 tools (the object files and
# libraries are plain PS2 data, identical on every host); PHASE 2 rebuilds only
# the host tools with the Android compiler and overwrites the x86 ones.

## Exit with code 1 when any command executed returns a non-zero exit code.
onerr()
{
  exit 1;
}
trap onerr ERR

## Read information from the configuration file.
source "$(dirname "$0")/../config/ps2dev-config.sh"
## Absolute path now: this script later does "cd" into the cloned repository.
CONFIG_DIR="$(cd "$(dirname "$0")/../config" && pwd)"

## Download the source code.
REPO_URL="$PS2SDK_REPO_URL"
REPO_REF="$PS2SDK_DEFAULT_REPO_REF"
REPO_FOLDER="$(s="$REPO_URL"; s=${s##*/}; printf "%s" "${s%.*}")"

# Checking if a specific Git reference has been passed in parameter $1
if test -n "$1"; then
  REPO_REF="$1"
  printf 'Using specified repo reference %s\n' "$REPO_REF"
fi

if test ! -d "$REPO_FOLDER"; then
  git clone --depth 1 -b "$REPO_REF" "$REPO_URL" "$REPO_FOLDER"
else
  git -C "$REPO_FOLDER" remote set-url origin "$REPO_URL"
  git -C "$REPO_FOLDER" fetch origin "$REPO_REF" --depth=1
  git -C "$REPO_FOLDER" checkout -f FETCH_HEAD
fi

cd "$REPO_FOLDER"

# make sure ps2sdk's makefile does not use it
unset PS2SDKSRC

## These must be set (by config/ci-env.sh); several paths below are derived from them.
: "${PS2DEV:?PS2DEV is not set}"
: "${PS2SDK:?PS2SDK is not set}"

## Determine the maximum number of processes that Make can work with.
PROC_NR=$(getconf _NPROCESSORS_ONLN)

## Find an x86_64 PS2 cross toolchain that runs on this machine (see config/ps2dev-x86.sh).
source "$CONFIG_DIR/ps2dev-x86.sh"
ps2dev_x86_setup

## ------------------------------------------------------------------
## PHASE 1: build + install everything with x86_64 tools.
## ------------------------------------------------------------------
## ps2sdk installs crt0.o and friends INTO the toolchain tree. In a normal full build
## these folders already exist (created by the toolchain step); when the toolchain
## step is skipped (dev mode) they must be created here. mkdir -p is harmless otherwise.
mkdir -p "$PS2DEV/ee/mips64r5900el-ps2-elf/lib" "$PS2DEV/ee/mips64r5900el-ps2-elf/include" \
         "$PS2DEV/iop/mipsel-none-elf/lib" "$PS2DEV/iop/mipsel-none-elf/include" \
         "$PS2DEV/dvp" "$PS2DEV/bin"

## A previous package may have left Android (aarch64) tools in $PS2SDK/bin; never run them.
rm -rf "${PS2SDK:?PS2SDK is not set}/bin"

## Marker that tells later steps (and the dev cache) that ps2sdk is complete.
## Build-state marker: kept OUTSIDE $PS2DEV so the package has exactly the official layout.
PS2DEV_STATE_DIR="$(dirname "$PS2DEV")/.ps2dev-state"
mkdir -p "$PS2DEV_STATE_DIR"
rm -f "$PS2DEV_STATE_DIR/ps2sdk-step-ok"

echo "=== PHASE 1: PS2 libraries + x86 helper tools (x86_64 toolchain) ==="
## Build and install.
run_x86 make -j "$PROC_NR" clean
run_x86 make -j "$PROC_NR" || run_x86 make -j "$PROC_NR" clean
## If the multi-job build failed, then build it with a single job.
## Otherwise, it won't build anything since it is already built.
run_x86 make -j 1
run_x86 make -j "$PROC_NR" install
run_x86 make -j "$PROC_NR" clean

## Point the x86 toolchain at the freshly installed ps2sdk (crt0.o + libcglue, libkernel, ...).
ps2dev_x86_link_sdk

## Keep a copy of the x86 helper tools: later steps (ports, ...) must RUN them
## during their build, which the Android versions installed below cannot do.
rm -rf "$HOME/ps2sdk-x86-tools"
cp -a "$PS2SDK/bin" "$HOME/ps2sdk-x86-tools"

## ------------------------------------------------------------------
## PHASE 2: rebuild ONLY the host tools with the Android compiler and install
## them over the x86 ones. (Not "make ONLY_HOST_TOOLS=1 install": the top-level
## release-clean would delete the libraries installed in phase 1.)
## ------------------------------------------------------------------
echo "=== PHASE 2: host tools for Android ==="
if [ -z "$CC" ]; then
  echo "ERROR: CC (Android compiler) is not set; cannot build the Android host tools."
  exit 1
fi
echo "Android compiler: $CC"
PS2SDKSRC="$(pwd)" make -C tools -j "$PROC_NR" clean
PS2SDKSRC="$(pwd)" make -C tools -j "$PROC_NR"
PS2SDKSRC="$(pwd)" make -C tools release
PS2SDKSRC="$(pwd)" make -C tools -j "$PROC_NR" clean

## Verify the installed host tools really are Android binaries of the TARGET ABI.
## ELF machine: b7=aarch64 (default), 28=arm, 3e=x86-64, 03=x86 (set by the workflow).
WANT_MACHINE="${ANDROID_ELF_MACHINE_HEX:-b7}"
for tool in bin2c ps2-irxgen srxfixup romimg adpenc ps2adpcm; do
  f="$PS2SDK/bin/$tool"
  if [ ! -f "$f" ]; then
    echo "ERROR: $f was not installed"; exit 1
  fi
  mach="$(od -An -tx1 -j18 -N1 "$f" | tr -d ' \n')"
  if [ "$mach" != "$WANT_MACHINE" ]; then
    echo "ERROR: $f has ELF machine 0x$mach, expected 0x$WANT_MACHINE (Android host architecture)"; exit 1
  fi
done
echo "Host tools OK: Android binaries (ELF machine 0x$WANT_MACHINE) in $PS2SDK/bin"

## gcc needs to include libcglue, libpthreadglue, libkernel and libcdvd from ps2sdk to be able to build executables,
## because they are part of the standard libraries
# Create symbolink links using relative paths
(cd $PS2DEV/ee/mips64r5900el-ps2-elf/lib && ln -sf ../../../ps2sdk/ee/lib/libcglue.a libcglue.a && cd -)
(cd $PS2DEV/ee/mips64r5900el-ps2-elf/lib && ln -sf ../../../ps2sdk/ee/lib/libpthreadglue.a libpthreadglue.a && cd -)
(cd $PS2DEV/ee/mips64r5900el-ps2-elf/lib && ln -sf ../../../ps2sdk/ee/lib/libprofglue.a libprofglue.a && cd -)
(cd $PS2DEV/ee/mips64r5900el-ps2-elf/lib && ln -sf ../../../ps2sdk/ee/lib/libkernel.a libkernel.a && cd -)
(cd $PS2DEV/ee/mips64r5900el-ps2-elf/lib && ln -sf ../../../ps2sdk/ee/lib/libcdvd.a libcdvd.a && cd -)

## ps2sdk is complete: let later steps know.
touch "$PS2DEV_STATE_DIR/ps2sdk-step-ok"
