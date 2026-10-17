#!/bin/zsh
# Local development helper: build the Debug app with ad-hoc signing, run the
# tests, or build and open the app. Used by the VS Code tasks.
#
#   scripts/dev.sh run     build, then quit any running copy and open the app
#   scripts/dev.sh build   build only
#   scripts/dev.sh test    run the unit tests
set -euo pipefail

ROOT="${0:A:h:h}"
APP="$ROOT/build/derived/Build/Products/Debug/MacDash.app"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

cd "$ROOT"

build() {
  local log
  log=$(xcodebuild -project PureMac.xcodeproj -scheme PureMac -configuration Debug \
    -derivedDataPath build/derived -skipMacroValidation \
    CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO DEVELOPMENT_TEAM= CODE_SIGN_STYLE=Manual \
    build 2>&1) || true
  print -r -- "$log" | grep -E "error:|BUILD (SUCCEEDED|FAILED)" | sort -u || true
  # Never open a stale app after a failed build.
  print -r -- "$log" | grep -q "BUILD SUCCEEDED" || { echo "Build failed; app not opened."; exit 1; }
}

case "${1:-run}" in
  build)
    build
    ;;
  run)
    build
    pkill -x MacDash 2>/dev/null || true
    sleep 1
    open "$APP"
    echo "Opened $APP"
    ;;
  test)
    xcodebuild -project PureMac.xcodeproj -scheme PureMac -configuration Debug \
      -derivedDataPath build/derived-tests -skipMacroValidation \
      CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO DEVELOPMENT_TEAM= \
      test | grep -E "error: -\[|Executed [0-9]+ tests.*seconds$|TEST (SUCCEEDED|FAILED)"
    ;;
  *)
    echo "Usage: scripts/dev.sh [run|build|test]"
    exit 2
    ;;
esac
