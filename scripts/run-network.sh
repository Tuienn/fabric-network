#!/usr/bin/env bash
# Orchestrator chạy end-to-end mạng Hyperledger Fabric 2-org / 3-orderer.
# Mặc định MODE B (đọc env từ config/.env.network).
#
# Phases:
#   1. Sanity / prereq
#   2. Start CA stack
#   3. Enroll org1 / org2 / orderer (qua container fabric-ca)
#   4. validate-stack (configtx + compose syntax)
#   5. Start orderer + peer + couchdb
#   6. setup_channel (create + join + anchor)
#   7. (optional) smoke probe
#
# Usage:
#   ./scripts/run-network.sh                    # full pipeline
#   ./scripts/run-network.sh --skip-enroll      # bỏ qua nếu đã enroll trước
#   ./scripts/run-network.sh --skip-channel     # chỉ start container, không tạo channel
#   ./scripts/run-network.sh --reset            # clean-reset --all --yes trước khi chạy
#   ./scripts/run-network.sh --no-smoke         # bỏ smoke test
#
# Env:
#   CHANNEL_NAME   (default: mychannel)
#   FABRIC_CA_TAG  (default: 1.5.8)
#   FABRIC_TOOLS_TAG (default: 2.5)

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHANNEL_NAME="${CHANNEL_NAME:-mychannel}"
FABRIC_CA_TAG="${FABRIC_CA_TAG:-1.5.8}"
FABRIC_TOOLS_TAG="${FABRIC_TOOLS_TAG:-2.5}"

SKIP_ENROLL=false
SKIP_CHANNEL=false
DO_RESET=false
DO_SMOKE=true

for arg in "$@"; do
  case "$arg" in
    --skip-enroll)  SKIP_ENROLL=true ;;
    --skip-channel) SKIP_CHANNEL=true ;;
    --reset)        DO_RESET=true ;;
    --no-smoke)     DO_SMOKE=false ;;
    -h|--help)
      sed -n '2,22p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *) echo "Unknown arg: $arg" >&2; exit 2 ;;
  esac
done

C_BLD=$'\033[1m'; C_BLU=$'\033[34m'; C_GRN=$'\033[32m'
C_YLW=$'\033[33m'; C_RED=$'\033[31m'; C_OFF=$'\033[0m'
[ -t 1 ] || { C_BLD=""; C_BLU=""; C_GRN=""; C_YLW=""; C_RED=""; C_OFF=""; }

phase() { echo; echo "${C_BLD}${C_BLU}>>> $1${C_OFF}"; }
log()   { echo "    $*"; }
die()   { echo "${C_RED}ERROR:${C_OFF} $*" >&2; exit 1; }

# ---------- Docker wrapper: auto fallback "sg docker -c" ----------
DOCKER_PREFIX=""
if docker ps >/dev/null 2>&1; then
  DOCKER_PREFIX=""
elif command -v sg >/dev/null 2>&1 && sg docker -c 'docker ps' >/dev/null 2>&1; then
  log "docker requires group switch — using 'sg docker -c'"
  DOCKER_PREFIX="sg docker -c"
else
  die "không truy cập được docker daemon. Thử: sudo usermod -aG docker \$USER && newgrp docker"
fi

drun() {
  if [ -n "${DOCKER_PREFIX}" ]; then
    sg docker -c "$*"
  else
    eval "$@"
  fi
}

# ---------- Phase 1: Sanity ----------
phase "Phase 1/7  Sanity & prerequisites"

# Đảm bảo tất cả script có quyền execute (fix khi clone về máy có core.fileMode=false)
chmod +x "${ROOT_DIR}/scripts/"*.sh 2>/dev/null || true

[ -f "${ROOT_DIR}/config/configtx.yaml" ] || die "thiếu config/configtx.yaml"
[ -f "${ROOT_DIR}/config/docker-compose-ca.yaml" ] || die "thiếu compose CA"
[ -f "${ROOT_DIR}/config/docker-compose-network.yaml" ] || die "thiếu compose network"

if [ ! -f "${ROOT_DIR}/config/.env.network" ]; then
  log "${C_YLW}.env.network chưa có — tạo file mặc định${C_OFF}"
  cat > "${ROOT_DIR}/config/.env.network" <<'ENV'
FABRIC_LOGGING_SPEC=INFO
COUCHDB_USER=admin
COUCHDB_PASSWORD=adminpw
ENV
fi
log "OK config files"

if [ "${DO_RESET}" = true ]; then
  phase "Phase 1.5  Clean reset (--reset)"
  drun "${ROOT_DIR}/scripts/clean-reset.sh --all --yes"
