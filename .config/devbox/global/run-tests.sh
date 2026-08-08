#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(CDPATH= cd -P -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(CDPATH= cd -P -- "$SCRIPT_DIR/../../.." && pwd)

exec bash "$REPO_ROOT/tests/run.sh"
