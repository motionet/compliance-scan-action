#!/usr/bin/env bash
# scan.sh — Submit project tarball to Motionet Compliance API, poll for result,
# write SARIF, evaluate severity gate.
#
# Environment variables (set by action.yml):
#   MOTIONET_API_KEY           — required, X-API-Key header
#   MOTIONET_API_URL           — required, base URL
#   MOTIONET_REGULATIONS       — comma-separated, default EU_AI_ACT
#   MOTIONET_MIN_SEVERITY      — default info
#   MOTIONET_FAIL_ON_SEVERITY  — default none
#   MOTIONET_SARIF_OUTPUT      — output file path
#   MOTIONET_TARBALL           — path to the created .tar.gz
#
# Exit codes:
#   0 — scan complete, no findings above fail-on-severity
#   1 — scan complete, findings exceed fail-on-severity
#   2 — API error, quota exceeded (429), timeout, or invalid key

set -euo pipefail

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

log_info()  { echo "::notice::${*}"; }
log_warn()  { echo "::warning::${*}"; }
log_error() { echo "::error::${*}"; }

die() {
  log_error "${*}"
  # Emit exit code to GITHUB_OUTPUT so callers can assert exit-2 vs exit-1
  [[ -n "${GITHUB_OUTPUT:-}" ]] && echo "action-exit-code=2" >> "${GITHUB_OUTPUT}" || true
  exit 2
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
}

require_cmd curl
require_cmd jq

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

API_KEY="${MOTIONET_API_KEY:-}"
API_URL="${MOTIONET_API_URL:-https://compliance-api.motionet.io}"
REGULATIONS="${MOTIONET_REGULATIONS:-EU_AI_ACT}"
MIN_SEVERITY="${MOTIONET_MIN_SEVERITY:-info}"
FAIL_ON_SEVERITY="${MOTIONET_FAIL_ON_SEVERITY:-none}"
SARIF_OUTPUT="${MOTIONET_SARIF_OUTPUT:-compliance-results.sarif}"
TARBALL="${MOTIONET_TARBALL:-}"

POLL_INTERVAL_SECONDS=5
POLL_MAX_ATTEMPTS=60

