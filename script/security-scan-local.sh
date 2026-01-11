#!/usr/bin/env bash
set -euo pipefail

# ---- Config (bisa dioverride via env) ----
HOST_PORT="${HOST_PORT:-7903}"          # port di host untuk DAST
CONTAINER_PORT="${CONTAINER_PORT:-7903}" # port di container (nginx kamu listen 7903)
IMAGE_TAG="${IMAGE_TAG:-almondsense:local}"

# kalau port HOST_PORT kepake, auto cari port kosong mulai dari 8790
if ss -lnt 2>/dev/null | awk '{print $4}' | grep -q ":${HOST_PORT}\$"; then
  for p in 8790 8791 8792 8793 8794 8795; do
    if ! ss -lnt 2>/dev/null | awk '{print $4}' | grep -q ":${p}\$"; then
      HOST_PORT="$p"
      break
    fi
  done
fi


TRIVY_IMAGE="${TRIVY_IMAGE:-aquasec/trivy:latest}"
ZAP_IMAGE="${ZAP_IMAGE:-ghcr.io/zaproxy/zaproxy:stable}"
CURL_IMAGE="${CURL_IMAGE:-curlimages/curl:8.6.0}"

# ---- Path resolve: script bisa dijalankan dari mana saja ----
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
OUT_DIR="${OUT_DIR:-${SCRIPT_DIR}/security-reports}"

mkdir -p "${OUT_DIR}"

echo "=============================================="
echo "Local DevSecOps Scan Runner"
echo "REPO_ROOT : ${REPO_ROOT}"
echo "OUT_DIR   : ${OUT_DIR}"
echo "IMAGE_TAG : ${IMAGE_TAG}"
echo "HOST_PORT : ${HOST_PORT} (container ${CONTAINER_PORT})"
echo "=============================================="
echo ""

# Helper: HTTP check tanpa butuh curl di host
http_check() {
  docker run --rm --network host "${CURL_IMAGE}" -fsS "http://localhost:${HOST_PORT}" >/dev/null 2>&1
}

echo "[1/5] Trivy CONFIG scan (Dockerfile/compose/nginx/haproxy/etc)"
docker run --rm \
  -v "${REPO_ROOT}:/work" -w /work \
  -v "${OUT_DIR}:/out" \
  "${TRIVY_IMAGE}" \
  config --severity HIGH,CRITICAL \
  --format sarif --output /out/trivy-config.sarif .

echo "[2/5] Trivy FS scan (repo vuln + secrets)"
docker run --rm \
  -v "${REPO_ROOT}:/work" -w /work \
  -v "${OUT_DIR}:/out" \
  "${TRIVY_IMAGE}" \
  fs --scanners vuln,secret \
  --severity HIGH,CRITICAL \
  --format sarif --output /out/trivy-fs.sarif .

echo "[3/5] Build app image locally (from repo root Dockerfile)"
docker build -t "${IMAGE_TAG}" -f "${REPO_ROOT}/Dockerfile" "${REPO_ROOT}"

echo "[4/5] Trivy IMAGE scan (OS + dependency CVE)"
docker run --rm \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -v "${OUT_DIR}:/out" \
  "${TRIVY_IMAGE}" \
  image --severity HIGH,CRITICAL \
  --format sarif --output /out/trivy-image.sarif "${IMAGE_TAG}"

echo "[5/5] DAST baseline with OWASP ZAP (against local container)"

# Run app
docker rm -f app-under-test >/dev/null 2>&1 || true
docker run -d --rm \
  --name app-under-test \
  -p "${HOST_PORT}:${CONTAINER_PORT}" \
  "${IMAGE_TAG}"

# Wait for app
echo "Waiting for app to be ready..."
for i in {1..30}; do
  if http_check; then
    echo "App is up on http://localhost:${HOST_PORT}"
    break
  fi
  echo "  - still waiting... (${i}/30)"
  sleep 2
  if [ "$i" -eq 30 ]; then
    echo "ERROR: App did not become ready in time"
    docker logs app-under-test || true
    exit 1
  fi
done

# ZAP baseline scan (report ke OUT_DIR)
docker run --rm -t --network host \
  -v "${OUT_DIR}:/zap/wrk" \
  "${ZAP_IMAGE}" zap-baseline.py \
    -t "http://localhost:${HOST_PORT}" \
    -a -j -I \
    -r zap_report.html

docker rm -f app-under-test >/dev/null 2>&1 || true

echo ""
echo "✅ Done. Reports are in: ${OUT_DIR}/"
ls -lh "${OUT_DIR}"

