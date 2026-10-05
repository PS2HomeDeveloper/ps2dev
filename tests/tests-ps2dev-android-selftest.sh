#!/bin/bash
# ps2dev-android-selftest.sh -- does an extracted Android ps2dev package actually RUN?
# Works in any Android shell (Termux, adb shell, an APK that unpacks the package, the
# Termux Docker image used by CI, ...). It needs only bash, find, od, grep, timeout.
#
# usage:  bash ps2dev-android-selftest.sh [ps2dev folder] [machine_hex] [timeout_seconds]
#         defaults: $HOME/ps2dev  b7  10
# env:    MACHINE_HEX      ELF e_machine (hex) of programs to test: b7=aarch64 (default), 28=arm, 3e=x86-64, 03=x86
#         SELFTEST_TIMEOUT seconds allowed per command (default 10; CI under emulation uses more)
#
# Why not "--version must exit 0"? Many correct programs exit non-zero for --version (collect2,
# lto-wrapper, fixincl, every ps2sdk tool prints a usage text, ...). Those are NOT errors.
# A program is BROKEN only when the system cannot start it:
#   * the dynamic linker complains (CANNOT LINK EXECUTABLE / missing library / Exec format error)
#   * exit code 126 (not executable), 127 (not found) or >= 128 (crash / signal)
# PS2 (MIPS) programs and data files cannot run on a phone and are ignored automatically.
#
# Part 2 compiles tiny programs with the EE and IOP compilers: the real "does it work" test.

ROOT="${1:-$HOME/ps2dev}"
# Arguments win over environment variables: the Termux Docker entrypoint drops the environment, so
# CI passes the machine and timeout as arguments.
MACHINE_HEX="${2:-${MACHINE_HEX:-b7}}"
TMO="${3:-${SELFTEST_TIMEOUT:-10}}"
[ -d "$ROOT" ] || { echo "folder not found: $ROOT"; exit 2; }

LOADER_RE='CANNOT LINK EXECUTABLE|error while loading shared libraries|Exec format error|only position independent|library ".*" not found|cannot execute|Syntax error'
CHECKED=0; BROKEN=0; REPORT="$(mktemp)"

echo "== Part 1: can every program for ELF machine 0x$MACHINE_HEX in $ROOT be started? =="
while IFS= read -r -d '' f; do
  case "$f" in *.o|*.a|*.so|*.so.*) continue;; esac
  [ -x "$f" ] || continue
  h="$(od -An -v -tx1 -N20 "$f" 2>/dev/null | tr -d ' \n')"
  [ "${h:0:8}" = "7f454c46" ] || continue            # not an ELF file
  etype="${h:32:2}"; mach="${h:36:2}"
  [ "$mach" = "$MACHINE_HEX" ] || continue            # e.g. PS2 (MIPS) programs
  case "$etype" in 02|03) ;; *) continue;; esac       # executables / PIE only (skip .o)
  CHECKED=$((CHECKED + 1))
  out="$(timeout "$TMO" "$f" --version 2>&1 </dev/null)"; rc=$?
  if echo "$out" | grep -Eq "$LOADER_RE" || [ "$rc" -eq 126 ] || [ "$rc" -eq 127 ] || [ "$rc" -ge 128 ]; then
    BROKEN=$((BROKEN + 1))
    { echo "BROKEN (rc=$rc): $f"; echo "$out" | head -n 2 | sed 's/^/    /'; } >> "$REPORT"
  fi
done < <(find "$ROOT" -type f -print0)
echo "programs checked: $CHECKED"
echo "programs that cannot start: $BROKEN"
[ "$BROKEN" -gt 0 ] && cat "$REPORT"
rm -f "$REPORT"
FAILS=0
if [ "$CHECKED" -eq 0 ]; then echo "ERROR: no program matched (wrong MACHINE_HEX or empty folder?)"; FAILS=$((FAILS + 1)); fi

echo
echo "== Part 2: compile real code with the PS2 compilers =="
export PS2DEV="$ROOT"; export PS2SDK="$ROOT/ps2sdk"
export PATH="$ROOT/bin:$ROOT/ee/bin:$ROOT/iop/bin:$ROOT/dvp/bin:$PS2SDK/bin:$PATH"
T="$(mktemp -d)"
printf 'int add(int a,int b){return a+b;}\n' > "$T/t.c"
printf '#include <vector>\nint f(){std::vector<int> v(3,1);return (int)v.size();}\n' > "$T/t.cpp"
printf 'int main(void){return 0;}\n' > "$T/m.c"

t() {  # t "description" command...
  local d="$1"; shift
  if timeout "$TMO" "$@" >"$T/log" 2>&1; then echo "  OK    $d"; else echo "  FAIL  $d"; sed 's/^/        /' "$T/log" | head -n 6; FAILS=$((FAILS + 1)); fi
}
t "EE  gcc   C   (compile)"        mips64r5900el-ps2-elf-gcc -c "$T/t.c"   -o "$T/ee_c.o"
t "EE  g++   C++ (compile, STL)"   mips64r5900el-ps2-elf-g++ -c "$T/t.cpp" -o "$T/ee_cpp.o"
t "EE  gcc   LTO (compile)"        mips64r5900el-ps2-elf-gcc -flto -c "$T/t.c" -o "$T/ee_lto.o"
t "IOP gcc   C   (compile)"        mipsel-none-elf-gcc -c "$T/t.c" -o "$T/iop_c.o"
t "EE  readelf sees MIPS object"   sh -c "mips64r5900el-ps2-elf-readelf -h '$T/ee_c.o' | grep -q MIPS"
t "IOP readelf sees MIPS object"   sh -c "mipsel-none-elf-readelf -h '$T/iop_c.o' | grep -q MIPS"
t "EE  gcc   C   (link, needs ps2sdk libs)" mips64r5900el-ps2-elf-gcc "$T/m.c" -o "$T/ee_prog.elf"
rm -rf "$T"

echo
if [ "$BROKEN" -eq 0 ] && [ "$FAILS" -eq 0 ]; then echo "RESULT: ALL GOOD"; exit 0; fi
echo "RESULT: PROBLEMS FOUND (cannot start: $BROKEN, failed tests: $FAILS)"; exit 1
