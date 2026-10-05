#!/usr/bin/env bash
# Build Fritzing.app for one architecture, complete the bundle like tools/deploy_fritzing_mac.sh
# upstream, run macdeployqt, add the ngspice runtime, generate the parts database and zip the
# bundle unsigned.
set -euo pipefail
: "${QT_ROOT:?set QT_ROOT to the Qt installation root}"
ROOT="${1:-${RUNNER_TEMP:?set RUNNER_TEMP or pass the root directory}/fritzing}"
ARCH="${2:?arm64 or x86_64}"
OUT="${3:-$PWD/out}"
KIT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOCK="${4:-$KIT/versions.lock.json}"
[[ $(uname -m) == "$ARCH" ]] || { echo "runner is $(uname -m), expected $ARCH" >&2; exit 2; }
export MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-12.0}"

lock() {
  python3 -c 'import json, sys
value = json.load(open(sys.argv[1]))
for key in sys.argv[2].split("."):
    value = value[key]
print(value)' "$LOCK" "$1"
}

APP="$ROOT/fritzing-app"
PARTS="$ROOT/fritzing-parts"
NGSPICE_RUNTIME="$ROOT/ngspice-$(lock dependencies.ngspice)-runtime-$ARCH"
NGSPICE_LIBRARY="$(lock macos_runtime.ngspice.library)"
NGSPICE_MODEL="$(lock macos_runtime.ngspice.required_code_model)"
[[ -f "$NGSPICE_RUNTIME/lib/$NGSPICE_LIBRARY" ]] || {
  echo "missing $NGSPICE_RUNTIME/lib/$NGSPICE_LIBRARY; run scripts/bootstrap-macos.sh first" >&2
  exit 3
}

