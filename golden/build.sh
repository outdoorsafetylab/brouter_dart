#!/usr/bin/env bash
# Builds the reference engine of `docs/design.md` D4/D5: BRouter v1.7.10 from source, with
# the engine's Math.cos/sin/exp/atan2 calls switched to StrictMath (fdlibm),
# into golden/.build/brouter. Idempotent: a finished build is left alone.
set -euo pipefail
cd "$(dirname "$0")"
VERSION=v1.7.10
SRC=.build/brouter
if [[ -f .build/done-$VERSION ]]; then exit 0; fi
rm -rf .build && mkdir -p .build
git clone -q --depth 1 --branch "$VERSION" https://github.com/abrensch/brouter.git "$SRC"
# The only change to upstream (`docs/design.md` D4): strictmath.patch switches the
# engine's transcendental calls to StrictMath.
git -C "$SRC" apply "$PWD/strictmath.patch"
# Nothing outside the patch may still call them.
if grep -rnE '(^|[^t])Math\.(cos|sin|exp|atan2)\(' "$SRC"/brouter-{util,codec,mapaccess,expressions,core}/src/main; then
  echo "unpatched Math call left" >&2; exit 1
fi
(cd "$SRC" && ./gradlew -q :brouter-core:jar :brouter-mapaccess:jar :brouter-expressions:jar :brouter-codec:jar :brouter-util:jar)
touch .build/done-$VERSION
