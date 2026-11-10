#!/usr/bin/env bash
set -Eeuo pipefail

# Run on the Jenkins host: bash installer.sh
# Requirements: curl, Jenkins admin account and an API token.
JENKINS_URL="${JENKINS_URL:-http://127.0.0.1:8080}"
JENKINS_URL="${JENKINS_URL%/}"
PLUGIN_FILE="${1:-$(dirname "$(readlink -f "$0")")/plugins.txt}"

for cmd in curl; do
  command -v "$cmd" >/dev/null || { echo "Missing dependency: $cmd" >&2; exit 1; }
done
[[ -f "$PLUGIN_FILE" ]] || { echo "Missing file: $PLUGIN_FILE" >&2; exit 1; }

read -r -p 'Jenkins admin username: ' JENKINS_USER
[[ -n "$JENKINS_USER" ]] || { echo 'Username is required' >&2; exit 1; }
read -r -s -p 'Jenkins API token (not your password): ' JENKINS_TOKEN
echo
[[ -n "$JENKINS_TOKEN" ]] || { echo 'API token is required' >&2; exit 1; }

# Restrict credential exposure to a temporary curl config file.
CURL_CONFIG="$(mktemp)"
COOKIE_JAR="$(mktemp)"
trap 'rm -f "$CURL_CONFIG" "$COOKIE_JAR"' EXIT
chmod 600 "$CURL_CONFIG" "$COOKIE_JAR"
# curl config quotes and backslashes must be escaped.
escape_curl() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }
printf 'user = "%s:%s"\n' "$(escape_curl "$JENKINS_USER")" "$(escape_curl "$JENKINS_TOKEN")" > "$CURL_CONFIG"
unset JENKINS_TOKEN

CURL=(curl --silent --show-error --fail-with-body --connect-timeout 15 --max-time 180 --config "$CURL_CONFIG" --cookie "$COOKIE_JAR" --cookie-jar "$COOKIE_JAR")

echo "Checking Jenkins: $JENKINS_URL"
if ! "${CURL[@]}" "$JENKINS_URL/whoAmI/api/json" >/dev/null; then
  echo 'Unable to connect/authenticate. Verify URL, admin account and API token.' >&2
  exit 1
fi

# API-token authentication normally bypasses CSRF crumbs, but fetch one if available.
CRUMB_HEADER=''
CRUMB_JSON="$("${CURL[@]}" "$JENKINS_URL/crumbIssuer/api/json" 2>/dev/null || true)"
if command -v jq >/dev/null 2>&1 && [[ -n "$CRUMB_JSON" ]]; then
  CRUMB_FIELD="$(printf '%s' "$CRUMB_JSON" | jq -r '.crumbRequestField // empty' 2>/dev/null || true)"
  CRUMB_VALUE="$(printf '%s' "$CRUMB_JSON" | jq -r '.crumb // empty' 2>/dev/null || true)"
  [[ -n "$CRUMB_FIELD" && -n "$CRUMB_VALUE" ]] && CRUMB_HEADER="$CRUMB_FIELD: $CRUMB_VALUE"
fi

count=0
failed=0
while IFS= read -r plugin || [[ -n "$plugin" ]]; do
  plugin="${plugin%%#*}"
  plugin="$(printf '%s' "$plugin" | tr -d '\r' | xargs)"
  [[ -z "$plugin" ]] && continue
  if [[ ! "$plugin" =~ ^[a-zA-Z0-9][a-zA-Z0-9_.-]*$ ]]; then
    echo "Invalid plugin ID: $plugin" >&2
    failed=$((failed+1))
    continue
  fi
  echo "Requesting installation: $plugin"
  xml="<jenkins><install plugin='${plugin}@latest' /></jenkins>"
  headers=()
  [[ -n "$CRUMB_HEADER" ]] && headers=(-H "$CRUMB_HEADER")
  if "${CURL[@]}" "${headers[@]}" -H 'Content-Type: text/xml' \
       --data-binary "$xml" "$JENKINS_URL/pluginManager/installNecessaryPlugins" >/dev/null; then
    count=$((count+1))
  else
    echo "FAILED requesting $plugin" >&2
    failed=$((failed+1))
  fi
done < "$PLUGIN_FILE"

echo "Installation requests accepted: $count; failed: $failed"
echo "Track progress: $JENKINS_URL/pluginManager/"
echo 'Restart Jenkins only after downloads/installations complete and no jobs are running.'
echo 'Note: previously installed Blue Ocean plugins are not automatically removed.'
[[ $failed -eq 0 ]]
