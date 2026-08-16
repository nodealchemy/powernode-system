# frozen_string_literal: true

require "rails_helper"

# IMP-4a5094b22df0 — an approval CARD must never name a row outside the account
# the gated operation belongs to.
#
# Driven through Ai::DeferredOperation#preview, the single production consumer
# of executor previews, and deliberately through a caller that does NOT
# pre-scope the ids it passes. Every live controller pre-scopes today, so an
# end-to-end example through one of them passes with or without the anchor —
# it would pin the controller, not the executor, and the executors are what
# this task makes safe.
#
# source_type/source_id are left unset on purpose: the gate's own anchor
# (Ai::DeferredOperation#assert_source_within_account!) runs inside
# #execute_now! and never on the card path, so omitting it keeps the executor's
# own scoping as the only thing under test.
RSpec.describe "approval-card preview account anchoring" do
  let(:tenant) { create(:account) }
  let(:victim) { create(:account) }

  let!(:victim_network)  { create(:sdwan_network, account: victim, name: "victim-core") }
  let!(:victim_instance) { create(:system_node_instance, account: victim, name: "victim-edge-01") }
  let!(:victim_peer) do
    create(:sdwan_peer, account: victim, network: victim_network, node_instance: victim_instance)
  end

  let!(:tenant_network)  { create(:sdwan_network, account: tenant, name: "tenant-core") }
  let!(:tenant_instance) { create(:system_node_instance, account: tenant, name: "tenant-edge-01") }
  let!(:tenant_peer) do
    create(:sdwan_peer, account: tenant, network: tenant_network, node_instance: tenant_instance)
  end

  def operation_for(executor_class, action_category, params)
    ::Ai::DeferredOperation.create!(
      account: tenant,
      action_category: action_category,
      executor_class: executor_class,
      params: params
    )
  end

  # Returns the whole payload, never just the summary: Ai::DeferredOperation
  # #preview rescues StandardError into { summary: action_category, error: }, so
  # a fix that merely made summarize RAISE would satisfy every "does not name
  # the victim" assertion below. Each example asserts :error is nil first, so
  # absence of the foreign name is evidence of anchoring rather than of a
  # swallowed exception.
  def card_preview(executor_class, action_category, params)
    operation_for(executor_class, action_category, params).preview
  end

  describe "Sdwan::Executors::UpdatePeer" do
    it "renders the bare id rather than a foreign peer's operator label" do
      preview = card_preview("Sdwan::Executors::UpdatePeer", "sdwan.peer_update",
                             { peer_id: victim_peer.id })

      expect(preview[:error]).to be_nil
      expect(preview[:summary]).to include(victim_peer.id)
      expect(preview[:summary]).not_to include("victim-edge-01")
      expect(preview[:summary]).not_to include("victim-core")
    end

    # CONTROL — green before and after. It exists so a fix that anchors by
    # refusing to name ANYTHING cannot pass as a fix.
    it "still names an in-account peer" do
      preview = card_preview("Sdwan::Executors::UpdatePeer", "sdwan.peer_update",
                             { peer_id: tenant_peer.id })

      expect(preview[:error]).to be_nil
      expect(preview[:summary]).to include("tenant-edge-01 on tenant-core")
    end
  end

  describe "Sdwan::Executors::DeleteRoutePolicy" do
    let!(:victim_policy) { create(:sdwan_route_policy, account: victim, name: "victim-policy") }
    let!(:tenant_policy) { create(:sdwan_route_policy, account: tenant, name: "tenant-policy") }

    it "renders the bare id rather than a foreign policy's name" do
      preview = card_preview("Sdwan::Executors::DeleteRoutePolicy", "sdwan.route_policy_delete",
                             { policy_id: victim_policy.id })

      expect(preview[:error]).to be_nil
      expect(preview[:summary]).to include(victim_policy.id)
      expect(preview[:summary]).not_to include("victim-policy")
    end

    it "still names an in-account policy" do # CONTROL
      preview = card_preview("Sdwan::Executors::DeleteRoutePolicy", "sdwan.route_policy_delete",
                             { policy_id: tenant_policy.id })

      expect(preview[:error]).to be_nil
      expect(preview[:summary]).to include("tenant-policy")
    end
  end

  describe "Sdwan::Executors::UpdatePortMapping" do
    let!(:victim_mapping) do
      create(:sdwan_port_mapping, account: victim, network: victim_network, name: "victim-portmap")
    end
    let!(:tenant_mapping) do
      create(:sdwan_port_mapping, account: tenant, network: tenant_network, name: "tenant-portmap")
    end

    it "renders the bare id rather than a foreign mapping's name and network" do
      preview = card_preview("Sdwan::Executors::UpdatePortMapping", "sdwan.port_mapping_update",
                             { mapping_id: victim_mapping.id })

      expect(preview[:error]).to be_nil
      expect(preview[:summary]).to include(victim_mapping.id)
      expect(preview[:summary]).not_to include("victim-portmap")
      expect(preview[:summary]).not_to include("victim-core")
    end

    it "still names an in-account mapping" do # CONTROL
      preview = card_preview("Sdwan::Executors::UpdatePortMapping", "sdwan.port_mapping_update",
                             { mapping_id: tenant_mapping.id })

      expect(preview[:error]).to be_nil
      expect(preview[:summary]).to include("tenant-portmap on tenant-core")
    end
  end

  # The create-shaped pair. Their label was scoped by an account_id the CALLER
  # supplied in params[:attributes] — the one hash `attrs` strips the tenancy
  # keys out of before any write. Both halves of that defect are pinned: a
  # request naming the victim's account must not resolve the victim's network,
  # and an HONEST request (no dispatcher puts account_id in attributes) must
  # stop degrading to a bare UUID now that the operation carries the anchor.
  describe "Sdwan::Executors::CreateFirewallRule" do
    it "ignores a caller-supplied account_id when labelling the network" do
      preview = card_preview(
        "Sdwan::Executors::CreateFirewallRule", "sdwan.firewall_rule_create",
        { network_id: victim_network.id, attributes: { name: "deny-all", account_id: victim.id } }
      )

      expect(preview[:error]).to be_nil
      expect(preview[:summary]).to include(victim_network.id)
      expect(preview[:summary]).not_to include("victim-core")
    end

    it "names the network of an honest in-account request" do
      preview = card_preview(
        "Sdwan::Executors::CreateFirewallRule", "sdwan.firewall_rule_create",
        { network_id: tenant_network.id, attributes: { name: "allow-ssh" } }
      )

      expect(preview[:error]).to be_nil
      expect(preview[:summary]).to eq("Add firewall rule 'allow-ssh' to SDWAN network tenant-core")
    end
  end

  describe "Sdwan::Executors::CreateVirtualIp" do
    it "ignores a caller-supplied account_id when labelling the network" do
      preview = card_preview(
        "Sdwan::Executors::CreateVirtualIp", "sdwan.virtual_ip_create",
        { network_id: victim_network.id, attributes: { name: "vip-a", account_id: victim.id } }
      )

      expect(preview[:error]).to be_nil
      expect(preview[:summary]).to include(victim_network.id)
      expect(preview[:summary]).not_to include("victim-core")
    end

    it "names the network of an honest in-account request" do
      preview = card_preview(
        "Sdwan::Executors::CreateVirtualIp", "sdwan.virtual_ip_create",
        { network_id: tenant_network.id, attributes: { name: "vip-a" } }
      )

      expect(preview[:error]).to be_nil
      expect(preview[:summary]).to eq("Allocate SDWAN VIP 'vip-a' on network tenant-core")
    end
  end

  # The residual IMP-97bb6231a322 narrowed but could not close: CreatePeer's
  # corroboration fallback names a network and a node instance whenever the two
  # agree on an owner, and two ids from the SAME victim agree. Threading the
  # operation is what closes it — the operation's account answers first, so the
  # corroboration arm never runs. Latent either way (peer creation has no gated
  # dispatcher yet), which is why it is pinned rather than left to the wiring.
  describe "Sdwan::Executors::CreatePeer" do
    it "names neither row when both ids are corroborated but foreign" do
      preview = card_preview(
        "Sdwan::Executors::CreatePeer", "sdwan.peer_create",
        { network_id: victim_network.id, attributes: { node_instance_id: victim_instance.id } }
      )

      expect(preview[:error]).to be_nil
      expect(preview[:summary]).not_to include("victim-edge-01")
      expect(preview[:summary]).not_to include("victim-core")
    end

    it "still names an in-account peer create" do # CONTROL
      preview = card_preview(
        "Sdwan::Executors::CreatePeer", "sdwan.peer_create",
        { network_id: tenant_network.id, attributes: { node_instance_id: tenant_instance.id } }
      )

      expect(preview[:error]).to be_nil
      expect(preview[:summary]).to eq("Add SDWAN peer tenant-edge-01 on tenant-core")
    end
  end

  # IMP-8e4674f4d62d — the follow-on sweep base.rb's #scoped_label_record
  # docstring names. Same mechanism, same oracle: drive Ai::DeferredOperation
  # #preview through a caller that does NOT pre-scope its ids.
  #
  # DeleteAccessGrant is first and separate because what its card names is not a
  # resource name but a USER'S EMAIL ADDRESS — a cross-account disclosure of
  # personal data rather than a label bug. Its impact line discloses a second
  # fact, the foreign grant's device count, and is asserted separately: a fix
  # that anchored only the summary would leave a working oracle for "how many
  # VPN devices does that other account's grant have".
  describe "Sdwan::Executors::DeleteAccessGrant" do
    let!(:victim_user) { create(:user, account: victim, email: "victim-operator@example.test") }
    let!(:victim_grant) do
      create(:sdwan_access_grant, account: victim, network: victim_network, user: victim_user)
    end
    let!(:victim_devices) { create_list(:sdwan_user_device, 2, access_grant: victim_grant) }

    let!(:tenant_user) { create(:user, account: tenant, email: "tenant-operator@example.test") }
    let!(:tenant_grant) do
      create(:sdwan_access_grant, account: tenant, network: tenant_network, user: tenant_user)
    end
    let!(:tenant_device) { create(:sdwan_user_device, access_grant: tenant_grant) }

    it "renders the bare id rather than a foreign grant holder's email address" do
      preview = card_preview("Sdwan::Executors::DeleteAccessGrant", "sdwan.access_grant_delete",
                             { network_id: victim_network.id, grant_id: victim_grant.id })

      expect(preview[:error]).to be_nil
      expect(preview[:summary]).to include(victim_grant.id)
      expect(preview[:summary]).not_to include("victim-operator@example.test")
    end

    it "does not disclose a foreign grant's device count in the impact line" do
      preview = card_preview("Sdwan::Executors::DeleteAccessGrant", "sdwan.access_grant_delete",
                             { network_id: victim_network.id, grant_id: victim_grant.id })

      expect(preview[:error]).to be_nil
      expect(preview[:impact]).to eq("Destroys the access grant and every VPN device beneath it")
      expect(preview[:impact]).not_to include("2 device")
    end

    it "still names an in-account grant and counts its devices" do # CONTROL
      preview = card_preview("Sdwan::Executors::DeleteAccessGrant", "sdwan.access_grant_delete",
                             { network_id: tenant_network.id, grant_id: tenant_grant.id })

      expect(preview[:error]).to be_nil
      expect(preview[:summary]).to eq("Delete SDWAN access grant tenant-operator@example.test")
      expect(preview[:impact]).to include("1 device")
    end

    # The network/grant pairing #scoped_grant re-validates is a SECOND guard,
    # not the same one: it refuses a grant that has moved network since the
    # operation was parked. Anchoring must not cost it — an in-account grant
    # named against the wrong in-account network still declines to be labelled.
    it "keeps refusing to name an in-account grant on a different network" do
      other_network = create(:sdwan_network, account: tenant, name: "tenant-spare")

      preview = card_preview("Sdwan::Executors::DeleteAccessGrant", "sdwan.access_grant_delete",
                             { network_id: other_network.id, grant_id: tenant_grant.id })

      expect(preview[:error]).to be_nil
      expect(preview[:summary]).not_to include("tenant-operator@example.test")
      expect(preview[:impact]).to eq("Destroys the access grant and every VPN device beneath it")
    end
  end

  # The behavioural examples above are all satisfiable by a hand-written
  # `find_by(id:, account_id:)` per executor, or by a post-filter that reads the
  # row unscoped and then discards it. The property the task actually buys is
  # that the card path issues NO unscoped lookup of the row it is about to name
  # — which is a statement about the SQL, not about one pair of ids, and holds
  # for any id the caller supplies.
  describe "structurally: the card path never reads the labelled row unscoped" do
    it "puts an account_id predicate on every SELECT of the labelled table" do
      operation = operation_for("Sdwan::Executors::UpdatePeer", "sdwan.peer_update",
                                { peer_id: victim_peer.id })

      statements = []
      subscription = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
        statements << payload[:sql].to_s
      end
      begin
        operation.preview
      ensure
        ActiveSupport::Notifications.unsubscribe(subscription)
      end

      peer_reads = statements.select do |sql|
        sql.start_with?("SELECT") && sql.include?('FROM "system_sdwan_peers"')
      end

      # Not vacuous: an implementation that stopped looking the row up at all
      # would satisfy `all(...)` over an empty list.
      expect(peer_reads).not_to be_empty
      # On the PREDICATE, not merely on the string: `account_id` appearing in a
      # projection or an ORDER BY is not a scope, and a bare `include` check
      # would accept both.
      expect(peer_reads).to all(match(/WHERE.*account_id/m))
    end
  end

  # base.rb's resolve_scoped docstring names Base.preview as a deliberate
  # nil-account caller — the pre-gate path, where a surface previews before any
  # DeferredOperation exists. That contract is load-bearing and survives: the
  # keyword is optional, one positional argument still works, and nothing
  # raises. What changes is the posture, not the reachability — with no account
  # to anchor on the label degrades to the id rather than naming a row whose
  # owner nobody has established.
  describe "pre-gate preview with no operation (the nil-account contract)" do
    it "accepts a single positional argument and renders a payload" do
      payload = ::Sdwan::Executors::UpdatePeer.preview({ peer_id: tenant_peer.id })

      expect(payload).to include(:summary, :impact)
      expect(payload[:summary]).to include(tenant_peer.id)
      expect(payload[:summary]).not_to include("tenant-edge-01")
    end

    it "accepts an explicit nil for the operation" do
      payload = ::Sdwan::Executors::UpdatePeer.preview({ peer_id: tenant_peer.id },
                                                       deferred_operation: nil)

      expect(payload[:summary]).to include(tenant_peer.id)
    end
  end
end
