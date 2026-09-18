#!/usr/bin/env bash
set -euo pipefail

# Fetch external build artifacts under .s2i/artifacts.
# This script runs outside the Containerfile build flow.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ARTIFACTS_DIR="${ROOT_DIR}/.s2i/artifacts"
OKP_DIR="${ARTIFACTS_DIR}/okp_embeddings_model"
CHECKSUM_FILE="${ARTIFACTS_DIR}/okp_embeddings_model.SHA256SUM"

if [[ "$#" -ne 1 ]]; then
  echo "Usage: $0 <artifacts.txt>" >&2
  exit 2
fi

ARTIFACTS_TXT="$1"
if [[ ! -f "${ARTIFACTS_TXT}" ]]; then
  echo "ERROR: artifacts file not found: ${ARTIFACTS_TXT}" >&2
  exit 1
fi

MODEL_REVISION="9b5b096411652ec1189c68fcfb90d0a82c5b45af"

mkdir -p "${ARTIFACTS_DIR}"
rm -rf "${OKP_DIR}"

VENV_DIR="${ROOT_DIR}/.s2i/.venv-artifacts"
python3 -m venv "${VENV_DIR}"
# shellcheck disable=SC1091
source "${VENV_DIR}/bin/activate"
python -m pip install --upgrade pip
python -m pip install "huggingface_hub==1.30.0"

python - <<'PY'
from huggingface_hub import snapshot_download

snapshot_download(
    repo_id="ibm-granite/granite-embedding-30m-english",
    revision="9b5b096411652ec1189c68fcfb90d0a82c5b45af",
    local_dir=".s2i/artifacts/okp_embeddings_model",
)
print("Downloaded ibm-granite/granite-embedding-30m-english@9b5b096411652ec1189c68fcfb90d0a82c5b45af -> .s2i/artifacts/okp_embeddings_model")
PY

(
  cd "${ROOT_DIR}/.s2i/artifacts"
  # Ignore local Hugging Face cache metadata to keep manifest deterministic.
  find okp_embeddings_model -type f ! -path 'okp_embeddings_model/.cache/*' -print0 \
    | sort -z \
    | xargs -0 sha256sum \
    | LC_ALL=C sort > "${CHECKSUM_FILE}"
)

echo "Wrote checksum manifest: ${CHECKSUM_FILE}"

MANIFEST_SHA256=$(sha256sum "${CHECKSUM_FILE}" | awk '{print $1}')
EXPECTED_SHA256=$(awk '$1 == "okp_embeddings_model" {print $2}' "${ARTIFACTS_TXT}" | tail -n1)
EXPECTED_SOURCE=$(awk '$1 == "okp_embeddings_model" {print $3}' "${ARTIFACTS_TXT}" | tail -n1)

if [ -z "${EXPECTED_SHA256}" ] || [ -z "${EXPECTED_SOURCE}" ]; then
  echo "ERROR: Missing okp_embeddings_model entry in ${ARTIFACTS_TXT}" >&2
  exit 1
fi

if [ "${EXPECTED_SOURCE}" != "hf://ibm-granite/granite-embedding-30m-english@${MODEL_REVISION}" ]; then
  echo "ERROR: Source/revision mismatch in ${ARTIFACTS_TXT}" >&2
  echo "       expected source: hf://ibm-granite/granite-embedding-30m-english@${MODEL_REVISION}" >&2
  echo "       actual source:   ${EXPECTED_SOURCE}" >&2
  exit 1
fi

if [ "${EXPECTED_SHA256}" = "<to-be-updated-by-script>" ]; then
  echo "ERROR: Placeholder hash found in ${ARTIFACTS_TXT}. Set the expected manifest hash first." >&2
  echo "       Computed manifest hash: ${MANIFEST_SHA256}" >&2
  exit 1
fi

if [ "${MANIFEST_SHA256}" != "${EXPECTED_SHA256}" ]; then
  echo "ERROR: Manifest hash mismatch for okp_embeddings_model" >&2
  echo "       expected: ${EXPECTED_SHA256}" >&2
  echo "       actual:   ${MANIFEST_SHA256}" >&2
  exit 1
fi

echo "Verified okp_embeddings_model manifest hash: ${MANIFEST_SHA256}"
