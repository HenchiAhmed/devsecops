#!/usr/bin/env bash
set -Eeuo pipefail

IMAGE="ghcr.io/zaproxy/zaproxy:stable"
SERVICE="${serviceName:-devsecops-svc}"
APP_URL="${applicationURL:-http://192.168.10.111}"
RULES="zap_rules"

echo "========== OWASP ZAP API SCAN =========="

# 1. Verify dependencies
for cmd in docker kubectl curl; do
    command -v "$cmd" >/dev/null 2>&1 || {
        echo "ERROR: Missing command: $cmd"
        exit 1
    }
done

# 2. Get Kubernetes NodePort
PORT=$(kubectl -n default get svc "$SERVICE" \
    -o jsonpath='{.spec.ports[0].nodePort}')

if [[ ! "$PORT" =~ ^[0-9]+$ ]]; then
    echo "ERROR: Invalid or missing NodePort"
    exit 1
fi

TARGET="${APP_URL%/}:${PORT}/v3/api-docs"

echo "Service: $SERVICE"
echo "NodePort: $PORT"
echo "Target: $TARGET"
echo "Image: $IMAGE"

# 3. Verify custom ZAP rules
if [[ ! -f "$RULES" ]]; then
    echo "ERROR: Missing rules file: $RULES"
    exit 1
fi

# 4. Verify OpenAPI endpoint
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

# 5. Prepare report directory
REPORT_DIR="$PWD/owasp-zap-report"
mkdir -p "$REPORT_DIR"

# Temporary working directory for the default ZAP user
ZAP_WORK=$(mktemp -d "$PWD/.zap-work-XXXXXX")

# Only this temporary directory is writable by the
# container user, never the whole Jenkins workspace.
chmod 0777 "$ZAP_WORK"

cleanup() {
    rm -rf -- "$ZAP_WORK"
}
trap cleanup EXIT

cp "$RULES" "$ZAP_WORK/zap_rules"
chmod 0644 "$ZAP_WORK/zap_rules"

# 6. Run ZAP API Scan
echo "========== START OWASP ZAP =========="

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
            -z "-silent" \
            -d

        RC=$?

        echo "========== ZAP INTERNAL LOG =========="

        for LOG in \
            /home/zap/.ZAP/zap.log \
            /home/zap/.ZAP_D/zap.log
        do
            if [ -f "$LOG" ]; then
                echo "=== $LOG ==="
                tail -n 80 "$LOG"
            fi
        done

        exit "$RC"
    ' _ "$TARGET"

EXIT_CODE=$?

set -e

# 7. Save generated reports
echo "========== SAVE REPORTS =========="

for REPORT in zap_report.html zap_report.json; do
    if [[ -f "$ZAP_WORK/$REPORT" ]]; then
        mv -f "$ZAP_WORK/$REPORT" "$REPORT_DIR/$REPORT"
        echo "Saved: owasp-zap-report/$REPORT"
    fi
done

# 8. Report scan result
echo "========== ZAP RESULT =========="
echo "Exit Code: $EXIT_CODE"

case "$EXIT_CODE" in
    0)
        echo "SUCCESS: No blocking security alerts"
        exit 0
        ;;
    1)
        echo "FAIL: Security findings classified FAIL"
        exit 1
        ;;
    2)
        echo "WARNING: Security findings classified WARN"
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