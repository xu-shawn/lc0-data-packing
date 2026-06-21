#!/bin/bash
#
# Download the Syzygy 3-4-5 and 6-piece WDL+DTZ tablebases (~150 GB) into
# ./Syzygy and verify every file against the mirror's published md5 checksums.
#
# Safe to re-run: completed/valid files are skipped, partial downloads resume,
# and any file failing its md5 is re-downloaded from scratch.

set -euo pipefail

BASE_URL="https://tablebase.lichess.ovh/tables/standard"
DEST="./Syzygy"
SUBDIRS=(3-4-5-wdl 3-4-5-dtz 6-wdl 6-dtz)
MAX_ATTEMPTS=10
RETRY_WAIT=10

mkdir -p "$DEST"

md5_of() {
    md5sum "$1" | awk '{print $1}'
}

# Download a single file, resuming/retrying until it matches its expected md5.
download_one() {
    local url=$1 out=$2 want=$3
    local attempt=0

    # Already have a correct copy? Nothing to do.
    if [ -f "$out" ] && [ "$(md5_of "$out")" = "$want" ]; then
        return 0
    fi

    while [ "$attempt" -lt "$MAX_ATTEMPTS" ]; do
        attempt=$((attempt + 1))
        if wget -c -q --show-progress --timeout=60 --tries=5 --waitretry=10 \
            --retry-connrefused "$url" -O "$out"; then
            if [ "$(md5_of "$out")" = "$want" ]; then
                return 0
            fi
            echo "    md5 mismatch; discarding and re-downloading (attempt ${attempt}/${MAX_ATTEMPTS})..."
            rm -f "$out"
        else
            echo "    download incomplete (attempt ${attempt}/${MAX_ATTEMPTS}); will resume..."
        fi
        [ "$attempt" -lt "$MAX_ATTEMPTS" ] && sleep "$RETRY_WAIT"
    done

    return 1
}

# 1. Fetch the master checksum list and load it into a basename -> md5 map.
echo "Fetching checksum list..."
curl -fsSL "$BASE_URL/md5" -o "$DEST/.md5.all"

declare -A MD5
while read -r sum name; do
    MD5["$name"]="$sum"
done < "$DEST/.md5.all"

# 2. Build the download list from the four target directory listings. This
#    keeps us to 3-4-5 and 6 piece, WDL + DTZ, excluding 7-piece and -nr sets.
echo "Listing files in: ${SUBDIRS[*]}"
: > "$DEST/.files.list"
for d in "${SUBDIRS[@]}"; do
    curl -fsSL "$BASE_URL/$d/" \
        | grep -oE 'href="[^"]+\.rtb[wz]"' \
        | sed -E "s#href=\"([^\"]+)\"#$d/\1#" \
        >> "$DEST/.files.list"
done
total=$(wc -l < "$DEST/.files.list")
echo "Found $total files to fetch into $DEST/"

# 3. Download each file, verifying md5 inline.
i=0
fail=0
while read -r rel; do
    i=$((i + 1))
    fname="${rel##*/}"
    want="${MD5[$fname]:-}"

    if [ -z "$want" ]; then
        echo "[$i/$total] WARNING: no published md5 for $fname; skipping"
        fail=$((fail + 1))
        continue
    fi

    echo "[$i/$total] $rel"
    if ! download_one "$BASE_URL/$rel" "$DEST/$fname" "$want"; then
        echo "    ERROR: gave up on $fname after ${MAX_ATTEMPTS} attempts"
        fail=$((fail + 1))
    fi
done < "$DEST/.files.list"

# 4. Final independent verification pass over everything we downloaded.
echo "============================================="
echo "Running final md5 verification..."
awk -F/ '{print $NF}' "$DEST/.files.list" | sort -u > "$DEST/.wanted.names"
awk 'NR==FNR{w[$1]=1; next} ($2 in w){print}' \
    "$DEST/.wanted.names" "$DEST/.md5.all" > "$DEST/.md5.check"

if (cd "$DEST" && md5sum -c --quiet .md5.check); then
    echo "All $total files verified OK."
else
    echo "ERROR: one or more files failed verification (see above)."
    exit 1
fi

if [ "$fail" -ne 0 ]; then
    echo "Note: $fail file(s) could not be downloaded; re-run to retry them."
    exit 1
fi

echo "Done. Total size:"
du -sh "$DEST"
