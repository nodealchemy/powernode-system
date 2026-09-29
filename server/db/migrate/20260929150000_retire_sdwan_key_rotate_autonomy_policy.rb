# frozen_string_literal: true

# IMP-2e7816b5ee95 — retire system.sdwan_key_rotate from running installs.
#
# The category was declared auto_approve in
# System::Governance::PolicyDeclarations::SDWAN_REMEDIATION_POLICIES (earlier in
# FLEET_AUTONOMY_POLICIES) and has had NO producer since IMP-df40782d3f4d moved
# system.sdwan_credential_expiring onto system.sdwan_credential_refresh. It was
# kept "for a future key-TTL lane". That lane was never built, and a governed
# key rotation now exists: system_sdwan_rotate_peer_key under
# sdwan.peer_key_rotate, declared require_approval. Keeping both would leave an
# auto_approve control over the same act, waiting for whichever producer first
# chose the looser spelling.
#
# THE ROW EXISTS ON RUNNING INSTALLS: PolicyReconciler created it on every
# account whose SDWAN Manager (earlier Fleet Autonomy) set it reconciled.
#
# WHY A MIGRATION AND NOT A SEED OR THE RECONCILER — the precedent of
# 20260903120000_retire_underscored_package_module_autonomy_policy.rb:
#
#   * db:seed runs on FIRST BOOT ONLY, so nothing in db/seeds reaches an
#     install that is already up.
#   * System::Governance::PolicyReconciler is ABSENCE-ONLY: it creates a
#     declared row that is missing and never deletes one (its one update arm,
#     the owner re-home, rewrites ai_agent_id only). Dropping the declaration
#     strands the row rather than removing it.
#   * db/seeds/system_autonomy_orphan_cleanup.rb would collect it on the ADMIN
#     ACCOUNT ONLY, and it is a seed. The delete below is account-wide.
#
# Left alone the row keeps rendering in the Autonomy modal, where every save now
# 422s on the unregistered category, and it gates nothing.
#
# NOT CONVERGED ONTO sdwan.peer_key_rotate, deliberately. That is not a second
# spelling of this category but a different act with a different audience: this
# one was the autonomous tier of a sensor lane nobody built, seeded auto_approve;
# the new one is the operator verb's gate, seeded require_approval. Copying a
# verb across would carry auto_approve into the gate an operator's rotation
# request meets. The new rows come from the reconciler at the declared verb.
#
# WHAT CHANGES FOR AN OPERATOR: nothing resolved system.sdwan_key_rotate, so no
# verdict changes. Every deleted row is logged with its scope, agent and verb so
# a tuned row is recoverable rather than silently gone.
#
# Data-only, no DDL. Idempotent: a re-run matches nothing. Never raises from
# `up` on a missing table — a raising data migration crash-loops rails at boot.
# Not reversible: `down` cannot know which rows an install had, and a restored
# row would be unregistered and un-saveable.
class RetireSdwanKeyRotateAutonomyPolicy < ActiveRecord::Migration[8.1]
  RETIRED_CATEGORIES = %w[
    system.sdwan_key_rotate
  ].freeze

  # The governed category a key rotation resolves now — named in the log line
  # only; nothing is written to it here.
  GOVERNED_CATEGORY = "sdwan.peer_key_rotate"

  # Local model: a migration must not depend on an app model whose validations
  # and callbacks can drift out from under it.
  class PolicyRow < ActiveRecord::Base
    self.table_name = "ai_intervention_policies"
  end

  def up
    return unless table_exists?(:ai_intervention_policies)

    doomed = PolicyRow.where(action_category: RETIRED_CATEGORIES)
    count = doomed.count

    if count.zero?
      say "No system.sdwan_key_rotate policy rows to retire"
      return
    end

    # STATE THE COUNT, and the verb, before the delete: this is the only record
    # of what an install had tuned on the category being withdrawn.
    doomed.order(:account_id, :id).each do |row|
      say "retiring #{row.action_category} (account_id=#{row.account_id.inspect} " \
          "scope=#{row.scope.inspect} agent_id=#{row.ai_agent_id.inspect} policy=#{row.policy.inspect} " \
          "active=#{row.is_active.inspect}) — no producer; a governed key rotation gates on " \
          "#{GOVERNED_CATEGORY}, whose rows the governance reconcile creates at its declared verb"
    end

    doomed.delete_all
    say "Retired #{count} system.sdwan_key_rotate autonomy policy row(s)"
  end

  def down
    raise ActiveRecord::IrreversibleMigration,
          "the retired category had no producer and is no longer registered; re-creating its rows " \
          "would restore un-saveable Autonomy modal entries"
  end
end
