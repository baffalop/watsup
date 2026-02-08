#!/bin/bash
# Manual CLI testing helper
# Usage: ./scripts/test-cli.sh [clean|token|real|restore]

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

# Restore mode - recreate config by piping saved tokens through credential prompts
# Only needed after 'clean' (e.g., config schema change or testing caching)
# Token files are stored outside the repo (two dirs up)
if [[ "$1" == "restore" ]]; then
    TOKEN_DIR="$(dirname "$(dirname "$PROJECT_DIR")")"
    TTK="$TOKEN_DIR/.watsup-ttk"
    JTK="$TOKEN_DIR/.watsup-jtk"
    if [[ ! -f "$TTK" || ! -f "$JTK" ]]; then
        echo "Token files not found at $TOKEN_DIR/.watsup-{ttk,jtk}"
        exit 1
    fi
    echo "=== Restoring credentials ==="
    # Config is saved after credentials, before Watson parsing.
    # CLI will crash with EOF when entry prompts exhaust stdin — that's expected.
    cat "$TTK" <(printf '\npodfather\nngaidakov@podfather.com\n') "$JTK" | ./_build/default/bin/main.exe >/dev/null 2>&1 || true
    if [[ -f "$HOME/.config/watsup/config.sexp" ]]; then
        echo "Config restored."
    else
        echo "FAILED: config not created."
        exit 1
    fi
    exit 0
fi

# Real config mode - use actual ~/.config/watsup (for API testing with real token)
# Extra args after "real" are piped as stdin lines to the CLI
if [[ "$1" == "real" ]]; then
    echo "=== Real Config Mode ==="
    echo "Using real config at: $HOME/.config/watsup/config.sexp"
    echo ""
    shift  # remove "real"
    if [[ $# -gt 0 ]]; then
        printf '%s\n' "$@" | ./_build/default/bin/main.exe
    else
        ./_build/default/bin/main.exe
    fi
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
