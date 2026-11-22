#!/usr/bin/env bash
set -Eeuo pipefail

: "${serviceName:?serviceName manquant}"
: "${applicationURL:?applicationURL manquante}"
: "${applicationURI:?applicationURI manquante}"

PORT=$(kubectl -n default get svc "$serviceName" \
  -o jsonpath='{.spec.ports[0].nodePort}')

if [[ -z "$PORT" ]]; then
    echo "ERROR: Service without NodePort"
    exit 1
fi

URL="${applicationURL}:${PORT}/${applicationURI#/}"

echo "Testing URL: $URL"

for attempt in $(seq 1 12); do

    BODY_FILE=$(mktemp)

    HTTP_CODE=$(curl -sS \
        --connect-timeout 5 \
        --max-time 10 \
        -o "$BODY_FILE" \
        -w '%{http_code}' \
        "$URL") || HTTP_CODE="000"

    RESPONSE=$(cat "$BODY_FILE")
    rm -f "$BODY_FILE"

    echo "Attempt $attempt: HTTP=$HTTP_CODE Response=[$RESPONSE]"

    if [[ "$HTTP_CODE" == "200" && "$RESPONSE" == "100" ]]; then
        echo "Increment Test Passed"
        echo "HTTP Status Code Test Passed"
        exit 0
    fi

    sleep 5
done

echo "ERROR: Integration test failed after 12 attempts"
exit 1