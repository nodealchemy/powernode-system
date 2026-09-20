# frozen_string_literal: true

# IMP-074fcd68284f — stage 1 of 3 for per-service Linux capabilities
# (module security.capabilities = a CEILING; a service's own
# capabilities = its effective set, must be a SUBSET; absent = inherit
# the ceiling; explicit [] = zero). This stage only makes "absent" and
# "explicit []" representable in the DB and preserves that distinction
# through import + serialization; the agent-side resolver that actually
# ACTS on it ships separately, and ONLY after this stage (ordering is a
# safety requirement — see manifest_import_service.rb's apply_services
# comment for why the reverse order strips capabilities fleet-wide).
#
# `system_module_services.capabilities` was `NOT NULL DEFAULT '[]'`, so
# SQL NULL was never storable — a service that never declared
# `capabilities:` and one that declared `capabilities: []` wrote the
# identical row value, collapsing "inherit the module ceiling" and
# "explicitly grant nothing" into one indistinguishable state before
# the value ever left the database (on top of the two `|| []` collapses
# in Ruby, fixed alongside this migration).
#
# DELIBERATELY NO BACKFILL. An earlier version of this migration nulled
# every row that was exactly `[]`, on the premise that a stored `[]`
# carried no intent because nothing had ever read the column. That
# premise was wrong: a survey of every shipped manifest found nine
# services that explicitly declare `capabilities: []` at the SERVICE
# level, four of them (postgres-primary, postgres-replica, redis,
# vault) under a module ceiling that grants six or seven real
# capabilities (CAP_SETUID, CAP_SETPCAP, CAP_DAC_OVERRIDE, CAP_IPC_LOCK,
# ...) for exactly the root-prep work those services do. A backfill
# would have turned "grant nothing" into "inherit the whole ceiling"
# for all four — the same silent privilege WIDENING this whole design
# exists to prevent, just arriving through pre-existing boilerplate
# instead of a future manifest edit. The column's stored value alone
# cannot distinguish "artifact of the collapse" from "an author's
# deliberate zero" — that intent lives only in the manifests, and
# auditing it is its own task, blocking the agent-side resolver
# (stage 3), not this one. So stage 1 changes NOTHING about existing
# rows: every row keeps whatever `[]`/non-empty value it holds today,
# unchanged, and only a future re-import can write a real NULL.
class PreserveServiceCapabilitiesPresence < ActiveRecord::Migration[8.1]
  def up
    change_column_default :system_module_services, :capabilities, from: [], to: nil
    change_column_null :system_module_services, :capabilities, true
  end

  # NOT a restoration — a lossy, one-way collapse to the SAFE direction.
  # `up` above is pure DDL now (no backfill) and never writes a row, so
  # there is nothing for `down` to actually reverse; it can only choose
  # a value for whatever NULLs exist at the moment it runs.
  #
  # The real hazard lives entirely here, not in `up`: once the fixed
  # import/serializer code has been live for any length of time, a
  # legitimate re-import can write a genuine NULL meaning "inherit the
  # module ceiling". `down` collapses EVERY NULL it finds to `[]`
  # ("grant nothing") — it cannot tell a fresh, real "inherit" apart
  # from the ones this migration never touched — so a down/up cycle run
  # after that point permanently turns every such row into an explicit
  # zero. The direction is safe (it revokes access rather than granting
  # it), but it is still a silent, one-way, undetected behavior change.
  # Treat this migration as single-use — safe to revert only in the
  # narrow window immediately after landing it, before any real import
  # has run against the fixed code — not as a template for a later
  # similar change.
  def down
    execute(<<~SQL.squish)
      UPDATE system_module_services
         SET capabilities = '[]'::jsonb
       WHERE capabilities IS NULL
    SQL
    change_column_null :system_module_services, :capabilities, false
    change_column_default :system_module_services, :capabilities, from: nil, to: []
  end
end