cd "$APP"
# The repository only tracks .ts sources; the release procedure compiles them to .qm.
"$QT_ROOT/bin/lrelease" translations/*.ts
# phoenix.pro assigns QMAKE_APPLE_DEVICE_ARCHS = x86_64 arm64 (universal). The dependencies built
# here are single-architecture, so the -after assignment overrides the project after it is parsed
# (qmake -help: "-after: all variable assignments after this will be parsed after [files]").
"$QT_ROOT/bin/qmake" phoenix.pro CONFIG+=release -after "QMAKE_APPLE_DEVICE_ARCHS=$ARCH"
make -j"$(sysctl -n hw.ncpu)" release

BUNDLE="$ROOT/release64/Fritzing.app"
BIN="$BUNDLE/Contents/MacOS/Fritzing"
[[ -x "$BIN" ]] || { echo "missing $BIN" >&2; exit 3; }
ARCHS=$(lipo -archs "$BIN")
[[ "$ARCHS" == "$ARCH" ]] || { echo "binary architectures '$ARCHS' differ from '$ARCH'" >&2; exit 3; }

SUPPORT="$BUNDLE/Contents/MacOS"
cp -R sketches help INSTALL.txt README.md LICENSE.CC-BY-SA LICENSE.GPL2 LICENSE.GPL3 "$SUPPORT/"
mkdir -p "$SUPPORT/translations"
cp translations/*.qm "$SUPPORT/translations/"
find "$SUPPORT/translations" -name '*.qm' -size -128c -delete
# The .git directory is part of the product: Fritzing reads the parts commit with libgit2 at start-up.
cp -R "$PARTS" "$SUPPORT/fritzing-parts"
# libquazip refers to the Qt frameworks through @rpath; without -libpath macdeployqt resolves that rpath
# only against the QuaZip directory, skips QtCore5Compat and the app aborts at start-up.
"$QT_ROOT/bin/macdeployqt" "$BUNDLE" -verbose=1 -libpath="$QT_ROOT/lib"

# --------------------------------------------------------------------------------------------------
# ngspice runtime, after macdeployqt so that it does not try to redeploy a non-Qt library.
#
# Fritzing loads libngspice.0.dylib at simulation start by scanning QCoreApplication::libraryPaths()
# and then reads the code models from the ngspice/ directory next to the library it found. In a
# deployed bundle libraryPaths() contains Contents/PlugIns -- both CFBundleCopyBuiltInPlugInsURL and
# the "Plugins = PlugIns" entry that macdeployqt writes into Contents/Resources/qt.conf resolve
# there, the latter against the bundle prefix Contents/ -- and Contents/MacOS, which is
# applicationDirPath(). The runtime is installed once in Contents/PlugIns and linked from
# Contents/MacOS, so whichever of the two search roots is used first finds the same files.
# --------------------------------------------------------------------------------------------------
PLUGINS="$BUNDLE/Contents/PlugIns"
[[ "$PLUGINS" == */Fritzing.app/Contents/PlugIns ]] || { echo "refusing to write outside the bundle: $PLUGINS" >&2; exit 5; }
rm -rf "$PLUGINS/ngspice" "$PLUGINS/${NGSPICE_LIBRARY:?}"
mkdir -p "$PLUGINS/ngspice"
cp "$NGSPICE_RUNTIME/lib/$NGSPICE_LIBRARY" "$PLUGINS/$NGSPICE_LIBRARY"
# Only the code models; the static archive and the libtool files of the install prefix are not runtime.
find "$NGSPICE_RUNTIME/lib/ngspice" -maxdepth 1 -name '*.cm' -exec cp {} "$PLUGINS/ngspice/" \;
chmod u+w "$PLUGINS/$NGSPICE_LIBRARY" "$PLUGINS/ngspice"/*.cm

# libtool stamps the absolute build prefix as the install name. Point it at @rpath and pull every
# non-system dependency into the bundle, so the ngspice runtime never reaches outside Fritzing.app.
install_name_tool -id "@rpath/$NGSPICE_LIBRARY" "$PLUGINS/$NGSPICE_LIBRARY"
MACHO=("$PLUGINS/$NGSPICE_LIBRARY")
while IFS= read -r model; do MACHO+=("$model"); done < <(find "$PLUGINS/ngspice" -maxdepth 1 -name '*.cm' | sort)
index=0
while [[ $index -lt ${#MACHO[@]} ]]; do
  binary=${MACHO[$index]}
  index=$((index + 1))
  # Code models live one directory below the library they belong to.
  relative=""
  [[ "$(dirname "$binary")" == "$PLUGINS" ]] || relative="../"
  while IFS= read -r dependency; do
    name="$(basename "$dependency")"
    case "$dependency" in
      /usr/lib/*|/System/*) continue ;;
      # An @rpath reference to something that is already staged is made independent of LC_RPATH.
      @rpath/*)
        if [[ -f "$PLUGINS/$name" ]]; then
          install_name_tool -change "$dependency" "@loader_path/$relative$name" "$binary"
        fi
        continue ;;
      @*) continue ;;
    esac
    if [[ ! -f "$PLUGINS/$name" ]]; then
      [[ -f "$dependency" ]] || { echo "$binary needs $dependency, which does not exist" >&2; exit 5; }
      cp "$dependency" "$PLUGINS/$name"
      chmod u+w "$PLUGINS/$name"
      install_name_tool -id "@rpath/$name" "$PLUGINS/$name"
      MACHO+=("$PLUGINS/$name")
      printf 'staged the ngspice dependency %s\n' "$dependency"
    fi
    install_name_tool -change "$dependency" "@loader_path/$relative$name" "$binary"
  done < <(otool -L "$binary" | tail -n +2 | awk '{print $1}')
  # install_name_tool invalidates the ad hoc signature that the linker produced; on arm64 an
  # unsigned Mach-O file cannot be loaded at all, so every touched file is re-signed ad hoc.
  codesign --force --sign - "$binary"
done
ln -sfn "../PlugIns/$NGSPICE_LIBRARY" "$SUPPORT/$NGSPICE_LIBRARY"
ln -sfn "../PlugIns/ngspice" "$SUPPORT/ngspice"

# Parts database from the deployed bundle, as in the upstream deploy script. FMessageBox is muted
# in this mode, but a plain QMessageBox on failure would block forever, hence the alarm.
DB="$SUPPORT/fritzing-parts/parts.db"
perl -e 'alarm shift; exec @ARGV' 1200 "$BIN" -db "$DB"
[[ -s "$DB" ]] || { echo "parts.db was not generated at $DB" >&2; exit 4; }
file "$DB"

# Everything the simulator needs has to be in the bundle, built for this architecture and free of
# references to libraries outside it, before anything is packaged.
for required in "Contents/PlugIns/$NGSPICE_LIBRARY" "Contents/PlugIns/ngspice/$NGSPICE_MODEL" \
  "Contents/MacOS/$NGSPICE_LIBRARY" "Contents/MacOS/ngspice/$NGSPICE_MODEL"; do
  [[ -e "$BUNDLE/$required" ]] || { echo "missing simulation runtime: $required" >&2; exit 5; }
done
for binary in "${MACHO[@]}"; do
  file "$binary"
  BINARY_ARCHS=$(lipo -archs "$binary")
  [[ "$BINARY_ARCHS" == "$ARCH" ]] || { echo "$binary is '$BINARY_ARCHS', expected '$ARCH'" >&2; exit 5; }
  otool -L "$binary"
  ESCAPED=$(otool -L "$binary" | tail -n +2 | awk '$1 ~ /^\// && $1 !~ /^\/usr\/lib\// && $1 !~ /^\/System\// {print $1}')
  [[ -z "$ESCAPED" ]] || { echo "$binary still references libraries outside the bundle: $ESCAPED" >&2; exit 5; }
done

mkdir -p "$OUT"
rm -f "$OUT/fritzing-macos-$ARCH-unsigned.zip"
ditto -c -k --sequesterRsrc --keepParent "$BUNDLE" "$OUT/fritzing-macos-$ARCH-unsigned.zip"
file "$BIN"
echo "unsigned artifact: $OUT/fritzing-macos-$ARCH-unsigned.zip"
