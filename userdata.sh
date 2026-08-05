#!/bin/bash
# ---------------------------------------------------------------------------
# EC2 User Data bootstrap -- Amazon Linux 2023.
#
# The CloudFormation Launch Template substitutes the DB_* / REGION values into
# the "workshop environment" block below before handing this to cloud-init.
# Run standalone for testing by exporting those variables first.
#
# Logs land in /var/log/user-data.log and in the console output.
# ---------------------------------------------------------------------------
set -euo pipefail

exec > >(tee -a /var/log/user-data.log | logger -t user-data -s 2>/dev/console) 2>&1
echo "=== workshop bootstrap started $(date -u +%FT%TZ) ==="

APP_DIR=/opt/workshop
APP_USER=workshop
ENV_FILE=/etc/workshop.env

# --- workshop environment (CloudFormation overrides these) -----------------
GIT_REPO_URL="${GIT_REPO_URL:-https://github.com/Nik-1019/aws-multi-region-resilience-workshop.git}"
GIT_BRANCH="${GIT_BRANCH:-main}"
DB_HOST="${DB_HOST:-localhost}"
DB_PORT="${DB_PORT:-3306}"
DB_NAME="${DB_NAME:-workshop}"
DB_USER="${DB_USER:-admin}"
DB_PASSWORD="${DB_PASSWORD:-}"
DB_ENGINE="${DB_ENGINE:-mysql}"
PRIMARY_REGION="${PRIMARY_REGION:-us-east-1}"
APP_PORT="${APP_PORT:-80}"
WORKSHOP_AUTHOR="${WORKSHOP_AUTHOR:-nyx - cajayon.nikko01@gmail.com}"

# --- packages --------------------------------------------------------------
echo "--- installing packages"
dnf install -y --setopt=install_weak_deps=False \
    git python3 python3-pip python3-devel gcc

# --- application user ------------------------------------------------------
if ! id "${APP_USER}" >/dev/null 2>&1; then
    useradd --system --create-home --home-dir /home/${APP_USER} \
            --shell /sbin/nologin "${APP_USER}"
fi

# --- source ----------------------------------------------------------------
echo "--- fetching ${GIT_REPO_URL} (${GIT_BRANCH})"
rm -rf "${APP_DIR}"
if ! git clone --depth 1 --branch "${GIT_BRANCH}" "${GIT_REPO_URL}" "${APP_DIR}"; then
    echo "!!! git clone failed -- the instance will serve nothing. Check GitRepoURL." >&2
    exit 1
fi
chown -R "${APP_USER}:${APP_USER}" "${APP_DIR}"

# --- python dependencies ---------------------------------------------------
echo "--- installing python dependencies"
python3 -m venv "${APP_DIR}/.venv"
"${APP_DIR}/.venv/bin/pip" install --upgrade pip
"${APP_DIR}/.venv/bin/pip" install -r "${APP_DIR}/requirements.txt"
chown -R "${APP_USER}:${APP_USER}" "${APP_DIR}/.venv"

# --- environment file ------------------------------------------------------
# 0640 root:workshop -- the password must not be world readable.
echo "--- writing ${ENV_FILE}"
cat > "${ENV_FILE}" <<EOF
DB_HOST=${DB_HOST}
DB_PORT=${DB_PORT}
DB_NAME=${DB_NAME}
DB_USER=${DB_USER}
DB_PASSWORD=${DB_PASSWORD}
DB_ENGINE=${DB_ENGINE}
PRIMARY_REGION=${PRIMARY_REGION}
APP_PORT=${APP_PORT}
WORKSHOP_AUTHOR=${WORKSHOP_AUTHOR}
EOF
chown root:"${APP_USER}" "${ENV_FILE}"
chmod 640 "${ENV_FILE}"

# --- systemd unit ----------------------------------------------------------
# CAP_NET_BIND_SERVICE lets the unprivileged user bind port 80.
echo "--- installing systemd unit"
cat > /etc/systemd/system/workshop.service <<EOF
[Unit]
Description=AWS Multi-Region Resilience Workshop app
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${APP_USER}
Group=${APP_USER}
WorkingDirectory=${APP_DIR}
EnvironmentFile=${ENV_FILE}
ExecStart=${APP_DIR}/.venv/bin/gunicorn \\
    --bind 0.0.0.0:${APP_PORT} \\
    --workers 1 --threads 8 --timeout 30 \\
    --access-logfile - --error-logfile - \\
    app:app
Restart=always
RestartSec=3
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
NoNewPrivileges=true
PrivateTmp=true

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now workshop.service

# --- verify ----------------------------------------------------------------
echo "--- waiting for the app to answer on :${APP_PORT}"
for attempt in $(seq 1 30); do
    if curl -fsS --max-time 3 "http://127.0.0.1:${APP_PORT}/health" >/dev/null 2>&1; then
        echo "=== bootstrap complete -- app is healthy ==="
        exit 0
    fi
    sleep 2
done

echo "!!! app did not become healthy in 60s; dumping recent logs" >&2
systemctl status workshop.service --no-pager || true
journalctl -u workshop.service -n 50 --no-pager || true
exit 1
