#!/usr/bin/env bash
# Copies the golden inputs and the layer-3 routes table into assets/ (not in
# git: the rd5 files are 35 MB). Run golden/gen.sh or dart test first.
set -euo pipefail
cd "$(dirname "$0")"
release=$(awk '/^release/{print $2}' ../golden/data/INPUT)
in=../golden/.build/input/$release
(cd "$in" && shasum -a 256 -c SHA256SUMS >/dev/null)
cp "$in"/E120_N20.rd5 "$in"/E120_N25.rd5 "$in"/lookups.dat "$in"/hiking-mountain.brf "$in"/trekking.brf assets/
cp ../golden/data/routes.tsv.gz assets/
