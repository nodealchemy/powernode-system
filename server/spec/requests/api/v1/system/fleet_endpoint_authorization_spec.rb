# frozen_string_literal: true

require "rails_helper"

# IMP-27a8654e7c04 — WHICH principals can reach the four operator-facing fleet
# endpoints. Written so the next reader does not have to re-derive it.
#
# Every other spec for these endpoints grants the permission synthetically
# (fleet_boot_replay_spec.rb uses user_with_permissions("system.fleet.autonomy")),
# which proves the endpoint works for a principal holding the permission but says
# nothing about whether any real ROLE holds it. This spec drives real roles
# instead — the factory's :super_admin / :admin / :owner traits assign actual
# Role records, so it exercises the production path
# (User#has_permission? -> roles.joins(:role_permissions)).
#
# Ground truth established here, per endpoint, per role.
RSpec.describe "system fleet endpoint authorization", type: :request do
  let(:account) { create(:account) }

  # Real roles, not synthetic permission lists.
  let(:super_admin) { create(:user, :super_admin, account: account) }
  let(:admin)       { create(:user, :admin, account: account) }
  let(:owner)       { create(:user, :owner, account: account) }

  let(:node) { create(:system_node, account: account) }
  let(:instance) { create(:system_node_instance, node: node) }

  def headers_for(user)
    auth_headers_for(user).merge("Content-Type" => "application/json")
  end

  # Each endpoint reduced to "did authorization let me through?" — a 403 is a
  # refusal, anything else means the gate passed (the action's own validation
  # may still reject the payload, which is not what this spec is about).
  def reach(endpoint, user)
    case endpoint
    when :boot_replay
      get "/api/v1/system/fleet/boot_replay?instance_id=#{instance.id}", headers: headers_for(user)
    when :signals
      post "/api/v1/system/fleet/signals", params: {}.to_json, headers: headers_for(user)
    when :attribute_failure
      post "/api/v1/system/fleet/attribute_failure",
           params: { instance_id: instance.id }.to_json, headers: headers_for(user)
    when :attribution_feedback
      post "/api/v1/system/fleet/attribution_feedback",
           params: { instance_id: instance.id, candidate_kind: "module", confirmed: true }.to_json,
           headers: headers_for(user)
    end

    response.status == 403 ? :refused : :reached
  end

  ENDPOINTS = %i[boot_replay signals attribute_failure attribution_feedback].freeze

  # ── The grant-all rule ───────────────────────────────────────────────────
  #
  # system.admin short-circuits User#has_permission? (core user.rb:140), so
  # super_admin — the only role whose permission list contains it
  # (config/permissions.rb:922) — reaches everything regardless of how an
  # endpoint is gated. The filed finding claimed "no admin can reach these
  # endpoints"; that is false, and this pins why.
  describe "super_admin" do
    ENDPOINTS.each do |endpoint|
      it "reaches #{endpoint} via the system.admin grant-all rule" do
        expect(reach(endpoint, super_admin)).to eq(:reached)
      end
    end
  end

  # ── The actual defect ────────────────────────────────────────────────────
  #
  # An operator who is admin or owner but NOT super_admin holds no
  # system.admin, so each endpoint is decided by the specific permission it
  # names. This controller is documented as operator-facing and JWT-backed
  # (fleet_controller.rb:6-9), and is explicitly the counterpart to
  # worker_api/fleet_controller, so every one of its endpoints must be
  # reachable by an ordinary fleet operator.
  describe "admin (not super_admin)" do
    ENDPOINTS.each do |endpoint|
      it "reaches #{endpoint}" do
        expect(reach(endpoint, admin)).to eq(:reached)
      end
    end
  end

  # BY DESIGN, not a second defect. The system extension's catalog grants to
  # `admin` 71 times, `system_worker` 19, `manager` 3, `member` 2 — and `owner`
  # ZERO times, across all 84 grants in powernode_system/engine.rb. An owner
  # holds no system.* permission at all, so it is refused here exactly as it is
  # refused everywhere else in the extension. Pinned so this reads as the
  # extension's consistent posture rather than an oversight for someone to
  # "fix" by widening.
  describe "owner (not super_admin)" do
    ENDPOINTS.each do |endpoint|
      it "is refused #{endpoint}, holding no system.* permission" do
        expect(reach(endpoint, owner)).to eq(:refused)
      end
    end

    it "holds none of the fleet permissions, which is why" do
      expect(owner.has_permission?("system.fleet.read")).to be false
      expect(owner.has_permission?("system.fleet.autonomy")).to be false
      expect(owner.has_permission?("system.node_instances.read")).to be false
    end
  end

  # The effective matrix these expectations rest on. Asserted directly, because
  # a static read of Permissions.all_roles DISAGREES with runtime — the
  # extension's catalog grants reach the Role rows separately, so only
  # has_permission? against a real role is authoritative. This is the
  # role-grant vs effective-access conflation that 2e6a9df09/73eecf3e
  # corrected in docs; asserting it here keeps the distinction honest.
  describe "effective permissions by role" do
    it "gives admin the operator fleet permission but not the worker one" do
      expect(admin.has_permission?("system.fleet.read")).to be true
      expect(admin.has_permission?("system.node_instances.read")).to be true
      expect(admin.has_permission?("system.fleet.autonomy")).to be false
    end

    it "gives super_admin everything through system.admin" do
      expect(super_admin.has_permission?("system.fleet.autonomy")).to be true
      expect(super_admin.has_permission?("system.fleet.read")).to be true
    end
  end

  # ── Still a fence ────────────────────────────────────────────────────────
  #
  # Widening to "any authenticated user" would be the wrong fix. A member with
  # no fleet permissions must still be refused, or the gate is decorative.
  describe "a user with no fleet permissions" do
    let(:nobody) { create(:user, account: account, permissions: []) }

    ENDPOINTS.each do |endpoint|
      it "is refused #{endpoint}" do
        expect(reach(endpoint, nobody)).to eq(:refused)
      end
    end
  end

  # ── The permission the endpoints should name ─────────────────────────────
  #
  # The catalog already carries an operator-facing fleet permission next to the
  # worker one (powernode_system/engine.rb:190-193):
  #
  #   system.fleet.autonomy  "Fleet autonomy decision making (worker)"  grant: { system_worker: true }
  #   system.fleet.read      "View fleet / concierge state"             grant: { admin: true }
  #
  # These four endpoints read fleet state; none of them makes an autonomy
  # decision. Pinned so a future edit cannot quietly re-point them at the
  # worker permission, and so the two stay distinguishable.
  describe "the fleet permission catalog" do
    it "defines both a worker-scoped and an operator-scoped fleet permission" do
      expect(::Permissions.all_permissions).to include("system.fleet.autonomy", "system.fleet.read")
    end

    # An undefined permission silently degrades to admin-only, because
    # system.admin short-circuits has_permission? before any lookup. A typo
    # here would look exactly like "only super_admin can reach it".
    it "leaves no fleet permission the controller names undefined" do
      named = File.read(Rails.root.join(
        "../extensions/system/server/app/controllers/api/v1/system/fleet_controller.rb"
      )).scan(/require_permission\("([^"]+)"\)/).flatten.uniq

      expect(named).not_to be_empty
      expect(named - ::Permissions.all_permissions.keys).to be_empty
    end
  end
end
