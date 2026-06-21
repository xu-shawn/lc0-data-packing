#!/bin/bash

set -e

CURRENT_PID=""
STOP_REQUESTED=0

run_interruptible() {
    "$@" &
    CURRENT_PID=$!

    local status=0
    if ! wait "$CURRENT_PID"; then
        status=$?
    fi
    CURRENT_PID=""
    return "$status"
}

handle_signal() {
    STOP_REQUESTED=1
    if [ -n "$CURRENT_PID" ] && kill -0 "$CURRENT_PID" 2>/dev/null; then
        kill "$CURRENT_PID" 2>/dev/null || true
        wait "$CURRENT_PID" 2>/dev/null || true
        CURRENT_PID=""
    fi
}

trap 'handle_signal' INT TERM

# Download a tarball, resuming partial downloads and retrying until the
# complete, valid file is retrieved. wget -c compares the local size against
# the server's Content-Length, so a clean exit means the file is whole;
# tar -tf then confirms the archive itself isn't truncated/corrupt. Returns
# 0 on success, 130 if interrupted, 1 if it gives up after MAX_DOWNLOAD_ATTEMPTS.
download_verified_tarball() {
    local url=$1
    local out=$2
    local attempt=0
    local status=0

    while [ "$attempt" -lt "$MAX_DOWNLOAD_ATTEMPTS" ]; do
        [ "$STOP_REQUESTED" -ne 0 ] && return 130
        attempt=$((attempt + 1))
        echo "Download attempt ${attempt}/${MAX_DOWNLOAD_ATTEMPTS} for ${out##*/}..."

        if run_interruptible wget -c --timeout=60 --tries=5 --waitretry=10 \
            --retry-connrefused "$url" -O "$out"; then
            if tar -tf "$out" >/dev/null 2>&1; then
                return 0
            fi
            echo "Archive is corrupt; discarding and restarting download..."
            rm -f "$out"
        else
            status=$?
            [ "$STOP_REQUESTED" -ne 0 ] && return 130
            echo "Download did not complete (wget exit ${status}); will resume."
        fi

        [ "$attempt" -lt "$MAX_DOWNLOAD_ATTEMPTS" ] && sleep "$RETRY_WAIT"
    done

    echo "Giving up on ${out##*/} after ${MAX_DOWNLOAD_ATTEMPTS} attempts."
    return 1
}

BASE_URL="https://data.lczero.org/files/training_data/test90/"
FIRST_TAR="training-run3-test90-20250922-1817.tar"
LAST_TAR="training-run3-test90-20251106-0917.tar"
DATA_DIR="./data"
BINPACK_DIR="./binpacks"
SYZYGY_PATH=$1
RESCORER_BIN="./lc0/build/release/rescorer"
MAX_DOWNLOAD_ATTEMPTS=10
RETRY_WAIT=10

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
    | sort \
    | awk -v first="$FIRST_TAR" -v last="$LAST_TAR" 'first <= $0 && $0 <= last')

if [ -z "$TARBALLS" ]; then
    echo "No tarballs found at $BASE_URL"
    exit 1
fi

for TARBALL in $TARBALLS; do
    if [ "$STOP_REQUESTED" -ne 0 ]; then
        echo "Interrupted, stopping..."
        exit 130
    fi

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

    # Fetch the tarball, resuming/retrying until the full archive is present.
    # This also re-validates any tarball left over from a previous run, so we
    # never extract or rescore a half-downloaded file.
    echo "Downloading ${TARBALL}..."
    if ! download_verified_tarball "${BASE_URL}${TARBALL}" "$TAR_PATH"; then
        if [ "$STOP_REQUESTED" -ne 0 ]; then
            echo "Interrupted, stopping..."
            exit 130
        fi
        echo "Could not retrieve a complete ${TARBALL}; skipping for now."
        rm -f "$TAR_PATH"
        continue
    fi

    # Start each unfinished tarball from a clean slate. A leftover extraction or
    # .partial binpack means an earlier run was interrupted -- possibly mid-rescore,
    # which deletes input files (--delete-files) -- so the state can't be trusted.
    rm -rf "$EXTRACT_PATH"
    rm -f "${BINPACK_PATH}.partial"

    # Extract atomically: unpack into a staging dir and move the result into place
    # only on success, so EXTRACT_PATH never names a half-extracted tree.
    echo "Extracting ${TARBALL}..."
    STAGING_DIR="${DATA_DIR}/.staging-${NAME}"
    rm -rf "$STAGING_DIR"
    mkdir -p "$STAGING_DIR"
    run_interruptible tar -xf "$TAR_PATH" -C "$STAGING_DIR"
    mv "${STAGING_DIR}/${NAME}" "$EXTRACT_PATH"
    rm -rf "$STAGING_DIR"

    echo "Running rescorer..."
    run_interruptible "$RESCORER_BIN" rescore \
        --syzygy-paths="$SYZYGY_PATH" \
        --input="$EXTRACT_PATH" \
        --binpack-file="${BINPACK_PATH}.partial" \
        --nnue-best-score=true \
        --nnue-best-move=true \
        --deblunder=true \
        --deblunder-q-blunder-threshold=0.10 \
        --deblunder-q-blunder-width=0.03 \
        --threads=5 \
        --delete-files

    # Publish the binpack atomically only after a full, successful rescore, then
    # mark success. Until this point BINPACK_PATH never exists, so a partial
    # rescore can never be mistaken for a finished one. Empty/stub tarballs (just
    # a LICENSE, no games) produce no .partial file; that's still a complete
    # result, so mark them done with no binpack rather than failing.
    if [ -f "${BINPACK_PATH}.partial" ]; then
        mv "${BINPACK_PATH}.partial" "$BINPACK_PATH"
    else
        echo "No positions in ${TARBALL} (empty/stub tarball); no binpack produced."
    fi
    touch "$DONE_FLAG"

    echo "Cleaning up..."
    rm -f "$TAR_PATH"
    rm -rf "$EXTRACT_PATH"

    echo "Finished processing $TARBALL"
done

echo "All done!"
