#!/usr/bin/env bash
# AncientVision Field Deployment Installer
#
# Installation script for deploying AncientVision as systemd services on field laptops.
# Supports Ubuntu/Debian. Requires sudo.
#
# Usage:
#   sudo bash deploy/install.sh /opt/ancientvision
#   sudo bash deploy/install.sh /opt/ancientvision --skip-docker
#   sudo bash deploy/install.sh /opt/ancientvision --enable-api-key mySecretKey123
#
# Environment:
#   INSTALL_DIR     Default: /opt/ancientvision
#   ENABLE_API_KEY  If set, configure API key authentication
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
INSTALL_DIR="${1:-/opt/ancientvision}"

# Flags
SKIP_DOCKER=false
ENABLE_API_KEY=""
ENABLE_MONITORING=false

# Parse arguments
for arg in "${@:2}"; do
  case "$arg" in
    --skip-docker)
      SKIP_DOCKER=true
      ;;
    --enable-monitoring)
      ENABLE_MONITORING=true
      ;;
    --enable-api-key)
      ENABLE_API_KEY="${arg#*=}"
      ;;
  esac
done

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log_info() {
  echo -e "${GREEN}[INFO]${NC} $*"
}

log_warn() {
  echo -e "${YELLOW}[WARN]${NC} $*"
}

log_error() {
  echo -e "${RED}[ERROR]${NC} $*"
}

# Check if running as root
if [[ $EUID -ne 0 ]]; then
  log_error "This script must be run as root (use sudo)"
  exit 1
fi

# Check OS
if ! command -v systemctl &> /dev/null; then
  log_error "systemd not found. This script requires systemd."
  exit 1
fi

log_info "AncientVision Field Deployment Installer"
log_info "Installing to: $INSTALL_DIR"
log_info "Repository: $REPO_ROOT"
echo ""

# === Step 1: Check dependencies ===
log_info "Step 1: Checking dependencies..."

MISSING_DEPS=()
for cmd in docker git curl; do
  if ! command -v "$cmd" &> /dev/null; then
    MISSING_DEPS+=("$cmd")
  fi
done

