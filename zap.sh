#!/usr/bin/env bash
set -Eeuo pipefail

IMAGE="ghcr.io/zaproxy/zaproxy:stable"
SERVICE="${serviceName:-devsecops-svc}"
APP_URL="${applicationURL:-http://192.168.10.111}"
RULES="zap_rules"

echo "========== OWASP ZAP API SCAN =========="

# 1. Verification des outils
for cmd in docker kubectl curl; do
    command -v "$cmd" >/dev/null || {
        echo "ERROR: $cmd not installed"
        exit 1
    }
done

# 2. Recuperer le NodePort Kubernetes
PORT=$(kubectl -n default get svc "$SERVICE" \
    -o jsonpath='{.spec.ports[0].nodePort}')

if [[ -z "$PORT" ]]; then
    echo "ERROR: NodePort not found"
    exit 1
fi

TARGET="${APP_URL%/}:${PORT}/v3/api-docs"

echo "Service: $SERVICE"
echo "Port: $PORT"
echo "Target: $TARGET"
echo "Image: $IMAGE"

# 3. Verifier les regles ZAP
if [[ ! -f "$RULES" ]]; then
    echo "ERROR: Missing rules file: $RULES"
    exit 1
fi

# 4. Verifier OpenAPI
echo "========== CHECK OPENAPI =========="

HTTP_CODE=$(curl -sS \
    --connect-timeout 5 \
    --max-time 20 \
    -o /dev/null \
    -w '%{http_code}' \
    "$TARGET") || {
        echo "ERROR: OpenAPI endpoint unreachable"
        exit 1
    }

echo "OpenAPI HTTP: $HTTP_CODE"

if [[ "$HTTP_CODE" != "200" ]]; then
    echo "ERROR: OpenAPI returned HTTP $HTTP_CODE"
    exit 1
fi

# 5. Preparer les rapports
mkdir -p owasp-zap-report

# Repertoire temporaire dedie au conteneur ZAP
# Ne pas modifier les permissions du workspace entier.
ZAP_WORK=$(mktemp -d "$PWD/.zap-work-XXXXXX")
chmod 777 "$ZAP_WORK"

cp "$RULES" "$ZAP_WORK/zap_rules"
chmod 644 "$ZAP_WORK/zap_rules"

cleanup() {
    rm -f "$ZAP_WORK/zap_rules"
    rmdir "$ZAP_WORK" 2>/dev/null || true
}
trap cleanup EXIT

# 6. Executer OWASP ZAP
echo "========== START ZAP =========="

set +e

docker run --rm \
    --memory=4g \
    -e JAVA_OPTS="-Xmx2g" \
    -v "$ZAP_WORK:/zap/wrk:rw" \
    "$IMAGE" \
    bash -c '
        zap-api-scan.py \
            -t "$1" \
            -f openapi \
            -c zap_rules \
            -r zap_report.html \
            -J zap_report.json \
            -T 10 \
            -d

        RC=$?

        echo "========== ZAP INTERNAL LOG =========="
        if [ -f /home/zap/.ZAP/zap.log ]; then
            tail -n 80 /home/zap/.ZAP/zap.log
        fi

        exit "$RC"
    ' _ "$TARGET"

EXIT_CODE=$?

set -e

# 7. Recuperer les rapports
echo "========== SAVE REPORTS =========="

for report in zap_report.html zap_report.json; do
    if [[ -f "$ZAP_WORK/$report" ]]; then
        mv -f "$ZAP_WORK/$report" \
            "owasp-zap-report/$report"
        echo "Saved: owasp-zap-report/$report"
    fi
done

# 8. Resultat
echo "========== ZAP RESULT =========="
echo "Exit Code: $EXIT_CODE"

case "$EXIT_CODE" in
    0)
        echo "SUCCESS: No blocking security alerts"
        exit 0
        ;;
    1)
        echo "FAIL: Security vulnerabilities classified FAIL"
        exit 1
        ;;
    2)
        echo "WARNING: Security alerts detected"
        echo "Continuing pipeline according to lab policy"
        exit 0
        ;;
    3)
        echo "ERROR: ZAP scan execution failed"
        exit 3
        ;;
    *)
        echo "ERROR: Unexpected Docker/ZAP error"
        exit "$EXIT_CODE"
        ;;
esac