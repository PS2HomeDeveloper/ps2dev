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
  # bionic (Android's libc) already contains the pthread functions; there is no separate libpthread.
  grep -rlE -e ' -lpthread' --include=Makefile --include='Makefile.*' --include='*.mk' . 2>/dev/null \
    | xargs -r sed -i -E 's# -lpthread##g'
fi

## Android's libc (bionic) has NO pthread_cancel(): "call to undeclared function 'pthread_cancel'"
## (src/ps2link.c). Provide a replacement through a header that is force-included into every file:
## the thread is interrupted with a signal and ends itself. Used only for Android builds.
MAKE_CC_ARGS=()
if [ -n "$ANDROID_NDK_HOME" ]; then
  cat > "$PWD/android-compat.h" <<'EOF_COMPAT'
/* Android compatibility for ps2client (bionic has no pthread_cancel). */
#ifndef PS2DEV_ANDROID_COMPAT_H
#define PS2DEV_ANDROID_COMPAT_H
#include <pthread.h>
#include <signal.h>
static void ps2dev_cancel_handler(int sig) { (void)sig; pthread_exit(NULL); }
static inline int ps2dev_pthread_cancel(pthread_t t)
{
  struct sigaction sa;
  sa.sa_handler = ps2dev_cancel_handler;
  sigemptyset(&sa.sa_mask);
  sa.sa_flags = 0;
  sigaction(SIGUSR2, &sa, NULL);
  return pthread_kill(t, SIGUSR2);
}
#define pthread_cancel ps2dev_pthread_cancel
#endif
EOF_COMPAT
  MAKE_CC_ARGS=(CC="$CC -include $PWD/android-compat.h")
fi

## Determine the maximum number of processes that Make can work with.
PROC_NR=$(getconf _NPROCESSORS_ONLN)

## Build and install.
make "${MAKE_CC_ARGS[@]}" -j "$PROC_NR" clean
make "${MAKE_CC_ARGS[@]}" -j "$PROC_NR"
make "${MAKE_CC_ARGS[@]}" -j "$PROC_NR" install
make "${MAKE_CC_ARGS[@]}" -j "$PROC_NR" clean
