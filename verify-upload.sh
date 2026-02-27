#!/bin/bash
# verify-upload.sh - Send test DICOM through CTP and verify it arrives in XNAT prearchive
#
# Prerequisites:
#   - CTP container running (./restart.sh)
#   - XNAT running and reachable from CTP container
#   - .env configured with XNAT_URL, XNAT_USERNAME, XNAT_PASSWORD
#   - storescu installed (brew install dcmtk / apt install dcmtk)
#
# Usage:
#   ./verify-upload.sh                          # Use bundled test data
#   ./verify-upload.sh /path/to/custom/*.dcm    # Use your own DICOM files

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PASS=0
FAIL=0

# Load config from .env
if [ -f "$SCRIPT_DIR/.env" ]; then
    set -a
    source "$SCRIPT_DIR/.env"
    set +a
fi

# Use XNAT_URL from .env (override with XNAT_VERIFY_URL for Docker-internal addresses)
XNAT_VERIFY_URL="${XNAT_VERIFY_URL:-$XNAT_URL}"
XNAT_USER="${XNAT_USERNAME:-admin}"
XNAT_PASS="${XNAT_PASSWORD:-admin}"
CTP_HOST="localhost"
CTP_PORT="${CTP_DICOM_PORT:-1085}"
CTP_AET="CTP"

