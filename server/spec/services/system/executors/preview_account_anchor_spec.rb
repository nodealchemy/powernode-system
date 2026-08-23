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
  # IMP-343163bf37a4 — the create/reactivate pair renders the same shape the
  # delete card below is guarded for: a grant holder's EMAIL ADDRESS. Both
  # classes share one label ladder (ReactivateAccessGrant inherits it), so the
  # guard is applied to each surface an operator can actually be shown.
  describe "Sdwan::Executors::CreateAccessGrant / ReactivateAccessGrant" do
    let!(:victim_grant_user) do
      create(:user, account: victim, email: "victim-grantee@example.test")
    end
    let!(:tenant_grant_user) do
      create(:user, account: tenant, email: "tenant-grantee@example.test")
    end

    it "renders bare ids rather than a foreign user's email or network name" do
      preview = card_preview("Sdwan::Executors::CreateAccessGrant", "sdwan.access_grant_create",
                             { network_id: victim_network.id, user_id: victim_grant_user.id })

      expect(preview[:error]).to be_nil
      expect(preview[:summary]).to include(victim_network.id)
      expect(preview[:summary]).not_to include("victim-grantee@example.test")
      expect(preview[:summary]).not_to include("victim-core")
    end

    it "applies the same anchoring to the reactivate card" do
      preview = card_preview("Sdwan::Executors::ReactivateAccessGrant",
                             "sdwan.access_grant_reactivate",
                             { network_id: victim_network.id, user_id: victim_grant_user.id })

      expect(preview[:error]).to be_nil
      expect(preview[:summary]).not_to include("victim-grantee@example.test")
      expect(preview[:summary]).not_to include("victim-core")
    end

    # A foreign USER paired with an IN-ACCOUNT network: the network alone must
    # not license naming, or the anchor is being read off the row it checks.
    it "names neither row when the user and the network disagree on owner" do
      preview = card_preview("Sdwan::Executors::CreateAccessGrant", "sdwan.access_grant_create",
                             { network_id: tenant_network.id, user_id: victim_grant_user.id })

      expect(preview[:error]).to be_nil
      expect(preview[:summary]).not_to include("victim-grantee@example.test")
    end

    it "still names an in-account grantee and network" do # CONTROL
      preview = card_preview("Sdwan::Executors::CreateAccessGrant", "sdwan.access_grant_create",
                             { network_id: tenant_network.id, user_id: tenant_grant_user.id })

      expect(preview[:error]).to be_nil
      expect(preview[:summary]).to eq("Grant SDWAN access to tenant-grantee@example.test on tenant-core")
    end

    it "still names an in-account grantee on the reactivate card" do # CONTROL
      preview = card_preview("Sdwan::Executors::ReactivateAccessGrant",
                             "sdwan.access_grant_reactivate",
                             { network_id: tenant_network.id, user_id: tenant_grant_user.id })

      expect(preview[:error]).to be_nil
      expect(preview[:summary]).to eq(
        "Reinstate SDWAN access for tenant-grantee@example.test on tenant-core"
      )
    end
  end

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

  describe "Sdwan::Executors::DeletePeer" do
    # IMP-ee57d0fbe859 pinned that the update and delete cards for ONE peer
    # name it identically. That invariant went structural-only once
    # IMP-4a5094b22df0 anchored UpdatePeer and left DeletePeer unanchored: the
    # two rendered the same string only while both previews happened to be
    # handed the same anchor. Anchoring both restores it.
    it "renders the bare id rather than a foreign peer's operator label" do
      preview = card_preview("Sdwan::Executors::DeletePeer", "sdwan.peer_delete",
                             { peer_id: victim_peer.id, network_id: victim_network.id })

      expect(preview[:error]).to be_nil
      expect(preview[:summary]).to include(victim_peer.id)
      expect(preview[:summary]).not_to include("victim-edge-01")
      expect(preview[:summary]).not_to include("victim-core")
    end

    it "still names an in-account peer" do # CONTROL
      preview = card_preview("Sdwan::Executors::DeletePeer", "sdwan.peer_delete",
                             { peer_id: tenant_peer.id, network_id: tenant_network.id })

      expect(preview[:error]).to be_nil
      expect(preview[:summary]).to include("tenant-edge-01 on tenant-core")
    end

    it "names the peer exactly as the update card does, on one anchor" do
      params = { peer_id: tenant_peer.id }

      delete_summary = card_preview("Sdwan::Executors::DeletePeer", "sdwan.peer_delete", params)[:summary]
      update_summary = card_preview("Sdwan::Executors::UpdatePeer", "sdwan.peer_update", params)[:summary]

      expect(delete_summary.delete_prefix("Delete SDWAN peer "))
        .to eq(update_summary.delete_prefix("Update SDWAN peer ")),
            "update/delete cards must name the same peer identically"
    end
  end

  describe "Sdwan::Executors::DeleteNetwork" do
    it "renders the bare id rather than a foreign network's name" do
      preview = card_preview("Sdwan::Executors::DeleteNetwork", "sdwan.network_delete",
                             { network_id: victim_network.id })

      expect(preview[:error]).to be_nil
      expect(preview[:summary]).to include(victim_network.id)
      expect(preview[:summary]).not_to include("victim-core")
    end

    it "still names an in-account network" do # CONTROL
      preview = card_preview("Sdwan::Executors::DeleteNetwork", "sdwan.network_delete",
                             { network_id: tenant_network.id })

      expect(preview[:error]).to be_nil
      expect(preview[:summary]).to eq("Delete SDWAN network 'tenant-core'")
    end
  end

  describe "Sdwan::Executors::UpdateFirewallRule" do
    let!(:victim_rule) do
      create(:sdwan_firewall_rule, account: victim, network: victim_network, name: "victim-rule")
    end
    let!(:tenant_rule) do
      create(:sdwan_firewall_rule, account: tenant, network: tenant_network, name: "tenant-rule")
    end

    it "renders the bare id rather than a foreign rule's name and network" do
      preview = card_preview("Sdwan::Executors::UpdateFirewallRule", "sdwan.firewall_rule_update",
                             { rule_id: victim_rule.id, attributes: { enabled: false } })

      expect(preview[:error]).to be_nil
      expect(preview[:summary]).to include(victim_rule.id)
      expect(preview[:summary]).not_to include("victim-rule")
      expect(preview[:summary]).not_to include("victim-core")
    end

    it "still names an in-account rule" do # CONTROL
      preview = card_preview("Sdwan::Executors::UpdateFirewallRule", "sdwan.firewall_rule_update",
                             { rule_id: tenant_rule.id, attributes: { enabled: false } })

      expect(preview[:error]).to be_nil
      expect(preview[:summary]).to eq("Update firewall rule 'tenant-rule' on SDWAN network tenant-core")
    end
  end

  describe "Sdwan::Executors::UpdateVirtualIp" do
    let!(:victim_vip) do
      create(:sdwan_virtual_ip, network: victim_network, name: "victim-vip")
    end
    let!(:tenant_vip) do
      create(:sdwan_virtual_ip, network: tenant_network, name: "tenant-vip")
    end

    it "renders the bare id rather than a foreign VIP's name and network" do
      preview = card_preview("Sdwan::Executors::UpdateVirtualIp", "sdwan.virtual_ip_update",
                             { vip_id: victim_vip.id, attributes: { description: "x" } })

      expect(preview[:error]).to be_nil
      expect(preview[:summary]).to include(victim_vip.id)
      expect(preview[:summary]).not_to include("victim-vip")
      expect(preview[:summary]).not_to include("victim-core")
    end

    it "still names an in-account VIP" do # CONTROL
      preview = card_preview("Sdwan::Executors::UpdateVirtualIp", "sdwan.virtual_ip_update",
                             { vip_id: tenant_vip.id, attributes: { description: "x" } })

      expect(preview[:error]).to be_nil
      expect(preview[:summary]).to eq("Update SDWAN VIP 'tenant-vip' on network tenant-core")
    end
  end

  # Sdwan::UserDevice carries NO account_id of its own, so #scoped_label_record
  # cannot anchor it directly — it returns nil for any model without the
  # column, which would leave every device card, in-account included, naming a
  # bare UUID. The device is reached THROUGH its access grant, which does carry
  # one; the CONTROL example is what distinguishes "anchored" from "anchored so
  # hard it names nothing".
  describe "Sdwan::Executors::RevokeUserDevice" do
    let!(:victim_grant2) { create(:sdwan_access_grant, account: victim, network: victim_network) }
    let!(:victim_dev) { create(:sdwan_user_device, access_grant: victim_grant2, label: "victim-phone") }
    let!(:tenant_grant2) { create(:sdwan_access_grant, account: tenant, network: tenant_network) }
    let!(:tenant_dev) { create(:sdwan_user_device, access_grant: tenant_grant2, label: "tenant-phone") }

    it "renders the bare id rather than a foreign device's label" do
      preview = card_preview("Sdwan::Executors::RevokeUserDevice", "system.sdwan_user_device_revoke",
                             { grant_id: victim_grant2.id, device_id: victim_dev.id })

      expect(preview[:error]).to be_nil
      expect(preview[:summary]).to include(victim_dev.id)
      expect(preview[:summary]).not_to include("victim-phone")
    end

    it "still names an in-account device" do # CONTROL
      preview = card_preview("Sdwan::Executors::RevokeUserDevice", "system.sdwan_user_device_revoke",
                             { grant_id: tenant_grant2.id, device_id: tenant_dev.id })

      expect(preview[:error]).to be_nil
      expect(preview[:summary]).to eq("Revoke SDWAN user device tenant-phone")
    end

    # The request a caller can actually construct: their OWN grant id, plus
    # someone else's device id. The foreign-grant example above cannot reach
    # this — its anchor returns nil and the device lookup never runs — so
    # without this one, reading the device globally once the grant is anchored
    # survives the whole suite.
    it "renders the bare id for a foreign device named against an in-account grant" do
      preview = card_preview("Sdwan::Executors::RevokeUserDevice", "system.sdwan_user_device_revoke",
                             { grant_id: tenant_grant2.id, device_id: victim_dev.id })

      expect(preview[:error]).to be_nil
      expect(preview[:summary]).to include(victim_dev.id)
      expect(preview[:summary]).not_to include("victim-phone")
    end
  end

  describe "System::Executors::InstancePool::DeletePool" do
    def pool_for(account, name)
      ::System::InstancePool.create!(
        account: account,
        node_template: create(:system_node_template, account: account),
        name: name, target_size: 1, min_size: 0, max_size: 2,
        lifecycle_class: "ephemeral", status: "active",
        provider_region: create(:system_provider_region),
        provider_instance_type: create(:system_provider_instance_type)
      )
    end

    let!(:victim_pool) { pool_for(victim, "victim-pool") }
    let!(:tenant_pool) { pool_for(tenant, "tenant-pool") }

    it "renders the bare id rather than a foreign pool's name" do
      preview = card_preview("System::Executors::InstancePool::DeletePool",
                             "system.instance_pool_delete", { pool_id: victim_pool.id })

      expect(preview[:error]).to be_nil
      expect(preview[:summary]).to include(victim_pool.id)
      expect(preview[:summary]).not_to include("victim-pool")
    end

    it "still names an in-account pool" do # CONTROL
      preview = card_preview("System::Executors::InstancePool::DeletePool",
                             "system.instance_pool_delete", { pool_id: tenant_pool.id })

      expect(preview[:error]).to be_nil
      expect(preview[:summary]).to eq("Delete instance pool 'tenant-pool'")
    end
  end

  describe "System::Executors::Runtime::DecommissionK3sCluster" do
    let!(:victim_cluster) { create(:devops_kubernetes_cluster, account: victim, name: "victim-cluster") }
    let!(:tenant_cluster) { create(:devops_kubernetes_cluster, account: tenant, name: "tenant-cluster") }

    it "renders the bare id rather than a foreign cluster's name" do
      preview = card_preview("System::Executors::Runtime::DecommissionK3sCluster",
                             "system.runtime_k8s_cluster_decommission",
                             { cluster_id: victim_cluster.id })

      expect(preview[:error]).to be_nil
      expect(preview[:summary]).to include(victim_cluster.id)
      expect(preview[:summary]).not_to include("victim-cluster")
    end

    it "still names an in-account cluster" do # CONTROL
      preview = card_preview("System::Executors::Runtime::DecommissionK3sCluster",
                             "system.runtime_k8s_cluster_decommission",
                             { cluster_id: tenant_cluster.id })

      expect(preview[:error]).to be_nil
      expect(preview[:summary]).to eq("Decommission K3s cluster 'tenant-cluster'")
    end
  end

  # The three verbs whose label rung is DEAD, so what their card leaks is
  # thinner than a name and still real: EXISTENCE. Each renders
  # `row.try(:<missing method>) || row.id` on the found arm and a bare noun on
  # the not-found arm, so an unanchored lookup answered "a row with this UUID
  # exists somewhere in the platform" — which is why the found/not-found
  # DIFFERENCE is the oracle here, and why (unlike DeleteNetwork/DeletePool/
  # DecommissionK3sCluster) the id is deliberately NOT added to the not-found
  # arm: identical text on both arms would erase the only observable and make
  # the anchoring unverifiable.
  #
  # The dead rungs are a separate defect (offer 01a00899-026d): the
  # controller's `description:` renders `try(:cidr)` where the card renders a
  # UUID, so the two surfaces naming one operation disagree — the thing
  # IMP-ee57d0fbe859 exists to prevent. The respond_to? assertions below are
  # the tripwire: repairing a rung turns these into ordinary name disclosures,
  # and the example fails so the change cannot land without revisiting them.
  describe "the dead-rung verbs (existence is still a disclosure)" do
    let!(:victim_vip2) { create(:sdwan_virtual_ip, network: victim_network, name: "victim-vip2") }
    let!(:tenant_vip2) { create(:sdwan_virtual_ip, network: tenant_network, name: "tenant-vip2") }

    {
      "Sdwan::Executors::DeleteVirtualIp" => [ "sdwan.virtual_ip_delete", "Delete SDWAN VIP" ],
      "Sdwan::Executors::FailoverVirtualIp" => [ "system.sdwan_vip_failover", "Failover VIP" ]
    }.each do |klass, (category, floor)|
      it "#{klass.demodulize} confirms nothing about a foreign VIP's existence" do
        preview = card_preview(klass, category, { vip_id: victim_vip2.id })

        expect(preview[:error]).to be_nil
        expect(preview[:summary]).to eq(floor)
        expect(preview[:summary]).not_to include(victim_vip2.id)
      end

      it "#{klass.demodulize} still identifies an in-account VIP" do # CONTROL
        preview = card_preview(klass, category, { vip_id: tenant_vip2.id })

        expect(preview[:error]).to be_nil
        expect(preview[:summary]).to eq("#{floor} #{tenant_vip2.id}")
      end
    end

    it "pins the dead rung the two VIP verbs rest on" do
      expect(::Sdwan::VirtualIp.new).not_to respond_to(:address),
                                            "the dead label rung was repaired — these cards now disclose a NAME"
    end
  end

  # Latent, and pinned rather than left to the wiring (the CreatePeer
  # precedent). Nothing previews PromotePublication today — its one caller
  # invokes `.execute` directly — but `system.disk_image_publication_promote`
  # is a registered action category with a seeded require_approval policy, so
  # the label is one gate site away from being rendered to approvers. Driven
  # through the executor's own `preview` because there is no operation shape to
  # drive it through yet.
  describe "System::Executors::DiskImage::PromotePublication (latent)" do
    def publication_for(account)
      platform = create(:system_node_platform, account: account)
      create(:system_disk_image_publication, account: account, node_platform: platform)
    end

    let!(:victim_pub) { publication_for(victim) }
    let!(:tenant_pub) { publication_for(tenant) }

    def preview_for(pub, account)
      ::System::Executors::DiskImage::PromotePublication.preview(
        { publication_id: pub.id },
        deferred_operation: ::Ai::DeferredOperation::PreviewContext.new(account)
      )
    end

    it "confirms nothing about a foreign publication's existence" do
      expect(preview_for(victim_pub, tenant)[:summary]).to eq("Promote disk image")
    end

    it "still identifies an in-account publication" do # CONTROL
      expect(preview_for(tenant_pub, tenant)[:summary]).to eq("Promote disk image #{tenant_pub.id} to active")
    end

    it "pins the dead rung this card rests on" do
      expect(::System::DiskImagePublication.new).not_to respond_to(:tag),
                                                       "the dead label rung was repaired — this card now discloses a NAME"
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

    # IMP-343163bf37a4. With no operation there is no supplied-free account, so
    # the anchor can only be a row's own owner CORROBORATED by another row the
    # same request names — CreatePeer's arm 2. Deriving it from the network
    # alone is not an anchor: `network.account_id == anchor` cannot fail when
    # anchor was read off that network, so any caller-supplied id would get its
    # network named. Here the named user belongs to a DIFFERENT account than
    # the named network, so nothing corroborates and neither row is named.
    it "names neither row when the two ids it is given disagree on owner" do
      grantee = create(:user, account: tenant, email: "tenant-grantee@example.test")

      payload = ::Sdwan::Executors::CreateAccessGrant.preview(
        { network_id: victim_network.id, user_id: grantee.id },
        deferred_operation: nil
      )

      expect(payload[:summary]).to include(victim_network.id)
      expect(payload[:summary]).not_to include("victim-core")
      expect(payload[:summary]).not_to include("tenant-grantee@example.test")
    end
  end
end
