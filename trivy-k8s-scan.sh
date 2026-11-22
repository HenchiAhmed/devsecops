
#!/usr/bin/env bash
set -Eeuo pipefail

# ========================================
# TRIVY CONFIGURATION
# ========================================

IMAGE="${imageName:?ERREUR : imageName non defini}"
WORKSPACE="${WORKSPACE:-$PWD}"

TRIVY_VERSION="0.76.2"

# Mode DEV : autoriser les vulnerabilites critiques
# Mettre false pour reactiver le blocage
ALLOW_CRITICAL="${ALLOW_CRITICAL:-true}"

# Reports inside Jenkins workspace
REPORT_DIR="$WORKSPACE/trivy-reports"
REPORT="$REPORT_DIR/trivy-report.json"

# Persistent Trivy cache OUTSIDE Jenkins workspace
CACHE_DIR="${TRIVY_CACHE_DIR:-/var/lib/jenkins/trivy-cache}"

# Temporary files OUTSIDE Jenkins workspace
TMP_DIR=""

cleanup() {
    if [[ -n "$TMP_DIR" && -d "$TMP_DIR" ]]; then
        rm -rf -- "$TMP_DIR"
    fi
}

trap cleanup EXIT

echo "========================================"
echo "TRIVY IMAGE SECURITY SCAN"
echo "Image               : $IMAGE"
echo "Trivy Version       : $TRIVY_VERSION"
echo "Allow Critical      : $ALLOW_CRITICAL"
echo "Report Directory    : $REPORT_DIR"
echo "Cache Directory     : $CACHE_DIR"
echo "========================================"

# ========================================
# 1. CHECK DEPENDENCIES
# ========================================

for CMD in docker python3 mktemp; do
    if ! command -v "$CMD" >/dev/null 2>&1; then
        echo "ERREUR : commande absente : $CMD"
        exit 2
    fi
done

# ========================================
# 2. PREPARE DIRECTORIES
# ========================================

mkdir -p "$REPORT_DIR"

if ! mkdir -p "$CACHE_DIR"; then
    echo "ERREUR : impossible de creer le cache Trivy."
    echo "Verifier les permissions : $CACHE_DIR"
    exit 2
fi

# Temporary files also outside workspace
TMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/trivy-input.XXXXXX")

# The container runs as root by default.
# Cache and reports remain writable from Docker.
echo "Directories prepared."

# ========================================
# 3. VERIFY DOCKER IMAGE
# ========================================

echo "========== VERIFY DOCKER IMAGE =========="

if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
    echo "ERREUR : image Docker introuvable : $IMAGE"
    exit 2
fi

# ========================================
# 4. EXPORT DOCKER IMAGE
# ========================================

echo "========== EXPORT DOCKER IMAGE =========="

if ! docker save -o "$TMP_DIR/image.tar" "$IMAGE"; then
    echo "ERREUR : export Docker impossible."
    exit 2
fi

echo "Docker image exported successfully."

# ========================================
# 5. TRIVY VULNERABILITY SCAN
# ========================================

echo "========== TRIVY SECURITY SCAN =========="

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

# ========================================
# 6. VERIFY REPORT
# ========================================

echo "========== VERIFY TRIVY REPORT =========="

if [[ ! -s "$REPORT" ]]; then
    echo "ERREUR : rapport Trivy absent ou vide."
    exit 2
fi

echo "Report generated: $REPORT"

# ========================================
# 7. ANALYZE VULNERABILITIES
# ========================================

python3 - "$REPORT" "$ALLOW_CRITICAL" <<'PY'
import json
import sys
from collections import Counter

report_path = sys.argv[1]
allow_critical = sys.argv[2].lower() == "true"

try:
    with open(report_path, encoding="utf-8") as file:
        report = json.load(file)
except (OSError, json.JSONDecodeError) as exc:
    print(f"ERROR: Cannot read Trivy report: {exc}")
    sys.exit(2)

counts = Counter()

for result in report.get("Results", []):
    for vulnerability in result.get("Vulnerabilities") or []:
        severity = vulnerability.get("Severity", "UNKNOWN")
        counts[severity] += 1

print("\n========== TRIVY RESULTS ==========")

for severity in ("LOW", "MEDIUM", "HIGH", "CRITICAL"):
    print(f"{severity}: {counts[severity]}")

print("===================================")

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

echo "========== TRIVY SCAN COMPLETED =========="
