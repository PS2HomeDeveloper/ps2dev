#!/bin/bash
# 005-ps2client-extra.sh by ps2dev developers

## Exit with code 1 when any command executed returns a non-zero exit code.
onerr()
{
  exit 1;
}
trap onerr ERR

## Read information from the configuration file.
source "$(dirname "$0")/../config/ps2dev-config.sh"

## ps2client talks to the PS2 over an Ethernet/network link, which phones do not have,
## so it is NOT part of the Android/iOS packages. The Android workflow exports
## ANDROID_NDK_HOME (and may export PS2DEV_SKIP_PS2CLIENT=1 for iOS). Linux/Windows
## builds have neither, so ps2client is built there. PS2DEV_FORCE_PS2CLIENT=1 overrides.
if [ "$PS2DEV_FORCE_PS2CLIENT" != "1" ] && { [ -n "$ANDROID_NDK_HOME" ] || [ "$PS2DEV_SKIP_PS2CLIENT" = "1" ]; }; then
  echo "=== Skipping ps2client: not included in Android/iOS packages ==="
  exit 0
fi

## Download the source code.
REPO_URL="$PS2CLIENT_REPO_URL"
REPO_REF="$PS2CLIENT_DEFAULT_REPO_REF"
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

## Determine the maximum number of processes that Make can work with.
PROC_NR=$(getconf _NPROCESSORS_ONLN)

## Build and install.
make -j "$PROC_NR" clean
make -j "$PROC_NR"
make -j "$PROC_NR" install
make -j "$PROC_NR" clean
