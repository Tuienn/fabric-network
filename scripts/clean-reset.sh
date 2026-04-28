#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NETWORK_COMPOSE="${ROOT_DIR}/config/docker-compose-network.yaml"
CA_COMPOSE="${ROOT_DIR}/config/docker-compose-ca.yaml"
NETWORK_ENV="${ROOT_DIR}/config/.env.network"

WITH_VOLUMES=false
WITH_ARTIFACTS=false
WITH_ORGS=false
YES=false
DRY_RUN=false

VOLUMES=(
  config_orderer1.example.com
  config_orderer2.example.com
  config_orderer3.example.com
  config_peer0.org1.example.com
  config_peer1.org1.example.com
  config_peer0.org2.example.com
  config_peer1.org2.example.com
)

# Files inside channel-artifacts/ created inside Docker (may be root-owned)
ARTIFACTS=(
  "${ROOT_DIR}/channel-artifacts/mychannel.block"
  "${ROOT_DIR}/channel-artifacts/Org1MSPanchors.tx"
  "${ROOT_DIR}/channel-artifacts/Org2MSPanchors.tx"
  "${ROOT_DIR}/channel-artifacts/anchor-updates"
)

# Directories under organizations/ created inside Docker (always root-owned)
ORG_DIRS=(
  "${ROOT_DIR}/organizations/peerOrganizations"
  "${ROOT_DIR}/organizations/ordererOrganizations"
  "${ROOT_DIR}/organizations/fabric-ca/org1"
  "${ROOT_DIR}/organizations/fabric-ca/org2"
  "${ROOT_DIR}/organizations/fabric-ca/ordererOrg"
)

usage() {
  cat <<'EOF'
Usage: ./scripts/clean-reset.sh [options]

Stop Fabric stacks and optionally purge local ledger/channel artifacts.

Options:
  --with-volumes     Remove Docker volumes for orderer/peer ledgers
  --with-artifacts   Remove generated channel artifacts (mychannel.block, anchors tx)
  --with-orgs        Remove organizations/ MSP/TLS certs and CA data (root-owned)
  --all              Equivalent to --with-volumes --with-artifacts --with-orgs
  --yes              Skip destructive confirmation prompt
  --dry-run          Print actions without executing them
  -h, --help         Show this help

Examples:
  ./scripts/clean-reset.sh
  ./scripts/clean-reset.sh --all --yes
  ./scripts/clean-reset.sh --with-volumes --dry-run
EOF
}

run_cmd() {
  if [ "${DRY_RUN}" = true ]; then
    echo "[dry-run] $*"
  else
    eval "$@"
  fi
}

# Remove paths under ROOT_DIR that may be root-owned (created inside Docker containers).
# Uses a busybox container so no sudo needed.
docker_rm() {
  local rel_args=()
  for p in "$@"; do
    rel_args+=("/ws/${p#${ROOT_DIR}/}")
  done
  if [ "${DRY_RUN}" = true ]; then
    for a in "${rel_args[@]}"; do
      echo "[dry-run] docker-busybox rm -rf ${a}"
    done
    return 0
  fi
  docker run --rm -v "${ROOT_DIR}":/ws:z busybox rm -rf "${rel_args[@]}" 2>/dev/null || true
}

confirm_if_needed() {
  [ "${DRY_RUN}" = true ] && return 0
  [ "${YES}" = true ] && return 0

  if [ "${WITH_VOLUMES}" = true ] || [ "${WITH_ARTIFACTS}" = true ] || [ "${WITH_ORGS}" = true ]; then
    echo "Warning: this will delete local data (volumes/artifacts/orgs)."
    read -r -p "Type 'yes' to continue: " answer
    if [ "${answer}" != "yes" ]; then
      echo "Aborted."
      exit 1
    fi
  fi
}

parse_args() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --with-volumes)   WITH_VOLUMES=true ;;
      --with-artifacts) WITH_ARTIFACTS=true ;;
      --with-orgs)      WITH_ORGS=true ;;
      --all)            WITH_VOLUMES=true; WITH_ARTIFACTS=true; WITH_ORGS=true ;;
      --yes)            YES=true ;;
      --dry-run)        DRY_RUN=true ;;
      -h|--help)        usage; exit 0 ;;
      *)
        echo "Unknown option: $1" >&2
        usage >&2
        exit 1
        ;;
    esac
    shift
  done
}

remove_volumes() {
  for vol in "${VOLUMES[@]}"; do
    if [ "${DRY_RUN}" = true ]; then
      echo "[dry-run] docker volume rm ${vol}"
      continue
    fi
    docker volume rm "${vol}" >/dev/null 2>&1 || true
    echo "Removed volume (if existed): ${vol}"
  done
}

remove_artifacts() {
  local docker_needed=()

  for path in "${ARTIFACTS[@]}"; do
    if [ "${DRY_RUN}" = true ]; then
      echo "[dry-run] rm -rf ${path}"
      continue
    fi
    [ -e "${path}" ] || continue
    if rm -rf "${path}" 2>/dev/null; then
      echo "Removed artifact: ${path}"
    else
      docker_needed+=("${path}")
    fi
  done

  if [ ${#docker_needed[@]} -gt 0 ]; then
    echo "  (root-owned — removing via Docker busybox)"
    docker_rm "${docker_needed[@]}"
    for path in "${docker_needed[@]}"; do
      echo "Removed artifact (via Docker): ${path}"
    done
  fi
}

remove_organizations() {
  local existing=()

  for dir in "${ORG_DIRS[@]}"; do
    if [ "${DRY_RUN}" = true ]; then
      echo "[dry-run] rm -rf ${dir}"
      continue
    fi
    [ -d "${dir}" ] || continue
    existing+=("${dir}")
  done

  [ "${DRY_RUN}" = true ] && return 0
  [ ${#existing[@]} -eq 0 ] && { echo "  (nothing to remove)"; return 0; }

  docker_rm "${existing[@]}"
  for dir in "${existing[@]}"; do
    echo "Removed org dir (via Docker): ${dir}"
  done
}

main() {
  parse_args "$@"

  if [ ! -f "${NETWORK_COMPOSE}" ] || [ ! -f "${CA_COMPOSE}" ]; then
    echo "Error: compose files not found under ${ROOT_DIR}/config" >&2
    exit 1
  fi

  echo "==> Stopping runtime network stack"
  run_cmd "docker compose --env-file \"${NETWORK_ENV}\" -f \"${NETWORK_COMPOSE}\" down --remove-orphans || true"

  echo "==> Stopping CA stack"
  run_cmd "docker compose -f \"${CA_COMPOSE}\" down --remove-orphans || true"

  confirm_if_needed

  if [ "${WITH_VOLUMES}" = true ]; then
    echo "==> Removing ledger volumes"
    remove_volumes
  fi

  if [ "${WITH_ARTIFACTS}" = true ]; then
    echo "==> Removing channel artifacts"
    remove_artifacts
  fi

  if [ "${WITH_ORGS}" = true ]; then
    echo "==> Removing organization directories (MSP/TLS + CA data)"
    remove_organizations
  fi

  echo "Done."
}

main "$@"
