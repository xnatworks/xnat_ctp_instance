#!/bin/bash
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
docker-compose -f "$SCRIPT_DIR/docker-compose.yml" down
mkdir -p "$SCRIPT_DIR/roots" "$SCRIPT_DIR/quarantines" "$SCRIPT_DIR/logs"
docker-compose -f "$SCRIPT_DIR/docker-compose.yml" up -d
