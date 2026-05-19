#!/usr/bin/env bash
# Run the system extension RSpec suite with SimpleCov coverage tracking.
#
# Requires:
#   1. parent platform's server/Gemfile includes:
#        gem 'simplecov', require: false, group: :test
#   2. parent platform's server/spec/spec_helper.rb (or rails_helper.rb)
#      requires this extension's simplecov config at the top, e.g.:
#        require_relative '../../extensions/system/server/spec/support/simplecov'
#
# Output: HTML report at extensions/system/coverage/index.html
#
# Usage:
#   bash extensions/system/scripts/run-coverage.sh                       # full suite
#   bash extensions/system/scripts/run-coverage.sh spec/controllers/...  # subset
#
# Audit plan item: P3.7d (~/.claude/plans/forform-a-deep-examination-fizzy-lobster.md).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EXT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
PLATFORM_SERVER="$(cd "${EXT_ROOT}/../../server" 2>/dev/null && pwd || true)"

if [[ -z "${PLATFORM_SERVER}" || ! -f "${PLATFORM_SERVER}/Gemfile" ]]; then
  echo "FATAL: cannot locate parent platform server/ (expected at \$EXT_ROOT/../../server)"
  echo "       This script assumes extensions/system/ is mounted inside powernode-platform/."
  exit 1
fi

if ! grep -q "^[[:space:]]*gem ['\"]simplecov['\"]" "${PLATFORM_SERVER}/Gemfile"; then
  echo "WARN: simplecov gem not in parent Gemfile. Coverage tracking will be skipped."
  echo "      Add to ${PLATFORM_SERVER}/Gemfile:"
  echo "        gem 'simplecov', require: false, group: :test"
  echo "      Then 'bundle install' and re-run."
  echo ""
fi

cd "${PLATFORM_SERVER}"

# Default args: run the entire extension spec tree. Caller can override.
SPEC_ARGS="${*:-../extensions/system/server/spec}"

COVERAGE=1 bundle exec rspec --format progress ${SPEC_ARGS}

echo ""
echo "Coverage report: ${EXT_ROOT}/coverage/index.html"
