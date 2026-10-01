#!/bin/bash
# 004-ps2-packer-extra.sh by ps2dev developers

## Exit with code 1 when any command executed returns a non-zero exit code.
onerr()
{
  exit 1;
}
trap onerr ERR

## Read information from the configuration file.
source "$(dirname "$0")/../config/ps2dev-config.sh"


CONFIG_DIR="$(cd "$(dirname "$0")/../config" && pwd)"

source "$CONFIG_DIR/ps2dev-x86.sh"
ps2dev_x86_setup

: "${X86_TOOLCHAIN:?ERROR: x86 PS2SDK toolchain was not found}"

X86_HOST_TOOLS=""
for d in "$HOME/ps2sdk-x86-tools" "$X86_TOOLCHAIN/ps2sdk/bin"; do
  if [ -d "$d" ] && [ -n "$(ls -A "$d" 2>/dev/null)" ]; then
    X86_HOST_TOOLS="$d"
    break
  fi
done

: "${X86_HOST_TOOLS:?ERROR: x86 PS2SDK host tools were not found}"
test -x "$X86_HOST_TOOLS/bin2c" || {
  echo "ERROR: x86 PS2SDK bin2c was not found: $X86_HOST_TOOLS/bin2c"
  exit 1
}

## Download the source code.
REPO_URL="$PS2_PACKER_REPO_URL"
REPO_REF="$PS2_PACKER_DEFAULT_REPO_REF"
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

export PATH="$X86_TOOLCHAIN/ee/bin:$X86_TOOLCHAIN/iop/bin:$PATH"

## Determine the maximum number of processes that Make can work with.
PROC_NR=$(getconf _NPROCESSORS_ONLN)

## Build and install.
PATH="$X86_TOOLCHAIN/ee/bin:$X86_TOOLCHAIN/iop/bin:$PATH" make -j "$PROC_NR" BIN2C="$X86_HOST_TOOLS/bin2c" clean
PATH="$X86_TOOLCHAIN/ee/bin:$X86_TOOLCHAIN/iop/bin:$PATH" make -j "$PROC_NR" BIN2C="$X86_HOST_TOOLS/bin2c"
PATH="$X86_TOOLCHAIN/ee/bin:$X86_TOOLCHAIN/iop/bin:$PATH" make -j "$PROC_NR" BIN2C="$X86_HOST_TOOLS/bin2c" install
PATH="$X86_TOOLCHAIN/ee/bin:$X86_TOOLCHAIN/iop/bin:$PATH" make -j "$PROC_NR" BIN2C="$X86_HOST_TOOLS/bin2c" clean
