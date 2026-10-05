#!/usr/bin/env bash
#
# Local, GitHub-free build of the unsigned Fritzing macOS distribution for the architecture of this
# Mac. One command that checks every prerequisite before the first heavy download, installs Qt with
# the aqtinstall version pinned in versions.lock.json when QT_ROOT does not point at a complete Qt,
# runs the validated bootstrap-macos.sh and build-macos.sh of this kit, puts the four part packages
# of parts/dist next to the application as custom-parts/, optionally signs the bundle ad hoc, writes
# the SHA-256 of the final ZIP and keeps a log.
#
# Nothing is uploaded and no toolchain is installed automatically. The Xcode command line tools,
# CMake and Python have to be present already; a missing prerequisite is reported with the exact
# command that fixes it. Only the PATH of this process is used, no system setting is changed.
#
# Re-running is safe and cheap: a complete Qt, the fetched sources, the built dependencies and an
# existing build output are reused instead of being downloaded or built again.
#
# Exit codes: 0 success, 1 failure, 2 wrong platform or architecture, 3 missing prerequisite.
#
# Written for the bash 3.2 that ships with macOS and for the BSD userland: no associative arrays and
# no GNU coreutils. Every path is quoted, so directories with spaces work.

set -euo pipefail

KIT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOCK="$KIT/versions.lock.json"
STARTED=$(date +%s)

usage() {
  cat <<'USAGE'
Usage: scripts/build-local-macos.sh [options]

  --work-dir <path>    Working directory for Qt, sources, dependencies and object files (about
                       30 GB). Kept between runs so that a repeated run resumes.
                       Default: $HOME/fritzing-build
  --out-dir <path>     Directory for the final ZIP, its SHA-256 file and the logs.
                       Default: <kit>/out
  --qt-root <path>     Existing Qt installation to use, for example /opt/Qt/<version>/macos.
                       Defaults to the QT_ROOT environment variable. When it is empty or
                       incomplete, Qt is installed into <work-dir>/Qt.
  --arch <arch>        arm64 or x86_64. Must match this Mac; the default is what it reports.
  --force-qt-install   Install Qt into <work-dir>/Qt again even if a complete Qt is already there.
  --skip-bootstrap     Reuse the sources and dependencies already in the working directory without
                       contacting the network.
  --skip-build         Reuse the Fritzing.app produced by an earlier run and only repackage it.
  --sign-adhoc         Sign the bundle ad hoc (codesign --force --deep --sign -) before packaging.
                       No Apple Developer ID, no notarisation; see LOCAL-MACOS-BUILD.md.
  -h, --help           Show this text.
USAGE
}

