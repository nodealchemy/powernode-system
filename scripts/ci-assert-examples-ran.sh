#!/usr/bin/env bash
# Fail a spec job that executed ZERO examples, in words that cannot be read as
# an ordinary test failure. See scripts/ci-rspec.sh for the incident this
# comes from (run 1773).
#
# Runs under `if: always()` so it still reports when an earlier step died —
# that is the case worth naming, since a job killed before its suite otherwise
# shows up as a bare `failure` alongside genuine ones.
set -uo pipefail

# Job-scoped: two jobs sharing a runner must never sum into one file, or a
# job that ran nothing inherits its neighbour's count and passes. Both
# scripts run inside the same job, so these expressions agree by
# construction — ci_zero_example_gate_spec pins that they stay identical.
TOTALS="${CI_EXAMPLES_TOTALS_FILE:-${RUNNER_TEMP:-/tmp}/ci-examples-${GITHUB_RUN_ID:-norun}-${GITHUB_JOB:-nojob}}"
label="${1:-this job}"

if [ -f "$TOTALS" ]; then
  total=$(awk '{ s += $1 } END { print s + 0 }' "$TOTALS")
else
  total=0
fi

if [ "$total" -eq 0 ]; then
  echo "NO EXAMPLES RAN: ${label} executed 0 rspec examples."
  echo
  echo "This job was never tested. It did not fail a test — it never reached one,"
  echo "so nothing about the code under test was verified. Do NOT read this as an"
  echo "ordinary spec failure."
  echo
  echo "Look upstream in this job for an infrastructure fault: sidecar/container"
  echo "start, bundle install, or the test-database prepare step."
  exit 1
fi

echo "${label} executed ${total} rspec examples."
