#!/bin/bash
# Manual CLI testing helper
# Usage: ./scripts/test-cli.sh [clean]

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
TEST_HOME="${PROJECT_DIR}/.test-home"

# Clean mode - remove test config
if [[ "$1" == "clean" ]]; then
    echo "Cleaning test config..."
    rm -rf "$TEST_HOME"
    exit 0
fi

# Create isolated test home
mkdir -p "$TEST_HOME"

echo "=== Test Environment ==="
echo "TEST_HOME: $TEST_HOME"
echo "Config will be at: $TEST_HOME/.config/watsup/config.sexp"
echo ""

# Run with isolated HOME
cd "$PROJECT_DIR"
HOME="$TEST_HOME" opam exec -- dune exec watsup

echo ""
echo "=== Config after run ==="
cat "$TEST_HOME/.config/watsup/config.sexp" 2>/dev/null || echo "(no config created)"
