# frozen_string_literal: true

require "rails_helper"

# APO-3d review finding 6 (IMP-0c10b9fd5596) — the reap's SILENT case.
#
# The reap drops the dead instance's Sdwan::ServiceBackend rows before the
# terminate takes its addresses away. For the NORM, though — a published
# service nobody ever scaled, dialling the instance through its LEGACY
# backend_host column — there are no rows to drop. .remove_instance! honestly
# returns [], the regen is skipped, and the service keeps rendering a router
# pointing at the host the executor has just terminated.
#
# Nothing in the payload said so: an empty removed_sdwan_service_backend_ids
# reads as "no published service routed to this instance". It now reports the
# stranded services by id, so the operator sees the route that outlived its
# backend instead of inferring silence.
RSpec.describe System::Ai::Skills::ReapInstanceExecutor, "stranded legacy routes (APO-3d)",
               type: :service do
  let(:account) { create(:account) }
  let(:node_template) { create(:system_node_template, account: account) }

  let!(:failed) do
    node = create(:system_node, account: account, node_template: node_template)
    create(:system_node_instance, :running, node: node, name: "dead-#{SecureRandom.hex(3)}",
           private_ip_address: "10.0.1.5", cloud_instance_id: "mock-#{SecureRandom.hex(6)}")
  end

  let(:provider) { instance_double(System::Providers::MockProvider, provider_type: "mock") }

  before do
    allow(System::Providers::Registry).to receive(:for_instance).and_return(provider)
    allow(provider).to receive(:terminate_instance).and_return({ success: true })
    allow(::Sdwan::ServiceExposureWriter).to receive(:write!)
      .and_return(output_path: "/tmp/x.yaml", route_count: 1, skipped_service_ids: [],
                  drained_service_ids: [])
  end

  def reap!(operation_id: "op-stranded")
    described_class.new(account: account, agent: nil, user: nil)
                   .execute(gated: true, instance_id: failed.id, operation_id: operation_id)
  end

  it "reports a service whose LEGACY column names the reaped instance and has no member row left" do
    service = create(:sdwan_service, :local_exposed, account: account,
                     backend_host: "10.0.1.5", backend_port: 3000)

    result = reap!

    expect(result[:success]).to be(true), "reap failed: #{result[:error]}"
    expect(result.dig(:data, :removed_sdwan_service_backend_ids)).to eq([])
    expect(result.dig(:data, :stranded_sdwan_service_ids)).to eq([ service.id ])
  end

  it "does NOT call a service stranded while a member row still serves it" do
    service = create(:sdwan_service, :local_exposed, account: account,
                     backend_host: "10.0.1.5", backend_port: 3000)
    survivor = create(:system_node_instance, :running,
                      node: create(:system_node, account: account, node_template: node_template),
                      private_ip_address: "10.0.1.6")
    ::Sdwan::ServiceBackend.add_instance!(service: service, instance: survivor)

    result = reap!

    expect(result[:success]).to be(true), "reap failed: #{result[:error]}"
    expect(result.dig(:data, :removed_sdwan_service_backend_ids).size).to eq(1)
    expect(result.dig(:data, :stranded_sdwan_service_ids)).to eq([])
    expect(service.reload.load_balanced_backends.map(&:address)).to eq([ "10.0.1.6" ])
  end

  it "declares the key it reports, so the catalog and a plan author can see it" do
    expect(described_class.descriptor[:outputs].keys)
      .to include(:stranded_sdwan_service_ids)
  end
end
