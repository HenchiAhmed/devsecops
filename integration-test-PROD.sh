
#!/usr/bin/env bash
set -Eeuo pipefail

# Configuration
APP_URL="${applicationURL:-http://192.168.10.111}"
APP_URI="${applicationURI:-/increment/99}"

echo "========== PROD INTEGRATION TEST =========="

# Recuperer le NodePort HTTP de Istio Ingress Gateway
PORT=$(kubectl -n istio-system get svc istio-ingressgateway \
    -o jsonpath='{.spec.ports[?(@.port==80)].nodePort}')

if [[ ! "$PORT" =~ ^[0-9]+$ ]]; then
    echo "ERROR: Istio Ingress Gateway NodePort not found"
    exit 1
fi

TARGET="${APP_URL%/}:${PORT}/${APP_URI#/}"

echo "NodePort: $PORT"
echo "Target: $TARGET"

# Attendre que l'application soit disponible
sleep 5

# Tester jusqu'a 5 fois
for ATTEMPT in 1 2 3 4 5; do

    echo "========== ATTEMPT $ATTEMPT/5 =========="

    BODY_FILE=$(mktemp)

    HTTP_CODE=$(curl -sS \
        --connect-timeout 5 \
        --max-time 15 \
        -o "$BODY_FILE" \
        -w '%{http_code}' \
        "$TARGET") || HTTP_CODE="000"

    RESPONSE=$(cat "$BODY_FILE")
    rm -f "$BODY_FILE"

    echo "HTTP Status: $HTTP_CODE"
    echo "Response: [$RESPONSE]"

    # Verifier reponse et statut HTTP
    if [[ "$RESPONSE" == "100" && "$HTTP_CODE" == "200" ]]; then
        echo "Increment Test Passed"
        echo "HTTP Status Code Test Passed"
        exit 0
    fi

    echo "Test failed - retrying..."

    if [[ "$ATTEMPT" -lt 5 ]]; then
        sleep 5
    fi

done

echo "========== PROD TEST FAILED =========="
echo "Check Istio Gateway, VirtualService and PROD services"

exit 1