fi

# ---------- Phase 2: CA stack ----------
phase "Phase 2/7  Start CA stack"
drun "docker compose -f ${ROOT_DIR}/config/docker-compose-ca.yaml up -d"
log "Đợi CA ready (8s)..."
sleep 8
drun "docker compose -f ${ROOT_DIR}/config/docker-compose-ca.yaml ps"

# ---------- Phase 3: Enroll ----------
if [ "${SKIP_ENROLL}" = true ]; then
  phase "Phase 3/7  Enroll (SKIPPED --skip-enroll)"
else
  phase "Phase 3/7  Enroll org1 / org2 / orderer"
  ENROLL_BASE="docker run --rm --network host \
    -v '${ROOT_DIR}':/workspace:z -w /workspace \
    hyperledger/fabric-ca:${FABRIC_CA_TAG} bash -lc"

  log "→ org1"
  drun "${ENROLL_BASE} \"./scripts/enroll-org.sh org1 org1.example.com 7054 ca-org1\""
  log "→ org2"
  drun "${ENROLL_BASE} \"./scripts/enroll-org.sh org2 org2.example.com 8054 ca-org2\""
  log "→ orderer"
  drun "${ENROLL_BASE} \"./scripts/enroll-org.sh orderer example.com 9054 ca-orderer\""
fi

# ---------- Phase 4: Validate ----------
phase "Phase 4/7  Validate stack"
drun "${ROOT_DIR}/scripts/validate-stack.sh"

# ---------- Phase 5: Network ----------
phase "Phase 5/7  Start orderer + peer + couchdb"
drun "docker compose --env-file ${ROOT_DIR}/config/.env.network -f ${ROOT_DIR}/config/docker-compose-network.yaml up -d"

log "Đợi peer/orderer healthy (tối đa 90s)..."
DEADLINE=$(( $(date +%s) + 90 ))
while true; do
  STATUS="$(drun "docker compose --env-file ${ROOT_DIR}/config/.env.network -f ${ROOT_DIR}/config/docker-compose-network.yaml ps --format '{{.Name}}|{{.Status}}'" 2>/dev/null || true)"
  TOTAL=$(echo "${STATUS}" | grep -cE 'orderer|peer' || true)
  HEALTHY=$(echo "${STATUS}" | grep -E 'orderer|peer' | grep -c '(healthy)' || true)
  if [ "${TOTAL}" -ge 7 ] && [ "${HEALTHY}" -ge 7 ]; then
    log "${C_GRN}${HEALTHY}/${TOTAL} orderer+peer healthy${C_OFF}"
    break
  fi
  if [ "$(date +%s)" -ge "${DEADLINE}" ]; then
    log "${C_YLW}timeout — tiếp tục với ${HEALTHY}/${TOTAL} healthy${C_OFF}"
    break
  fi
  sleep 5
done

# ---------- Phase 6: Channel ----------
if [ "${SKIP_CHANNEL}" = true ]; then
  phase "Phase 6/7  Channel setup (SKIPPED --skip-channel)"
else
  phase "Phase 6/7  Channel setup (${CHANNEL_NAME})"
  drun "docker run --rm --network host \
    -v '${ROOT_DIR}':/workspace:z -w /workspace \
    hyperledger/fabric-tools:${FABRIC_TOOLS_TAG} bash -lc \
    \"export FABRIC_CFG_PATH=/workspace/config; ./scripts/setup_channel.sh\""
fi

# ---------- Phase 7: Smoke ----------
if [ "${DO_SMOKE}" = true ] && [ "${SKIP_CHANNEL}" = false ]; then
  phase "Phase 7/7  Smoke probe"
  drun "docker run --rm --network host \
    -v '${ROOT_DIR}':/workspace:z -w /workspace \
    hyperledger/fabric-tools:${FABRIC_TOOLS_TAG} bash -lc \
    \"osnadmin channel list \
       -o localhost:9443 \
       --ca-file /workspace/organizations/ordererOrganizations/example.com/orderers/orderer1.example.com/tls/ca.crt \
       --client-cert /workspace/organizations/ordererOrganizations/example.com/users/Admin@example.com/tls/client.crt \
       --client-key /workspace/organizations/ordererOrganizations/example.com/users/Admin@example.com/tls/client.key\""
else
  phase "Phase 7/7  Smoke probe (SKIPPED)"
fi

phase "DONE"
echo "  Channel:     ${CHANNEL_NAME}"
echo "  Healthcheck: ./scripts/health-check.sh"
echo "  Tear down:   ./scripts/clean-reset.sh --all --yes"
