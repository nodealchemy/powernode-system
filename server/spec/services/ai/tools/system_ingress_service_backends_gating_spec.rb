# frozen_string_literal: true

require "rails_helper"

# APO-3d (IMP-0c10b9fd5596) — the operator/agent door onto the backend set.
#
# After APO-3c the ONLY way to give a published service a backend set, or to
# set its per-service load-balancer overrides (metadata["load_balancer"]), was
# the rails console. `system_set_service_backends` is that door: DECLARATIVE
# (the list given becomes the set), declared mutating, and GATED through
# Ai::AutonomyGate on its own category via the DeferredToolCall replay seam —
# a backend set decides where every request to a published service goes.
#
# THE ORACLE IS THE ROW, never the response shape (IMP-ce5d320d3e4e shipped a
# guard that refused from the body while the write landed).
RSpec.describe "SystemIngressTool set_service_backends gating (APO-3d)" do
  let(:account) { create(:account) }
  # system.ingress.read is the tool floor Ai::Executors::DeferredToolCall
  # re-asks for before it replays; manage is the per-action permission.
  let(:user) do
    create(:user, account: account, permissions: %w[system.ingress.read system.ingress.manage])
  end
  let(:tool) { Ai::Tools::SystemIngressTool.new(account: account, user: user) }

  let!(:service) do
    create(:sdwan_service, :local_exposed, account: account, backend_host: "10.0.1.5", backend_port: 3000)
  end

  before do
    allow(::Sdwan::ServiceExposureWriter).to receive(:write!)
      .and_return(output_path: "/tmp/x.yaml", route_count: 1, skipped_service_ids: [])
  end

  def set!(**extra)
    tool.execute(params: {
      action: "system_set_service_backends", service_id: service.id,
      backends: [
        { backend_host: "10.0.1.5", backend_port: 3000 },
        { backend_host: "10.0.1.6", backend_port: 3000, weight: 3 }
      ]
    }.merge(extra))
  end

  def latest_deferred
    ::Ai::DeferredOperation.where(account_id: account.id).order(created_at: :desc).first
  end

  describe "the declaration" do
    let(:declaration) { Ai::Tools::SystemIngressTool.declared_action("system_set_service_backends") }

    it "arms the gate through the DeferredToolCall replay seam" do
      expect(declaration).to be_present
      aggregate_failures do
        expect(declaration[:mutating]).to be(true)
        expect(declaration[:action_category]).to eq(Ai::Tools::SystemIngressTool::SERVICE_BACKENDS_CATEGORY)
        expect(declaration[:executor_class]).to eq("Ai::Executors::DeferredToolCall")
        expect(declaration[:gate_context]).to be_present
        expect(declaration[:on_proceed]).to be_present
      end
    end

    it "is advertised, permission-mapped to manage, and announces the gate in its description" do
      defn = Ai::Tools::SystemIngressTool.action_definitions.fetch("system_set_service_backends")

      expect(defn[:parameters].keys).to include(:service_id, :backends, :load_balancer)
      expect(Ai::Tools::SystemIngressTool::ACTION_PERMISSIONS["system_set_service_backends"])
        .to eq("system.ingress.manage")
      expect(defn[:description]).to include(Ai::Tools::SystemIngressTool::SERVICE_BACKENDS_CATEGORY)
      expect(defn[:description]).to match(/pending/i)
    end

    # SWEEP-2026-09-03 (carried out of IMP-0c10b9fd5596) — the category was
    # gated but DECLARED nowhere: without a PolicyDeclarations row the engine's
    # register_categories! never registered it, so the verdict fell to the
    # unmatched default (require_approval — the right answer) while
    # System::AutonomyActions#update rejected every operator edit to it. The
    # control was correct and invisible. Declared beside its ingress siblings.
    it "is declared require_approval beside the ingress rows and registered for the Autonomy modal" do
      category = Ai::Tools::SystemIngressTool::SERVICE_BACKENDS_CATEGORY
      declared = ::System::Governance::PolicyDeclarations::FLEET_AUTONOMY_POLICIES

      expect(declared.fetch(category, nil)).to eq("require_approval"),
        "#{category} is not declared in FLEET_AUTONOMY_POLICIES"
      expect(declared).to include("system.expose_service_local")
      expect(Ai::InterventionPolicy.category_registered?(category)).to be(true)
    end
  end

  describe "an ungated call" do
    it "parks the change instead of writing the set" do
      expect { set! }.to change(::Ai::DeferredOperation, :count).by(1)

      expect(service.reload.backends.count).to eq(0), "the set was written despite the gate"
      expect(latest_deferred.action_category).to eq(Ai::Tools::SystemIngressTool::SERVICE_BACKENDS_CATEGORY)
      expect(latest_deferred.executor_class).to eq("Ai::Executors::DeferredToolCall")
    end

    it "answers with the pending envelope" do
      response = set!

      expect(response[:success]).to be(true)
      expect(response[:data][:pending]).to be(true)
      expect(response[:data][:deferred_operation_id]).to eq(latest_deferred.id)
    end

    it "keeps a malformed payload's own error rather than parking an approval that can only fail" do
      expect { set!(backends: [ { backend_host: "10.0.1.7" } ]) }
        .not_to change(::Ai::DeferredOperation, :count)

      expect(set!(backends: [ { backend_host: "10.0.1.7" } ])[:error]).to match(/backend_port/)
      expect(set!(service_id: SecureRandom.uuid)[:success]).to be(false)
    end

    # A service id is checked against the caller's account (#account_services);
    # a VIP id must be too. Unscoped, a caller with system.ingress.manage in
    # its OWN account could point its own published service at another
    # tenant's VIP address.
    it "refuses a backend VIP from another account, parking nothing" do
      other = create(:account)
      foreign_vip = create(:sdwan_virtual_ip,
                           network: create(:sdwan_network, account: other), account: other)

      response = nil
      expect {
        response = set!(backends: [ { backend_vip_id: foreign_vip.id, backend_port: 3000 } ])
      }.not_to change(::Ai::DeferredOperation, :count)

      expect(response[:success]).to be(false)
      expect(response[:error]).to match(/not found in this account/)
      expect(service.reload.backends.count).to eq(0)
    end

    it "refuses a caller without system.ingress.manage before the gate, parking nothing" do
      reader = create(:user, account: account, permissions: %w[system.ingress.read])
      reader_tool = Ai::Tools::SystemIngressTool.new(account: account, user: reader)

      expect {
        response = reader_tool.execute(params: { action: "system_set_service_backends",
                                                 service_id: service.id,
                                                 backends: [ { backend_host: "10.0.1.6", backend_port: 3000 } ] })
        expect(response[:success]).to be(false)
        expect(response[:error]).to match(/permission denied/)
      }.not_to change(::Ai::DeferredOperation, :count)
    end
  end

  # "It parks" and "the parked operation still does the work" are two claims.
  describe "the approved replay" do
    it "writes the DECLARED set — upserting by address, removing what is absent — and regenerates" do
      stale = ::Sdwan::ServiceBackend.create!(service: service, backend_host: "10.0.1.9", backend_port: 3000)
      set!
      latest_deferred.execute_now!

      rows = service.reload.backends.order(:created_at)
      expect(rows.map { |b| [ b.backend_host, b.backend_port, b.weight, b.status ] })
        .to contain_exactly([ "10.0.1.5", 3000, 1, "active" ], [ "10.0.1.6", 3000, 3, "active" ])
      expect(::Sdwan::ServiceBackend.exists?(stale.id)).to be(false)
      expect(::Sdwan::ServiceExposureWriter).to have_received(:write!).with(account: account)
    end

    it "writes the per-service load-balancer overrides into metadata, nil deleting a key" do
      service.update!(metadata: { "load_balancer" => { "health_check_path" => "/old", "health_check_timeout" => "9s" } })
      set!(load_balancer: { health_check_enabled: true, health_check_path: "/-/ready", health_check_timeout: nil })
      latest_deferred.execute_now!

      expect(service.reload.metadata["load_balancer"])
        .to eq("health_check_enabled" => true, "health_check_path" => "/-/ready")
    end

    it "clears the set back to the legacy single backend when given an empty list" do
      ::Sdwan::ServiceBackend.create!(service: service, backend_host: "10.0.1.9", backend_port: 3000)
      set!(backends: [])
      latest_deferred.execute_now!

      expect(service.reload.backends.count).to eq(0)
      expect(service.load_balanced_backends.map(&:address)).to eq([ "10.0.1.5" ])
    end

    # REVIEW FINDING 1 (IMP-0c10b9fd5596). Draining EVERY member takes the
    # service out of rotation: Sdwan::ServiceExposureWriter skips it and emits
    # no router at all. This verb is the only producer that can reach that
    # state deliberately, so it is the one place a caller can be told — a
    # success envelope indistinguishable from "the set is serving" is the
    # soft-fail-into-success shape the exposure executors guard against.
    it "says the service is OUT OF ROTATION when the declared set is entirely draining" do
      set!(backends: [ { backend_host: "10.0.1.5", backend_port: 3000, status: "draining" } ])
      latest_deferred.execute_now!

      expect(service.reload.fully_drained?).to be(true)
      body = latest_deferred.reload.result.to_h.deep_symbolize_keys
      expect(body.dig(:data, :out_of_rotation)).to be(true)
    end

    it "reports a serving set as IN rotation" do
      set!
      latest_deferred.execute_now!

      body = latest_deferred.reload.result.to_h.deep_symbolize_keys
      expect(body.dig(:data, :out_of_rotation)).to be(false)
    end

    it "returns the set in the tool's own envelope on the proceed branch" do
      set!
      op = latest_deferred
      op.execute_now!

      expect(op.reload.result.to_h.to_s).to include("10.0.1.6")
    end
  end
end
