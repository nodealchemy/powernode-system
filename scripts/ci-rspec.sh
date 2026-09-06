#!/usr/bin/env bash
# Run rspec and record how many examples it actually executed.
#
# WHY THIS EXISTS. On run 1773 the rspec, provider-specs and worker-specs jobs
# each reported conclusion `failure` after 13-23 seconds, every step marked
# `cancelled`, with not one line of rspec output: the postgres sidecar could
# not bind the fixed host port, so no example ran. That outcome is
# byte-identical, on the workflow surface, to a build whose tests genuinely
# failed. "3 jobs failed" therefore carries no information — a reviewer cannot
# separate a broken build from an untested one, and a real regression landing
# in that window hides behind a red that was never a test result.
#
# The port collision itself is fixed elsewhere (per-job kernel-assigned sidecar
# ports). This wrapper addresses the REPORTING, which stays wrong regardless:
# any infrastructure fault that kills a job before its suite lands in the same
# indistinguishable bucket. Recording the count here lets
# ci-assert-examples-ran.sh fail the job with a message that says "never ran".
#
# Exits with rspec's OWN status — never a pipeline stage's. A `| tee` without
# this care reports tee's success and turns a red suite green.
set -uo pipefail

# Job-scoped: two jobs sharing a runner must never sum into one file, or a
# job that ran nothing inherits its neighbour's count and passes. Both
# scripts run inside the same job, so these expressions agree by
# construction — ci_zero_example_gate_spec pins that they stay identical.
TOTALS="${CI_EXAMPLES_TOTALS_FILE:-${RUNNER_TEMP:-/tmp}/ci-examples-${GITHUB_RUN_ID:-norun}-${GITHUB_JOB:-nojob}}"
log="$(mktemp)"

bundle exec rspec "$@" 2>&1 | tee "$log"
rc=${PIPESTATUS[0]}

# rspec's summary is "N examples, M failures" (optionally ", P pending"), at
# the start of a line. Sum every summary in the log: one invocation can print
# more than one, and summing is safe because the only comparison made is
# against zero.
grep -Eo '^[0-9]+ examples?,' "$log" \
  | grep -Eo '^[0-9]+' \
  | awk '{ s += $1 } END { print s + 0 }' >> "$TOTALS"

rm -f "$log"
exit "$rc"
