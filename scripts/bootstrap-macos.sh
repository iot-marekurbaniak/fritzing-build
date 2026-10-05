#!/usr/bin/env bash
# Fetch the pinned sources and build the sibling dependencies that fritzing-app/pri/*detect.pri
# expect next to the fritzing-app checkout, plus the ngspice shared library that Fritzing loads at
# simulation start. Idempotent: existing directories and finished builds are reused.
set -euo pipefail
: "${QT_ROOT:?set QT_ROOT to the Qt installation root}"
ROOT="${1:-${RUNNER_TEMP:?set RUNNER_TEMP or pass the root directory}/fritzing}"
KIT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOCK="${2:-$KIT/versions.lock.json}"
# Qt 6.8 supports macOS 12 and later; clang and CMake both honour this variable.
export MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-12.0}"

lock() {
  python3 -c 'import json, sys
value = json.load(open(sys.argv[1]))
for key in sys.argv[2].split("."):
    value = value[key]
print(value)' "$LOCK" "$1"
}

lock_list() {
  # One element of a JSON array per line, so that the caller can read it into a bash array without
  # word splitting. Used for the pinned ngspice configure options.
  python3 -c 'import json, sys
value = json.load(open(sys.argv[1]))
for key in sys.argv[2].split("."):
    value = value[key]
print("\n".join(value))' "$LOCK" "$1"
}

require_tool() {
  local tool=$1 hint=$2
  command -v "$tool" >/dev/null 2>&1 || { printf '%s is required but was not found. %s\n' "$tool" "$hint" >&2; exit 5; }
}

pinned_checkout() {
  # Shallow but complete tree, HEAD on a named branch that tracks origin. Fritzing opens this
  # repository with libgit2 1.7.1, which rejects partial clones (extensions.partialclone), and
  # its parts checker compares the HEAD branch name with the remote branches.
  local url=$1 dir=$2 commit=$3 branch=$4
  if [[ ! -d "$dir/.git" ]]; then
    git init -q "$dir"
    git -C "$dir" remote add origin "$url"
  fi
  git -C "$dir" fetch --depth 1 origin "$commit"
  git -C "$dir" checkout -q -B "$branch" FETCH_HEAD
  git -C "$dir" config "branch.$branch.remote" origin
  git -C "$dir" config "branch.$branch.merge" "refs/heads/$branch"
  [[ $(git -C "$dir" rev-parse HEAD) == "$commit" ]] || { echo "$dir is not at $commit" >&2; exit 1; }
}

fetch_tar() {
  # $3 is an optional expected SHA-256. The digest of a freshly downloaded archive is always
  # printed, so an unpinned source can be pinned in the lock after the first run.
  local url=$1 dir=$2 expected=${3:-} archive actual
  [[ -d "$dir" ]] && return 0
  archive="$(mktemp "${TMPDIR:-/tmp}/kit.XXXXXX")"
  curl --fail --location --retry 3 --silent --show-error --output "$archive" "$url"
  actual="$(shasum -a 256 "$archive" | awk '{print $1}')"
  printf 'downloaded %s sha256=%s\n' "$dir" "$actual"
  if [[ -n "$expected" && "$actual" != "$expected" ]]; then
    rm -f "$archive"
    printf '%s has SHA-256 %s, the lock expects %s\n' "$url" "$actual" "$expected" >&2
    exit 1
  fi
  mkdir -p "$dir"
  tar xzf "$archive" -C "$dir" --strip-components=1 || { rm -rf "$dir"; rm -f "$archive"; exit 1; }
  rm -f "$archive"
}

mkdir -p "$ROOT"
cd "$ROOT"
pinned_checkout "$(lock fritzing_app.repository)" fritzing-app "$(lock fritzing_app.commit)" "$(lock fritzing_app.branch)"
pinned_checkout "$(lock fritzing_parts.repository)" fritzing-parts "$(lock fritzing_parts.commit)" "$(lock fritzing_parts.branch)"

# Header-only dependencies (boostdetect.pri, svgppdetect.pri, spicedetect.pri).
BOOST_DIR="boost_$(lock dependencies.boost | tr . _)"
fetch_tar "$(lock sources.boost)" "$BOOST_DIR"
fetch_tar "$(lock sources.svgpp)" "svgpp-$(lock dependencies.svgpp)"
NGSPICE_DIR="ngspice-$(lock dependencies.ngspice)"
fetch_tar "$(lock sources.ngspice)" "$NGSPICE_DIR" "$(lock macos_runtime.ngspice.sha256)"
if [[ ! -d "$NGSPICE_DIR/include/ngspice" ]]; then
  mkdir -p "$NGSPICE_DIR/include"
  cp -R "$NGSPICE_DIR/src/include/ngspice" "$NGSPICE_DIR/include/"
fi

# ngspice as a shared library for this architecture. Fritzing does not link against it: it loads
# libngspice.0.dylib when a simulation starts and then reads the XSPICE code models from the
# ngspice/ directory next to the library, so the runtime has to be built here, from the same pinned
# tarball that provides the headers. A Homebrew ngspice is deliberately not used: it is not pinned,
# it may be built for the other architecture and it lives outside the bundle.
NGSPICE_ARCH="$(uname -m)"
NGSPICE_RUNTIME="$ROOT/$NGSPICE_DIR-runtime-$NGSPICE_ARCH"
NGSPICE_BUILD="$ROOT/$NGSPICE_DIR-build-$NGSPICE_ARCH"
NGSPICE_LIB="$NGSPICE_RUNTIME/lib/$(lock macos_runtime.ngspice.library)"
NGSPICE_MODEL="$NGSPICE_RUNTIME/lib/ngspice/$(lock macos_runtime.ngspice.required_code_model)"
ngspice_runtime_ready() {
  # A finished install for exactly this architecture; anything else is rebuilt.
  [[ -f "$NGSPICE_LIB" && -f "$NGSPICE_MODEL" ]] || return 1
  [[ "$(lipo -archs "$NGSPICE_LIB" 2>/dev/null)" == "$NGSPICE_ARCH" ]]
}
if ngspice_runtime_ready; then
  printf 'ngspice %s runtime for %s is already built at %s\n' "$(lock dependencies.ngspice)" "$NGSPICE_ARCH" "$NGSPICE_RUNTIME"
