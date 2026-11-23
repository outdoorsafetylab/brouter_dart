#!/usr/bin/env bash
# Regenerates golden/data from the fixed inputs of `docs/design.md` D5. The release tag
# below is the only thing to change when the inputs move to new tiles.
set -euo pipefail
cd "$(dirname "$0")"
RELEASE=golden-input-2026-11-23
TILES=(E120_N20 E120_N25)
PROFILES=(hiking-mountain trekking)

./build.sh
IN=.build/input/$RELEASE
if [[ ! -f $IN/SHA256SUMS ]]; then
  mkdir -p "$IN"
  gh release download "$RELEASE" --repo outdoorsafetylab/brouter_dart --dir "$IN"
fi
(cd "$IN" && shasum -a 256 -c SHA256SUMS)

CP=".build/classes:$(ls .build/brouter/brouter-*/build/libs/*.jar | tr '\n' ':')"
mkdir -p .build/classes
javac -d .build/classes -cp "$CP" src/Golden.java

OUT=.build/out
rm -rf "$OUT" && mkdir -p "$OUT"
for t in "${TILES[@]}"; do java -cp "$CP" Golden decode "$IN/$t.rd5" "$OUT"; done
LC_ALL=C sort -u "$OUT"/*.ways.hex > "$OUT/ways.hex"
LC_ALL=C sort -u "$OUT"/*.nodes.hex > "$OUT/nodes.hex"
for p in "${PROFILES[@]}"; do
  java -cp "$CP" Golden rules "$IN/lookups.dat" "$IN/$p.brf" "$OUT/ways.hex" "$OUT/nodes.hex" "$OUT/$p.rules.tsv"
done
java -cp "$CP" Golden ops "$IN/lookups.dat" ops.brf "$OUT/ways.hex" "$OUT/nodes.hex" "$OUT/ops.tsv"

rm -rf data && mkdir -p data
for t in "${TILES[@]}"; do gzip -9n < "$OUT/$t.decode.tsv" > "data/$t.decode.tsv.gz"; done
gzip -9n < "$OUT/ways.hex" > data/ways.hex.gz
gzip -9n < "$OUT/nodes.hex" > data/nodes.hex.gz
for p in "${PROFILES[@]}"; do gzip -9n < "$OUT/$p.rules.tsv" > "data/$p.rules.tsv.gz"; done
gzip -9n < "$OUT/ops.tsv" > data/ops.tsv.gz
java -cp "$CP" Golden util "$OUT/util.tsv"
java -cp "$CP" Golden routes routes.tsv "$IN" "$OUT/routes.tsv" > /dev/null
gzip -9n < "$OUT/routes.tsv" > data/routes.tsv.gz
gzip -9n < "$OUT/util.tsv" > data/util.tsv.gz
{ echo "release $RELEASE"; cat "$IN/SHA256SUMS"; } > data/INPUT
