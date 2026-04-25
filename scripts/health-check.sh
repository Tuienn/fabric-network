#!/usr/bin/env bash
# Health check toàn diện cho mạng Hyperledger Fabric 2-org / 3-orderer.
# Kiểm tra: prerequisites, file/cấu hình, container, port, channel, peer join,
# CouchDB. In bảng kết quả và exit non-zero nếu có check fail.
#
# Usage:
#   ./scripts/health-check.sh                # full check
#   ./scripts/health-check.sh --quick        # bỏ qua channel/peer probe
#   ./scripts/health-check.sh --no-color
#
# Env:
#   CHANNEL_NAME (default: mychannel)
#   DOCKER_CMD   (default: docker; auto fallback "sg docker -c")

set -uo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHANNEL_NAME="${CHANNEL_NAME:-mychannel}"

QUICK=false
USE_COLOR=true
for arg in "$@"; do
  case "$arg" in
    --quick) QUICK=true ;;
    --no-color) USE_COLOR=false ;;
    -h|--help)
      sed -n '2,12p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *) echo "Unknown arg: $arg" >&2; exit 2 ;;
  esac
done

if [ "${USE_COLOR}" = true ] && [ -t 1 ]; then
  C_RED=$'\033[31m'; C_GRN=$'\033[32m'; C_YLW=$'\033[33m'
  C_BLU=$'\033[34m'; C_BLD=$'\033[1m'; C_OFF=$'\033[0m'
else
  C_RED=""; C_GRN=""; C_YLW=""; C_BLU=""; C_BLD=""; C_OFF=""
fi

PASS=0; FAIL=0; WARN=0
FAILED_ITEMS=()

ok()    { echo "  ${C_GRN}[OK]${C_OFF}    $1"; PASS=$((PASS+1)); }
fail()  { echo "  ${C_RED}[FAIL]${C_OFF}  $1"; FAIL=$((FAIL+1)); FAILED_ITEMS+=("$1"); }
warn()  { echo "  ${C_YLW}[WARN]${C_OFF}  $1"; WARN=$((WARN+1)); }
section() { echo; echo "${C_BLD}${C_BLU}== $1 ==${C_OFF}"; }

# ---------- Docker wrapper (auto sg docker fallback) ----------
DOCKER_CMD="${DOCKER_CMD:-}"
if [ -z "${DOCKER_CMD}" ]; then
  if docker ps >/dev/null 2>&1; then
    DOCKER_CMD="docker"
  elif command -v sg >/dev/null 2>&1 && sg docker -c 'docker ps' >/dev/null 2>&1; then
    DOCKER_CMD="sg docker -c"
  else
    DOCKER_CMD="docker"
  fi
fi

dexec() {
  if [ "${DOCKER_CMD}" = "sg docker -c" ]; then
    sg docker -c "$*"
  else
    eval "${DOCKER_CMD} $*"
  fi
}

# ---------- 1. Prerequisites ----------
section "Prerequisites"
for bin in docker bash jq curl; do
  if command -v "$bin" >/dev/null 2>&1; then
    ok "binary '$bin' available"
  else
    if [ "$bin" = "jq" ] || [ "$bin" = "curl" ]; then
      warn "binary '$bin' missing (optional, một số probe sẽ skip)"
    else
      fail "binary '$bin' missing"
    fi
  fi
done

if dexec 'docker version --format "{{.Server.Version}}"' >/dev/null 2>&1; then
  DOCKER_VER="$(dexec 'docker version --format "{{.Server.Version}}"' 2>/dev/null | tr -d '\r')"
  ok "docker daemon reachable (server v${DOCKER_VER})"
else
  fail "docker daemon not reachable (thử: sudo usermod -aG docker \$USER; newgrp docker)"
fi

if dexec 'docker compose version' >/dev/null 2>&1; then
  ok "docker compose plugin available"
else
  fail "docker compose plugin missing"
fi

# ---------- 2. Project files ----------
section "Project files & config"
REQUIRED_FILES=(
  "config/configtx.yaml"
  "config/core.yaml"
  "config/docker-compose-ca.yaml"
  "config/docker-compose-network.yaml"
  "config/.env.network"
  "scripts/enroll-org.sh"
  "scripts/setup_channel.sh"
  "scripts/clean-reset.sh"
  "scripts/update-anchor-peers.sh"
  "scripts/validate-stack.sh"
)
for f in "${REQUIRED_FILES[@]}"; do
  if [ -f "${ROOT_DIR}/${f}" ]; then
    ok "${f}"
  else
    fail "missing ${f}"
  fi
done

REQUIRED_DIRS=(
  "organizations/peerOrganizations/org1.example.com"
  "organizations/peerOrganizations/org2.example.com"
  "organizations/ordererOrganizations/example.com"
  "channel-artifacts"
)
for d in "${REQUIRED_DIRS[@]}"; do
  if [ -d "${ROOT_DIR}/${d}" ]; then
    ok "${d}/"
  else
    fail "missing dir ${d}/ (chưa enroll? chạy run-network.sh)"
  fi
