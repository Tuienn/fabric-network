#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

bash -n "${ROOT_DIR}/scripts/enroll-org.sh"
bash -n "${ROOT_DIR}/scripts/clean-reset.sh"
bash -n "${ROOT_DIR}/scripts/update-anchor-peers.sh"
bash -n "${ROOT_DIR}/scripts/setup_channel.sh"

docker compose -f "${ROOT_DIR}/config/docker-compose-ca.yaml" config >/dev/null
docker compose -f "${ROOT_DIR}/config/docker-compose-network.yaml" --env-file "${ROOT_DIR}/config/.env.network" config >/dev/null

PY_BIN="$(command -v python3 || command -v python || true)"
if [[ -n "${PY_BIN}" ]] && "${PY_BIN}" -c "import yaml" >/dev/null 2>&1; then
  ROOT_DIR="${ROOT_DIR}" "${PY_BIN}" - <<'PY'
import os
from pathlib import Path
import yaml
root = Path(os.environ['ROOT_DIR'])
for rel in [
    'config/configtx.yaml',
    'config/docker-compose-ca.yaml',
    'config/docker-compose-network.yaml',
]:
    yaml.safe_load((root / rel).read_text())
print('YAML parse checks passed')
PY
else
  echo "Skipping python YAML parse (python3 + pyyaml not available)"
fi

echo "Validation complete"

