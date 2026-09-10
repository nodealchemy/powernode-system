# frozen_string_literal: true

require "rails_helper"

# Campaign 01a08c9b increment B2 — Node as a status component.
RSpec.describe System::Status::Contributors::NodeContributor do
  let(:account)     { create(:account) }
  let(:contributor) { described_class.new }

  def components
    [].tap { |acc| contributor.each_component(account) { |record| acc << record } }
  end

  def condition(record, type)
    contributor.conditions_for(record).find { |c| c["type"] == type }
  end

  def verdict(record)
    Platform::Status::Condition.verdict_for_set(contributor.conditions_for(record))
  end

  # An instance whose provider carries a connection in the given state.
  def instance_with_connection!(node:, connection_status:, enabled: true)
    provider = create(:system_provider, account: account)
    region = create(:system_provider_region, provider: provider)
    create(:system_provider_connection, provider: provider, account: account,
                                        status: connection_status, enabled: enabled)
    create(:system_node_instance, account: account, node: node,
                                  provider_region: region, status: "running")
  end

  describe "scope — nothing is gone for this kind" do
    it "enumerates every node the account has, disabled included" do
      enabled = create(:system_node, account: account, enabled: true)
      disabled = create(:system_node, account: account, enabled: false)

      expect(components.map(&:id)).to match_array([ enabled.id, disabled.id ])
    end

    it "does not enumerate another account's nodes" do
      other = create(:system_node, account: create(:account))

      expect(components.map(&:id)).not_to include(other.id)
    end
  end

  describe "Held reflects the one lifecycle attribute a node has" do
    it "is true with reason Disabled for a disabled node, and the verdict is held" do
      node = create(:system_node, account: account, enabled: false)

      expect(condition(node, "Held")["status"]).to be(true)
      expect(condition(node, "Held")["reason"]).to eq("Disabled")
      expect(verdict(node)).to eq(Platform::ComponentStatus::HELD)
    end

    it "omits the provider question for a disabled node rather than answering unknown" do
      # `unknown` would rank a deliberately disabled node ABOVE a held one and
      # turn operator intent amber.
      node = create(:system_node, account: account, enabled: false)

      expect(condition(node, "ProviderReachable")).to be_nil
    end

    it "is false with reason NotHeld for an enabled node" do
      node = create(:system_node, account: account)

      expect(condition(node, "Held")["status"]).to be(false)
      expect(condition(node, "Held")["reason"]).to eq("NotHeld")
    end
  end

  describe "ProviderReachable maps every ProviderConnection status" do
    it "has a branch for each STATUSES value" do
      expect(described_class::CONNECTION_STATES.keys)
        .to match_array(System::ProviderConnection::STATUSES)
    end

    it "is true when every reachable connection is connected" do
      node = create(:system_node, account: account)
      instance_with_connection!(node: node, connection_status: "connected")

      expect(condition(node, "ProviderReachable")["status"]).to be(true)
      expect(condition(node, "ProviderReachable")["reason"]).to eq("Connected")
      expect(verdict(node)).to eq(Platform::ComponentStatus::OK)
    end

    it "reports a pending connection as observed, not as blindness" do
      node = create(:system_node, account: account)
      instance_with_connection!(node: node, connection_status: "pending")

      reachable = condition(node, "ProviderReachable")

      expect(reachable["status"]).to be(false)
      expect(reachable["reason"]).to eq("ConnectionPending")
      expect(verdict(node)).to eq(Platform::ComponentStatus::DEGRADED)
    end

    it "goes down when every connection errored, and only degrades when some did" do
      all_bad = create(:system_node, account: account)
      instance_with_connection!(node: all_bad, connection_status: "error")

      expect(condition(all_bad, "ProviderReachable")["severity"]).to eq("down")
      expect(verdict(all_bad)).to eq(Platform::ComponentStatus::DOWN)

      mixed = create(:system_node, account: account)
      instance_with_connection!(node: mixed, connection_status: "error")
      instance_with_connection!(node: mixed, connection_status: "connected")

      expect(condition(mixed, "ProviderReachable")["reason"]).to eq("ConnectionErrored")
      expect(condition(mixed, "ProviderReachable")["severity"]).to be_nil
      expect(verdict(mixed)).to eq(Platform::ComponentStatus::DEGRADED)
    end

    it "is unknown when no instance's provider carries a connection" do
      node = create(:system_node, account: account)

      reachable = condition(node, "ProviderReachable")

      expect(reachable["status"]).to eq("unknown")
      expect(reachable["reason"]).to eq("NoProviderConnection")
      expect(verdict(node)).to eq(Platform::ComponentStatus::NOT_MEASURED)
    end

    it "ignores a disabled connection, which is not a failed one" do
      node = create(:system_node, account: account)
      instance_with_connection!(node: node, connection_status: "error", enabled: false)

      expect(condition(node, "ProviderReachable")["reason"]).to eq("NoProviderConnection")
    end

    # A database CHECK constraint (system_provider_connections_status_check)
    # currently makes an out-of-enum value unstorable, so this branch is a guard
    # against a STATUSES addition rather than a state reachable today — the
    # model constant and the constraint have to move together. Asserted by
    # stubbing the read rather than by writing a row the database refuses.
    it "reports an unrecognised connection status as unknown, never ok" do
      node = create(:system_node, account: account)
      instance_with_connection!(node: node, connection_status: "connected")
      allow_any_instance_of(System::ProviderConnection).to receive(:status).and_return("quarantined")

      reachable = condition(node, "ProviderReachable")

      expect(reachable["status"]).to eq("unknown")
      expect(reachable["reason"]).to eq("UnknownStatus")
      expect(Platform::Status::Condition.verdict_for(reachable))
        .to eq(Platform::ComponentStatus::NOT_MEASURED)
    end

    it "lets an unmapped status win over a connected sibling rather than being masked by it" do
      # The precedence half, asserted on the resolver directly: a healthy
      # sibling must not hide a state nobody has mapped.
      expect(contributor.send(:worst_connection_status, %w[connected quarantined]))
        .to eq("quarantined")
      expect(contributor.send(:worst_connection_status, %w[connected error]))
        .to eq("error")
      expect(contributor.send(:worst_connection_status, %w[connected connected]))
        .to eq("connected")
    end
  end

  describe "contract surface" do
    let(:node) { create(:system_node, account: account) }

    it "declares no dependencies, because its instances declare the edge toward it" do
      expect(contributor.dependencies_for(node)).to eq([])
    end

    it "offers no actions, there being no node member route an operator would drive from here" do
      expect(contributor.actions_for(node)).to eq([])
    end

    it "links to the real nodes page" do
      expect(contributor.links_for(node))
        .to eq([ { "label" => "Nodes", "path" => "/app/system/compute/nodes" } ])
    end

    it "uses updated_at as the generation, there being no version column" do
      expect(contributor.observed_generation_for(node)).to eq(node.updated_at.iso8601)
    end

    it "sorts above node_instance and below platform_subsystem" do
      subsystem = System::Status::Contributors::PlatformSubsystemContributor.new
      instance = System::Status::Contributors::NodeInstanceContributor.new

      expect(contributor.presentation["group_order"])
        .to be_between(subsystem.presentation["group_order"] + 1,
                       instance.presentation["group_order"] - 1)
    end
  end
end
