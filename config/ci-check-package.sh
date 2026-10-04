#!/bin/bash
# ci-check-package.sh -- verify an Android (aarch64) ps2dev folder BEFORE it is archived/published.
#
# Checks every aarch64 ELF file (executables and shared objects) in the folder:
#   0. no ELF file of a foreign architecture (only the Android ABI and PS2/MIPS are allowed).
#   1. executables must be PIE (ET_DYN). Android 5.0+ refuses ET_EXEC programs.
#   2. every DT_NEEDED library must be a core Android system library. Anything else
#      (e.g. libc++_shared.so) would be missing on a clean Termux/Android install.
# PS2 (MIPS) programs, .o and .a files are not aarch64 ELF files and are ignored on purpose.
#
# usage: ci-check-package.sh <ps2dev folder>
# env:   READELF            readelf to use (default: NDK llvm-readelf)
#        CHECK_MACHINE      regex for the "Machine:" line (default: AArch64)
#        ALLOWED_NEEDED     space separated allow-list (default: core Android system libs)

ROOT="${1:?usage: $0 <ps2dev folder>}"
READELF="${READELF:-$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/linux-x86_64/bin/llvm-readelf}"
CHECK_MACHINE="${CHECK_MACHINE:-AArch64}"
ALLOWED_NEEDED="${ALLOWED_NEEDED:-libc.so libm.so libdl.so liblog.so libz.so libandroid.so}"

command -v "$READELF" >/dev/null 2>&1 || { echo "ERROR: readelf not found: $READELF"; exit 1; }
[ -d "$ROOT" ]    || { echo "ERROR: folder not found: $ROOT"; exit 1; }

TOTAL=0; NONPIE=0; BADDEP=0; FOREIGN=0
declare -A MISSING=()   # library name -> number of files needing it
BAD_LIST="$(mktemp)"

while IFS= read -r -d '' f; do
  HDR="$("$READELF" -h "$f" 2>/dev/null)" || continue
  TYPE_LINE="$(echo "$HDR" | grep 'Type:')"
  case "$TYPE_LINE" in *REL*"(Relocatable"*) continue;; esac   # .o files
  if ! echo "$HDR" | grep -q "Machine:.*$CHECK_MACHINE"; then
    # Not our Android architecture. PS2 (MIPS) programs/objects are expected; anything else is a
    # file built for the wrong machine that slipped into the package (e.g. an x86_64 file copied
    # from the build machine into an arm64 package).
    echo "$HDR" | grep -q "Machine:.*MIPS" && continue
    echo "FOREIGN-ARCH: $f ($(echo "$HDR" | grep 'Machine:' | sed 's/^ *Machine: *//'))"
    FOREIGN=$((FOREIGN + 1))
    continue
  fi
  TOTAL=$((TOTAL + 1))

  if echo "$TYPE_LINE" | grep -q 'EXEC'; then
    echo "NON-PIE: $f"
    NONPIE=$((NONPIE + 1))
  fi

  while IFS= read -r lib; do
    [ -n "$lib" ] || continue
    ok=0
    for a in $ALLOWED_NEEDED; do [ "$lib" = "$a" ] && ok=1 && break; done
    if [ "$ok" -eq 0 ]; then
      MISSING["$lib"]=$(( ${MISSING["$lib"]:-0} + 1 ))
      echo "$lib <- $f" >> "$BAD_LIST"
      BADDEP=$((BADDEP + 1))
    fi
  done < <("$READELF" -d "$f" 2>/dev/null | sed -n 's/.*(NEEDED).*Shared library: \[\(.*\)\].*/\1/p')
done < <(find "$ROOT" -type f -print0)

echo "Android ELF files checked:   $TOTAL"
echo "non-PIE executables:       $NONPIE"
echo "wrong-architecture files:  $FOREIGN"
echo "unavailable dependencies:  $BADDEP"
if [ "$BADDEP" -ne 0 ]; then
  echo "--- libraries that are NOT core Android system libs (library: files needing it) ---"
  for lib in "${!MISSING[@]}"; do echo "  $lib: ${MISSING[$lib]} file(s)"; done
  echo "--- first offenders ---"
  head -n 25 "$BAD_LIST"
fi
rm -f "$BAD_LIST"

if [ "$TOTAL" -eq 0 ]; then echo "ERROR: no Android ELF files found (is the check broken?)"; exit 1; fi
if [ "$NONPIE" -ne 0 ] || [ "$BADDEP" -ne 0 ] || [ "$FOREIGN" -ne 0 ]; then echo "PACKAGE CHECK FAILED"; exit 1; fi
echo "PACKAGE CHECK OK"
