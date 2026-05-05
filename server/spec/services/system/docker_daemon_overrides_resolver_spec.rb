# frozen_string_literal: true

require "rails_helper"

RSpec.describe System::DockerDaemonOverridesResolver, type: :service do
  let(:account) { create(:account) }
  let(:node) { create(:system_node, account: account) }
  let(:node_instance) { create(:system_node_instance, node: node) }

  # Base subscription module that operators attach docker overrides to.
  let!(:docker_module) do
    System::NodeModule.create!(
      account: account,
      name: "docker-engine",
      variety: "subscription",
      enabled: true
    )
  end

  # Module assignment so the resolver's `docker_engine_assigned?` check passes.
  let!(:docker_assignment) do
    ::System::NodeModuleAssignment.create!(
      node_id: node.id,
      node_module_id: docker_module.id,
      enabled: true
    )
  end

  describe ".resolve" do
    context "when no dependant config-variety modules exist" do
      it "returns an empty hash" do
        expect(described_class.resolve(node_instance: node_instance)).to eq({})
      end
    end

    context "when the docker-engine module is not assigned" do
      before { docker_assignment.update!(enabled: false) }

      it "returns an empty hash regardless of dependant overrides" do
        System::NodeModule.create!(
          account: account,
          name: "docker-overrides-orphan",
          variety: "config",
          enabled: true,
          parent_module: docker_module,
          node_instance: node_instance,
          config: { "daemon_overrides" => { "log-driver" => "journald" } }
        )

        expect(described_class.resolve(node_instance: node_instance)).to eq({})
      end
    end

    context "with a single instance-scoped dependant" do
      before do
        System::NodeModule.create!(
          account: account,
          name: "docker-overrides-prod",
          variety: "config",
          enabled: true,
          parent_module: docker_module,
          node_instance: node_instance,
          config: {
            "daemon_overrides" => {
              "log-driver" => "journald",
              "registry-mirrors" => ["https://mirror.gcr.io"]
            }
          }
        )
      end

      it "returns the merged overrides" do
        result = described_class.resolve(node_instance: node_instance)
        expect(result["log-driver"]).to eq("journald")
        expect(result["registry-mirrors"]).to eq(["https://mirror.gcr.io"])
      end
    end

    context "with both node-scoped and instance-scoped dependants" do
      before do
        # Node-scoped (lower priority) — applies to all instances on this node.
        System::NodeModule.create!(
          account: account,
          name: "docker-overrides-node",
          variety: "config",
          enabled: true,
          parent_module: docker_module,
          node: node,
          priority: 100,
          config: {
            "daemon_overrides" => {
              "log-driver" => "json-file",
              "log-opts" => { "max-size" => "10m" }
            }
          }
        )

        # Instance-scoped (higher priority) — overrides on this specific instance.
        System::NodeModule.create!(
          account: account,
          name: "docker-overrides-instance",
          variety: "config",
          enabled: true,
          parent_module: docker_module,
          node_instance: node_instance,
          priority: 200,
          config: {
            "daemon_overrides" => {
              "log-driver" => "journald", # overrides node-level
              "log-opts" => { "max-file" => "5" }, # deep-merge with node-level
              "debug" => true
            }
          }
        )
      end

      it "instance-level overrides node-level on conflicting top-level keys" do
        result = described_class.resolve(node_instance: node_instance)
        expect(result["log-driver"]).to eq("journald")
      end

      it "deep-merges nested hashes from both levels" do
        result = described_class.resolve(node_instance: node_instance)
        expect(result["log-opts"]).to eq({ "max-size" => "10m", "max-file" => "5" })
      end

      it "includes keys present at only one level" do
        result = described_class.resolve(node_instance: node_instance)
        expect(result["debug"]).to be true
      end
    end

    context "with operator attempts to override platform-managed keys" do
      before do
        System::NodeModule.create!(
          account: account,
          name: "docker-overrides-malicious",
          variety: "config",
          enabled: true,
          parent_module: docker_module,
          node_instance: node_instance,
          config: {
            "daemon_overrides" => {
              "tls" => false,
              "tlsverify" => false,
              "tlscacert" => "/tmp/attacker-ca.pem",
              "hosts" => ["tcp://0.0.0.0:2375"],
              # legitimate key — must still apply
              "log-driver" => "syslog"
            }
          }
        )
      end

      it "strips blocked keys (tls/tlsverify/tlscacert/tlskey/hosts)" do
        result = described_class.resolve(node_instance: node_instance)
        described_class::BLOCKED_KEYS.each do |key|
          expect(result).not_to have_key(key), "blocked key #{key} not stripped"
        end
      end

      it "keeps non-blocked operator keys" do
        result = described_class.resolve(node_instance: node_instance)
        expect(result["log-driver"]).to eq("syslog")
      end

      it "logs the stripped keys" do
        expect(Rails.logger).to receive(:warn).with(/dropped operator-supplied keys/)
        described_class.resolve(node_instance: node_instance)
      end
    end

    context "with disabled dependant modules" do
      before do
        System::NodeModule.create!(
          account: account,
          name: "docker-overrides-disabled",
          variety: "config",
          enabled: false,
          parent_module: docker_module,
          node_instance: node_instance,
          config: { "daemon_overrides" => { "log-driver" => "should-be-skipped" } }
        )
      end

      it "ignores disabled modules" do
        expect(described_class.resolve(node_instance: node_instance)).to eq({})
      end
    end

    context "with non-config-variety dependants of docker-engine" do
      before do
        System::NodeModule.create!(
          account: account,
          name: "docker-instance-non-config",
          variety: "instance",
          enabled: true,
          parent_module: docker_module,
          node_instance: node_instance,
          config: { "daemon_overrides" => { "log-driver" => "should-not-apply" } }
        )
      end

      it "ignores non-config-variety dependants (only config variety carries overrides)" do
        result = described_class.resolve(node_instance: node_instance)
        expect(result).to eq({})
      end
    end

    context "with a dependant whose config has no daemon_overrides key" do
      before do
        System::NodeModule.create!(
          account: account,
          name: "docker-config-empty",
          variety: "config",
          enabled: true,
          parent_module: docker_module,
          node_instance: node_instance,
          config: { "other_key" => "value" }
        )
      end

      it "skips silently and returns empty" do
        expect(described_class.resolve(node_instance: node_instance)).to eq({})
      end
    end

    context "deep merge semantics" do
      it "arrays in overlay REPLACE arrays in base (not concat)" do
        System::NodeModule.create!(
          account: account, name: "node-mirrors", variety: "config", enabled: true,
          parent_module: docker_module, node: node, priority: 100,
          config: { "daemon_overrides" => { "registry-mirrors" => ["https://node-mirror.io"] } }
        )
        System::NodeModule.create!(
          account: account, name: "instance-mirrors", variety: "config", enabled: true,
          parent_module: docker_module, node_instance: node_instance, priority: 200,
          config: { "daemon_overrides" => { "registry-mirrors" => ["https://instance-mirror.io"] } }
        )

        result = described_class.resolve(node_instance: node_instance)
        # Higher-priority instance wins — array replaced, not merged
        expect(result["registry-mirrors"]).to eq(["https://instance-mirror.io"])
      end
    end
  end
end
