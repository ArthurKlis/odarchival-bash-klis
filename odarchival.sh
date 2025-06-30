#!/bin/bash

########################################
#     C coPilot  Microsoft & Kliś     #
#     2025-06-29                      #
#     version 1                       #
#     Optical Disc Archival Tool      #
########################################

set -euo pipefail
shopt -s nullglob

########################################
#           CONFIGURATION             #
########################################

DEST_BASE="/home/publicentity/Optical discs"
WORKDIR=$(mktemp -d /tmp/optical_archive_XXXXXX)
MOUNTDIR="$WORKDIR/mount"
ISO_TEMP="$WORKDIR/temp.iso"
XML_TEMP="$WORKDIR/metadata.xml"
TRAP_CLEANUP=true

########################################
#              CLEANUP                #
########################################

cleanup() {
  echo "[Cleanup] Cleaning up temporary resources..."
  mountpoint -q "$MOUNTDIR" && sudo umount "$MOUNTDIR" || true
  [[ -d "$WORKDIR" ]] && rm -rf "$WORKDIR"
}
trap cleanup EXIT INT TERM

########################################
#        [Step 0] Dependency Check     #
########################################

echo "[Step 0] Checking dependencies..."
REQUIRED_CMDS=(dd sha256sum cksum blockdev lsblk mount umount expr date mkdir cp awk sed mktemp grep chown logname)
MISSING=()

for cmd in "${REQUIRED_CMDS[@]}"; do
  if ! command -v "$cmd" &>/dev/null; then
    MISSING+=("$cmd")
  fi
done