if [[ ${#MISSING_DEPS[@]} -gt 0 ]]; then
  if [[ "$SKIP_DOCKER" == true ]]; then
    log_warn "Missing: ${MISSING_DEPS[*]} (--skip-docker enabled, skipping installation)"
  else
    log_error "Missing required packages: ${MISSING_DEPS[*]}"
    log_info "Install with: sudo apt-get install -y ${MISSING_DEPS[*]}"
    exit 1
  fi
else
  log_info "All dependencies present"
fi

echo ""

# === Step 2: Create ancientvision user ===
log_info "Step 2: Creating ancientvision user..."

if id "ancientvision" &>/dev/null; then
  log_warn "User 'ancientvision' already exists (skipping)"
else
  useradd -m -s /bin/bash -G docker ancientvision || {
    log_error "Failed to create user 'ancientvision'"
    exit 1
  }
  log_info "Created user: ancientvision (added to docker group)"
fi

echo ""

# === Step 3: Deploy repository ===
log_info "Step 3: Deploying repository..."

mkdir -p "$INSTALL_DIR"

if [[ -d "$INSTALL_DIR/.git" ]]; then
  log_warn "$INSTALL_DIR is already a git repo (skipping clone)"
else
  if [[ "$SKIP_DOCKER" == false ]]; then
    log_info "Cloning from $REPO_ROOT..."
    cp -r "$REPO_ROOT" "$INSTALL_DIR" || {
      log_error "Failed to copy repository"
      exit 1
    }
  else
    log_warn "Skipping repository deployment (--skip-docker)"
  fi
fi

chown -R ancientvision:ancientvision "$INSTALL_DIR"
chmod 750 "$INSTALL_DIR"
log_info "Repository deployed to: $INSTALL_DIR"

echo ""

# === Step 4: Create data directory ===
log_info "Step 4: Setting up data directory..."

DATA_DIR="$INSTALL_DIR/data"
mkdir -p "$DATA_DIR"/{field,models,logs}
chown -R ancientvision:ancientvision "$DATA_DIR"
chmod 755 "$DATA_DIR"
log_info "Data directory: $DATA_DIR"

echo ""

# === Step 5: Configure environment ===
log_info "Step 5: Configuring environment..."

ENV_FILE="$INSTALL_DIR/.env"
if [[ ! -f "$ENV_FILE" ]]; then
  cat > "$ENV_FILE" << 'EOF'
# AncientVision Environment Configuration

# Data directory (mounted in compose)
DATA_DIR=/opt/ancientvision/data

# Flask configuration
FLASK_ENV=production
PORT=8765

# Firestore (optional, leave empty to disable)
GOOGLE_APPLICATION_CREDENTIALS=

# Firestore collection name
FIRESTORE_COLLECTION=vibration_samples

# API authentication (optional, leave empty to disable)
API_KEY=

# Logging
LOG_LEVEL=INFO

# Rate limiting (requests per second per device)
RATE_LIMIT_RPS=10
EOF
  log_info "Created default .env file: $ENV_FILE"
  log_warn "Edit $ENV_FILE to customize settings (API keys, Firestore, etc.)"
else
  log_info ".env file already exists: $ENV_FILE"
fi

# Set API key if provided
if [[ -n "$ENABLE_API_KEY" ]]; then
  sed -i "s/^API_KEY=.*/API_KEY=$ENABLE_API_KEY/" "$ENV_FILE"
  log_info "API key configured in .env"
fi

chown ancientvision:ancientvision "$ENV_FILE"
chmod 600 "$ENV_FILE"

echo ""

# === Step 6: Install systemd services ===
log_info "Step 6: Installing systemd services..."

SYSTEMD_DIR="/etc/systemd/system"
SERVICES=(
  "ancientvision-collector.service"
  "ancientvision-trainer.service"
)

if [[ "$ENABLE_MONITORING" == true ]]; then
  SERVICES+=("ancientvision-monitor.service")
fi

for service in "${SERVICES[@]}"; do
  src="$INSTALL_DIR/deploy/systemd/$service"
  dst="$SYSTEMD_DIR/$service"

  if [[ ! -f "$src" ]]; then
    log_error "Service file not found: $src"
    exit 1
  fi

  cp "$src" "$dst"
  log_info "Installed: $service"
done

# Reload systemd daemon
systemctl daemon-reload
log_info "Systemd daemon reloaded"

echo ""

# === Step 7: Enable and start services ===
log_info "Step 7: Enabling services..."

# Start collector (primary service)
systemctl enable ancientvision-collector.service
log_info "Enabled: ancientvision-collector.service"

# Trainer: enable but don't start (runs on-demand or via timer)
systemctl enable ancientvision-trainer.service
log_info "Enabled: ancientvision-trainer.service"

if [[ "$ENABLE_MONITORING" == true ]]; then
  systemctl enable ancientvision-monitor.service
  log_info "Enabled: ancientvision-monitor.service"
fi

echo ""

log_info "Installation complete!"
echo ""
echo "=== Next Steps ==="
echo ""
echo "1. Review configuration:"
echo "   cat $ENV_FILE"
echo ""
echo "2. (Optional) Set up Firestore credentials:"
echo "   export GOOGLE_APPLICATION_CREDENTIALS=/path/to/service-account.json"
echo "   systemctl set-environment GOOGLE_APPLICATION_CREDENTIALS=..."
echo ""
echo "3. Start the collector service:"
echo "   sudo systemctl start ancientvision-collector.service"
echo ""
echo "4. Check service status:"
echo "   sudo systemctl status ancientvision-collector.service"
echo ""
echo "5. View logs:"
echo "   sudo journalctl -u ancientvision-collector.service -f"
echo ""
echo "6. Run training (after collecting samples):"
echo "   sudo systemctl start ancientvision-trainer.service"
echo ""
echo "7. Check API health:"
echo "   curl http://localhost:8765/health"
echo ""
