#!/usr/bin/env bash
set -Eeuo pipefail

IMAGE="ghcr.io/zaproxy/zaproxy:stable"
SERVICE="${serviceName:-devsecops-svc}"
APP_URL="${applicationURL:-http://192.168.10.111}"
RULES="zap_rules"

echo "========== OWASP ZAP API SCAN =========="

# Recuperer le NodePort Kubernetes
PORT=$(kubectl -n default get svc "$SERVICE" \
  -o jsonpath='{.spec.ports[0].nodePort}')

if [[ -z "$PORT" ]]; then
    echo "ERROR: Kubernetes NodePort not found"
    exit 1
fi

TARGET="${APP_URL%/}:${PORT}/v3/api-docs"

echo "Target: $TARGET"
echo "Image: $IMAGE"

# Verifier que les regles personnalisees existent
if [[ ! -f "$RULES" ]]; then
    echo "ERROR: Custom rules file not found: $RULES"
    exit 1
fi

# Verifier OpenAPI
echo "========== CHECK OPENAPI =========="

curl -fsS \
    --connect-timeout 5 \
    --max-time 20 \
    "$TARGET" \
    -o /dev/null || {
        echo "ERROR: OpenAPI endpoint unavailable"
        exit 1
    }

# Repertoire de sortie
mkdir -p owasp-zap-report

# ZAP utilisera les permissions du compte Jenkins
echo "========== RUN ZAP =========="

set +e

docker run --rm \
    --user "$(id -u):$(id -g)" \
    -e HOME=/tmp \
    -v "$(pwd):/zap/wrk:rw" \
    "$IMAGE" \
    zap-api-scan.py \
    -t "$TARGET" \
    -f openapi \
    -c "$RULES" \
    -r zap_report.html \
    -J zap_report.json

EXIT_CODE=$?

set -e

# Deplacer les rapports sans sudo
for report in zap_report.html zap_report.json; do
    if [[ -f "$report" ]]; then
        mv -f "$report" owasp-zap-report/
    fi
done

echo "========== ZAP RESULT =========="
echo "Exit Code: $EXIT_CODE"

case "$EXIT_CODE" in
    0)
        echo "SUCCESS: No FAIL or WARN alerts"
        exit 0
        ;;
    1)
        echo "FAIL: Security findings classified FAIL"
        exit 1
        ;;
    2)
        echo "WARNING: Security findings classified WARN"
        exit 0
        ;;
    3)
        echo "ERROR: ZAP scan execution failed"
        exit 3
        ;;
    *)
        echo "ERROR: Docker or unexpected ZAP failure"
        exit "$EXIT_CODE"
        ;;
esac