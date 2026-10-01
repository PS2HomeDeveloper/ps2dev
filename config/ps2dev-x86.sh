#!/bin/bash
# ps2dev-x86.sh -- helper for the Android-host build (source this file, do not run it).
#
# The Android toolchain built earlier cannot be executed on this Ubuntu machine.
# Anything that COMPILES PS2 CODE (ps2sdk libraries, ports, ...) therefore needs an
# x86_64 PS2 cross compiler. This file finds one and provides:
#   ps2dev_x86_setup   -> sets X86_TOOLCHAIN, PATH_X86, CLEAN_PATH
#   run_x86 CMD...     -> runs CMD with only x86_64 tools (no Android CC/PATH entries)

x86_ok()
{
  "$1/ee/bin/mips64r5900el-ps2-elf-gcc" --version >/dev/null 2>&1 && \
  "$1/iop/bin/mipsel-none-elf-gcc" --version >/dev/null 2>&1
}

ps2dev_x86_setup()
{
  : "${PS2DEV:?PS2DEV is not set}"
  X86_TOOLCHAIN=""
  X86_DIR="$HOME/ps2dev-x86"

  if [ "$PS2DEV_X86_SOURCE" != "download" ] && [ -n "$NATIVE_PS2DEV" ] && x86_ok "$NATIVE_PS2DEV"; then
    X86_TOOLCHAIN="$NATIVE_PS2DEV"
    echo "Using native x86_64 toolchain built in this job: $X86_TOOLCHAIN"
  elif x86_ok "$X86_DIR"; then
    X86_TOOLCHAIN="$X86_DIR"
    echo "Reusing previously downloaded x86_64 toolchain: $X86_TOOLCHAIN"
  else
    local URL SRC_DIR
    for URL in "$PS2DEV_X86_URL" \
               "https://github.com/ps2dev/ps2dev/releases/download/v2.0.0/ps2dev-ubuntu-latest.tar.gz" \
               "https://github.com/ps2dev/ps2dev/releases/download/latest/ps2dev-ubuntu-latest.tar.gz"; do
      [ -n "$URL" ] || continue
      echo "Trying prebuilt x86_64 toolchain: $URL"
      rm -rf "$X86_DIR.tmp" /tmp/ps2dev-x86.tar.gz
      mkdir -p "$X86_DIR.tmp"
      if curl -fL --retry 3 --connect-timeout 30 -o /tmp/ps2dev-x86.tar.gz "$URL" && \
         tar -xzf /tmp/ps2dev-x86.tar.gz -C "$X86_DIR.tmp"; then
        ## The archive normally has one top-level "ps2dev/" folder; accept both layouts.
        SRC_DIR="$X86_DIR.tmp"
        if [ ! -d "$SRC_DIR/ee" ] && [ -d "$SRC_DIR/ps2dev/ee" ]; then SRC_DIR="$SRC_DIR/ps2dev"; fi
        rm -rf "$X86_DIR"
        mv "$SRC_DIR" "$X86_DIR"
        rm -rf "$X86_DIR.tmp" /tmp/ps2dev-x86.tar.gz
        if x86_ok "$X86_DIR"; then
          X86_TOOLCHAIN="$X86_DIR"
          break
        fi
        echo "WARNING: downloaded toolchain does not run on this machine (e.g. needs a newer glibc)."
      else
        echo "WARNING: could not download/extract $URL"
      fi
    done
  fi

  if [ -z "$X86_TOOLCHAIN" ]; then
    echo "ERROR: no runnable x86_64 PS2 toolchain found (native build missing and prebuilt download failed)."
    return 1
  fi
  echo "x86_64 toolchain: $X86_TOOLCHAIN"
  "$X86_TOOLCHAIN/ee/bin/mips64r5900el-ps2-elf-gcc" --version | head -n 1
  "$X86_TOOLCHAIN/iop/bin/mipsel-none-elf-gcc" --version | head -n 1

  ## LTO objects (-flto -ffat-lto-objects) are only readable by the SAME GCC version
  ## as the Android package's compiler.
  local X86_GCC_VER ANDROID_GCC_VER
  X86_GCC_VER="$("$X86_TOOLCHAIN/ee/bin/mips64r5900el-ps2-elf-gcc" -dumpfullversion)"
  ANDROID_GCC_VER="$(ls "$PS2DEV/ee/lib/gcc/mips64r5900el-ps2-elf" 2>/dev/null | head -n 1 || true)"
  if [ -n "$ANDROID_GCC_VER" ] && [ "$ANDROID_GCC_VER" != "$X86_GCC_VER" ] && [ "$ALLOW_GCC_MISMATCH" != "1" ]; then
    echo "ERROR: GCC version mismatch: x86_64 toolchain is $X86_GCC_VER but the Android package has $ANDROID_GCC_VER."
    echo "       Set PS2DEV_X86_URL to a matching release, or ALLOW_GCC_MISMATCH=1 to continue anyway."
    return 1
  fi

  ## PATH without any Android entry (NDK clang/ld, $PS2DEV/*/bin), x86 compilers first.
  CLEAN_PATH="$(printf '%s' "$PATH" | tr ':' '\n' \
    | grep -v -e '/toolchains/llvm/prebuilt' -e "^$PS2DEV/" -e "^${ANDROID_NDK_HOME:-/nonexistent-ndk}" \
    | paste -sd: -)"
  PATH_X86="$X86_TOOLCHAIN/ee/bin:$X86_TOOLCHAIN/iop/bin:$CLEAN_PATH"
  export X86_TOOLCHAIN PATH_X86 CLEAN_PATH
}

run_x86()
{
  env -u CC -u CXX -u AR -u LD -u RANLIB -u NM -u STRIP -u CONFIGURE_HOST \
      -u CFLAGS -u CXXFLAGS -u CPPFLAGS -u LDFLAGS \
      PATH="${PATH_X86_EXTRA:+$PATH_X86_EXTRA:}$PATH_X86" "$@"
}
