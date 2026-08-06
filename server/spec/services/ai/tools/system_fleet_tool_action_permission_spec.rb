# frozen_string_literal: true

require "rails_helper"

# IMP-7ad2c4f02f55 — per-action classification of SystemFleetTool's
# ACTION_PERMISSIONS entries that named system.fleet.autonomy.
#
# WHY REAL ROLES AND NOT user_with_permissions. Every existing spec for this
# surface grants the permission synthetically, which proves an action works for
# a principal holding it while saying NOTHING about whether any real role does.
# That is exactly how the sibling controller defect (428f84ce) survived
# unnoticed: system.fleet.autonomy is catalogued worker-only
# (powernode_system/engine.rb), so an operator who is admin — but not
# super_admin — was refused, and no synthetic-grant spec could see it. These
# examples drive real Role records through User#has_permission?.
#
# THE THREE MOVED, and why each is a read of operator-facing fleet state:
#   system_recent_signals       reads System::FleetEvent scoped to @account.
#                               Exact MCP twin of the HTTP `signals` endpoint
#                               moved to system.fleet.read in 428f84ce.
#   system_inspect_correlation  reads System::FleetEvent by correlation_id,
#                               account-scoped. Twin of the boot_replay
#                               correlation view moved in the same commit.
#   system_compliance_snapshot  ComplianceSnapshotService#snapshot! is PURE
#                               READ — it only collect_*s and returns a Hash.
#                               Its own class comment says the CALLER persists
#                               the document via add_document, so the bang means
#                               "raises on bad args", not "mutates". Verified
#                               before moving it.
# None of the three makes or alters an autonomy DECISION, which is what
# system.fleet.autonomy is catalogued for ("Fleet autonomy decision making
# (worker)").
#
# THE FOUR LEFT ALONE are pinned below so a later bulk edit cannot sweep them
# in: two are cross-tenant writes to a GLOBAL table (one destroy-shaped), one
# marks a honeypot deception asset, and one rotates Vault key material.
RSpec.describe Ai::Tools::SystemFleetTool, "per-action permissions" do
  let(:account) { create(:account) }

  # Real Role records — the whole point of this file.
  let(:super_admin) { create(:user, :super_admin, account: account) }
  let(:admin)       { create(:user, :admin, account: account) }
  let(:nobody)      { create(:user, account: account, permissions: []) }
  let(:worker) do
    u = create(:user, account: account)
    u.roles = []
    u.add_role("system_worker")
    u
  end

  MOVED_TO_FLEET_READ = %w[
    system_recent_signals
    system_inspect_correlation
    system_compliance_snapshot
  ].freeze

  LEFT_ON_FLEET_AUTONOMY = %w[
    system_create_cve
    system_delete_cve
    system_module_mark_canary
    system_rotate_vault_transit_pepper
  ].freeze

  def tool_for(user) = described_class.new(account: account, user: user)

  # True when the call cleared the per-action permission gate. The action's own
  # validation may still reject the payload — that is not what this file tests.
  def cleared_gate?(user, action, **params)
    result = tool_for(user).execute(params: { action: action, **params }.with_indifferent_access)
    !(result.is_a?(Hash) && result[:success] == false &&
      result[:error].to_s.match?(/permission denied/i))
  rescue StandardError
    # An action-level raise is still past the gate.
    true
  end

  describe "the mapping itself" do
    it "maps each moved action to system.fleet.read" do
      MOVED_TO_FLEET_READ.each do |action|
        expect(described_class::ACTION_PERMISSIONS[action])
          .to eq("system.fleet.read"), "expected #{action} to be operator-facing"
      end
    end

    # Pinned so a bulk rename cannot quietly sweep these along with the reads.
    # Deliberately asserts the CURRENT mapping only — see the note at the top of
    # the "left alone" describe for what this does and does not claim.
    it "leaves the four non-read actions on system.fleet.autonomy" do
      LEFT_ON_FLEET_AUTONOMY.each do |action|
        expect(described_class::ACTION_PERMISSIONS[action])
          .to eq("system.fleet.autonomy"), "#{action} must not be moved without its own argument"
      end
    end

    it "leaves no other action on system.fleet.autonomy" do
      on_autonomy = described_class::ACTION_PERMISSIONS
                      .select { |_, perm| perm == "system.fleet.autonomy" }.keys

      expect(on_autonomy).to match_array(LEFT_ON_FLEET_AUTONOMY)
    end
  end

  # ── The defect: an operator who is admin but not super_admin ─────────────
  describe "admin (not super_admin)" do
    it "holds system.fleet.read but not system.fleet.autonomy" do
      expect(admin.has_permission?("system.fleet.read")).to be true
      expect(admin.has_permission?("system.fleet.autonomy")).to be false
    end

    MOVED_TO_FLEET_READ.each do |action|
      it "can invoke #{action}" do
        expect(cleared_gate?(admin, action, correlation_id: SecureRandom.uuid)).to be true
      end
    end
  end

  describe "super_admin" do
    MOVED_TO_FLEET_READ.each do |action|
      it "can invoke #{action} (system.admin grant-all)" do
        expect(cleared_gate?(super_admin, action, correlation_id: SecureRandom.uuid)).to be true
      end
    end
  end

  describe "system_worker" do
    # Unchanged by this commit: the worker reached these before and still does.
    # NOTE it reaches them via the system.admin grant-all rule rather than via
    # system.fleet.autonomy specifically — see IMP-019fd140.
    MOVED_TO_FLEET_READ.each do |action|
      it "still reaches #{action}" do
        expect(cleared_gate?(worker, action, correlation_id: SecureRandom.uuid)).to be true
      end
    end
  end

  # Widening to "any authenticated user" would be the wrong fix; the gate must
  # still be a gate.
  describe "a user holding no fleet permissions" do
    MOVED_TO_FLEET_READ.each do |action|
      it "is refused #{action}" do
        expect(cleared_gate?(nobody, action, correlation_id: SecureRandom.uuid)).to be false
      end
    end
  end

  # ── The four left alone ──────────────────────────────────────────────────
  #
  # This pins the CURRENT mapping so a bulk edit cannot sweep them in. It does
  # NOT assert that the current mapping confines them to anything narrower than
  # system.admin — it does not, because system_worker holds system.admin
  # (config/permissions.rb SYSTEM_PERMISSIONS) and is therefore grant-all. That
  # is tracked separately as IMP-019fd140 and is not this commit's to fix.
  describe "actions deliberately left on system.fleet.autonomy" do
    LEFT_ON_FLEET_AUTONOMY.each do |action|
      it "still refuses #{action} for an admin who is not super_admin" do
        expect(cleared_gate?(admin, action, cve_id: "CVE-2026-0001",
                                            module_id: SecureRandom.uuid)).to be false
      end
    end
  end

  # ── IMP-51296ff7208a: canary marking stays worker-only, and says so ──────
  #
  # An offer proposed retargeting system_module_mark_canary to
  # system.modules.update to match REST. Refused: this action is already
  # pinned in LEFT_ON_FLEET_AUTONOMY above as a deliberate exception
  # ("marks a honeypot deception asset"), and placing a decoy is an autonomy
  # decision rather than ordinary module editing. What WAS missing is the
  # thing that makes a deliberate denial readable — the restriction appears
  # in neither the description nor the denial message, so an admin hitting it
  # debugs a misconfiguration that does not exist.
  describe "worker-only canary marking (IMP-51296ff7208a)" do
    it "keeps mark_canary on the autonomy grant" do
      expect(described_class::ACTION_PERMISSIONS["system_module_mark_canary"])
        .to eq("system.fleet.autonomy")
    end

    it "explains the restriction in the denial message rather than reading as an outage" do
      msg = described_class.new(account: account, user: admin)
                           .send(:permission_denied_message, "system_module_mark_canary")
      expect(msg).to match(/by design|worker/i),
        "a deliberate worker-only denial must say so — see WORKER_ONLY_ACTIONS"
    end

    it "states the restriction in the action description too" do
      desc = described_class.action_definitions.dig("system_module_mark_canary", :description)
      expect(desc).to match(/autonomy|worker/i)
    end

    # The inverse is deliberately NOT worker-only: an operator must always be
    # able to CLEAR a decoy that is firing wrongly, and REST already allows
    # exactly that (unmark_canary requires system.modules.update), so MCP
    # matching it widens nothing.
    it "leaves unmark reachable by an ordinary module editor" do
      expect(described_class::ACTION_PERMISSIONS["system_unmark_module_canary"])
        .to eq("system.modules.update")
    end
  end

  # ── IMP-767c0448b8b9: template actions belong to the templates family ────
  #
  # Five template actions were gated on system.nodes.* while the registered
  # catalog carries the full system.templates family (engine.rb `resource
  # :templates`) and REST (node_templates_controller) gates every template
  # action on system.templates.*. create + compose_preview already used the
  # templates family, which made the nodes.* entries read as leftovers.
  #
  # NOTE on the worker divergence the finding named (nodes grants
  # system_worker read+update; templates grants the worker nothing): a
  # real-role behavioral assertion for that is NOT provable today because the
  # system_worker role holds system.admin grant-all (see IMP-019fd140 /
  # IMP-4bd5ac8ca3ad) — the worker clears every gate regardless of family.
  # The mapping pins below are the enforceable half; the behavioral half
  # becomes assertable when that grant-all is settled.
  describe "template-family mapping (IMP-767c0448b8b9)" do
    TEMPLATE_FAMILY = {
      "system_list_templates"           => "system.templates.read",
      "system_get_template"             => "system.templates.read",
      "system_discover_templates"       => "system.templates.read",
      "system_update_template"          => "system.templates.update",
      "system_delete_template"          => "system.templates.delete",
      # Already correct before this fix — pinned so a revert cannot sweep them.
      "system_create_template"          => "system.templates.create",
      "system_compose_preview_template" => "system.templates.read"
    }.freeze

    TEMPLATE_FAMILY.each do |action, perm|
      it "maps #{action} to #{perm}" do
        expect(described_class::ACTION_PERMISSIONS[action]).to eq(perm)
      end
    end

    it "leaves no template action on the nodes family" do
      strays = described_class::ACTION_PERMISSIONS
               .select { |a, p| a.include?("template") && p.start_with?("system.nodes.") }
      expect(strays).to be_empty,
        "template actions gated on the nodes family: #{strays.inspect}"
    end

    it "admin (not super_admin) holds the templates family end to end" do
      %w[read create update delete].each do |verb|
        expect(admin.has_permission?("system.templates.#{verb}")).to be(true),
          "admin lacks system.templates.#{verb} — retargeting would lock admins out"
      end
    end
  end
end