else
  require_tool make 'Install the Xcode command line tools: xcode-select --install'
  require_tool clang 'Install the Xcode command line tools: xcode-select --install'
  require_tool lipo 'Install the Xcode command line tools: xcode-select --install'
  NGSPICE_CONFIGURE=()
  while IFS= read -r ngspice_flag; do
    [[ -n "$ngspice_flag" ]] && NGSPICE_CONFIGURE+=("$ngspice_flag")
  done <<EOF
$(lock_list macos_runtime.ngspice.configure)
EOF
  [[ ${#NGSPICE_CONFIGURE[@]} -gt 0 ]] || { echo 'macos_runtime.ngspice.configure is empty in the lock' >&2; exit 5; }
  if [[ ! -x "$ROOT/$NGSPICE_DIR/configure" ]]; then
    # Release tarballs ship a generated configure. Only a source tree without one needs autotools.
    [[ -x "$ROOT/$NGSPICE_DIR/autogen.sh" ]] || { printf '%s has neither configure nor autogen.sh\n' "$NGSPICE_DIR" >&2; exit 5; }
    for ngspice_tool in autoconf automake libtool; do
      require_tool "$ngspice_tool" 'Install it with: brew install automake autoconf libtool'
    done
    ( cd "$ROOT/$NGSPICE_DIR" && ./autogen.sh )
  fi
  # A half-finished prefix must never look ready to the check above, so both directories start empty.
  rm -rf "$NGSPICE_RUNTIME" "$NGSPICE_BUILD"
  mkdir -p "$NGSPICE_BUILD"
  ( cd "$NGSPICE_BUILD" && "$ROOT/$NGSPICE_DIR/configure" --prefix="$NGSPICE_RUNTIME" "${NGSPICE_CONFIGURE[@]}" )
  make -C "$NGSPICE_BUILD" -j"$(sysctl -n hw.ncpu)"
  make -C "$NGSPICE_BUILD" install
  ngspice_runtime_ready || {
    printf 'the ngspice build did not install %s and %s for %s\n' "$NGSPICE_LIB" "$NGSPICE_MODEL" "$NGSPICE_ARCH" >&2
    exit 5
  }
  printf 'ngspice runtime %s built for %s\n' "$NGSPICE_LIB" "$(lipo -archs "$NGSPICE_LIB")"
  printf 'code models: %s\n' "$(find "$NGSPICE_RUNTIME/lib/ngspice" -name '*.cm' -exec basename {} \; | sort | tr '\n' ' ')"
fi

# Clipper1 (clipper1detect.pri): one translation unit, static archive.
CLIP="Clipper1-$(lock dependencies.clipper1)"
fetch_tar "$(lock sources.clipper1)" clipper-source
if [[ ! -f "$CLIP/lib/libpolyclipping.a" ]]; then
  SRC=$(find clipper-source -name clipper.cpp -print -quit)
  [[ -n "$SRC" ]] || { echo "clipper.cpp not found in clipper-source" >&2; exit 1; }
  mkdir -p "$CLIP/include/polyclipping" "$CLIP/lib"
  cp "$(dirname "$SRC")/clipper.hpp" "$CLIP/include/polyclipping/"
  clang++ -std=c++11 -O2 -c "$SRC" -o "$CLIP/clipper.o"
  ar rcs "$CLIP/lib/libpolyclipping.a" "$CLIP/clipper.o"
fi

# libgit2 static with the default SecureTransport backend; libgit2detect.pri links libgit2.a
# together with -framework Security, and phoenix.pro adds -liconv and -lz.
LIBGIT2="$ROOT/libgit2-$(lock dependencies.libgit2)"
fetch_tar "$(lock sources.libgit2)" libgit2-src
if [[ ! -f "$LIBGIT2/lib/libgit2.a" ]]; then
  cmake -S libgit2-src -B libgit2-build -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="$LIBGIT2" \
    -DBUILD_SHARED_LIBS=OFF -DBUILD_TESTS=OFF -DBUILD_CLI=OFF -DUSE_SSH=OFF
  cmake --build libgit2-build --parallel
  cmake --install libgit2-build
fi

# QuaZip 1.4 for Qt 6 (needs Core5Compat). The install prefix is the exact path expected by
# pri/quazipdetect.pri of the pinned commit: quazip-<Qt version>-<QuaZip version>intuisphere.
QUAZIP="$ROOT/quazip-$(lock qt.version)-$(lock dependencies.quazip)intuisphere"
fetch_tar "$(lock sources.quazip)" quazip-src
if [[ ! -e "$QUAZIP/lib/libquazip1-qt6.dylib" ]]; then
  cmake -S quazip-src -B quazip-build -DCMAKE_BUILD_TYPE=Release -DCMAKE_PREFIX_PATH="$QT_ROOT" \
    -DCMAKE_INSTALL_PREFIX="$QUAZIP" -DQUAZIP_QT_MAJOR_VERSION=6 -DQUAZIP_BZIP2=OFF -DQUAZIP_ENABLE_TESTS=OFF
  cmake --build quazip-build --parallel
  cmake --install quazip-build
fi
printf 'dependencies ready at %s\n' "$ROOT"
