
#!/usr/bin/env bash
set -Eeuo pipefail

IMAGE="${imageName:?ERREUR : imageName non defini}"
WORKSPACE="${WORKSPACE:-$PWD}"

TRIVY_VERSION="0.76.2"

# Mode DEV : autoriser les vulnerabilites critiques
# Mettre false pour reactiver le blocage
ALLOW_CRITICAL="${ALLOW_CRITICAL:-true}"

REPORT_DIR="$WORKSPACE/trivy-reports"
CACHE_DIR="$WORKSPACE/.trivy-cache"

mkdir -p "$REPORT_DIR" "$CACHE_DIR"

TMP_DIR="$(mktemp -d "$WORKSPACE/trivy-input.XXXXXX")"
trap 'rm -rf -- "$TMP_DIR"' EXIT

REPORT="$REPORT_DIR/trivy-report.json"

echo "========================================"
echo "TRIVY IMAGE SECURITY SCAN"
echo "Image : $IMAGE"
echo "Mode DEV - Allow Critical : $ALLOW_CRITICAL"
echo "========================================"

# 1. Verify Docker image
if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
    echo "ERREUR : image Docker introuvable."
    exit 2
fi

# 2. Export image
echo "Export de l'image..."

if ! docker save -o "$TMP_DIR/image.tar" "$IMAGE"; then
    echo "ERREUR : export Docker impossible."
    exit 2
fi

# 3. Trivy scan
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

    echo "ERREUR TECHNIQUE : scan Trivy echoue."
    exit 2
fi

# 4. Analyze report
python3 - "$REPORT" "$ALLOW_CRITICAL" <<'PY'
import json
import sys
from collections import Counter

report_path = sys.argv[1]
allow_critical = sys.argv[2].lower() == "true"

with open(report_path, encoding="utf-8") as file:
    report = json.load(file)

counts = Counter()

for result in report.get("Results", []):
    for vulnerability in result.get("Vulnerabilities") or []:
        severity = vulnerability.get("Severity", "UNKNOWN")
        counts[severity] += 1

print("\n====== TRIVY RESULTS ======")

for severity in ("LOW", "MEDIUM", "HIGH", "CRITICAL"):
    print(f"{severity}: {counts[severity]}")

print("===========================")

if counts["CRITICAL"] > 0:
    print("WARNING: Critical vulnerabilities detected!")

    if allow_critical:
        print("DEV EXCEPTION: Security gate bypassed.")
        print("Pipeline will continue.")
        sys.exit(0)

    print("FAILED: Critical vulnerabilities block pipeline.")
    sys.exit(1)

print("PASSED: No critical vulnerabilities found.")
sys.exit(0)
PY
