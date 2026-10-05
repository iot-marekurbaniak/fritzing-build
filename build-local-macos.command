#!/bin/bash
# Local macOS build of Fritzing, no GitHub Actions. Double-click in Finder, or run from Terminal:
#   ./build-local-macos.command
#   ./build-local-macos.command --work-dir "$HOME/fritzing build" --sign-adhoc
# The wrapper only starts scripts/build-local-macos.sh from the directory of this file; it does not
# change any system setting. See LOCAL-MACOS-BUILD.md.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
/bin/bash "$HERE/scripts/build-local-macos.sh" "$@"
CODE=$?
if [ "$CODE" -ne 0 ]; then
  echo
  echo "Build failed with exit code $CODE. See the log in the out/logs folder."
fi
exit "$CODE"
