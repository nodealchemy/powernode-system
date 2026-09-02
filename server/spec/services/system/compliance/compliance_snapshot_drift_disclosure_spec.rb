# frozen_string_literal: true

require "rails_helper"

# IMP-f28b393916f3 — the compliance snapshot's drift section is an audit-grade
# document, so its drift counts must be readable against a DENOMINATOR. Before
# this, #collect_drift_summary asked the drift question only of `running`
# instances and reported drifted/reconciled with nothing saying that an
# instance wedged in `error` (or mid-`starting`/`stopping`/`rebooting`) had
# been filtered out of the question entirely — the same hidden-filter shape
# IMP-351be1c674e0 fixed in drift_check.
RSpec.describe System::Compliance::ComplianceSnapshotService, "drift disclosure" do
  let(:account)  { create(:account) }
  let(:platform) { create(:system_node_platform, account: account) }
  let(:template) { create(:system_node_template, account: account, node_platform: platform) }
  let(:node)     { create(:system_node, account: account, node_template: template) }
  let(:category) { create(:system_node_module_category, account: account) }
  let(:digest)   { "sha256:#{'a' * 64}" }
  let(:mod) do
    create(:system_node_module, account: account, node_platform: platform,
           category: category, name: "disclosure-mod")
  end

  before do
    version = create(:system_node_module_version, node_module: mod, version_number: 1,
                     oci_digest: digest)
    mod.update!(current_version_id: version.id)
    create(:system_node_module_assignment, node: node, node_module: mod)
  end

  let!(:converged) do
    create(:system_node_instance, :running, node: node, running_module_digests: { mod.id => digest })
  end
  let!(:wedged) do
    create(:system_node_instance, node: node, status: "error", running_module_digests: {})
  end
  let!(:gone) do
    create(:system_node_instance, node: node, status: "terminated", running_module_digests: {})
  end

  subject(:summary) do
    result = described_class.snapshot!(account: account)
    expect(result.ok?).to be true
    result.snapshot[:drift_summary]
  end

  it "carries the non-terminated population as the denominator" do
    expect(summary[:instance_count]).to eq(2)
  end

  it "discloses the instance the drift question was never asked of" do
    expect(summary[:not_assessed_count]).to eq(1)
    expect(summary[:not_assessed_instances])
      .to contain_exactly(hash_including(id: wedged.id, status: "error"))
  end

  it "reports how many instances the drifted/reconciled counts actually cover" do
    expect(summary[:assessed_count]).to eq(1)
    expect(summary[:drifted_count]).to eq(0)
    expect(summary[:reconciled_count]).to eq(1)
  end

  it "keeps a terminated instance out of every bucket" do
    ids = summary[:not_assessed_instances].map { |i| i[:id] }
    expect(ids).not_to include(gone.id)
  end

  # ACTIVE_STATUSES, not `running` — the snapshot and drift_check must answer
  # the same question of the same population, or the audit document and the
  # maintenance verb disagree about the same fleet.
  it "assesses every reporting ACTIVE_STATUSES instance, not only the running ones" do
    stopped = create(:system_node_instance, node: node, status: "stopped",
                     running_module_digests: {}, last_heartbeat_at: 1.hour.ago)
    expect(summary[:assessed_count]).to eq(2)
    expect(summary[:drifted_count]).to eq(1)
    expect(summary[:not_assessed_instances].map { |i| i[:id] }).not_to include(stopped.id)
  end

  # Widening the population to ACTIVE_STATUSES pulls in `pending`/`provisioning`
  # rows that no agent has ever reported for. `running_module_digests` defaults
  # to `{}` NOT NULL, so #module_drift calls every assigned module "missing" for
  # them — that is the column's DEFAULT, not an observation. drift_check draws
  # exactly this line (PlatformMaintenanceExecutor#drift_summary_for splits
  # `reporting, silent = assessable.partition { |i| i.last_heartbeat_at.present? }`),
  # and the audit document must not disagree with it about the same fleet.
  it "does not call a never-reported provisioning instance drifted" do
    silent = create(:system_node_instance, node: node, status: "provisioning",
                    running_module_digests: {}, last_heartbeat_at: nil)

    expect(summary[:drifted_count]).to eq(0)
    expect(summary[:assessed_count]).to eq(1)
    expect(summary[:not_reporting_count]).to eq(1)
    expect(summary[:not_reporting_instances])
      .to contain_exactly(hash_including(id: silent.id, status: "provisioning"))
  end

  # `running` is EXCLUDED from that heartbeat gate on purpose: a live agent that
  # has mounted nothing persists `{}` through #record_heartbeat!, the platform
  # already calls that drift, and spec/services/system/fleet/sensors_spec.rb
  # pins the sensor emitting for exactly that row. Narrowing it here would make
  # the compliance document the one consumer that reported it clean.
  it "still assesses a running instance that has never heartbeated" do
    create(:system_node_instance, :running, node: node,
           running_module_digests: {}, last_heartbeat_at: nil)

    expect(summary[:assessed_count]).to eq(2)
    expect(summary[:drifted_count]).to eq(1)
    expect(summary[:not_reporting_count]).to eq(0)
  end

  # The three buckets and the denominator are only readable together if they
  # actually close: nothing may be counted twice and nothing may fall out.
  it "closes: assessed + not_reporting + not_assessed == instance_count" do
    create(:system_node_instance, node: node, status: "provisioning", running_module_digests: {})
    create(:system_node_instance, node: node, status: "stopped",
           running_module_digests: {}, last_heartbeat_at: 2.hours.ago)

    expect(summary[:assessed_count] + summary[:not_reporting_count] + summary[:not_assessed_count])
      .to eq(summary[:instance_count])
    expect(summary[:drifted_count] + summary[:reconciled_count]).to eq(summary[:assessed_count])
  end
end
