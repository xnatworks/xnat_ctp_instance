#!/bin/bash
set -e

echo "============================================"
echo "  RSNA Clinical Trial Processor (CTP)"
echo "============================================"
echo "DICOM Import Port: ${CTP_DICOM_PORT:-1085}"
echo "Admin Web UI:      http://localhost:${CTP_HTTP_PORT:-1080}"
echo "XNAT HTTP Target:  ${XNAT_URL:-http://xnat-nginx:80}"
echo "XNAT Project:      ${XNAT_PROJECT:-/prearchive}"
echo "============================================"

cd /opt/ctp

# Two config modes:
#   1. Template mode (default): config-template/config.xml is mounted read-only,
#      copied to config.xml, and __PLACEHOLDER__ values are substituted from env vars.
#   2. Custom mode: User mounts a complete config.xml directly to /opt/ctp/config.xml.
#      No substitution is performed - the config is used as-is.

if [ -f /opt/ctp/config-template/config.xml ]; then
    echo "Config mode: TEMPLATE (substituting env vars)"
    cp /opt/ctp/config-template/config.xml /opt/ctp/config.xml
    sed -i "s|__CTP_DICOM_PORT__|${CTP_DICOM_PORT:-1085}|g" config.xml
    sed -i "s|__CTP_HTTP_PORT__|${CTP_HTTP_PORT:-1080}|g" config.xml
    sed -i "s|__XNAT_URL__|${XNAT_URL:-http://xnat-nginx:80}|g" config.xml
    sed -i "s|__XNAT_USERNAME__|${XNAT_USERNAME:-admin}|g" config.xml
    sed -i "s|__XNAT_PASSWORD__|${XNAT_PASSWORD:-admin}|g" config.xml
    sed -i "s|__XNAT_PROJECT__|${XNAT_PROJECT:-/prearchive}|g" config.xml
else
    echo "Config mode: CUSTOM (using mounted config.xml as-is)"
fi

echo "Active config.xml:"
cat config.xml

echo "Starting CTP with Runner.jar..."
exec java -jar Runner.jar