done

# Compose syntax check
if dexec "docker compose -f ${ROOT_DIR}/config/docker-compose-ca.yaml config" >/dev/null 2>&1; then
  ok "docker-compose-ca.yaml syntax"
else
  fail "docker-compose-ca.yaml syntax invalid"
fi

if dexec "docker compose --env-file ${ROOT_DIR}/config/.env.network -f ${ROOT_DIR}/config/docker-compose-network.yaml config" >/dev/null 2>&1; then
  ok "docker-compose-network.yaml syntax"
else
  fail "docker-compose-network.yaml syntax invalid"
fi

# Channel artifacts (chỉ warn nếu thiếu — chưa setup channel cũng OK)
if [ -f "${ROOT_DIR}/channel-artifacts/${CHANNEL_NAME}.block" ]; then
  ok "channel block ${CHANNEL_NAME}.block"
else
  warn "channel block ${CHANNEL_NAME}.block chưa tạo"
fi

# ---------- 3. Containers ----------
section "Containers"
EXPECTED_CONTAINERS=(
  ca_org1 ca_org2 ca_orderer
  orderer1.example.com orderer2.example.com orderer3.example.com
  peer0.org1.example.com peer1.org1.example.com
  peer0.org2.example.com peer1.org2.example.com
  couchdb0.org1 couchdb1.org1 couchdb0.org2 couchdb1.org2
)

RUNNING_LIST="$(dexec 'docker ps --format "{{.Names}}|{{.Status}}"' 2>/dev/null || true)"
for c in "${EXPECTED_CONTAINERS[@]}"; do
  line="$(echo "${RUNNING_LIST}" | grep -E "^${c}\|" || true)"
  if [ -z "${line}" ]; then
    fail "container ${c} không chạy"
    continue
  fi
  status="${line#*|}"
  case "${c}" in
    ca_*)
      ok "${c} — ${status}"
      ;;
    *)
      if echo "${status}" | grep -q "(healthy)"; then
        ok "${c} — ${status}"
      elif echo "${status}" | grep -q "(unhealthy)"; then
        fail "${c} — ${status}"
      elif echo "${status}" | grep -qE "(starting|health: starting)"; then
        warn "${c} — ${status}"
      else
        ok "${c} — ${status}"
      fi
      ;;
  esac
done

# ---------- 4. Ports ----------
section "Ports listening trên host"
EXPECTED_PORTS=(
  "7050:orderer1" "8050:orderer2" "9050:orderer3"
  "9443:orderer1-admin" "10443:orderer2-admin" "11443:orderer3-admin"
  "7051:peer0.org1" "8051:peer1.org1"
  "9051:peer0.org2" "10051:peer1.org2"
  "7054:ca_org1" "8054:ca_org2" "9054:ca_orderer"
  "5984:couchdb0.org1" "6984:couchdb1.org1"
  "7984:couchdb0.org2" "8984:couchdb1.org2"
)
PORT_TOOL=""
if command -v ss >/dev/null 2>&1; then PORT_TOOL="ss"
elif command -v netstat >/dev/null 2>&1; then PORT_TOOL="netstat"
fi

if [ -z "${PORT_TOOL}" ]; then
  warn "không tìm thấy ss/netstat — bỏ qua port check"
else
  for entry in "${EXPECTED_PORTS[@]}"; do
    port="${entry%%:*}"; label="${entry#*:}"
    if [ "${PORT_TOOL}" = "ss" ]; then
      hit="$(ss -tln 2>/dev/null | awk '{print $4}' | grep -E ":${port}$" || true)"
    else
      hit="$(netstat -tln 2>/dev/null | awk '{print $4}' | grep -E ":${port}$" || true)"
    fi
    if [ -n "${hit}" ]; then
      ok "port ${port} (${label}) listening"
    else
      fail "port ${port} (${label}) NOT listening"
    fi
  done
fi

# ---------- 5. CouchDB reachability ----------
section "CouchDB endpoints"
COUCH_USER="$(grep -E '^COUCHDB_USER=' "${ROOT_DIR}/config/.env.network" 2>/dev/null | cut -d= -f2 || echo admin)"
COUCH_PASS="$(grep -E '^COUCHDB_PASSWORD=' "${ROOT_DIR}/config/.env.network" 2>/dev/null | cut -d= -f2 || echo adminpw)"
if command -v curl >/dev/null 2>&1; then
  for cport in 5984 6984 7984 8984; do
    if curl -fsS -u "${COUCH_USER}:${COUCH_PASS}" "http://localhost:${cport}/" >/dev/null 2>&1; then
      ok "couchdb localhost:${cport} reachable"
    else
      fail "couchdb localhost:${cport} unreachable"
    fi
  done
else
  warn "curl thiếu — bỏ qua CouchDB check"
fi

# ---------- 6. Channel & peer probes (skip với --quick) ----------
if [ "${QUICK}" = true ]; then
  section "Channel / peer probes"
  warn "skipped (--quick)"
