#!/usr/bin/env sh
# docker/healthcheck.sh
# Checks that all AncientVision Docker services are healthy.
#
# Usage:
#   ./docker/healthcheck.sh
#
# Exits 0 if every check passes, 1 if any check fails.
# Designed to run from the repository root on the Docker host.

set -eu

COLLECTOR_URL="http://localhost:8765/health"
WATCHER_URL="http://localhost:8766/health"

PASS=0
FAIL=1
overall=0   # accumulates: stays 0 only if all checks pass

# ── helpers ──────────────────────────────────────────────────────────────────

ok()   { printf '[OK]   %s\n' "$1"; }
fail() { printf '[FAIL] %s\n' "$1"; overall=1; }

http_check() {
    label="$1"
    url="$2"
    # curl: -s silent, -f fail on HTTP errors, --max-time 5s
    if curl -sf --max-time 5 "$url" > /dev/null 2>&1; then
        ok "$label ($url)"
    else
        fail "$label ($url) — not reachable or returned non-2xx"
    fi
}

# ── 1. Data collector /health ─────────────────────────────────────────────────
http_check "Collector /health" "$COLLECTOR_URL"

# ── 2. File-watcher /health ───────────────────────────────────────────────────
http_check "Watcher /health  " "$WATCHER_URL"

# ── 3. Docker containers running ─────────────────────────────────────────────
# We check for the known service names used across the compose files.
# docker ps --filter "name=..." returns only running containers.
for svc in data-collector file-watcher trainer; do
    count=$(docker ps --filter "name=${svc}" --filter "status=running" --quiet 2>/dev/null | wc -l | tr -d ' ')
    if [ "$count" -gt 0 ]; then
        ok "Docker container running: ${svc}"
    else
        # Trainer is not always running (restart: "no"), so downgrade to info.
        if [ "$svc" = "trainer" ]; then
            printf '[INFO] Docker container not running: %s (expected — one-shot service)\n' "$svc"
        else
            fail "Docker container not running: ${svc}"
        fi
    fi
done

# ── summary ───────────────────────────────────────────────────────────────────
printf '\n'
if [ "$overall" -eq 0 ]; then
    printf '[OK]   All checks passed.\n'
else
    printf '[FAIL] One or more checks failed.\n'
fi

exit "$overall"
