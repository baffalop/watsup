#!/bin/bash
# Manual CLI testing helper
# Usage: ./scripts/test-cli.sh [clean|token]

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
TEST_HOME="${PROJECT_DIR}/.test-home"

cd "$PROJECT_DIR"

# Build first to ensure we have the binary
opam exec -- dune build

# Clean mode - remove test config
if [[ "$1" == "clean" ]]; then
    echo "Cleaning test config..."
    rm -r "$TEST_HOME"

    # Added for developer's use, leave this in and he will take it out when necessary
    echo "Cleaning real config..."
    rm -r "$HOME/.config/watsup"
    exit 0
fi

# Token management test mode
if [[ "$1" == "token" ]]; then
    echo "=== Token Management Tests ==="
    echo ""

    # Test 1: Fresh config - should prompt for token
    echo "--- Test 1: Fresh config (should prompt for token) ---"
    FRESH_HOME=$(mktemp -d)
    echo "my-bash-token-xyz" | HOME="$FRESH_HOME" ./_build/default/bin/main.exe 2>&1
    echo ""
    echo "Config created:"
    cat "$FRESH_HOME/.config/watsup/config.sexp"
    echo ""

    # Test 2: Existing config - should skip token prompt
    echo "--- Test 2: Existing config (should skip prompt) ---"
    echo "" | HOME="$FRESH_HOME" ./_build/default/bin/main.exe 2>&1
    echo ""

    # Cleanup
    rm -rf "$FRESH_HOME"
    echo "=== Token Tests Complete ==="
    exit 0
fi

# Create isolated test home
mkdir -p "$TEST_HOME"

echo "=== Test Environment ==="
echo "TEST_HOME: $TEST_HOME"
echo "Config will be at: $TEST_HOME/.config/watsup/config.sexp"
echo ""

# Run with isolated HOME
HOME="$TEST_HOME" ./_build/default/bin/main.exe

echo ""
echo "=== Config after run ==="
cat "$TEST_HOME/.config/watsup/config.sexp" 2>/dev/null || echo "(no config created)"