# Test data
if [ $# -gt 0 ]; then
    DICOM_FILES=("$@")
else
    DICOM_FILES=("$SCRIPT_DIR"/testdata/tcia-prostate-3t/*.dcm)
fi

if [ ${#DICOM_FILES[@]} -eq 0 ]; then
    echo "ERROR: No DICOM files found"
    exit 1
fi

result() {
    if [ "$1" = "PASS" ]; then
        PASS=$((PASS + 1))
        echo "  PASS: $2"
    else
        FAIL=$((FAIL + 1))
        echo "  FAIL: $2"
    fi
}

echo "=========================================="
echo "  CTP Upload Verification"
echo "=========================================="
echo "CTP:         $CTP_HOST:$CTP_PORT (AET: $CTP_AET)"
echo "XNAT verify: $XNAT_VERIFY_URL"
echo "DICOM files: ${#DICOM_FILES[@]}"
echo ""

# --- Test 1: CTP is running ---
echo "--- 1. CTP admin UI reachable ---"
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" "http://$CTP_HOST:${CTP_HTTP_PORT:-1080}" 2>/dev/null || echo "000")
if [ "$HTTP_CODE" = "200" ]; then
    result "PASS" "CTP admin UI returned HTTP 200"
else
    result "FAIL" "CTP admin UI returned HTTP $HTTP_CODE"
    echo "  Is CTP running? Try: ./restart.sh"
    exit 1
fi

# --- Test 2: XNAT auth ---
echo "--- 2. XNAT authentication ---"
JSESSION=$(curl -s -u "$XNAT_USER:$XNAT_PASS" "$XNAT_VERIFY_URL/data/JSESSION" 2>/dev/null)
if [ -n "$JSESSION" ] && [ ${#JSESSION} -gt 10 ]; then
    result "PASS" "Got JSESSIONID"
else
    result "FAIL" "Could not authenticate (response: $JSESSION)"
    echo "  Check XNAT_VERIFY_URL and credentials in .env"
    exit 1
fi

# --- Test 3: Snapshot prearchive before ---
echo "--- 3. Prearchive snapshot (before) ---"
BEFORE=$(curl -s -H "Cookie: JSESSIONID=$JSESSION" "$XNAT_VERIFY_URL/data/prearchive/projects" 2>/dev/null)
BEFORE_COUNT=$(echo "$BEFORE" | python3 -c "import sys,json; print(len(json.load(sys.stdin)['ResultSet']['Result']))" 2>/dev/null || echo "0")
BEFORE_LASTMOD=$(echo "$BEFORE" | python3 -c "
import sys, json
data = json.load(sys.stdin)['ResultSet']['Result']
mods = [s.get('lastmod','') for s in data]
print(max(mods) if mods else '')
" 2>/dev/null || echo "")
echo "  Sessions in prearchive: $BEFORE_COUNT"

# --- Test 4: Send DICOM to CTP ---
echo "--- 4. Send ${#DICOM_FILES[@]} DICOM files to CTP via C-STORE ---"
if ! command -v storescu &>/dev/null; then
    result "FAIL" "storescu not installed (brew install dcmtk / apt install dcmtk)"
    exit 1
fi

STORE_OUTPUT=$(storescu -aec "$CTP_AET" "$CTP_HOST" "$CTP_PORT" "${DICOM_FILES[@]}" 2>&1)
STORE_RC=$?
if [ $STORE_RC -eq 0 ]; then
    result "PASS" "storescu completed successfully (exit code 0)"
else
    result "FAIL" "storescu failed (exit code $STORE_RC)"
    echo "$STORE_OUTPUT"
    exit 1
fi

# --- Test 5: Wait for CTP to compress and export ---
echo "--- 5. Waiting for CTP export (up to 30s) ---"
FOUND=false
for i in $(seq 1 6); do
    sleep 5
    AFTER=$(curl -s -H "Cookie: JSESSIONID=$JSESSION" "$XNAT_VERIFY_URL/data/prearchive/projects" 2>/dev/null)
    AFTER_COUNT=$(echo "$AFTER" | python3 -c "import sys,json; print(len(json.load(sys.stdin)['ResultSet']['Result']))" 2>/dev/null || echo "0")
    AFTER_LASTMOD=$(echo "$AFTER" | python3 -c "
import sys, json
data = json.load(sys.stdin)['ResultSet']['Result']
mods = [s.get('lastmod','') for s in data]
print(max(mods) if mods else '')
" 2>/dev/null || echo "")

    if [ "$AFTER_COUNT" -gt "$BEFORE_COUNT" ]; then
        FOUND=true
        result "PASS" "New session appeared in prearchive ($BEFORE_COUNT -> $AFTER_COUNT)"
        break
    elif [ -n "$AFTER_LASTMOD" ] && [ "$AFTER_LASTMOD" != "$BEFORE_LASTMOD" ]; then
        FOUND=true
        result "PASS" "Prearchive session updated (lastmod changed)"
        break
    fi
    echo "  ${i}... ($AFTER_COUNT sessions, waiting)"
done

if [ "$FOUND" = "false" ]; then
    result "FAIL" "No prearchive change detected after 30s"
    echo "  Check CTP logs: tail -20 logs/ctp.log"
fi

# --- Test 6: Verify session details ---
echo "--- 6. Verify prearchive session ---"
SESSIONS=$(curl -s -H "Cookie: JSESSIONID=$JSESSION" "$XNAT_VERIFY_URL/data/prearchive/projects" 2>/dev/null)
echo "$SESSIONS" | python3 -c "
import sys, json
data = json.load(sys.stdin)['ResultSet']['Result']
if not data:
    print('  No sessions found')
    sys.exit(1)
# Show most recent session
data.sort(key=lambda x: x.get('lastmod', ''), reverse=True)
s = data[0]
print(f\"  Subject:  {s.get('subject', '?')}\")
print(f\"  Project:  {s.get('project', '?')}\")
print(f\"  Status:   {s.get('status', '?')}\")
print(f\"  Modified: {s.get('lastmod', '?')}\")
print(f\"  URL:      {s.get('url', '?')}\")
" 2>/dev/null
result "PASS" "Session details retrieved"

# --- Test 7: Check CTP logs for errors ---
echo "--- 7. CTP export log check ---"
ERRORS=$(grep -c "Unable to export\|HTTP response code: [45]" "$SCRIPT_DIR/logs/ctp.log" 2>/dev/null; true)
if [ "$ERRORS" = "0" ] || [ -z "$ERRORS" ]; then
    result "PASS" "No export errors in CTP log"
else
    result "FAIL" "$ERRORS export errors found in CTP log"
    grep "Unable to export\|HTTP response code: [45]" "$SCRIPT_DIR/logs/ctp.log" 2>/dev/null | tail -5
fi

# --- Summary ---
echo ""
echo "=========================================="
TOTAL=$((PASS + FAIL))
echo "  Results: $PASS/$TOTAL passed"
if [ $FAIL -gt 0 ]; then
    echo "  $FAIL FAILED"
    exit 1
else
    echo "  All tests passed"
    exit 0
fi
