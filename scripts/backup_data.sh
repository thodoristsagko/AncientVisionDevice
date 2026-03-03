#!/usr/bin/env bash
# Backup the field-data Docker volume to a tar.gz file.
# Usage: ./scripts/backup_data.sh [output-file]
# Default output: field-data-backup-YYYY-MM-DD.tar.gz

set -euo pipefail

OUTPUT="${1:-field-data-backup-$(date +%Y-%m-%d).tar.gz}"
echo "Backing up field-data volume to: $OUTPUT"
docker run --rm \
  -v field-data:/data \
  -v "$(pwd)":/backup \
  alpine \
  tar czf "/backup/$OUTPUT" -C /data .
echo "Done: $OUTPUT"
