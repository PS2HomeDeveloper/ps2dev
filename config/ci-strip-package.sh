#!/bin/bash
# ci-strip-package.sh -- strip debug information from the Android (host) binaries of a ps2dev folder,
# like the official "make install-strip" does. Some of our installs (e.g. "make install-gcc") do NOT
# strip, which leaves the compilers with full debug info: gigabytes unpacked, hundreds of MB packed.
#
# Only ELF files of the target Android machine are touched (executables and shared objects).
# PS2 (MIPS) objects, static libraries (.a), .o files and data files are never modified.
#
# usage: ci-strip-package.sh <ps2dev folder>
# env:   READELF / STRIP   tools to use (default: NDK llvm-readelf / llvm-strip)
#        CHECK_MACHINE     regex for the "Machine:" line of readelf (default: AArch64)

ROOT="${1:?usage: $0 <ps2dev folder>}"
NDK_BIN="$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/linux-x86_64/bin"
READELF="${READELF:-$NDK_BIN/llvm-readelf}"
STRIP="${STRIP:-$NDK_BIN/llvm-strip}"
CHECK_MACHINE="${CHECK_MACHINE:-AArch64}"
command -v "$READELF" >/dev/null 2>&1 || { echo "ERROR: readelf not found: $READELF"; exit 1; }
command -v "$STRIP"   >/dev/null 2>&1 || { echo "ERROR: strip not found: $STRIP"; exit 1; }
[ -d "$ROOT" ] || { echo "ERROR: folder not found: $ROOT"; exit 1; }

BEFORE="$(du -sk "$ROOT" | cut -f1)"
N=0; FAIL=0
while IFS= read -r -d '' f; do
  case "$f" in *.o|*.a) continue;; esac
  # real ELF files only (first 4 bytes = 7f 45 4c 46)
  [ "$(od -An -tx1 -N4 "$f" 2>/dev/null | tr -d ' \n')" = "7f454c46" ] || continue
  HDR="$("$READELF" -h "$f" 2>/dev/null)" || continue
  echo "$HDR" | grep -q "Machine:.*$CHECK_MACHINE" || continue          # skip MIPS (PS2) etc.
  echo "$HDR" | grep 'Type:' | grep -q 'EXEC\|DYN' || continue            # skip relocatable objects
  if "$STRIP" --strip-unneeded "$f" 2>/dev/null; then N=$((N + 1)); else echo "WARNING: could not strip $f"; FAIL=$((FAIL + 1)); fi
done < <(find "$ROOT" -type f -print0)

AFTER="$(du -sk "$ROOT" | cut -f1)"
echo "stripped $N Android binaries ($FAIL failed)"
echo "folder size: $((BEFORE / 1024)) MiB -> $((AFTER / 1024)) MiB"
echo "--- 15 largest files after stripping ---"
find "$ROOT" -type f -printf '%s %p\n' | sort -rn | head -n 15 | awk '{printf "%8.1f MiB  %s\n", $1/1048576, $2}'
[ "$N" -gt 0 ] || { echo "ERROR: no binaries were stripped (is CHECK_MACHINE right?)"; exit 1; }
