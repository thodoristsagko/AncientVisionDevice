#!/usr/bin/env bash
# Pre-commit checks script for CI/CD pipelines.
# This script runs code quality checks without requiring the pre-commit framework.
#
# Usage:
#   bash scripts/run_precommit.sh
#   # or in CI:
#   docker compose -f docker-compose.dev.yml run --rm ml-dev bash scripts/run_precommit.sh

set -e

echo "==> Checking for trailing whitespace in Python files..."
if grep -rn " $" scripts/*.py docker/collect/*.py docker/watcher/*.py 2>/dev/null; then
    echo "WARNING: trailing whitespace found in Python files"
else
    echo "OK: No trailing whitespace"
fi

echo ""
echo "==> Running flake8 linter..."
python -m flake8 scripts/ docker/collect/ docker/watcher/ \
    --max-line-length=120 \
    --ignore=E501,W503,E302,E303 \
    || (echo "WARNING: flake8 found style issues (non-blocking)" && true)

echo ""
echo "==> Checking for merge conflict markers..."
if grep -r "^<<<<<<< \|^=======$\|^>>>>>>> " scripts/ docker/ 2>/dev/null; then
    echo "ERROR: merge conflict markers found"
    exit 1
else
    echo "OK: No merge conflict markers"
fi

echo ""
echo "==> Checking for large files..."
find scripts/ docker/ -type f -size +500k && \
    echo "WARNING: large files found (consider adding to .gitignore)" || \
    echo "OK: No large files"

echo ""
echo "Pre-commit checks complete."