# Resolve SARIF output path — must be absolute or relative to GITHUB_WORKSPACE
if [[ "${SARIF_OUTPUT}" != /* ]]; then
  SARIF_OUTPUT="${GITHUB_WORKSPACE:-$(pwd)}/${SARIF_OUTPUT}"
fi

# ---------------------------------------------------------------------------
# Validation
# ---------------------------------------------------------------------------

[[ -n "${API_KEY}" ]]  || die "api-key input is required but was not provided"
[[ -n "${TARBALL}" ]]  || die "MOTIONET_TARBALL is not set — packaging step may have failed"
[[ -f "${TARBALL}" ]]  || die "Tarball not found at: ${TARBALL}"

# ---------------------------------------------------------------------------
# Step 1: Submit scan
# ---------------------------------------------------------------------------

log_info "Submitting scan to ${API_URL}/api/v2/scans ..."

HTTP_RESPONSE=$(
  curl \
    --silent \
    --show-error \
    --write-out "\n%{http_code}" \
    --max-time 120 \
    --retry 3 \
    --retry-delay 2 \
    --retry-on-http-error 503 \
    -X POST \
    "${API_URL}/api/v2/scans" \
    -H "X-API-Key: ${API_KEY}" \
    -H "Content-Type: application/gzip" \
    -H "X-Regulations: ${REGULATIONS}" \
    -H "X-Min-Severity: ${MIN_SEVERITY}" \
    --data-binary "@${TARBALL}" \
    2>&1
) || die "curl failed submitting scan: ${HTTP_RESPONSE}"

HTTP_BODY=$(echo "${HTTP_RESPONSE}" | head -n -1)
HTTP_STATUS=$(echo "${HTTP_RESPONSE}" | tail -n 1)

log_info "API responded with HTTP ${HTTP_STATUS}"

# Handle quota / auth errors first
case "${HTTP_STATUS}" in
  429)
    die "API quota exceeded (HTTP 429). Check your plan limits at https://compliance-api.motionet.io/dashboard. This is not a compliance failure."
    ;;
  401|403)
    die "Authentication failed (HTTP ${HTTP_STATUS}). Verify your MOTIONET_API_KEY secret is correct."
    ;;
  413)
    die "Tarball too large (HTTP 413). The project exceeds the API size limit. Exclude additional directories using .gitignore patterns."
    ;;
  400)
    ERROR_MSG=$(echo "${HTTP_BODY}" | jq -r '.message // "Bad request"' 2>/dev/null || echo "Bad request")
    die "API rejected the request (HTTP 400): ${ERROR_MSG}"
    ;;
esac

# Accept 200 (sync), 201 (sync), or 202 (async)
if [[ "${HTTP_STATUS}" != "200" && "${HTTP_STATUS}" != "201" && "${HTTP_STATUS}" != "202" ]]; then
  ERROR_MSG=$(echo "${HTTP_BODY}" | jq -r '.message // "Unknown error"' 2>/dev/null || echo "Unknown error")
  die "Unexpected API response (HTTP ${HTTP_STATUS}): ${ERROR_MSG}"
fi

# Extract scan ID
SCAN_ID=$(echo "${HTTP_BODY}" | jq -r '.id // .scanId // empty' 2>/dev/null)
[[ -n "${SCAN_ID}" ]] || die "Could not extract scan ID from API response: ${HTTP_BODY}"

log_info "Scan submitted. Scan ID: ${SCAN_ID}"

# ---------------------------------------------------------------------------
# Step 2: Poll if async (202)
# ---------------------------------------------------------------------------

if [[ "${HTTP_STATUS}" == "202" ]]; then
  log_info "Scan is processing asynchronously. Polling every ${POLL_INTERVAL_SECONDS}s (max ${POLL_MAX_ATTEMPTS} attempts) ..."

  ATTEMPT=0
  SCAN_STATUS="pending"

  while [[ "${SCAN_STATUS}" != "completed" && "${SCAN_STATUS}" != "failed" ]]; do
    ATTEMPT=$((ATTEMPT + 1))

    if [[ ${ATTEMPT} -gt ${POLL_MAX_ATTEMPTS} ]]; then
      die "Scan timed out after $((POLL_MAX_ATTEMPTS * POLL_INTERVAL_SECONDS)) seconds (${POLL_MAX_ATTEMPTS} poll attempts). Scan ID: ${SCAN_ID}"
    fi

    sleep "${POLL_INTERVAL_SECONDS}"

    POLL_RESPONSE=$(
      curl \
        --silent \
        --show-error \
        --write-out "\n%{http_code}" \
        --max-time 30 \
        "${API_URL}/api/v2/scans/${SCAN_ID}" \
        -H "X-API-Key: ${API_KEY}" \
        2>&1
    ) || die "curl failed polling scan status: ${POLL_RESPONSE}"

    POLL_BODY=$(echo "${POLL_RESPONSE}" | head -n -1)
    POLL_STATUS=$(echo "${POLL_RESPONSE}" | tail -n 1)

    case "${POLL_STATUS}" in
      429)
        die "API quota exceeded during polling (HTTP 429). Scan ID: ${SCAN_ID}"
        ;;
      401|403)
        die "Authentication failed during polling (HTTP ${POLL_STATUS})"
        ;;
    esac

    if [[ "${POLL_STATUS}" != "200" ]]; then
      log_warn "Poll attempt ${ATTEMPT}/${POLL_MAX_ATTEMPTS} — unexpected HTTP ${POLL_STATUS}, retrying ..."
      continue
    fi

    SCAN_STATUS=$(echo "${POLL_BODY}" | jq -r '.status // "pending"' 2>/dev/null || echo "pending")
    log_info "Poll ${ATTEMPT}/${POLL_MAX_ATTEMPTS} — status: ${SCAN_STATUS}"

    HTTP_BODY="${POLL_BODY}"
  done

  if [[ "${SCAN_STATUS}" == "failed" ]]; then
    ERROR_MSG=$(echo "${HTTP_BODY}" | jq -r '.error // .message // "Scan failed on server"' 2>/dev/null || echo "Scan failed on server")
    die "Scan failed (status=failed): ${ERROR_MSG}. Scan ID: ${SCAN_ID}"
  fi

  log_info "Scan completed after ${ATTEMPT} poll attempts."
fi

# ---------------------------------------------------------------------------
# Step 3: Parse scan results
# ---------------------------------------------------------------------------

COMPLIANCE_SCORE=$(echo "${HTTP_BODY}" | jq -r '.complianceScore // .score // 0' 2>/dev/null || echo "0")
FINDINGS_COUNT=$(echo "${HTTP_BODY}"   | jq -r '.findingsCount // (.findings | length) // 0' 2>/dev/null || echo "0")
CRITICAL_COUNT=$(echo "${HTTP_BODY}"   | jq -r '.criticalCount // 0' 2>/dev/null || echo "0")
HIGH_COUNT=$(echo "${HTTP_BODY}"       | jq -r '.highCount // 0' 2>/dev/null || echo "0")

log_info "Results: score=${COMPLIANCE_SCORE}, findings=${FINDINGS_COUNT}, critical=${CRITICAL_COUNT}, high=${HIGH_COUNT}"

# ---------------------------------------------------------------------------
# Step 4: Write SARIF output
# ---------------------------------------------------------------------------

log_info "Writing SARIF to ${SARIF_OUTPUT} ..."

# Try dedicated SARIF endpoint first; fall back to embedded sarifReport field
SARIF_CONTENT=$(echo "${HTTP_BODY}" | jq -r '.sarifReport // empty' 2>/dev/null)

if [[ -z "${SARIF_CONTENT}" ]]; then
  # Fetch SARIF from dedicated endpoint
  SARIF_RESPONSE=$(
    curl \
      --silent \
      --show-error \
      --write-out "\n%{http_code}" \
      --max-time 60 \
      "${API_URL}/api/v2/scans/${SCAN_ID}/sarif" \
      -H "X-API-Key: ${API_KEY}" \
      -H "Accept: application/json" \
      2>&1
  ) || true

  SARIF_BODY=$(echo "${SARIF_RESPONSE}" | head -n -1)
  SARIF_HTTP=$(echo "${SARIF_RESPONSE}" | tail -n 1)

  if [[ "${SARIF_HTTP}" == "200" ]] && echo "${SARIF_BODY}" | jq -e '.version' >/dev/null 2>&1; then
    SARIF_CONTENT="${SARIF_BODY}"
  else
    log_warn "Could not fetch SARIF from API (HTTP ${SARIF_HTTP:-unknown}). Generating minimal SARIF from findings."
    SARIF_CONTENT=""
  fi
fi

if [[ -z "${SARIF_CONTENT}" ]]; then
  # Build minimal SARIF 2.1.0 from findings array in scan response
  SARIF_CONTENT=$(echo "${HTTP_BODY}" | jq '
    {
      "$schema": "https://raw.githubusercontent.com/oasis-tcs/sarif-spec/master/Schemata/sarif-schema-2.1.0.json",
      "version": "2.1.0",
      "runs": [
        {
          "tool": {
            "driver": {
              "name": "Motionet Compliance Scanner",
              "version": "1.0.0",
              "informationUri": "https://compliance-api.motionet.io",
              "rules": (
                [.findings[]? | {
                  "id": (.checkId // "UNKNOWN"),
                  "name": (.checkId // "UNKNOWN"),
                  "shortDescription": { "text": (.message // "Compliance finding") },
                  "helpUri": ("https://compliance-api.motionet.io/checks/" + (.checkId // "unknown")),
                  "defaultConfiguration": {
                    "level": (
                      if .severity == "critical" then "error"
                      elif .severity == "high" then "error"
                      elif .severity == "medium" then "warning"
                      else "note"
                      end
                    )
                  }
                }] | unique_by(.id)
              )
            }
          },
          "results": [
            .findings[]? |
            {
              "ruleId": (.checkId // "UNKNOWN"),
              "level": (
                if .severity == "critical" then "error"
                elif .severity == "high" then "error"
                elif .severity == "medium" then "warning"
                else "note"
                end
              ),
              "message": { "text": (.message // "Compliance finding") },
              "locations": [
                {
                  "physicalLocation": {
                    "artifactLocation": {
                      "uri": (.evidence.file // ""),
                      "uriBaseId": "%SRCROOT%"
                    },
                    "region": {
                      "startLine": (.evidence.line // 1)
                    }
                  }
                }
              ]
            }
          ]
        }
      ]
    }
  ' 2>/dev/null) || SARIF_CONTENT='{"$schema":"https://raw.githubusercontent.com/oasis-tcs/sarif-spec/master/Schemata/sarif-schema-2.1.0.json","version":"2.1.0","runs":[{"tool":{"driver":{"name":"Motionet Compliance Scanner","version":"1.0.0"}},"results":[]}]}'
fi

# Ensure parent directory exists
mkdir -p "$(dirname "${SARIF_OUTPUT}")" \
  || die "Failed to create SARIF output directory: $(dirname "${SARIF_OUTPUT}")"

echo "${SARIF_CONTENT}" > "${SARIF_OUTPUT}" \
  || die "Failed to write SARIF to ${SARIF_OUTPUT} — check disk space and write permissions"
log_info "SARIF written to ${SARIF_OUTPUT}"

# ---------------------------------------------------------------------------
# Step 5: Set GitHub Action outputs
# ---------------------------------------------------------------------------

{
  echo "compliance-score=${COMPLIANCE_SCORE}"
  echo "findings-count=${FINDINGS_COUNT}"
  echo "critical-count=${CRITICAL_COUNT}"
  echo "high-count=${HIGH_COUNT}"
  echo "scan-id=${SCAN_ID}"
  echo "sarif-file=${SARIF_OUTPUT}"
} >> "${GITHUB_OUTPUT}" \
  || die "Failed to write to GITHUB_OUTPUT — GITHUB_OUTPUT env var may be unset or the file is not writable"

# ---------------------------------------------------------------------------
# Step 6: Evaluate severity gate
# ---------------------------------------------------------------------------

severity_rank() {
  case "${1,,}" in
    critical) echo 5 ;;
    high)     echo 4 ;;
    medium)   echo 3 ;;
    low)      echo 2 ;;
    info)     echo 1 ;;
    none)     echo 0 ;;
    *)        echo 0 ;;
  esac
}

FAIL_RANK=$(severity_rank "${FAIL_ON_SEVERITY}")

if [[ ${FAIL_RANK} -eq 0 ]]; then
  log_info "Severity gate: none — scan passes regardless of findings."
  [[ -n "${GITHUB_OUTPUT:-}" ]] && echo "action-exit-code=0" >> "${GITHUB_OUTPUT}" || true
  exit 0
fi

# Count findings at or above the fail-on-severity threshold from scan body
BLOCKING_COUNT=$(echo "${HTTP_BODY}" | jq --argjson threshold "${FAIL_RANK}" '
  [.findings[]? |
    select(
      (.severity == "critical" and 5 >= $threshold) or
      (.severity == "high"     and 4 >= $threshold) or
      (.severity == "medium"   and 3 >= $threshold) or
      (.severity == "low"      and 2 >= $threshold) or
      (.severity == "info"     and 1 >= $threshold)
    )
  ] | length
' 2>/dev/null) || BLOCKING_COUNT=0

if [[ -z "${BLOCKING_COUNT}" || "${BLOCKING_COUNT}" == "null" ]]; then
  BLOCKING_COUNT=0
fi

if [[ ${BLOCKING_COUNT} -gt 0 ]]; then
  log_error "Severity gate breached: ${BLOCKING_COUNT} finding(s) at or above '${FAIL_ON_SEVERITY}' severity. Scan ID: ${SCAN_ID}"
  log_error "Review findings in ${SARIF_OUTPUT} or at ${API_URL}/scans/${SCAN_ID}"
  [[ -n "${GITHUB_OUTPUT:-}" ]] && echo "action-exit-code=1" >> "${GITHUB_OUTPUT}" || true
  exit 1
fi

log_info "Severity gate passed: no findings at or above '${FAIL_ON_SEVERITY}'."
[[ -n "${GITHUB_OUTPUT:-}" ]] && echo "action-exit-code=0" >> "${GITHUB_OUTPUT}" || true
exit 0
