#!/usr/bin/env bash
# Dừng toàn bộ mạng Hyperledger Fabric (CA + orderer + peer + couchdb).
# Mặc định: chỉ stop container, GIỮ LẠI volume + ledger + channel artifacts
# (chạy lại run-network.sh --skip-enroll để khởi động lại nhanh).
#
# Usage:
#   ./scripts/stop-network.sh                  # docker compose down (giữ volume)
#   ./scripts/stop-network.sh --with-volumes   # xóa luôn volume ledger
#   ./scripts/stop-network.sh --all            # xóa volume + channel artifacts
#   ./scripts/stop-network.sh --yes            # bỏ prompt xác nhận khi destructive
#
# Note: wrapper mỏng quanh clean-reset.sh — giữ tên ngữ nghĩa "stop" cho dễ nhớ.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

WITH_VOLUMES=false
WITH_ARTIFACTS=false
YES=false

for arg in "$@"; do
  case "$arg" in
    --with-volumes)  WITH_VOLUMES=true ;;
    --with-artifacts) WITH_ARTIFACTS=true ;;
    --all)           WITH_VOLUMES=true; WITH_ARTIFACTS=true ;;
    --yes|-y)        YES=true ;;
    -h|--help)
      sed -n '2,12p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *) echo "Unknown arg: $arg" >&2; exit 2 ;;
  esac
done

C_BLD=$'\033[1m'; C_BLU=$'\033[34m'; C_GRN=$'\033[32m'; C_OFF=$'\033[0m'
[ -t 1 ] || { C_BLD=""; C_BLU=""; C_GRN=""; C_OFF=""; }

phase() { echo; echo "${C_BLD}${C_BLU}>>> $1${C_OFF}"; }

# ---------- Docker wrapper ----------
DOCKER_PREFIX=""
if docker ps >/dev/null 2>&1; then
  DOCKER_PREFIX=""
elif command -v sg >/dev/null 2>&1 && sg docker -c 'docker ps' >/dev/null 2>&1; then
  DOCKER_PREFIX="sg docker -c"
else
  echo "ERROR: không truy cập được docker daemon" >&2
  exit 1
fi

drun() {
  if [ -n "${DOCKER_PREFIX}" ]; then
    sg docker -c "$*"
  else
    eval "$@"
  fi
}

phase "Stop network stack (orderer + peer + couchdb)"
drun "docker compose --env-file ${ROOT_DIR}/config/.env.network -f ${ROOT_DIR}/config/docker-compose-network.yaml down --remove-orphans"

phase "Stop CA stack (ca_org1 / ca_org2 / ca_orderer)"
drun "docker compose -f ${ROOT_DIR}/config/docker-compose-ca.yaml down --remove-orphans"

# Cleanup container "lạc" (chạy --rm bị treo) cùng tên đã biết
phase "Sweep stragglers"
KNOWN_NAMES="ca_org1 ca_org2 ca_orderer \
  orderer1.example.com orderer2.example.com orderer3.example.com \
  peer0.org1.example.com peer1.org1.example.com \
  peer0.org2.example.com peer1.org2.example.com \
  couchdb0.org1 couchdb1.org1 couchdb0.org2 couchdb1.org2"
for name in ${KNOWN_NAMES}; do
  if drun "docker ps -a --format '{{.Names}}'" 2>/dev/null | grep -qx "${name}"; then
    drun "docker rm -f ${name}" >/dev/null 2>&1 || true
    echo "    removed ${name}"
  fi
done

# Optional destructive
if [ "${WITH_VOLUMES}" = true ] || [ "${WITH_ARTIFACTS}" = true ]; then
  if [ "${YES}" != true ]; then
    echo
    echo "${C_BLD}WARNING:${C_OFF} sắp xóa $( [ "${WITH_VOLUMES}" = true ] && printf "volume " ) $( [ "${WITH_ARTIFACTS}" = true ] && printf "artifacts " )"
    read -r -p "Tiếp tục? (yes/N) " ans
    case "${ans}" in yes|YES|y|Y) ;; *) echo "Hủy."; exit 0 ;; esac
  fi

  RESET_ARGS="--yes"
  [ "${WITH_VOLUMES}" = true ]  && RESET_ARGS="${RESET_ARGS} --with-volumes"
  [ "${WITH_ARTIFACTS}" = true ] && RESET_ARGS="${RESET_ARGS} --with-artifacts"

  phase "Delegate destructive cleanup -> clean-reset.sh ${RESET_ARGS}"
  drun "${ROOT_DIR}/scripts/clean-reset.sh ${RESET_ARGS}"
fi

phase "DONE"
echo "  Khởi động lại nhanh: ./scripts/run-network.sh --skip-enroll"
echo "  Kiểm tra trạng thái: ./scripts/health-check.sh"
