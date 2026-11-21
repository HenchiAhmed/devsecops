
#!/usr/bin/env bash
set -Eeuo pipefail

IMAGE="${imageName:?ERREUR : imageName non defini}"
WORKSPACE="${WORKSPACE:-$PWD}"

TRIVY_VERSION="0.76.2"

REPORT_DIR="$WORKSPACE/trivy-reports"
CACHE_DIR="$WORKSPACE/.trivy-cache"

mkdir -p "$REPORT_DIR" "$CACHE_DIR"

TMP_DIR="$(mktemp -d "$WORKSPACE/trivy-input.XXXXXX")"
trap 'rm -rf -- "$TMP_DIR"' EXIT

REPORT="$REPORT_DIR/trivy-report.json"

echo "========================================"
echo "TRIVY IMAGE SECURITY SCAN"
echo "Image : $IMAGE"
echo "========================================"

# 1. Verify that the image exists locally
if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
    echo "ERREUR : image Docker introuvable localement."
    echo "Verifier le docker build et le tag utilise."
    exit 2
fi

# 2. Export image without exposing docker.sock to Trivy
echo "Export de l'image..."
if ! docker save -o "$TMP_DIR/image.tar" "$IMAGE"; then
    echo "ERREUR : export Docker impossible."
    exit 2
fi

# 3. Scan and generate a JSON report
echo "Analyse des vulnerabilites..."

if ! docker run --rm \
    -v "$TMP_DIR:/scan:ro" \
    -v "$CACHE_DIR:/root/.cache" \
    -v "$REPORT_DIR:/reports" \
    "aquasec/trivy:$TRIVY_VERSION" \
    image \
    --input /scan/image.tar \
    --scanners vuln \
    --severity LOW,MEDIUM,HIGH,CRITICAL \
    --format json \
    --output /reports/trivy-report.json \
    --exit-code 0; then

    echo "ERREUR TECHNIQUE : Trivy n'a pas termine le scan."
    exit 2
fi

# 4. Analyze the completed report
python3 - "$REPORT" <<'PY'
import json
import sys
from collections import Counter

with open(sys.argv[1], encoding="utf-8") as file:
    report = json.load(file)

counts = Counter()

for result in report.get("Results", []):
    for vulnerability in result.get("Vulnerabilities") or []:
        counts[vulnerability.get("Severity", "UNKNOWN")] += 1

print("\n====== TRIVY RESULTS ======")

for severity in ("LOW", "MEDIUM", "HIGH", "CRITICAL"):
    print(f"{severity}: {counts[severity]}")

print("===========================")

if counts["CRITICAL"]:
    print("FAILED : critical vulnerabilities found.")
    sys.exit(1)

print("PASSED : no critical vulnerabilities found.")
PY
