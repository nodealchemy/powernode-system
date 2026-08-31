# frozen_string_literal: true

require "rails_helper"

# IMP-0d106a152c47 — `drift_check` answered every deployment "healthy"
# unconditionally: PlatformMaintenanceExecutor#instance_drifted? was the
# literal `false` behind a comment describing a detector it never called.
#
# The oracle that matters is the DRIFTED case. A spec that only exercises a
# healthy deployment passes against the literal `false`, which is exactly how
# the stub survived — so the drifted example comes first here, and the healthy
# example is its converse (a fix hardcoded to `true` must fail too).
RSpec.describe System::Ai::Skills::PlatformMaintenanceExecutor do
  let(:account) { create(:account) }
  let(:user) { create(:user, account: account) }
  let(:node_platform) { create(:system_node_platform, account: account) }
  let(:template) { create(:system_node_template, account: account, node_platform: node_platform) }
  let(:deployment) { create(:system_platform_deployment, account: account, node_template: template) }
  let(:executor) { described_class.new(account: account, user: user) }

  # An assigned module whose CURRENT version carries `want_digest` — the digest
  # an instance of this template is supposed to be running.
  def assign_module(node, want_digest:)
    node_module = create(:system_node_module, account: account, node_platform: node_platform)
    version = create(:system_node_module_version, node_module: node_module, oci_digest: want_digest)
    node_module.update!(current_version: version)
    create(:system_node_module_assignment, node: node, node_module: node_module)
    node_module
  end

  # `running_digests` is the agent heartbeat's node_module_id => mounted digest
  # map. `:matching` builds the healthy map from the assignment itself.
  def instance_on_template(want_digest:, running:)
    node = create(:system_node, account: account, node_template: template)
    node_module = assign_module(node, want_digest: want_digest)
    digests = running == :matching ? { node_module.id.to_s => want_digest } : running
    create(:system_node_instance, :running, node: node, running_module_digests: digests,
           last_heartbeat_at: 1.minute.ago)
  end

  def drift_check
    executor.execute(action: "drift_check", deployment_id: deployment.id)
  end

  def deployment_row(result)
    result[:data][:data][:deployments].find { |d| d[:deployment_id] == deployment.id }
  end

  describe "drift_check" do
    it "reports an instance running a stale module digest as drifted" do
      instance = instance_on_template(want_digest: "sha256:want", running: :matching)
      instance.update!(running_module_digests: instance.running_module_digests.transform_values { "sha256:stale" })

      row = deployment_row(drift_check)

      expect(row[:drift_count]).to eq(1)
      expect(row[:drifted_instances].map { |i| i[:id] }).to eq([ instance.id ])
    end

    it "reports an instance missing an assigned module as drifted" do
      instance = instance_on_template(want_digest: "sha256:want", running: :matching)
      other_module = create(:system_node_module, account: account, node_platform: node_platform)
      other_version = create(:system_node_module_version, node_module: other_module, oci_digest: "sha256:second")
      other_module.update!(current_version: other_version)
      create(:system_node_module_assignment, node: instance.node, node_module: other_module)

      row = deployment_row(drift_check)

      expect(row[:drift_count]).to eq(1)
      expect(row[:drifted_instances].map { |i| i[:id] }).to eq([ instance.id ])
    end

    it "reports an instance mounting a module it is no longer assigned as drifted" do
      instance = instance_on_template(want_digest: "sha256:want", running: :matching)
      instance.update!(running_module_digests: instance.running_module_digests.merge(
        SecureRandom.uuid => "sha256:orphan"
      ))

      row = deployment_row(drift_check)

      expect(row[:drift_count]).to eq(1)
      expect(row[:drifted_instances].first[:drift][:extra].values).to eq([ "sha256:orphan" ])
    end

    it "carries the per-instance drift detail the operator docs tell you to read" do
      instance = instance_on_template(want_digest: "sha256:want", running: :matching)
      node_module_id = instance.node.node_modules.first.id
      instance.update!(running_module_digests: { node_module_id.to_s => "sha256:stale" })

      detail = deployment_row(drift_check)[:drifted_instances].first[:drift]

      expect(detail[:mismatched]).to eq(node_module_id => { want: "sha256:want", have: "sha256:stale" })
      expect(detail[:missing]).to be_empty
      expect(detail[:extra]).to be_empty
    end

    it "does NOT report an instance running exactly its assigned digests as drifted" do
      instance_on_template(want_digest: "sha256:want", running: :matching)

      row = deployment_row(drift_check)

      expect(row[:drift_count]).to eq(0)
      expect(row[:drifted_instances]).to be_empty
      # Guards the converse of the not_reporting bucket: a healthy REPORTING
      # instance must not be parked there either.
      expect(row[:not_reporting_count]).to eq(0)
    end

    # The regression this bucket must never become: #record_heartbeat! writes
    # running_module_digests unconditionally, so a live agent that has mounted
    # nothing persists `{}`. ModuleDriftSensor and system_drift_report both call
    # that drift; keying the bucket off an empty map rather than
    # last_heartbeat_at would have made drift_check the one consumer that
    # reported it clean.
    it "counts a HEARTBEATED instance reporting no digests as drifted, not unknown" do
      node = create(:system_node, account: account, node_template: template)
      assign_module(node, want_digest: "sha256:want")
      instance = create(:system_node_instance, :running, node: node,
                        running_module_digests: {}, last_heartbeat_at: 1.minute.ago)

      row = deployment_row(drift_check)

      expect(row[:not_reporting_count]).to eq(0)
      expect(row[:drift_count]).to eq(1)
      expect(row[:drifted_instances].map { |i| i[:id] }).to eq([ instance.id ])
    end

    it "reports an instance that has NEVER HEARTBEATED as UNKNOWN, not clear" do
      node = create(:system_node, account: account, node_template: template)
      assign_module(node, want_digest: "sha256:want")
      silent = create(:system_node_instance, node: node, status: "provisioning",
                      running_module_digests: {}, last_heartbeat_at: nil)

      result = drift_check
      row = deployment_row(result)

      expect(row[:drift_count]).to eq(0)
      expect(row[:not_reporting_count]).to eq(1)
      expect(row[:not_reporting_instances].map { |i| i[:id] }).to eq([ silent.id ])
      expect(result[:data][:recommendations].join(" ")).to include("never heartbeated")
      expect(result[:data][:recommendations].join(" ")).not_to include("nothing to remediate")
    end

    it "recommends remediation when drift is present and reassures only when it is not" do
      drifted = instance_on_template(want_digest: "sha256:want", running: :matching)
      drifted.update!(running_module_digests: { drifted.node.node_modules.first.id.to_s => "sha256:stale" })

      expect(drift_check[:data][:recommendations].join(" ")).to include("drifted from their assigned modules")

      drifted.update!(running_module_digests: { drifted.node.node_modules.first.id.to_s => "sha256:want" })

      expect(drift_check[:data][:recommendations].join(" ")).to include("nothing to remediate")
    end
  end
end
