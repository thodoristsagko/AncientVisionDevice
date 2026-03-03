#!/usr/bin/env bash
# Backup the ./data bind-mount directory to a tar.gz file.
# Usage: ./scripts/backup_data.sh [output-file]
# Default output: field-data-backup-YYYY-MM-DD.tar.gz
# Run from the repo root (where ./data lives).

set -euo pipefail

OUTPUT="${1:-field-data-backup-$(date +%Y-%m-%d).tar.gz}"
echo "Backing up ./data to: $OUTPUT"
tar czf "$OUTPUT" -C ./data .
echo "Done: $OUTPUT"
