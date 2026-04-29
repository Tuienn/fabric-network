#!/usr/bin/env bash
# Deploy chaincode `vote-ledger` (Node.js) lên channel `mychannel`.
# Endorsement policy: OR('Org1MSP.peer','Org2MSP.peer') — chỉ cần 1 trong 2 org endorse.
#
# Yêu cầu trước khi chạy:
#   - Network đã start (./scripts/run-network.sh)
#   - Channel mychannel đã được tạo và join bởi cả 4 peers
#   - peer binary trong PATH (./scripts/install-binaries.sh hoặc Fabric tools image)
#
# Usage:
#   ./scripts/deploy-vote-ledger.sh                # deploy mới (sequence=1)
#   CC_VERSION=1.1 CC_SEQUENCE=2 ./scripts/deploy-vote-ledger.sh    # upgrade
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [ -z "${FABRIC_CFG_PATH:-}" ]; then
  export FABRIC_CFG_PATH="${ROOT_DIR}/config"
fi

CHANNEL_NAME="${CHANNEL_NAME:-mychannel}"
CC_NAME="${CC_NAME:-vote-ledger}"
CC_VERSION="${CC_VERSION:-1.0}"
CC_SEQUENCE="${CC_SEQUENCE:-1}"
CC_LABEL="${CC_NAME}_${CC_VERSION}"
CC_SRC_PATH="${CC_SRC_PATH:-${ROOT_DIR}/schnorr-threshold-blind-demo/chaincode/vote-ledger}"
CC_PACKAGE_FILE="${ROOT_DIR}/channel-artifacts/${CC_LABEL}.tar.gz"
SIGNATURE_POLICY="${SIGNATURE_POLICY:-OR('Org1MSP.peer','Org2MSP.peer')}"

ORDERER_ENDPOINT="${ORDERER_ENDPOINT:-localhost:7050}"
ORDERER_HOSTNAME_OVERRIDE="${ORDERER_HOSTNAME_OVERRIDE:-orderer1.example.com}"
ORDERER_CA="${ORDERER_CA:-${ROOT_DIR}/organizations/ordererOrganizations/example.com/orderers/orderer1.example.com/tls/ca.crt}"

require_binary() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Error: required command '$1' is not installed or not in PATH" >&2
    exit 1
  fi
}

require_dir() {
  if [ ! -d "$1" ]; then
    echo "Error: required directory '$1' does not exist" >&2
    exit 1
  fi
}

set_peer_globals() {
  local org="$1"
  local peer_index="$2"

  if [ "$org" = "1" ]; then
    export CORE_PEER_LOCALMSPID="Org1MSP"
    export CORE_PEER_MSPCONFIGPATH="${ROOT_DIR}/organizations/peerOrganizations/org1.example.com/users/Admin@org1.example.com/msp"
    if [ "$peer_index" = "0" ]; then
      export CORE_PEER_ADDRESS="localhost:7051"
      export CORE_PEER_TLS_ROOTCERT_FILE="${ROOT_DIR}/organizations/peerOrganizations/org1.example.com/peers/peer0.org1.example.com/tls/ca.crt"
    else
      export CORE_PEER_ADDRESS="localhost:8051"
      export CORE_PEER_TLS_ROOTCERT_FILE="${ROOT_DIR}/organizations/peerOrganizations/org1.example.com/peers/peer1.org1.example.com/tls/ca.crt"
    fi
  elif [ "$org" = "2" ]; then
    export CORE_PEER_LOCALMSPID="Org2MSP"
    export CORE_PEER_MSPCONFIGPATH="${ROOT_DIR}/organizations/peerOrganizations/org2.example.com/users/Admin@org2.example.com/msp"
    if [ "$peer_index" = "0" ]; then
      export CORE_PEER_ADDRESS="localhost:9051"
      export CORE_PEER_TLS_ROOTCERT_FILE="${ROOT_DIR}/organizations/peerOrganizations/org2.example.com/peers/peer0.org2.example.com/tls/ca.crt"
    else
      export CORE_PEER_ADDRESS="localhost:10051"
      export CORE_PEER_TLS_ROOTCERT_FILE="${ROOT_DIR}/organizations/peerOrganizations/org2.example.com/peers/peer1.org2.example.com/tls/ca.crt"
    fi
  else
    echo "Error: unsupported org '$org'" >&2
    exit 1
  fi
  export CORE_PEER_TLS_ENABLED=true
}

verify_prerequisites() {
  require_binary peer
  require_dir "${CC_SRC_PATH}"
  if [ ! -f "${CC_SRC_PATH}/package.json" ]; then
    echo "Error: ${CC_SRC_PATH}/package.json không tồn tại" >&2
    exit 1
  fi
  if [ ! -f "${ORDERER_CA}" ]; then
    echo "Error: orderer CA cert không tồn tại: ${ORDERER_CA}" >&2
    exit 1
  fi
  mkdir -p "${ROOT_DIR}/channel-artifacts"
}

package_chaincode() {
  echo "==> Packaging chaincode: ${CC_PACKAGE_FILE}"
  if [ -f "${CC_PACKAGE_FILE}" ]; then
    echo "    Package đã tồn tại, xoá để rebuild"
    rm -f "${CC_PACKAGE_FILE}"
  fi
  peer lifecycle chaincode package "${CC_PACKAGE_FILE}" \
    --path "${CC_SRC_PATH}" \
    --lang node \
    --label "${CC_LABEL}"
}

