# frozen_string_literal: true

require "rails_helper"

# IMP-156eb1a7bdbc — caller-facing error disclosure sweep.
#
# Every rescue arm below builds an entry that is part of the executor's
# RETURNED result (a `failures` / `errors` list the caller — an MCP tool, the
# composition runner, the model provider — reads back). Each one used to carry
# the raised exception's raw text (e.message, or a model's full_messages).
# The contract pinned here, per site: an exception carrying a MARKER string is
# raised from the collaborator, and the marker must appear nowhere in the
# result. The entry keeps a fixed, classified message (BaseSkillExecutor
# #safe_error_text) plus the exception's class under its own key; the raw
# text goes to the log only.
RSpec.describe "Skill executors: caller-facing error text (IMP-156eb1a7bdbc)" do
  let(:account) { create(:account) }
  let(:marker)  { "MARKER-156eb1 internal detail /var/lib/secret-path" }
  let(:generic) { ::Ai::Tools::BaseTool::DISPATCH_FALLBACK_GENERIC_MESSAGE }

  def deep_values(obj)
    case obj
    when Hash  then obj.flat_map { |k, v| [ k.to_s ] + deep_values(v) }
    when Array then obj.flat_map { |v| deep_values(v) }
    else [ obj.to_s ]
    end
  end

  def expect_withheld(result)
    leaked = deep_values(result).select { |v| v.include?("MARKER-156eb1") }
    expect(leaked).to be_empty, "raw exception text reached the caller: #{leaked.inspect}"
  end

  def error_of(entry)
    entry[:error] || entry["error"]
  end

  def error_class_of(entry)
    entry[:error_class] || entry["error_class"]
  end

  describe System::Ai::Skills::ScaleProjectExecutor do
    let(:exec) { described_class.new(account: account) }

    it "withholds the text of a failed service-backend join" do
      svc = double("Sdwan::Service", id: SecureRandom.uuid, slug: "web",
                                     backends: double(pluck: [], reload: double(pluck: [])))
      instance = instance_double("System::NodeInstance", id: SecureRandom.uuid)
      allow(exec).to receive(:mission_services).and_return([ svc ])
      allow(::System::NodeInstance).to receive(:where).and_return([ instance ])
      allow(::Sdwan::ServiceBackend).to receive(:add_instance!).and_raise(StandardError, marker)

      result = exec.send(:join_service_backends, mission: double, new_instance_ids: [ instance.id ], dry_run: false)

      expect_withheld(result)
      entry = result[:failures].first
      expect(entry).to include(step: "join_service_backends", service_id: svc.id)
      expect(error_of(entry)).to eq(generic)
      expect(error_class_of(entry)).to eq("StandardError")
    end

    it "withholds a ServiceExposureWriter::WriteError's text" do
      allow(::Sdwan::ServiceExposureWriter).to receive(:write!)
        .and_raise(::Sdwan::ServiceExposureWriter::WriteError, marker)
      failures = []

      exec.send(:regen_service_exposure!, failures)

      expect_withheld(failures)
      expect(failures.first).to include(step: "regenerate_service_exposure")
      expect(error_of(failures.first)).to eq(generic)
      expect(error_class_of(failures.first)).to eq("Sdwan::ServiceExposureWriter::WriteError")
    end

    it "withholds the text of a raising volume delete, instance terminate and backend leave in teardown" do
      volume_id = SecureRandom.uuid
      instance_id = SecureRandom.uuid
      volume = instance_double("System::ProviderVolume", id: volume_id, attached?: false)
      instance = instance_double("System::NodeInstance", id: instance_id)
      allow(::System::ProviderVolume).to receive(:find_by).with(id: volume_id).and_return(volume)
      allow(::System::NodeInstance).to receive(:find_by).with(id: instance_id).and_return(instance)
      allow(::System::VolumeManagementService).to receive(:delete).and_raise(StandardError, marker)
      allow(::Sdwan::ServiceBackend).to receive(:host_routed_services).and_raise(StandardError, marker)
      allow(::System::ProvisioningService).to receive(:terminate_instance).and_raise(StandardError, marker)

      result = exec.rollback_scale_project(node_instance_ids: [ instance_id ], storage_volume_ids: [ volume_id ])

      expect(result[:success]).to be false
      expect_withheld(result)
      expect(result[:errors].map { |e| e[:resource] })
        .to contain_exactly("provider_volume", "sdwan_service_backend", "node_instance")
      expect(result[:errors].map { |e| error_of(e) }.uniq).to eq([ generic ])
      expect(result[:errors].map { |e| error_class_of(e) }.uniq).to eq([ "StandardError" ])
    end
  end

  describe System::Ai::Skills::ReplaceInstanceExecutor do
    let(:exec) { described_class.new(account: account) }

    it "withholds the text of a raising peer enrolment" do
      network = double("Sdwan::Network", id: SecureRandom.uuid)
      peer = double("Sdwan::Peer", id: SecureRandom.uuid, network: network)
      replacement = instance_double("System::NodeInstance", id: SecureRandom.uuid)
      allow(::Sdwan::Peer).to receive(:find_by).and_return(nil)
      allow(exec).to receive(:inherited_peer_attributes).and_return({})
      allow(::Sdwan::PeerEnroller).to receive(:call).and_raise(StandardError, marker)

      _enrolled, errors = exec.send(:reenrol_sdwan!, peers: [ peer ], replacement: replacement)

      expect_withheld(errors)
      expect(errors.first).to include("step" => "enrol_peer", "previous_peer_id" => peer.id)
      expect(error_of(errors.first)).to eq(generic)
      expect(error_class_of(errors.first)).to eq("StandardError")
    end

    it "withholds a VIP's validation messages, naming only the failing attributes" do
      old_peer = SecureRandom.uuid
      new_peer = SecureRandom.uuid
      vip = ::Sdwan::VirtualIp.new(id: SecureRandom.uuid, holder_peer_ids: [ old_peer ],
                                   failover_holder_peer_ids: [])
      # Approach-agnostic: whichever of save / save! the executor uses, the
      # record fails validation with the marker in its full_messages.
      allow(vip).to receive(:save) { vip.errors.add(:cidr, marker) && false }
      allow(vip).to receive(:save!) do
        vip.errors.add(:cidr, marker)
        raise ActiveRecord::RecordInvalid, vip
      end
      relation = double("relation")
      allow(relation).to receive(:find_each).and_yield(vip)
      allow(::Sdwan::VirtualIp).to receive(:where).and_return(relation)

      _moved, errors = exec.send(:move_vips!, peer_map: { old_peer => new_peer })

      expect_withheld(errors)
      expect(errors.first).to include("step" => "move_vip", "virtual_ip_id" => vip.id)
      expect(error_of(errors.first)).to eq("Validation failed: cidr")
    end

    it "withholds the text of a raising backend re-home and a WriteError" do
      svc = double("Sdwan::Service", id: SecureRandom.uuid)
      failed = instance_double("System::NodeInstance", id: SecureRandom.uuid)
      replacement = instance_double("System::NodeInstance", id: SecureRandom.uuid)
      other = double("Sdwan::Service", id: SecureRandom.uuid)
      allow(::Sdwan::ServiceBackend).to receive(:host_routed_services).and_return([ svc, other ])
      allow(::Sdwan::ServiceBackend).to receive(:add_instance!) do |service:, instance:|
        raise StandardError, marker if service == svc

        instance
      end
      allow(::Sdwan::ServiceBackend).to receive(:drain_instance!)
      allow(::Sdwan::ServiceExposureWriter).to receive(:write!)
        .and_raise(::Sdwan::ServiceExposureWriter::WriteError, marker)

      rehomed, errors = exec.send(:rehome_service_backends!, failed: failed, replacement: replacement)

      expect(rehomed).to eq([ other.id ])
      expect_withheld(errors)
      expect(errors.map { |e| e["step"] }).to eq(%w[rehome_service_backends regenerate_service_exposure])
      expect(errors.map { |e| error_of(e) }.uniq).to eq([ generic ])
      expect(errors.map { |e| error_class_of(e) })
        .to eq([ "StandardError", "Sdwan::ServiceExposureWriter::WriteError" ])
    end
  end

  describe System::Ai::Skills::ProvisionClusterExecutor do
    let(:exec) { described_class.new(account: account) }

    it "withholds the text of a raising terminate in rollback" do
      instance_id = SecureRandom.uuid
      instance = instance_double("System::NodeInstance", id: instance_id)
      allow(::System::NodeInstance).to receive(:find_by).with(id: instance_id).and_return(instance)
      allow(::System::ProvisioningService).to receive(:terminate_instance).and_raise(StandardError, marker)

      result = exec.rollback_provision_cluster(node_instance_ids: [ instance_id ])

      expect(result[:success]).to be false
      expect_withheld(result)
      expect(result[:errors].first).to include(resource: "node_instance", id: instance_id)
      expect(error_of(result[:errors].first)).to eq(generic)
      expect(error_class_of(result[:errors].first)).to eq("StandardError")
    end
  end

  describe System::Ai::Skills::PlatformMaintenanceExecutor do
    # The inline-renewal path: an explicit, system.acme.renew-gated request
    # for one certificate_id. (The in-process fleet-tick path never renews
    # inline — platform_maintenance_executor_cert_rotate_spec.rb.)
    let(:renewer) { create(:user, account: account, permissions: [ "system.acme.renew" ]) }
    let(:exec) { described_class.new(account: account, user: renewer) }
    let!(:cert) { create(:system_acme_certificate, :expiring_soon, account: account) }

    # The call shape: CertificateManager.renew! takes `certificate:` as a
    # keyword. A positional call raised ArgumentError on every cert, so
    # cert_rotate could never renew anything.
    it "calls CertificateManager.renew! with the certificate: keyword" do
      expect(::Acme::CertificateManager).to receive(:renew!).with(certificate: cert)
        .and_return(::Acme::CertificateManager::Result.new(ok?: true, certificate: cert))

      result = exec.send(:cert_rotate, { certificate_id: cert.id })

      expect(result[:success]).to be true
      expect(result.dig(:data, :data, :rotated).map { |r| r[:id] }).to eq([ cert.id ])
      expect(result.dig(:data, :data, :failures)).to be_empty
    end

    it "withholds the text of a raising renew!" do
      allow(::Acme::CertificateManager).to receive(:renew!).and_raise(StandardError, marker)

      result = exec.send(:cert_rotate, { certificate_id: cert.id })

      expect_withheld(result)
      entry = result.dig(:data, :data, :failures).first
      expect(entry[:id]).to eq(cert.id)
      expect(error_of(entry)).to eq(generic)
      expect(error_class_of(entry)).to eq("StandardError")
      expect(result.dig(:data, :data, :rotated)).to be_empty
    end

    it "does not report a failed renewal as rotated, and withholds a non-caller-safe Result error" do
      allow(::Acme::CertificateManager).to receive(:renew!).and_return(
        ::Acme::CertificateManager::Result.new(ok?: false, certificate: cert, error: marker, caller_safe: nil)
      )

      result = exec.send(:cert_rotate, { certificate_id: cert.id })

      expect_withheld(result)
      expect(result.dig(:data, :data, :rotated)).to be_empty
      expect(result.dig(:data, :data, :failures).map { |f| f[:id] }).to eq([ cert.id ])
    end

    it "forwards a Result error its producer marked caller_safe" do
      allow(::Acme::CertificateManager).to receive(:renew!).and_return(
        ::Acme::CertificateManager::Result.new(ok?: false, certificate: cert,
                                               error: "certificate not in valid state (got renewing)",
                                               caller_safe: true)
      )

      result = exec.send(:cert_rotate, { certificate_id: cert.id })

      expect(error_of(result.dig(:data, :data, :failures).first)).to include("certificate not in valid state")
    end
  end
end