# --------------------------------------------------------------------------------------------------
# Small helpers
# --------------------------------------------------------------------------------------------------
step() { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$1"; }

abspath() {
  # Absolute path without a trailing slash and without "." or ".." components. Purely textual, so
  # the path does not have to exist yet and no GNU path resolver is needed.
  local path=$1 part out=""
  [[ "$path" == /* ]] || path="$PWD/$path"
  while [[ -n "$path" ]]; do
    part=${path%%/*}
    if [[ "$part" == "$path" ]]; then path=""; else path=${path#*/}; fi
    case "$part" in
      ''|.) ;;
      ..) out=${out%/*} ;;
      *) out="$out/$part" ;;
    esac
  done
  printf '%s\n' "${out:-/}"
}

existing_ancestor() {
  local path=$1
  while [[ ! -d "$path" && "$path" != "/" ]]; do path="$(dirname "$path")"; done
  printf '%s\n' "$path"
}

lock() {
  python3 -c 'import json, sys
value = json.load(open(sys.argv[1]))
for key in sys.argv[2].split("."):
    value = value[key]
print(value)' "$LOCK" "$1"
}

lock_list() {
  python3 -c 'import json, sys
value = json.load(open(sys.argv[1]))
for key in sys.argv[2].split("."):
    value = value[key]
print("\n".join(value))' "$LOCK" "$1"
}

# --------------------------------------------------------------------------------------------------
# Arguments
# --------------------------------------------------------------------------------------------------
WORK_DIR=""
OUT_DIR=""
QT_ROOT_OPTION="${QT_ROOT:-}"
WANTED_ARCH=""
FORCE_QT_INSTALL=0
SKIP_BOOTSTRAP=0
SKIP_BUILD=0
SIGN_ADHOC=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --work-dir) WORK_DIR="${2:?--work-dir needs a path}"; shift 2 ;;
    --out-dir) OUT_DIR="${2:?--out-dir needs a path}"; shift 2 ;;
    --qt-root) QT_ROOT_OPTION="${2:?--qt-root needs a path}"; shift 2 ;;
    --arch) WANTED_ARCH="${2:?--arch needs arm64 or x86_64}"; shift 2 ;;
    --force-qt-install) FORCE_QT_INSTALL=1; shift ;;
    --skip-bootstrap) SKIP_BOOTSTRAP=1; shift ;;
    --skip-build) SKIP_BUILD=1; shift ;;
    --sign-adhoc) SIGN_ADHOC=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) printf 'Unknown option: %s\n\n' "$1" >&2; usage >&2; exit 2 ;;
  esac
done

# --------------------------------------------------------------------------------------------------
# Platform and architecture. Nothing is created before these two checks pass.
# --------------------------------------------------------------------------------------------------
if [[ "$(uname -s)" != "Darwin" ]]; then
  printf 'This orchestrator builds Fritzing.app with Xcode and Qt for macOS and has to run on macOS; this system is %s.\n' "$(uname -s)" >&2
  printf 'On Windows use scripts\\build-local-windows.ps1 instead.\n' >&2
  exit 2
fi

ARCH="$(uname -m)"
case "$ARCH" in
  arm64|x86_64) ;;
  *) printf 'Unsupported architecture %s; this kit builds arm64 or x86_64.\n' "$ARCH" >&2; exit 2 ;;
esac
if [[ -n "$WANTED_ARCH" && "$WANTED_ARCH" != "$ARCH" ]]; then
  printf 'This Mac reports %s, --arch asks for %s. Native builds only: no universal binary is produced\n' "$ARCH" "$WANTED_ARCH" >&2
  printf 'and cross building is not supported, because the dependencies are built for one architecture.\n' >&2
  exit 2
fi
# A shell started under Rosetta reports x86_64 on Apple silicon, which would produce an artifact for
# the wrong architecture without any tool noticing.
if [[ "$(sysctl -n sysctl.proc_translated 2>/dev/null || echo 0)" == "1" ]]; then
  printf 'This shell runs under Rosetta, so it reports %s on an Apple silicon Mac.\n' "$ARCH" >&2
  printf 'Start a native terminal (or run: arch -arm64 %s) and try again.\n' "$0" >&2
  exit 2
fi

[[ -f "$LOCK" ]] || { printf 'versions.lock.json not found at %s\n' "$LOCK" >&2; exit 1; }
# Everything below reads the pinned versions from the lock, so this one tool is checked first.
if ! command -v python3 >/dev/null 2>&1; then
  printf 'python3 is required to read versions.lock.json and was not found.\n' >&2
  printf 'Install the Xcode command line tools (xcode-select --install) or Python\n' >&2
  printf '(brew install python, https://www.python.org/downloads/macos/), then run this again.\n' >&2
  exit 3
fi
[[ -n "$WORK_DIR" ]] || WORK_DIR="$HOME/fritzing-build"
[[ -n "$OUT_DIR" ]] || OUT_DIR="$KIT/out"
WORK_DIR="$(abspath "$WORK_DIR")"
OUT_DIR="$(abspath "$OUT_DIR")"
DOWNLOAD_DIR="$WORK_DIR/downloads"
BUILD_OUT_DIR="$WORK_DIR/build-out"
VENV_DIR="$WORK_DIR/aqt-venv"
QT_DIR="$WORK_DIR/Qt"
STAGE_DIR="$WORK_DIR/dist-macos-$ARCH"
LOG_DIR="$OUT_DIR/logs"
BUNDLE="$WORK_DIR/release64/Fritzing.app"
FINAL_ZIP="$OUT_DIR/fritzing-macos-$ARCH-unsigned.zip"
[[ "$OUT_DIR" != "$BUILD_OUT_DIR" ]] || { printf -- '--out-dir must not be the internal build output directory %s\n' "$BUILD_OUT_DIR" >&2; exit 1; }
[[ "$OUT_DIR" != "$WORK_DIR" ]] || { printf -- '--out-dir must not be the working directory %s\n' "$WORK_DIR" >&2; exit 1; }

mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/build-local-macos-$(date +%Y%m%d-%H%M%S).log"
exec > >(tee -a "$LOG_FILE") 2>&1

on_exit() {
  local code=$?
  # 2 and 3 are the guard exits; they explain themselves and nothing was built.
  if [[ $code -ne 0 && $code -ne 2 && $code -ne 3 ]]; then
    printf '\n'
    printf 'BUILD FAILED (exit %s)\n' "$code"
    printf 'Log        : %s\n' "$LOG_FILE"
    printf 'Work dir   : %s (kept, the next run continues from here)\n' "$WORK_DIR"
  fi
}
trap on_exit EXIT

QT_VERSION="$(lock qt.version)"
QT_ARCH="$(lock qt.macos_arch)"
QT_DIR_NAME="$(lock qt.macos_dir)"
AQT_VERSION="$(lock qt.aqtinstall)"
APP_VERSION="$(lock fritzing_app.version)"
LOCAL_QT_ROOT="$QT_DIR/$QT_VERSION/$QT_DIR_NAME"
NGSPICE_LIBRARY="$(lock macos_runtime.ngspice.library)"
NGSPICE_MODEL="$(lock macos_runtime.ngspice.required_code_model)"
NGSPICE_RUNTIME="$WORK_DIR/ngspice-$(lock dependencies.ngspice)-runtime-$ARCH"

step "Fritzing $APP_VERSION local macOS $ARCH build, no GitHub Actions, nothing is uploaded"
step "Kit         : $KIT"
step "Work dir    : $WORK_DIR"
step "Output dir  : $OUT_DIR"
step "Log         : $LOG_FILE"
step "macOS       : $(sw_vers -productVersion 2>/dev/null || echo unknown) on $ARCH"

# --------------------------------------------------------------------------------------------------
# Step 1: prerequisites. Everything is checked before the first download, and every finding names
# the command that fixes it.
# --------------------------------------------------------------------------------------------------
qt_is_complete() {
  local root=$1 marker
  [[ -n "$root" ]] || return 1
  for marker in bin/qmake bin/lrelease bin/macdeployqt mkspecs/macx-clang/qmake.conf \
    lib/QtCore.framework lib/QtSvg.framework lib/QtCore5Compat.framework lib/QtSerialPort.framework; do
    if [[ ! -e "$root/$marker" ]]; then
      step "Qt at '$root' is incomplete: $marker is missing"
      return 1
    fi
  done
  [[ "$("$root/bin/qmake" -query QT_VERSION 2>/dev/null)" == "$QT_VERSION" ]] || {
    step "Qt at '$root' is not version $QT_VERSION"
    return 1
  }
}

QT_ROOT_IN_USE=""
if [[ $FORCE_QT_INSTALL -eq 0 ]]; then
  if qt_is_complete "$QT_ROOT_OPTION"; then
    QT_ROOT_IN_USE="$(abspath "$QT_ROOT_OPTION")"
  elif qt_is_complete "$LOCAL_QT_ROOT"; then
    QT_ROOT_IN_USE="$LOCAL_QT_ROOT"
  fi
fi
NEED_QT_INSTALL=1
[[ -z "$QT_ROOT_IN_USE" ]] || NEED_QT_INSTALL=0
if [[ -n "$QT_ROOT_OPTION" && $NEED_QT_INSTALL -eq 1 && $FORCE_QT_INSTALL -eq 0 ]]; then
  step "WARNING: '$QT_ROOT_OPTION' is not a complete Qt $QT_VERSION; Qt will be installed into $QT_DIR"
fi

step 'Step 1/7: prerequisites'
PROBLEMS=()
problem() { PROBLEMS+=("$1"); }
need() {
  # $1 tool, $2 how to install it
  if command -v "$1" >/dev/null 2>&1; then
    step "$1: $(command -v "$1")"
  else
    problem "$1 not found. $2"
  fi
}

XCODE_HINT='Install the Xcode command line tools: xcode-select --install'
if ! xcode-select -p >/dev/null 2>&1; then
  problem "The Xcode command line tools are not installed. Run: xcode-select --install"
fi
# Compiler, binary tools and the archiver, all part of the command line tools.
for tool in clang clang++ make git curl tar ditto lipo otool install_name_tool codesign unzip shasum perl awk; do
  need "$tool" "$XCODE_HINT"
done
need cmake 'Install it with: brew install cmake (or download it from https://cmake.org/download/)'
step "python3: $(command -v python3)"
if [[ $NEED_QT_INSTALL -eq 1 ]]; then
  if ! python3 -c 'import sys, venv; sys.exit(0 if sys.version_info >= (3, 8) else 1)' >/dev/null 2>&1; then
    problem 'python3 is older than 3.8 or cannot create a virtual environment (aqtinstall needs one). Install a current one with: brew install python (or from https://www.python.org/downloads/macos/)'
  fi
fi

# The pinned ngspice release tarball ships a generated configure, so autotools are only a fallback.
if [[ $SKIP_BOOTSTRAP -eq 0 ]]; then
  MISSING_AUTOTOOLS=""
  for tool in autoconf automake libtool; do
    command -v "$tool" >/dev/null 2>&1 || MISSING_AUTOTOOLS="$MISSING_AUTOTOOLS $tool"
  done
  if [[ -n "$MISSING_AUTOTOOLS" ]]; then
    step "Note: autotools ($MISSING_AUTOTOOLS ) are missing. The pinned ngspice 42 tarball ships a"
    step "      generated configure, so they are only needed if that ever changes: brew install automake autoconf libtool"
  fi
fi

for relative in versions.lock.json scripts/bootstrap-macos.sh scripts/build-macos.sh \
  parts/LICENSE.txt parts/IMPORT-CUSTOM-PARTS.txt; do
  [[ -f "$KIT/$relative" ]] || problem "The build kit is incomplete: $relative is missing. Extract the kit again."
done
PART_COUNT=0
if [[ -d "$KIT/parts/dist" ]]; then
  PART_COUNT=$(find "$KIT/parts/dist" -maxdepth 1 -name '*.fzpz' | wc -l | tr -d ' ')
fi
[[ "$PART_COUNT" -gt 0 ]] || problem 'No part packages in parts/dist. Extract the kit again or run "python3 scripts/package-parts.py".'

case "$WORK_DIR" in
  *:*) problem "The working directory path contains a colon; make cannot build in such a path. Use --work-dir \"\$HOME/fritzing-build\"." ;;
esac
case "$WORK_DIR$QT_ROOT_IN_USE" in
  *\ *) step "WARNING: a path contains a space. qmake and make handle those poorly; a path such as \$HOME/fritzing-build is safer." ;;
esac
if [[ ${#WORK_DIR} -gt 120 ]]; then
  step "WARNING: the working directory path is ${#WORK_DIR} characters long; deep object paths can hit the system limit. Consider --work-dir \"\$HOME/fritzing-build\"."
fi

FREE_GB=$(df -Pk "$(existing_ancestor "$WORK_DIR")" | awk 'NR==2 {printf "%d", $4 / 1048576}')
if [[ "$FREE_GB" -lt 15 ]]; then
  problem "Only ${FREE_GB} GB free for $WORK_DIR; the build needs about 30 GB. Free space or pass --work-dir on another volume."
elif [[ "$FREE_GB" -lt 30 ]]; then
  step "WARNING: only ${FREE_GB} GB free for $WORK_DIR; about 30 GB is recommended."
else
  step "Free space  : ${FREE_GB} GB for $WORK_DIR"
fi

if [[ ${#PROBLEMS[@]} -gt 0 ]]; then
  step "${#PROBLEMS[@]} prerequisite(s) are missing; nothing was downloaded:"
  for item in "${PROBLEMS[@]}"; do printf '  - %s\n' "$item"; done
  printf '\nFix the items above and run the same command again; finished work is reused.\n'
  exit 3
fi
step 'All prerequisites are present'

mkdir -p "$WORK_DIR" "$DOWNLOAD_DIR" "$BUILD_OUT_DIR" "$OUT_DIR"

# --------------------------------------------------------------------------------------------------
# Step 2: Qt, from the lock, with the pinned aqtinstall in a virtual environment inside the working
# directory. Nothing is installed into the system Python.
# --------------------------------------------------------------------------------------------------
step 'Step 2/7: Qt'
if [[ $NEED_QT_INSTALL -eq 1 ]]; then
  if [[ $FORCE_QT_INSTALL -eq 1 && -d "$LOCAL_QT_ROOT" ]]; then
    step "--force-qt-install: removing $LOCAL_QT_ROOT"
    rm -rf "$LOCAL_QT_ROOT"
  fi
  if [[ ! -x "$VENV_DIR/bin/python" ]]; then
    step "Creating the aqtinstall virtual environment in $VENV_DIR"
    python3 -m venv "$VENV_DIR"
  fi
  [[ -x "$VENV_DIR/bin/python" ]] || { printf 'The virtual environment has no interpreter at %s. Delete %s and run again.\n' "$VENV_DIR/bin/python" "$VENV_DIR" >&2; exit 1; }
  if ! "$VENV_DIR/bin/python" -m pip show aqtinstall 2>/dev/null | grep -q "^Version: $AQT_VERSION\$"; then
    step "Installing aqtinstall==$AQT_VERSION into the virtual environment"
    "$VENV_DIR/bin/python" -m pip install --disable-pip-version-check "aqtinstall==$AQT_VERSION"
  else
    step "aqtinstall==$AQT_VERSION is already in the virtual environment"
  fi
  QT_MODULES=()
  while IFS= read -r qt_module; do
    [[ -n "$qt_module" ]] && QT_MODULES+=("$qt_module")
  done <<EOF
$(lock_list qt.modules)
EOF
  [[ ${#QT_MODULES[@]} -gt 0 ]] || { echo 'qt.modules is empty in the lock' >&2; exit 1; }
  step "Installing Qt $QT_VERSION $QT_ARCH into $QT_DIR (several GB, this takes a while)"
  "$VENV_DIR/bin/python" -m aqt install-qt mac desktop "$QT_VERSION" "$QT_ARCH" \
    --outputdir "$QT_DIR" --modules "${QT_MODULES[@]}"
  qt_is_complete "$LOCAL_QT_ROOT" || { printf 'Qt is still incomplete at %s after aqt install-qt. Delete %s and run again with --force-qt-install.\n' "$LOCAL_QT_ROOT" "$QT_DIR" >&2; exit 1; }
  QT_ROOT_IN_USE="$LOCAL_QT_ROOT"
else
  step "Reusing the complete Qt at $QT_ROOT_IN_USE"
fi
export QT_ROOT="$QT_ROOT_IN_USE"
step "QT_ROOT     : $QT_ROOT"

# --------------------------------------------------------------------------------------------------
# Step 3: sources, dependencies and the ngspice runtime. bootstrap-macos.sh is idempotent.
# --------------------------------------------------------------------------------------------------
step 'Step 3/7: sources, dependencies and the ngspice runtime'
export TMPDIR="$DOWNLOAD_DIR"
if [[ $SKIP_BOOTSTRAP -eq 1 ]]; then
  for required in fritzing-app/.git fritzing-parts/.git; do
    [[ -e "$WORK_DIR/$required" ]] || { printf -- '--skip-bootstrap was used but %s does not exist. Run again without it.\n' "$WORK_DIR/$required" >&2; exit 1; }
  done
  [[ -f "$NGSPICE_RUNTIME/lib/$NGSPICE_LIBRARY" ]] || { printf -- '--skip-bootstrap was used but the ngspice runtime %s does not exist. Run again without it.\n' "$NGSPICE_RUNTIME/lib/$NGSPICE_LIBRARY" >&2; exit 1; }
  step 'Skipped on request (--skip-bootstrap); the network is not used'
else
  bash "$KIT/scripts/bootstrap-macos.sh" "$WORK_DIR" "$LOCK"
fi

# --------------------------------------------------------------------------------------------------
# Step 4: the build itself, with the same script the GitHub workflow calls.
# --------------------------------------------------------------------------------------------------
step 'Step 4/7: compiling Fritzing (this is the long part)'
if [[ $SKIP_BUILD -eq 1 ]]; then
  [[ -x "$BUNDLE/Contents/MacOS/Fritzing" ]] || { printf -- '--skip-build was used but there is no earlier build at %s. Run again without it.\n' "$BUNDLE" >&2; exit 1; }
  step "Skipped on request (--skip-build); reusing $BUNDLE"
else
  bash "$KIT/scripts/build-macos.sh" "$WORK_DIR" "$ARCH" "$BUILD_OUT_DIR" "$LOCK"
  [[ -x "$BUNDLE/Contents/MacOS/Fritzing" ]] || { printf 'build-macos.sh finished but %s is missing\n' "$BUNDLE" >&2; exit 1; }
fi

BUNDLE_ARCHS=$(lipo -archs "$BUNDLE/Contents/MacOS/Fritzing")
[[ "$BUNDLE_ARCHS" == "$ARCH" ]] || { printf 'The built application is %s, expected %s\n' "$BUNDLE_ARCHS" "$ARCH" >&2; exit 1; }
for required in "Contents/PlugIns/$NGSPICE_LIBRARY" "Contents/PlugIns/ngspice/$NGSPICE_MODEL" \
  "Contents/MacOS/fritzing-parts/parts.db"; do
  [[ -e "$BUNDLE/$required" ]] || { printf 'The built application has no %s\n' "$required" >&2; exit 1; }
done
step "Application : $BUNDLE ($BUNDLE_ARCHS, ngspice runtime present)"

# --------------------------------------------------------------------------------------------------
# Step 5: the custom parts of this kit, staged next to the application.
# --------------------------------------------------------------------------------------------------
step 'Step 5/7: custom-parts folder'
rm -rf "$STAGE_DIR"
mkdir -p "$STAGE_DIR/custom-parts"
# ditto keeps symlinks, permissions and extended attributes of the bundle.
ditto "$BUNDLE" "$STAGE_DIR/Fritzing.app"
PART_NAMES=""
for package in "$KIT/parts/dist"/*.fzpz; do
  cp "$package" "$STAGE_DIR/custom-parts/"
  PART_NAMES="$PART_NAMES $(basename "$package")"
done
cp "$KIT/parts/IMPORT-CUSTOM-PARTS.txt" "$KIT/parts/LICENSE.txt" "$STAGE_DIR/custom-parts/"
step "Prepared $PART_COUNT part package(s):$PART_NAMES"

if [[ $SIGN_ADHOC -eq 1 ]]; then
  # Ad hoc only: no Apple Developer ID, no notarisation. Enough for running the build on this Mac.
  step 'Signing the bundle ad hoc (codesign --force --deep --sign -)'
  codesign --force --deep --sign - "$STAGE_DIR/Fritzing.app"
  codesign --verify --deep --strict "$STAGE_DIR/Fritzing.app"
  step 'Ad hoc signature verified'
else
  step 'Not signed (pass --sign-adhoc for an ad hoc signature)'
fi

# --------------------------------------------------------------------------------------------------
# Step 6: final archive. Fritzing.app and custom-parts/ sit next to each other in the ZIP root.
# --------------------------------------------------------------------------------------------------
step 'Step 6/7: final archive'
rm -f "$FINAL_ZIP"
ditto -c -k --sequesterRsrc "$STAGE_DIR" "$FINAL_ZIP"
ENTRIES=$(unzip -Z1 "$FINAL_ZIP")
MISSING=""
for entry in "Fritzing.app/Contents/MacOS/Fritzing" "Fritzing.app/Contents/MacOS/fritzing-parts/parts.db" \
  "Fritzing.app/Contents/PlugIns/$NGSPICE_LIBRARY" "Fritzing.app/Contents/PlugIns/ngspice/$NGSPICE_MODEL" \
  "custom-parts/IMPORT-CUSTOM-PARTS.txt" "custom-parts/LICENSE.txt"; do
  printf '%s\n' "$ENTRIES" | grep -qxF "$entry" || MISSING="$MISSING $entry"
done
for package in "$KIT/parts/dist"/*.fzpz; do
  printf '%s\n' "$ENTRIES" | grep -qxF "custom-parts/$(basename "$package")" || MISSING="$MISSING custom-parts/$(basename "$package")"
done
[[ -z "$MISSING" ]] || { printf 'The archive %s does not contain:%s\n' "$FINAL_ZIP" "$MISSING" >&2; exit 1; }
ENTRY_COUNT=$(printf '%s\n' "$ENTRIES" | wc -l | tr -d ' ')
SIZE_MB=$(( $(wc -c < "$FINAL_ZIP") / 1048576 ))
step "Archive verified: $ENTRY_COUNT entries, $SIZE_MB MB"

# --------------------------------------------------------------------------------------------------
# Step 7: checksum.
# --------------------------------------------------------------------------------------------------
step 'Step 7/7: SHA-256'
HASH=$(shasum -a 256 "$FINAL_ZIP" | awk '{print $1}')
SHA_FILE="$FINAL_ZIP.sha256"
printf '%s  %s\n' "$HASH" "$(basename "$FINAL_ZIP")" > "$SHA_FILE"

ELAPSED=$(( $(date +%s) - STARTED ))
printf '\n'
printf '=============================== BUILD FINISHED ===============================\n'
printf 'Artifact   : %s (%s MB)\n' "$FINAL_ZIP" "$SIZE_MB"
printf 'SHA-256    : %s\n' "$HASH"
printf '             %s\n' "$SHA_FILE"
printf 'Contents   : Fritzing.app (%s) and custom-parts/ (%s packages, IMPORT-CUSTOM-PARTS.txt)\n' "$ARCH" "$PART_COUNT"
printf 'Simulator  : Fritzing.app/Contents/PlugIns/%s with ngspice/ code models\n' "$NGSPICE_LIBRARY"
if [[ $SIGN_ADHOC -eq 1 ]]; then
  printf 'Signature  : ad hoc (no Developer ID, not notarised)\n'
else
  printf 'Signature  : none (unsigned)\n'
fi
printf 'Log        : %s\n' "$LOG_FILE"
printf 'Work dir   : %s\n' "$WORK_DIR"
printf '\n'
printf 'Unpack the archive, then remove the download quarantine of this locally built application:\n'
printf '  xattr -dr com.apple.quarantine "/path/to/Fritzing.app"\n'
printf 'Import the parts in Fritzing with File > Open on a .fzpz file from custom-parts\n'
printf '(see IMPORT-CUSTOM-PARTS.txt). Details and Gatekeeper notes: LOCAL-MACOS-BUILD.md.\n'
printf 'Running the same command again reuses everything that is already in the work directory.\n'
printf 'rm -rf "%s"   frees the work directory.\n' "$WORK_DIR"
printf 'Total time : %02d:%02d:%02d\n' $((ELAPSED / 3600)) $(((ELAPSED % 3600) / 60)) $((ELAPSED % 60))
