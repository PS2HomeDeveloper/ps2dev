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

## ps2client IS built for every platform, Android and iOS included: it talks to the PS2 over the
## network (TCP/UDP to ps2link), so a phone on the same Wi-Fi/LAN as the PS2 can use it.
## Set PS2DEV_SKIP_PS2CLIENT=1 to leave it out.
if [ "$PS2DEV_SKIP_PS2CLIENT" = "1" ]; then
  echo "=== Skipping ps2client (PS2DEV_SKIP_PS2CLIENT=1) ==="
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

## Cross-building for Android: the ps2client Makefile adds the BUILD machine's header/library folders
## (-I/usr/include ...), which make the Android compiler read Ubuntu's headers and fail
## ("'bits/libc-header-start.h' file not found"). Remove them; the Android compiler already
## knows its own sysroot. Only done for Android builds.
if [ -n "$ANDROID_NDK_HOME" ]; then
  grep -rlE -e '-I/usr/(local/)?include' -e '-L/usr/(local/)?lib' \
       --include=Makefile --include='Makefile.*' --include='*.mk' . 2>/dev/null \
    | xargs -r sed -i -E 's# -I/usr/(local/)?include##g; s# -L/usr/(local/)?lib[0-9a-z_/-]*##g'
  echo "--- host paths still mentioned in the Makefiles (should be empty) ---"
  grep -rn -e '/usr/include' -e '/usr/local/include' --include=Makefile --include='*.mk' . | head -n 5 || true
fi

## Determine the maximum number of processes that Make can work with.
PROC_NR=$(getconf _NPROCESSORS_ONLN)

## Build and install.
make -j "$PROC_NR" clean
make -j "$PROC_NR"
make -j "$PROC_NR" install
make -j "$PROC_NR" clean
