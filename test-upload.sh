#!/bin/bash
# Test DICOM upload to XNAT via CTP or direct
# Usage: ./test-upload.sh [dicom_file]

DICOM_FILE="${1:-/tmp/test.dcm}"

# Load config from .env if present
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
if [ -f "$SCRIPT_DIR/.env" ]; then
    set -a
    source "$SCRIPT_DIR/.env"
    set +a
fi

XNAT_URL="${XNAT_URL:-http://localhost:8181}"
XNAT_USER="${XNAT_USERNAME:-admin}"
XNAT_PASS="${XNAT_PASSWORD:-admin}"
CTP_HOST="localhost"
CTP_PORT="${CTP_DICOM_PORT:-1085}"
CTP_AET="CTP"

echo "=========================================="
echo "  CTP / XNAT DICOM Upload Test"
echo "=========================================="

# Check DICOM file exists
if [ ! -f "$DICOM_FILE" ]; then
    echo "ERROR: DICOM file not found: $DICOM_FILE"
    exit 1
fi
echo "DICOM file: $DICOM_FILE ($(stat -c%s "$DICOM_FILE" 2>/dev/null || stat -f%z "$DICOM_FILE") bytes)"

# ---- Test 1: CTP DICOM receiver ----
echo ""
echo "--- Test 1: Send DICOM to CTP (port $CTP_PORT) ---"
if command -v storescu &>/dev/null; then
    echo "Using: dcmtk storescu"
    storescu -v -aec "$CTP_AET" "$CTP_HOST" "$CTP_PORT" "$DICOM_FILE" 2>&1
    echo "Result: $?"
elif [ -x "$SCRIPT_DIR/tools/storescu" ]; then
    echo "Using: dcm4che storescu (bundled)"
    "$SCRIPT_DIR/tools/storescu" -c "$CTP_AET@$CTP_HOST:$CTP_PORT" "$DICOM_FILE" 2>&1
    echo "Result: $?"
else
    echo "SKIP: No storescu found (install dcmtk or use bundled tools/storescu)"
fi

# ---- Test 2: XNAT JSESSION auth ----
echo ""
echo "--- Test 2: XNAT session auth ---"
JSESSION=$(curl -s -u "$XNAT_USER:$XNAT_PASS" "$XNAT_URL/data/JSESSION")
if [ -n "$JSESSION" ] && [ ${#JSESSION} -gt 10 ]; then
    echo "OK: JSESSIONID=$JSESSION"
else
    echo "FAIL: Could not get session (response: $JSESSION)"
fi

# ---- Test 3: Direct XNAT upload (DICOM-zip, prearchive) ----
echo ""
echo "--- Test 3: Direct upload to XNAT (DICOM-zip handler) ---"
TMPZIP=$(mktemp /tmp/ctp-test-XXXXX.zip)
cd "$(dirname "$DICOM_FILE")" && zip -j "$TMPZIP" "$DICOM_FILE" >/dev/null 2>&1

RESPONSE=$(curl -s -w "\nHTTP_CODE:%{http_code}" \
    -H "Cookie: JSESSIONID=$JSESSION" \
    -H "Content-Type: application/zip" \
    -X POST \
    --data-binary "@$TMPZIP" \
    "$XNAT_URL/data/services/import?import-handler=DICOM-zip&inbody=true&dest=/prearchive/projects/CTP&overwrite=append")

HTTP_CODE=$(echo "$RESPONSE" | grep "HTTP_CODE:" | cut -d: -f2)
BODY=$(echo "$RESPONSE" | grep -v "HTTP_CODE:")
echo "HTTP $HTTP_CODE"
echo "$BODY"
rm -f "$TMPZIP"

# ---- Test 4: Direct XNAT upload (SI handler, archive) ----
echo ""
echo "--- Test 4: Direct upload to XNAT (SI handler, archive) ---"
TMPZIP2=$(mktemp /tmp/ctp-test-XXXXX.zip)
cd "$(dirname "$DICOM_FILE")" && zip -j "$TMPZIP2" "$DICOM_FILE" >/dev/null 2>&1

RESPONSE=$(curl -s -w "\nHTTP_CODE:%{http_code}" \
    -H "Cookie: JSESSIONID=$JSESSION" \
    -H "Content-Type: application/zip" \
    -X POST \
    --data-binary "@$TMPZIP2" \
    "$XNAT_URL/data/services/import?import-handler=SI&inbody=true&dest=/archive&overwrite=append&PROJECT_ID=CTP")

HTTP_CODE=$(echo "$RESPONSE" | grep "HTTP_CODE:" | cut -d: -f2)
BODY=$(echo "$RESPONSE" | grep -v "HTTP_CODE:")
echo "HTTP $HTTP_CODE"
echo "$BODY"
rm -f "$TMPZIP2"

# ---- Test 5: CTP admin web UI ----
echo ""
echo "--- Test 5: CTP admin web UI ---"
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" "http://$CTP_HOST:1080")
if [ "$HTTP_CODE" = "200" ]; then
    echo "OK: CTP admin UI reachable at http://$CTP_HOST:1080"
else
    echo "FAIL: HTTP $HTTP_CODE"
fi

# ---- Test 6: Check CTP export log ----
echo ""
echo "--- Test 6: CTP export log (last 5 lines) ---"
if command -v docker &>/dev/null; then
    docker exec ctp tail -5 /opt/ctp/logs/ctp.log 2>/dev/null || echo "SKIP: cannot read CTP logs"
else
    echo "SKIP: docker not available"
fi

echo ""
echo "=========================================="
echo "  Done"
echo "=========================================="
