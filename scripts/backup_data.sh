#!/usr/bin/env bash
# Backup the ./data bind-mount directory to a tar.gz file.
# Usage: ./scripts/backup_data.sh [output-file]
# Default output: field-data-backup-YYYY-MM-DD.tar.gz
# Run from the repo root (where ./data lives).

set -euo pipefail

OUTPUT="${1:-field-data-backup-$(date +%Y-%m-%d).tar.gz}"

if [ ! -d ./data ] || [ -z "$(ls -A ./data 2>/dev/null)" ]; then
  echo "No data directory found — nothing to back up."
  exit 0
fi

echo "Backing up ./data to: $OUTPUT"
tar czf "$OUTPUT" -C ./data .
echo "Done: $OUTPUT"