else
  section "Channel trên orderer"
  # Probe luôn qua docker (root) để né permission denied khi MSP/TLS thuộc owner root.
  OSN_OUT="$(dexec "docker run --rm --network host \
    -v '${ROOT_DIR}':/workspace -w /workspace \
    hyperledger/fabric-tools:2.5 bash -lc \
    \"osnadmin channel list -o localhost:9443 \
       --ca-file /workspace/organizations/ordererOrganizations/example.com/orderers/orderer1.example.com/tls/ca.crt \
       --client-cert /workspace/organizations/ordererOrganizations/example.com/users/Admin@example.com/tls/client.crt \
       --client-key /workspace/organizations/ordererOrganizations/example.com/users/Admin@example.com/tls/client.key\"" 2>&1 || true)"
  if echo "${OSN_OUT}" | grep -q "\"name\": \"${CHANNEL_NAME}\""; then
    ok "orderer1 admin: channel '${CHANNEL_NAME}' present"
  elif echo "${OSN_OUT}" | grep -qiE "no such file|cannot read"; then
    warn "osnadmin: thiếu Admin@example.com TLS material — skip"
  else
    fail "channel '${CHANNEL_NAME}' chưa có trên orderer1 admin"
  fi

  section "Peer joined channel"
  PEER_PROBE_SCRIPT='set -e
export FABRIC_CFG_PATH=/workspace/config
declare -A ADDR=( [org1p0]=localhost:7051 [org1p1]=localhost:8051 [org2p0]=localhost:9051 [org2p1]=localhost:10051 )
declare -A MSP=( [org1p0]=Org1MSP [org1p1]=Org1MSP [org2p0]=Org2MSP [org2p1]=Org2MSP )
declare -A USERMSP=( \
  [org1p0]=/workspace/organizations/peerOrganizations/org1.example.com/users/Admin@org1.example.com/msp \
  [org1p1]=/workspace/organizations/peerOrganizations/org1.example.com/users/Admin@org1.example.com/msp \
  [org2p0]=/workspace/organizations/peerOrganizations/org2.example.com/users/Admin@org2.example.com/msp \
  [org2p1]=/workspace/organizations/peerOrganizations/org2.example.com/users/Admin@org2.example.com/msp )
declare -A TLS=( \
  [org1p0]=/workspace/organizations/peerOrganizations/org1.example.com/peers/peer0.org1.example.com/tls/ca.crt \
  [org1p1]=/workspace/organizations/peerOrganizations/org1.example.com/peers/peer1.org1.example.com/tls/ca.crt \
  [org2p0]=/workspace/organizations/peerOrganizations/org2.example.com/peers/peer0.org2.example.com/tls/ca.crt \
  [org2p1]=/workspace/organizations/peerOrganizations/org2.example.com/peers/peer1.org2.example.com/tls/ca.crt )
for k in org1p0 org1p1 org2p0 org2p1; do
  export CORE_PEER_TLS_ENABLED=true
  export CORE_PEER_LOCALMSPID="${MSP[$k]}"
  export CORE_PEER_MSPCONFIGPATH="${USERMSP[$k]}"
  export CORE_PEER_ADDRESS="${ADDR[$k]}"
  export CORE_PEER_TLS_ROOTCERT_FILE="${TLS[$k]}"
  if peer channel list 2>/dev/null | grep -q "^CHANNEL_NAME_PLACEHOLDER$"; then
    echo "JOINED:$k"
  else
    echo "MISSING:$k"
  fi
done'
  PEER_PROBE_SCRIPT="${PEER_PROBE_SCRIPT//CHANNEL_NAME_PLACEHOLDER/${CHANNEL_NAME}}"

  PROBE_OUT="$(dexec "docker run --rm --network host \
    -v '${ROOT_DIR}':/workspace -w /workspace \
    hyperledger/fabric-tools:2.5 bash -lc '${PEER_PROBE_SCRIPT}'" 2>&1 || true)"

  for k in org1p0 org1p1 org2p0 org2p1; do
    if echo "${PROBE_OUT}" | grep -q "^JOINED:${k}$"; then
      ok "peer ${k} joined ${CHANNEL_NAME}"
    elif echo "${PROBE_OUT}" | grep -q "^MISSING:${k}$"; then
      fail "peer ${k} chưa join ${CHANNEL_NAME}"
    else
      warn "peer ${k} probe inconclusive"
    fi
  done
fi

# ---------- Summary ----------
section "Summary"
echo "  ${C_GRN}PASS${C_OFF}: ${PASS}    ${C_YLW}WARN${C_OFF}: ${WARN}    ${C_RED}FAIL${C_OFF}: ${FAIL}"
if [ "${FAIL}" -gt 0 ]; then
  echo
  echo "${C_RED}${C_BLD}Failed checks:${C_OFF}"
  for item in "${FAILED_ITEMS[@]}"; do
    echo "  - ${item}"
  done
  exit 1
fi
echo "${C_GRN}${C_BLD}All critical checks passed.${C_OFF}"
exit 0
