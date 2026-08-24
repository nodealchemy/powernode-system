#!/usr/bin/env bash
# needs-parent-modules.sh — the ONE definition of "this module packages a
# subtree of the parent (core) repo", sourced by every caller that has to
# agree about it.
# =============================================================================
# WHY THIS FILE EXISTS. Four scripts need this predicate and, before this file,
# three of them each carried their own copy of the list:
#
#   stage15.sh          `needs_parent` case — decides whether to clone /tmp/parent
#   should-skip-build.sh NEEDS_DECLARED_INPUTS — refused to skip these
#   push.sh              (implicitly, via BUILD_INPUT_PATHS supplied by CI)
#
# Their comments already said "keep this list in step with stage15.sh's
# needs_parent arm", which is the shape of a rule nothing enforces. A module
# added to stage15's arm but missed here would package parent content whose
# changes the inputs hash cannot see — the exact wrong-SKIP this machinery is
# built to prevent. One definition, sourced, removes that failure mode.
#
# WHAT MAKES A MODULE "NEEDS PARENT". Its stage15 arm clones the core
# powernode-platform repo and packages a subtree of it (server/, worker/,
# frontend/). Its build therefore has an input that does NOT live in this
# repository, so hashing modules/<slug>/ alone under-describes it.
#
# NOT on this list, and deliberately so:
#   powernode-system-base  cross-compiles the Go agent from agent/ — out of the
#                          module tree but IN this repo, so it is declarable via
#                          BUILD_INPUT_PATHS rather than via the core ref.
#   module-forge           bakes scripts/module-build/* into its own rootfs —
#                          likewise in-repo.
# Both still refuse to skip until their inputs are declared; see
# should-skip-build.sh's NEEDS_DECLARED_INPUTS.

# Is $1 a module whose build packages parent-repo content?
# Exit 0 = yes, 1 = no. No output.
module_needs_parent() {
  case "${1:-}" in
    powernode-hub-backend|powernode-hub-worker|powernode-hub-frontend|powernode-extension-system)
      return 0 ;;
    *)
      return 1 ;;
  esac
}

# Echo the --core-ref argument pair for $1, or nothing.
#
# This is what folds the parent commit into the build-inputs hash for exactly
# the modules whose inputs it actually describes. Emitting it UNCONDITIONALLY
# would be a regression, not extra safety: every package-origin module's hash
# would then change on every core commit, so none of them could ever skip —
# which is the whole saving this machinery exists for.
#
# $2 is the core ref (caller passes "${CORE_REF:-}"). Empty core ref emits
# nothing, which leaves the hash exactly as it was before this file existed;
# should-skip-build.sh separately refuses to skip a needs-parent module that
# has no core ref, so an unpinned build cannot silently skip.
core_ref_hash_args() {
  local module="${1:-}" core_ref="${2:-}"
  module_needs_parent "$module" || return 0
  [ -n "$core_ref" ] || return 0
  printf '%s\n%s\n' "--core-ref" "$core_ref"
}