install_on_peer() {
  local org="$1"
  local peer_index="$2"
  set_peer_globals "${org}" "${peer_index}"
  echo "==> Installing chaincode on peer${peer_index}.org${org}.example.com (${CORE_PEER_ADDRESS})"

  # Bỏ qua nếu đã install
  local installed
  installed="$(peer lifecycle chaincode queryinstalled --output json 2>/dev/null | grep -c "\"label\":\"${CC_LABEL}\"" || true)"
  if [ "${installed}" -gt 0 ]; then
    echo "    ${CC_LABEL} đã install trên peer này, skipping"
    return
  fi
  peer lifecycle chaincode install "${CC_PACKAGE_FILE}"
}

get_package_id() {
  set_peer_globals 1 0
  PACKAGE_ID="$(peer lifecycle chaincode queryinstalled --output json \
    | grep -B1 "\"label\":\"${CC_LABEL}\"" \
    | grep "package_id" \
    | head -n1 \
    | sed -E 's/.*"package_id":[[:space:]]*"([^"]+)".*/\1/')"
  if [ -z "${PACKAGE_ID:-}" ]; then
    echo "Error: không tìm được package_id cho label ${CC_LABEL}" >&2
    exit 1
  fi
  echo "==> PACKAGE_ID=${PACKAGE_ID}"
}

approve_for_org() {
  local org="$1"
  set_peer_globals "${org}" 0
  echo "==> Approving chaincode cho Org${org}"

  local approved
  approved="$(peer lifecycle chaincode queryapproved -C "${CHANNEL_NAME}" -n "${CC_NAME}" --output json 2>/dev/null \
    | grep -c "\"sequence\":[[:space:]]*${CC_SEQUENCE}" || true)"
  if [ "${approved}" -gt 0 ]; then
    echo "    Org${org} đã approve sequence=${CC_SEQUENCE}, skipping"
    return
  fi

  peer lifecycle chaincode approveformyorg \
    -o "${ORDERER_ENDPOINT}" \
    --ordererTLSHostnameOverride "${ORDERER_HOSTNAME_OVERRIDE}" \
    --tls --cafile "${ORDERER_CA}" \
    --channelID "${CHANNEL_NAME}" \
    --name "${CC_NAME}" \
    --version "${CC_VERSION}" \
    --package-id "${PACKAGE_ID}" \
    --sequence "${CC_SEQUENCE}" \
    --signature-policy "${SIGNATURE_POLICY}"
}

check_commit_readiness() {
  set_peer_globals 1 0
  echo "==> Checking commit readiness"
  peer lifecycle chaincode checkcommitreadiness \
    --channelID "${CHANNEL_NAME}" \
    --name "${CC_NAME}" \
    --version "${CC_VERSION}" \
    --sequence "${CC_SEQUENCE}" \
    --signature-policy "${SIGNATURE_POLICY}" \
    --output json
}

commit_chaincode() {
  set_peer_globals 1 0
  echo "==> Committing chaincode definition"

  # Bỏ qua nếu đã commit ở sequence này
  local committed
  committed="$(peer lifecycle chaincode querycommitted -C "${CHANNEL_NAME}" -n "${CC_NAME}" --output json 2>/dev/null \
    | grep -c "\"sequence\":[[:space:]]*${CC_SEQUENCE}" || true)"
  if [ "${committed}" -gt 0 ]; then
    echo "    Chaincode đã được commit ở sequence=${CC_SEQUENCE}, skipping"
    return
  fi

  local org1_peer0_tls="${ROOT_DIR}/organizations/peerOrganizations/org1.example.com/peers/peer0.org1.example.com/tls/ca.crt"
  local org2_peer0_tls="${ROOT_DIR}/organizations/peerOrganizations/org2.example.com/peers/peer0.org2.example.com/tls/ca.crt"

  peer lifecycle chaincode commit \
    -o "${ORDERER_ENDPOINT}" \
    --ordererTLSHostnameOverride "${ORDERER_HOSTNAME_OVERRIDE}" \
    --tls --cafile "${ORDERER_CA}" \
    --channelID "${CHANNEL_NAME}" \
    --name "${CC_NAME}" \
    --version "${CC_VERSION}" \
    --sequence "${CC_SEQUENCE}" \
    --signature-policy "${SIGNATURE_POLICY}" \
    --peerAddresses localhost:7051 --tlsRootCertFiles "${org1_peer0_tls}" \
    --peerAddresses localhost:9051 --tlsRootCertFiles "${org2_peer0_tls}"
}

verify_deployment() {
  set_peer_globals 1 0
  echo "==> Verifying deployment via querycommitted"
  peer lifecycle chaincode querycommitted -C "${CHANNEL_NAME}" -n "${CC_NAME}"

  echo "==> Smoke test: query GetMerkleRoot cho electionId fake (kỳ vọng error 'chưa được commit')"
  if peer chaincode query -C "${CHANNEL_NAME}" -n "${CC_NAME}" \
    -c '{"function":"GetMerkleRoot","Args":["__probe__"]}' 2>&1 | grep -q "chưa được commit"; then
    echo "    OK: chaincode đáp ứng đúng — sẵn sàng nhận tx"
  else
    echo "    Warning: smoke test không trả response như mong đợi (có thể do chaincode container chưa khởi tạo xong)"
  fi
}

main() {
  verify_prerequisites
  package_chaincode

  install_on_peer 1 0
  install_on_peer 1 1
  install_on_peer 2 0
  install_on_peer 2 1

  get_package_id
  approve_for_org 1
  approve_for_org 2

  check_commit_readiness
  commit_chaincode
  verify_deployment

  echo ""
  echo "==> Done. Chaincode '${CC_NAME}' v${CC_VERSION} (sequence ${CC_SEQUENCE}) đã sẵn sàng trên ${CHANNEL_NAME}"
  echo "    Endorsement policy: ${SIGNATURE_POLICY}"
}

main "$@"
