#!/usr/bin/env bash
set -euo pipefail

# Backup named Docker volumes used by Fabric peers/orderers into ./backups.
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BACKUP_DIR="${BACKUP_DIR:-${ROOT_DIR}/backups}"
STAMP="$(date +%Y%m%d-%H%M%S)"
ARCHIVE="${BACKUP_DIR}/fabric-volumes-${STAMP}.tar.gz"

mkdir -p "${BACKUP_DIR}"

# BusyBox tar keeps the script runtime lightweight.
docker run --rm \
  -v orderer1.example.com:/vol/orderer1.example.com \
  -v orderer2.example.com:/vol/orderer2.example.com \
  -v orderer3.example.com:/vol/orderer3.example.com \
  -v peer0.org1.example.com:/vol/peer0.org1.example.com \
  -v peer1.org1.example.com:/vol/peer1.org1.example.com \
  -v peer0.org2.example.com:/vol/peer0.org2.example.com \
  -v peer1.org2.example.com:/vol/peer1.org2.example.com \
  -v "${BACKUP_DIR}:/backup:z" \
  busybox sh -c "tar czf /backup/$(basename "${ARCHIVE}") -C /vol ."

echo "Backup created: ${ARCHIVE}"
