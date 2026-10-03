#!/bin/bash
# 003-ps2sdk-ports.sh by ps2dev developers (Android-host variant)
#
# The ports are PS2 libraries, so they are compiled by the x86_64 PS2 cross
# compiler (see config/ps2dev-x86.sh). During their build they may also RUN ps2sdk
# helper tools (bin2c, ...), which must be x86 versions: the Android ones installed
# by step 2 cannot execute here. So $PS2SDK/bin is swapped for the x86 copies while
# the ports build, and the Android tools are put back afterwards (even on failure).

## Exit with code 1 when any command executed returns a non-zero exit code.
onerr()
{
  exit 1;
}
trap onerr ERR

## Read information from the configuration file.
source "$(dirname "$0")/../config/ps2dev-config.sh"
CONFIG_DIR="$(cd "$(dirname "$0")/../config" && pwd)"

## Download the source code.
REPO_URL="$PS2SDK_PORTS_REPO_URL"
REPO_REF="$PS2SDK_PORTS_DEFAULT_REPO_REF"
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

: "${PS2DEV:?PS2DEV is not set}"
: "${PS2SDK:?PS2SDK is not set}"

## Determine the maximum number of processes that Make can work with.
PROC_NR=$(getconf _NPROCESSORS_ONLN)

## ports need the ps2sdk installed by step 2.
PS2DEV_STATE_DIR="$(dirname "$PS2DEV")/.ps2dev-state"
if [ ! -f "$PS2DEV_STATE_DIR/ps2sdk-step-ok" ] || [ ! -d "$PS2SDK/ee/lib" ] || [ ! -d "$PS2SDK/common/include" ]; then
  echo "ERROR: ps2sdk is not installed in $PS2SDK (run step 2 first, or restore the dev cache)."
  exit 1
fi

## x86_64 PS2 compilers.
source "$CONFIG_DIR/ps2dev-x86.sh"
ps2dev_x86_setup

## x86 copies of the ps2sdk helper tools: ours from step 2 if present, else the
## ones shipped inside the prebuilt toolchain.
X86_HOST_TOOLS=""
for d in "$HOME/ps2sdk-x86-tools" "$X86_TOOLCHAIN/ps2sdk/bin"; do
  if [ -d "$d" ] && [ -n "$(ls -A "$d" 2>/dev/null)" ]; then X86_HOST_TOOLS="$d"; break; fi
done

: "${X86_HOST_TOOLS:?ERROR: x86 PS2SDK host tools were not found}"
X86_PKG_CONFIG="$X86_HOST_TOOLS/mips64r5900el-ps2-elf-pkg-config"
: "${X86_PKG_CONFIG:?ERROR: x86 PS2SDK pkg-config was not found}"
export X86_PKG_CONFIG
if [ -z "$X86_HOST_TOOLS" ]; then
  echo "ERROR: no x86 ps2sdk helper tools found ($HOME/ps2sdk-x86-tools or $X86_TOOLCHAIN/ps2sdk/bin)."
  exit 1
fi
echo "x86 ps2sdk helper tools: $X86_HOST_TOOLS"

ANDROID_TOOLS_BACKUP="$PS2SDK/bin.android-backup"
restore_android_tools()
{
  if [ -d "$ANDROID_TOOLS_BACKUP" ]; then
    rm -rf "$PS2SDK/bin"
    mv "$ANDROID_TOOLS_BACKUP" "$PS2SDK/bin"
    echo "Android ps2sdk tools restored in $PS2SDK/bin"
  fi
}
trap restore_android_tools EXIT

rm -rf "$ANDROID_TOOLS_BACKUP"
if [ -d "$PS2SDK/bin" ]; then mv "$PS2SDK/bin" "$ANDROID_TOOLS_BACKUP"; fi
cp -a "$X86_HOST_TOOLS" "$PS2SDK/bin"
PATH_X86_EXTRA="$PS2SDK/bin"
export PATH_X86_EXTRA

## Build and install.
## Several ports download their sources from third-party servers that sometimes answer
## with transient errors (e.g. HTTP 522 / timeouts). Already finished ports are not
## affected, so simply retry a few times before giving up.
ATTEMPT=1
until run_x86 make -j "$PROC_NR"; do
  if [ "$ATTEMPT" -ge 3 ]; then
    echo "ERROR: ports build failed after $ATTEMPT attempts."
    exit 1
  fi
  ATTEMPT=$((ATTEMPT + 1))
  echo "=== make failed (possibly a download error); waiting 30s, then attempt $ATTEMPT of 3 ==="
  sleep 30
done
