# frozen_string_literal: true

require "rails_helper"

# North-star orchestrator #2 (LOCAL sibling of ExposeServicePubliclyExecutor).
# Resolves-or-creates an Sdwan::Service, flips on its local-exposure facet, and
# regenerates the reverse proxy. The ServiceExposureWriter is stubbed at its
# boundary so the spec asserts the orchestration (create/update + facet + regen)
# rather than YAML rendering (covered by service_exposure_writer_spec).
RSpec.describe System::Ai::Skills::ExposeServiceLocalExecutor do
  let(:account)  { create(:account) }

  # APO-1c (IMP-7e2bdc1774e4). This executor declares `requires_approval: true`,
  # and BaseSkillExecutor#execute now resolves Ai::InterventionPolicy BEFORE
  # #perform — an unconfigured category defaults to require_approval, so every
  # example below would park an approval instead of performing. These examples
  # are about what #perform DOES, so an operator policy puts the gate on its
  # proceed branch rather than removing it: the real entry point still runs.
  # See spec/support/skill_gate_helpers.rb.
  before { auto_execute_skill_policy!(account, described_class) }
  let(:exec)     { described_class.new(account: account) }
  let(:dns_cred) { create(:system_acme_dns_credential, :valid, account: account) }
  let!(:cert) do
    create(:system_acme_certificate, :valid, account: account, dns_credential: dns_cred,
                                             common_name: "apps.example.test")
  end

  before do
    allow(::Sdwan::ServiceExposureWriter).to receive(:write!)
      .and_return(output_path: "/tmp/local-services.yaml", route_count: 1)
  end

  describe ".descriptor" do
    it "advertises inputs, outputs, and approval gating" do
      d = described_class.descriptor
      expect(d[:name]).to eq("expose_service_local")
      expect(d[:category]).to eq("devops")
      expect(d[:requires_approval]).to be true
      expect(d[:inputs].keys).to include(:service_id, :slug, :name, :backend_port, :auth_mode,
                                         :required_permission, :required_group, :strip_prefix, :certificate_id)
      expect(d[:outputs].keys).to include(:service_id, :slug, :local_path, :local_url, :auth_mode, :created)
    end
  end

  describe "#execute — create-and-expose" do
    it "creates a new locally-exposed service and regenerates the proxy" do
      r = exec.execute(slug: "grafana", name: "Grafana", protocol: "https",
                       backend_host: "10.20.0.5", backend_port: 3000, auth_mode: "authenticated")

      expect(r[:success]).to be true
      expect(r.dig(:data, :created)).to be true
      expect(r.dig(:data, :slug)).to eq("grafana")
      expect(r.dig(:data, :local_path)).to eq("/svc/grafana")
      expect(r.dig(:data, :local_url)).to eq("https://apps.example.test/svc/grafana")
      expect(r.dig(:data, :routes_configured)).to eq(1)

      svc = ::Sdwan::Service.find_by(account_id: account.id, slug: "grafana")
      expect(svc.local_enabled).to be true
      expect(svc.local_auth_mode).to eq("authenticated")
      expect(::Sdwan::ServiceExposureWriter).to have_received(:write!).with(account: account)
    end

    it "requires slug, name, and backend_port when creating" do
      r = exec.execute(slug: "grafana")
      expect(r[:success]).to be false
      expect(r[:error]).to match(/requires slug, name, and backend_port/)
    end

    it "requires a backend (vip or host) when creating" do
      r = exec.execute(slug: "grafana", name: "Grafana", backend_port: 3000)
      expect(r[:success]).to be false
      expect(r[:error]).to match(/backend_vip_id or backend_host/)
    end

    it "surfaces the model's reserved-slug validation as a failure" do
      r = exec.execute(slug: "sidekiq", name: "X", backend_host: "h", backend_port: 80)
      expect(r[:success]).to be false
      expect(r[:error]).to match(/reserved/i)
    end

    it "surfaces the model's scoped-requires-permission-or-group validation" do
      r = exec.execute(slug: "scoped-svc", name: "Scoped", backend_host: "h", backend_port: 80,
                       auth_mode: "scoped")
      expect(r[:success]).to be false
      expect(r[:error]).to match(/permission or group/i)
    end
  end

  describe "#execute — expose an existing service" do
    let!(:service) do
      ::Sdwan::Service.create!(account: account, slug: "existing", name: "Existing",
                               protocol: "https", backend_host: "10.0.0.9", backend_port: 8080)
    end

    it "enables local exposure on the existing record (created: false)" do
      r = exec.execute(service_id: service.id, auth_mode: "scoped",
                       required_permission: "services.existing.view")

      expect(r[:success]).to be true
      expect(r.dig(:data, :created)).to be false
      expect(service.reload.local_enabled).to be true
      expect(service.local_auth_mode).to eq("scoped")
      expect(service.local_required_permission).to eq("services.existing.view")
    end

    it "fails clearly when the service_id is unknown / foreign" do
      r = exec.execute(service_id: SecureRandom.uuid)
      expect(r[:success]).to be false
      expect(r[:error]).to match(/not found/)
    end

    it "fails clearly instead of reporting a misleading success when the writer silently " \
       "skipped this service's router (no valid certificate/host resolvable) " \
       "(bug: routes_configured echoed the writer's total-exposed count, not what was actually rendered)" do
      allow(::Sdwan::ServiceExposureWriter).to receive(:write!)
        .and_return(output_path: "/tmp/local-services.yaml", route_count: 0,
                    skipped_service_ids: [ service.id ])

      r = exec.execute(service_id: service.id, auth_mode: "authenticated")

      expect(r[:success]).to be false
      expect(r[:error]).to match(/no valid certificate|host resolvable/i)
      # the facet flip is idempotent and already persisted — a later retry
      # (once a cert exists) picks up from here rather than starting over.
      expect(service.reload.local_enabled).to be true
    end

    # SWEEP-2026-09-03 (carried out of IMP-0c10b9fd5596) — the writer reports a
    # SECOND way a service can be left with no router: every declared backend
    # is draining (`drained_service_ids`, never rendered with an empty
    # `servers` list). #perform read only skipped_service_ids, so a fully
    # drained service fell through to success with a populated local_url.
    it "fails clearly instead of reporting a misleading success when the writer emitted no router " \
       "because every backend is draining" do
      allow(::Sdwan::ServiceExposureWriter).to receive(:write!)
        .and_return(output_path: "/tmp/local-services.yaml", route_count: 0,
                    skipped_service_ids: [], drained_service_ids: [ service.id ])

      r = exec.execute(service_id: service.id, auth_mode: "authenticated")

      expect(r[:success]).to be false
      expect(r[:error]).to match(/draining/i)
      expect(r[:error]).to include("system_set_service_backends")
      expect(service.reload.local_enabled).to be true
    end
  end
end