if [[ ${#MISSING[@]} -gt 0 ]]; then
  echo "Error: Missing required commands: ${MISSING[*]}"
  exit 1
fi
echo "[Step 0] OK - Dependencies present"

########################################
#       [Step 1] Detect Optical Drive  #
########################################

echo "[Step 1] Detecting optical drive..."
DEVICE=$(lsblk -pndo NAME,TYPE | awk '$2 == "rom" {print $1}' | head -n1)

if [[ -z "$DEVICE" || ! -b "$DEVICE" ]]; then
  echo "Error: No optical drive found. Insert a disc or check connection."
  exit 1
fi
echo "[Step 1] OK - Found device: $DEVICE"

########################################
#    [Step 2] Unmount if Mounted       #
########################################

echo "[Step 2] Unmounting $DEVICE if needed..."
MOUNTPOINT=$(lsblk -pno MOUNTPOINT "$DEVICE")
if [[ -n "$MOUNTPOINT" ]]; then
  sudo umount "$MOUNTPOINT" || sudo umount -l "$MOUNTPOINT"
fi
echo "[Step 2] OK - Device unmounted"

########################################
#     [Step 3] Determine Disc Size     #
########################################

echo "[Step 3] Getting block count..."
BLOCKS=$(expr $(sudo blockdev --getsize "$DEVICE") / 4)
if [[ "$BLOCKS" -le 0 ]]; then
  echo "Error: Unable to determine block count for $DEVICE."
  exit 1
fi
echo "[Step 3] OK - $BLOCKS blocks (2048 bytes each)"

########################################
#      [Step 4] Set Up Directories     #
########################################

echo "[Step 4] Preparing paths..."
mkdir -p "$MOUNTDIR"
echo "[Step 4] OK - Working directory ready at $WORKDIR"

########################################
#       [Step 5] Create ISO File       #
########################################

echo "[Step 5] Creating ISO image..."
dd if="$DEVICE" of="$ISO_TEMP" bs=2048 count="$BLOCKS" conv=noerror,sync status=progress
echo "[Step 5] OK - ISO image created"

########################################
#    [Step 6] Compute CRC32 & Store    #
########################################

echo "[Step 6] Calculating CRC32 hash..."
CRC32=$(cksum "$ISO_TEMP" | awk '{print $1}')
DEST_DIR="$DEST_BASE/$CRC32"
FINAL_ISO="$DEST_DIR/$CRC32.iso"

if [[ -e "$DEST_DIR" ]]; then
  echo "Error: Destination $DEST_DIR already exists. Aborting to prevent overwrite."
  exit 1
fi

mkdir -p "$DEST_DIR/cpcommand"
cp -n "$ISO_TEMP" "$FINAL_ISO"
echo "[Step 6] OK - ISO renamed to $FINAL_ISO"

########################################
#     [Step 7] Extract ISO Content     #
########################################

echo "[Step 7] Mounting and copying ISO contents..."
sudo mount -o loop "$FINAL_ISO" "$MOUNTDIR" || echo "Warning: Could not mount ISO."
cp -r "$MOUNTDIR"/* "$DEST_DIR/cpcommand/" 2>/dev/null || echo "Note: No files to copy or ISO may contain non-mountable data."
sudo umount "$MOUNTDIR" || true
echo "[Step 7] OK - Contents copied to cpcommand"

# Fix ownership for copied files
sudo chown -R "$USER_OWNER:$USER_OWNER" "$DEST_DIR/cpcommand"

########################################
#     [Step 8] SHA256 Verification     #
########################################

echo "[Step 8] Verifying SHA256 checksums..."
HASH_FILE=$(sha256sum "$FINAL_ISO" | awk '{print $1}')
HASH_STREAM=$(dd if="$DEVICE" bs=2048 count="$BLOCKS" conv=noerror,sync status=none | sha256sum | awk '{print $1}')

echo "ISO file SHA256:     $HASH_FILE"
echo "Live stream SHA256:  $HASH_STREAM"

if [[ "$HASH_FILE" == "$HASH_STREAM" ]]; then
  echo "[Step 8] OK - SHA256 checksums match"
else
  echo "[Step 8] WARNING - SHA256 checksum mismatch"
fi

########################################
#     [Step 9] Fix File Ownership      #
########################################

echo "[Step 9] Fixing file ownership..."
USER_OWNER=$(logname)
sudo chown -R "$USER_OWNER:$USER_OWNER" "$DEST_DIR"
echo "[Step 9] OK - Ownership reassigned to $USER_OWNER"

########################################
#     [Step 10] Generate XML File      #
########################################

echo "[Step 10] Generating XML metadata..."

# Auto-generated values
TIMESTAMP=$(date --iso-8601=seconds)
VOLUME_LABEL=$(blkid -o value -s LABEL "$DEVICE" 2>/dev/null || echo "Unknown")
USED_MB=$(du -sm "$FINAL_ISO" | cut -f1)

# Prompt for user-supplied metadata
read -p "Who entered this disc into the registry? " ENTERED_BY
read -p "What is the displayed name when mounted? [$VOLUME_LABEL] " DISPLAY_NAME
DISPLAY_NAME=${DISPLAY_NAME:-$VOLUME_LABEL}
read -p "Short description of contents: " DESCRIPTION
read -p "Who transferred the disc? " TRANSFERRED_BY
read -p "Device used: [$DEVICE] " DEVICE_USED
DEVICE_USED=${DEVICE_USED:-$DEVICE}
read -p "Date of transfer (YYYY-MM-DD): " TRANSFER_DATE
read -p "Transfer location: " TRANSFER_LOCATION
read -p "Exemplar number: " EXEMPLAR_NUMBER
read -p "Total number of exemplars: " EXEMPLAR_TOTAL
read -p "Total in series: " SERIES_TOTAL
read -p "Index in series: " SERIES_INDEX
read -p "Disc owner: " OWNERSHIP
read -p "Media type (CD/DVD/Blu-ray/M-DISC): " MEDIA_TYPE
read -p "Nominal capacity (e.g. 4.7GB): " MEDIA_CAPACITY
read -p "Retention period (e.g. 10 years): " RETENTION

cat > "$XML_TEMP" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<opticalDisc
  id="$HASH_STREAM"
  timestamp="$TIMESTAMP"
  burnedTimestamp="">
  <enteredBy>$ENTERED_BY</enteredBy>
  <displayName>$DISPLAY_NAME</displayName>
  <volumeLabel>$VOLUME_LABEL</volumeLabel>
  <mediaType>$MEDIA_TYPE</mediaType>
  <usedSizeMB>$USED_MB</usedSizeMB>
  <description>$DESCRIPTION</description>
  <transferredBy>$TRANSFERRED_BY</transferredBy>
  <deviceUsed>$DEVICE_USED</deviceUsed>
  <transferDate>$TRANSFER_DATE</transferDate>
  <transferLocation>$TRANSFER_LOCATION</transferLocation>
  <exemplarNumber>$EXEMPLAR_NUMBER</exemplarNumber>
  <exemplarTotal>$EXEMPLAR_TOTAL</exemplarTotal>
  <seriesTotal>$SERIES_TOTAL</seriesTotal>
  <seriesIndex>$SERIES_INDEX</seriesIndex>
  <ownership>$OWNERSHIP</ownership>
  <mediaCapacity>$MEDIA_CAPACITY</mediaCapacity>
  <retention>$RETENTION</retention>
</opticalDisc>
EOF

mv "$XML_TEMP" "$DEST_DIR/${CRC32}.xml"
echo "[Step 10] OK - Metadata XML saved to ${CRC32}.xml"

