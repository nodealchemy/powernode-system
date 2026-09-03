# frozen_string_literal: true

# IMP-7bba0413c36a — record HOW a CveExposure was matched, admit the
# `suspected` state, and resolve the keyword-only open rows already on disk.
#
# WHAT WAS WRONG. System::CveOps::ExposureCalculator has two matchers: an
# ecosystem-aware version-range match against an ingested SBOM
# (VersionMatcher), and a v0 fallback that looks for the CVE's package NAME in
# the module's name + repo with no version awareness at all. Both minted the
# same `open` row, and nothing recorded which one had spoken. On the
# 2026-09-03 control plane every open critical exposure was a fallback hit on
# a 2009 CVE (CVE-2009-3616 x3 on qemu-guest-agent modules, CVE-2009-3555 on
# nginx) whose NVD entry carries version "*"; the fallback's signature was the
# blank package_version (exposure_calculator.rb `package_version: nil`).
#
# WHAT THIS DOES.
#   1. `match_method` (`sbom` | `keyword`), NOT NULL. The column default is
#      `keyword`: a row that arrives with no claim about its evidence is read
#      as the weaker one. Existing rows are then backfilled from the only
#      evidence they carry — a blank package_version is the keyword fallback's
#      signature, a version is the SBOM matcher's — so old rows read
#      truthfully rather than uniformly.
#   2. The state check constraint gains `suspected`, the state the calculator
#      now mints keyword hits in (a suspicion, not an exposure — outside every
#      autonomy lane until an SBOM match confirms it). The exposure COUNTS
#      exclude on match evidence rather than on the state, precisely because
#      step 3 leaves the rows below `resolved` rather than `suspected`, and a
#      resolved row still appears in system_get_cve_exposure.
#   3. Keyword-only rows still OPEN are resolved with a note naming why. Rows
#      already resolved — including the four the operator resolved by hand on
#      ops-hub under this task — are untouched, as are `remediating` rows
#      (something was dispatched for those; an operator decides them). This
#      resolution is a SUPPRESSION for want of evidence, not a decision: an
#      SBOM match on such a row re-opens it (CveExposure#record_match keys on
#      the note below), so a real exposure is not hidden forever.
#
# WHY A MIGRATION: the calculator fix stops NEW false positives; the 565 rows
# already written keep feeding every open-exposure count, the CVE Responder's
# aged-out escalation and the compliance snapshot until something moves them.
#
# Reversible: `down` re-opens the rows this migration resolved (by the note it
# wrote), reads `suspected` back as the `open` the old schema meant, restores
# the four-state constraint and drops the column.
class AddMatchMethodToSystemCveExposures < ActiveRecord::Migration[8.1]
  # Mirrored in System::CveExposure::KEYWORD_FALSE_POSITIVE_NOTE; pinned as a
  # literal here because a migration must not read an app model that can
  # drift out from under it.
  FALSE_POSITIVE_NOTE = "keyword-fallback false positive (no version evidence)"

  CONSTRAINT = "ck_cve_exposures_state"
  OLD_STATES = %w[open remediating resolved wont_fix].freeze
  NEW_STATES = (OLD_STATES + %w[suspected]).freeze

  # Local model: a migration must not depend on an app model whose validations
  # and callbacks (here: match_method inference) can drift out from under it.
  class ExposureRow < ActiveRecord::Base
    self.table_name = "system_cve_exposures"
  end

  def up
    add_column :system_cve_exposures, :match_method, :string, null: false, default: "keyword"
    add_index :system_cve_exposures, :match_method
    ExposureRow.reset_column_information

    backfill_match_method!
    replace_state_constraint(NEW_STATES)
    resolve_keyword_false_positives!
  end

  def down
    reopened = ExposureRow.where(state: "resolved", resolution_note: FALSE_POSITIVE_NOTE)
                          .update_all(state: "open", resolved_at: nil, resolution_note: nil, updated_at: Time.current)
    say "Re-opened #{reopened} keyword-fallback row(s) this migration had resolved"

    demoted = ExposureRow.where(state: "suspected").update_all(state: "open", updated_at: Time.current)
    say "Read #{demoted} suspected row(s) back as open (the pre-migration meaning)"

    replace_state_constraint(OLD_STATES)
    remove_index :system_cve_exposures, :match_method
    remove_column :system_cve_exposures, :match_method
    ExposureRow.reset_column_information
  end

  # A blank package_version is the keyword fallback's signature (it wrote
  # `package_version: nil`); the SBOM matcher always records the matched
  # package's version. Public so the migration spec can exercise it directly.
  def backfill_match_method!
    sbom = ExposureRow.where.not(package_version: [ nil, "" ]).where.not(match_method: "sbom")
                      .update_all(match_method: "sbom")
    keyword = ExposureRow.where(package_version: [ nil, "" ]).where.not(match_method: "keyword")
                         .update_all(match_method: "keyword")
    say "Backfilled match_method: #{sbom} sbom row(s) (version evidence), #{keyword} keyword row(s) (none)"
  end

  # Only OPEN keyword rows: a resolved row carries a decision already, and a
  # remediating row had something dispatched for it. Idempotent — a re-run
  # matches nothing.
  def resolve_keyword_false_positives!
    now = Time.current
    count = ExposureRow.where(match_method: "keyword", state: "open")
                       .update_all(state: "resolved", resolved_at: now, resolution_note: FALSE_POSITIVE_NOTE,
                                   updated_at: now)
    say "Resolved #{count} keyword-only open exposure(s) as: #{FALSE_POSITIVE_NOTE}"
  end

  private

  def replace_state_constraint(states)
    remove_check_constraint :system_cve_exposures, name: CONSTRAINT if check_constraint_exists?(:system_cve_exposures, name: CONSTRAINT)
    add_check_constraint :system_cve_exposures,
                         "state IN (#{states.map { |s| "'#{s}'" }.join(', ')})",
                         name: CONSTRAINT
  end
end
