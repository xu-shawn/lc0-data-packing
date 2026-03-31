#!/bin/bash

set -e

BASE_URL="https://storage.lczero.org/files/training_data/test91/"
DATA_DIR="./data"
BINPACK_DIR="./binpacks"
SYZYGY_PATH=$1
RESCORER_BIN="./lc0/build/release/rescorer"

if [ -z "$SYZYGY_PATH" ]; then
    echo "Usage: $0 <SYZYGY_PATH>"
    exit 1
fi

mkdir -p "$DATA_DIR"
mkdir -p "$BINPACK_DIR"

echo "Fetching list of tarballs from $BASE_URL..."
TARBALLS=$(curl -s "$BASE_URL" \
    | grep -oE 'href="[^"]+\.tar"' \
    | sed -E 's/href="([^"]+)"/\1/' \
    | sort -r)

if [ -z "$TARBALLS" ]; then
    echo "No tarballs found at $BASE_URL"
    exit 1
fi

for TARBALL in $TARBALLS; do
    echo "============================================="
    echo "Processing $TARBALL..."

    NAME="${TARBALL%.tar}"
    TAR_PATH="${DATA_DIR}/${TARBALL}"
    EXTRACT_PATH="${DATA_DIR}/${NAME}"
    BINPACK_PATH="${BINPACK_DIR}/${NAME}.binpack"
    DONE_FLAG="${BINPACK_DIR}/${NAME}.done"

    # Full success check
    if [ -f "$BINPACK_PATH" ] || [ -f "$DONE_FLAG" ]; then
        echo "Already processed, skipping..."
        continue
    fi

    # Download only if missing
    if [ ! -f "$TAR_PATH" ]; then
        echo "Downloading ${TARBALL}..."
        wget -c "${BASE_URL}${TARBALL}" -O "$TAR_PATH"
    else
        echo "Tar already exists, skipping download..."
    fi

    # Extract only if missing
    if [ ! -d "$EXTRACT_PATH" ]; then
        echo "Extracting ${TARBALL}..."
        tar -xf "$TAR_PATH" -C "$DATA_DIR"
    else
        echo "Already extracted, skipping..."
    fi

    echo "Running rescorer..."
    "$RESCORER_BIN" rescore \
        --syzygy-paths="$SYZYGY_PATH" \
        --input="$EXTRACT_PATH" \
        --binpack-file="$BINPACK_PATH" \
        --nnue-best-score=true \
        --nnue-best-move=true \
        --deblunder=true \
        --deblunder-q-blunder-threshold=0.10 \
        --deblunder-q-blunder-width=0.03 \
        --threads=5 \
        --delete-files

    # Mark success explicitly
    touch "$DONE_FLAG"

    echo "Cleaning up..."
    rm -f "$TAR_PATH"
    rm -rf "$EXTRACT_PATH"

    echo "Finished processing $TARBALL"
done

echo "All done!"