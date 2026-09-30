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

## ------------------------------------------------------------------
## Find an x86_64 PS2 cross toolchain that actually runs on this machine.
##   1) the x86_64 "native" copy built earlier in this same job by the toolchain
##      scripts (NOT the Android one); used only if it exists and runs;
##   2) otherwise the prebuilt ps2dev release (override with PS2DEV_X86_URL).
##   Set PS2DEV_X86_SOURCE=download to always use the prebuilt release (step 2).
## ------------------------------------------------------------------
x86_ok()
{
  "$1/ee/bin/mips64r5900el-ps2-elf-gcc" --version >/dev/null 2>&1 && \
  "$1/iop/bin/mipsel-none-elf-gcc" --version >/dev/null 2>&1
}

X86_TOOLCHAIN=""
if [ "$PS2DEV_X86_SOURCE" != "download" ] && [ -n "$NATIVE_PS2DEV" ] && x86_ok "$NATIVE_PS2DEV"; then
  X86_TOOLCHAIN="$NATIVE_PS2DEV"
  echo "Using native x86_64 toolchain built in this job: $X86_TOOLCHAIN"
else
  X86_DIR="$HOME/ps2dev-x86"
  for URL in "$PS2DEV_X86_URL" \
             "https://github.com/ps2dev/ps2dev/releases/download/v2.0.0/ps2dev-ubuntu-latest.tar.gz" \
             "https://github.com/ps2dev/ps2dev/releases/download/latest/ps2dev-ubuntu-latest.tar.gz"; do
    [ -n "$URL" ] || continue
    echo "Trying prebuilt x86_64 toolchain: $URL"
    rm -rf "$X86_DIR.tmp" /tmp/ps2dev-x86.tar.gz
    mkdir -p "$X86_DIR.tmp"
    if curl -fL --retry 3 --connect-timeout 30 -o /tmp/ps2dev-x86.tar.gz "$URL" && \
       tar -xzf /tmp/ps2dev-x86.tar.gz -C "$X86_DIR.tmp" --strip-components 1; then
      rm -rf "$X86_DIR"
      mv "$X86_DIR.tmp" "$X86_DIR"
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
  exit 1
fi
echo "x86_64 toolchain: $X86_TOOLCHAIN"
"$X86_TOOLCHAIN/ee/bin/mips64r5900el-ps2-elf-gcc" --version | head -n 1
"$X86_TOOLCHAIN/iop/bin/mipsel-none-elf-gcc" --version | head -n 1

## The libraries are compiled with -flto -ffat-lto-objects, and LTO data is only
## readable by the SAME GCC version. The Android package's GCC must match.
X86_GCC_VER="$("$X86_TOOLCHAIN/ee/bin/mips64r5900el-ps2-elf-gcc" -dumpfullversion)"
ANDROID_GCC_VER="$(ls "$PS2DEV/ee/lib/gcc/mips64r5900el-ps2-elf" 2>/dev/null | head -n 1 || true)"
if [ -n "$ANDROID_GCC_VER" ] && [ "$ANDROID_GCC_VER" != "$X86_GCC_VER" ] && [ "$ALLOW_GCC_MISMATCH" != "1" ]; then
  echo "ERROR: GCC version mismatch: x86_64 toolchain is $X86_GCC_VER but the Android package has $ANDROID_GCC_VER."
  echo "       LTO objects built by one cannot be linked by the other. Set PS2DEV_X86_URL to a matching"
  echo "       release, or ALLOW_GCC_MISMATCH=1 to continue anyway."
  exit 1
fi

## ------------------------------------------------------------------
## PHASE 1: build + install everything with x86_64 tools.
## ------------------------------------------------------------------
## PATH for this phase: drop every Android entry (NDK clang/ld, $PS2DEV/*/bin) so
## that nothing tries to execute an aarch64 binary, and put the x86 cross
## compilers first.
CLEAN_PATH="$(printf '%s' "$PATH" | tr ':' '\n' \
  | grep -v -e '/toolchains/llvm/prebuilt' -e "^$PS2DEV/" -e "^$ANDROID_NDK_HOME" \
  | paste -sd: -)"
PATH_X86="$X86_TOOLCHAIN/ee/bin:$X86_TOOLCHAIN/iop/bin:$CLEAN_PATH"

## A previous package may have left Android (aarch64) tools in $PS2SDK/bin; never run them.
rm -rf "${PS2SDK:?PS2SDK is not set}/bin"

run_x86()
{
  env -u CC -u CXX -u AR -u LD -u RANLIB -u NM -u STRIP -u CONFIGURE_HOST \
      -u CFLAGS -u CXXFLAGS -u CPPFLAGS -u LDFLAGS \
      PATH="$PATH_X86" "$@"
}

echo "=== PHASE 1: PS2 libraries + x86 helper tools (x86_64 toolchain) ==="
## Build and install.
run_x86 make -j "$PROC_NR" clean
run_x86 make -j "$PROC_NR" || run_x86 make -j "$PROC_NR" clean
## If the multi-job build failed, then build it with a single job.
## Otherwise, it won't build anything since it is already built.
run_x86 make -j 1
run_x86 make -j "$PROC_NR" install
run_x86 make -j "$PROC_NR" clean

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

## Verify the installed host tools really are Android (aarch64, ELF machine 0xb7).
for tool in bin2c ps2-irxgen srxfixup romimg adpenc ps2adpcm; do
  f="$PS2SDK/bin/$tool"
  if [ ! -f "$f" ]; then
    echo "ERROR: $f was not installed"; exit 1
  fi
  mach="$(od -An -tx1 -j18 -N1 "$f" | tr -d ' \n')"
  if [ "$mach" != "b7" ]; then
    echo "ERROR: $f is not an aarch64 binary (ELF machine byte: $mach)"; exit 1
  fi
done
echo "Host tools OK: aarch64 binaries in $PS2SDK/bin"

## gcc needs to include libcglue, libpthreadglue, libkernel and libcdvd from ps2sdk to be able to build executables,
## because they are part of the standard libraries
# Create symbolink links using relative paths
(cd $PS2DEV/ee/mips64r5900el-ps2-elf/lib && ln -sf ../../../ps2sdk/ee/lib/libcglue.a libcglue.a && cd -)
(cd $PS2DEV/ee/mips64r5900el-ps2-elf/lib && ln -sf ../../../ps2sdk/ee/lib/libpthreadglue.a libpthreadglue.a && cd -)
(cd $PS2DEV/ee/mips64r5900el-ps2-elf/lib && ln -sf ../../../ps2sdk/ee/lib/libprofglue.a libprofglue.a && cd -)
(cd $PS2DEV/ee/mips64r5900el-ps2-elf/lib && ln -sf ../../../ps2sdk/ee/lib/libkernel.a libkernel.a && cd -)
(cd $PS2DEV/ee/mips64r5900el-ps2-elf/lib && ln -sf ../../../ps2sdk/ee/lib/libcdvd.a libcdvd.a && cd -)
