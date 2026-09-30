# frozen_string_literal: true

require "rails_helper"

# IMP-156eb1a7bdbc fix round (critic A M1 + follow-up 1).
#
# Once cert_rotate's renew! call shape was fixed it became a live ACME
# mutation, so two things it never needed as a no-op now matter:
#
#   1. WHO may rotate. system_fleet_tool fronts this skill with the
#      system.platform.read grant; every other renew door requires
#      system.acme.renew. The executor gates the cert_rotate branch the way
#      PlatformResilienceExecutor gates its drain: an explicit in-process
#      caller (internal_caller?) or a user holding system.acme.renew. An MCP
#      instance principal (no user) is refused.
#
#   2. WHERE the ACME order runs. The automatic system.acme_cert_expiring
#      remediation reaches cert_rotate from the all-accounts fleet tick, one
#      HTTP request. An ACME order is multi-minute, so that path must never
#      place one inline. It leaves the certificate to the scheduled renewal
#      sweep (Acme::RenewalSweepService via the worker's
#      AcmeCertificateRenewalJob), which already renews every valid
#      certificate inside the model's RENEWAL_WINDOW. Only an explicit,
#      permission-gated request for ONE certificate_id renews inline — the
#      same shape as the REST renew action and system_acme_renew_certificate.
RSpec.describe System::Ai::Skills::PlatformMaintenanceExecutor do
  let(:account) { create(:account) }
  let!(:due)    { create(:system_acme_certificate, :expiring_soon, account: account) }

  let(:renewer) { create(:user, account: account, permissions: [ "system.acme.renew" ]) }
  let(:reader)  { create(:user, account: account, permissions: [ "system.platform.read" ]) }

  let(:ok_result) { ::Acme::CertificateManager::Result.new(ok?: true, certificate: due) }

  before { allow(::Acme::CertificateManager).to receive(:renew!).and_return(ok_result) }

  def rotate(exec, **params)
    exec.send(:cert_rotate, params)
  end

  def payload(result) = result.dig(:data, :data)

  describe "authorization" do
    it "refuses a caller holding only the read grant, and places no ACME order" do
      result = rotate(described_class.new(account: account, user: reader), certificate_id: due.id)

      expect(result[:success]).to be false
      expect(result[:error]).to include("system.acme.renew")
      expect(::Acme::CertificateManager).not_to have_received(:renew!)
    end

    it "refuses the read-only caller on the all-due form too" do
      result = rotate(described_class.new(account: account, user: reader))

      expect(result[:success]).to be false
      expect(::Acme::CertificateManager).not_to have_received(:renew!)
    end

    it "refuses an MCP instance principal (no user, instance-authorized)" do
      exec = described_class.new(account: account)
      exec.instance_authorized = true

      result = rotate(exec, certificate_id: due.id)

      expect(result[:success]).to be false
      expect(result[:error]).to include("system.acme.renew")
      expect(::Acme::CertificateManager).not_to have_received(:renew!)
    end

    it "lets a system.acme.renew holder renew the named certificate" do
      result = rotate(described_class.new(account: account, user: renewer), certificate_id: due.id)

      expect(result[:success]).to be true
      expect(::Acme::CertificateManager).to have_received(:renew!).with(certificate: due)
      expect(payload(result)[:rotated].map { |r| r[:id] }).to eq([ due.id ])
    end

    it "lets the in-process reconciler (user: nil, not an instance) through" do
      result = rotate(described_class.new(account: account), certificate_id: due.id)

      expect(result[:success]).to be true
    end
  end

  describe "the fleet-tick path (in-process caller)" do
    let(:exec) { described_class.new(account: account) }

    it "places no ACME order for the signalled certificate and leaves it to the renewal sweep" do
      result = rotate(exec, certificate_id: due.id)

      expect(::Acme::CertificateManager).not_to have_received(:renew!)
      expect(payload(result)[:rotated]).to be_empty
      expect(payload(result)[:deferred_to_renewal_sweep].map { |r| r[:id] }).to eq([ due.id ])
    end

    it "places no ACME order on the all-due form either" do
      other = create(:system_acme_certificate, :expiring_soon, account: account)

      result = rotate(exec)

      expect(::Acme::CertificateManager).not_to have_received(:renew!)
      expect(payload(result)[:deferred_to_renewal_sweep].map { |r| r[:id] }).to contain_exactly(due.id, other.id)
    end

    # The deferral is only honest if the sweep really picks the certificate
    # up: run the real sweep and watch it renew exactly what was deferred.
    it "defers only what the scheduled renewal sweep actually renews" do
      deferred = payload(rotate(exec, certificate_id: due.id))[:deferred_to_renewal_sweep].map { |r| r[:id] }

      ::Acme::RenewalSweepService.run!(account: account)

      expect(::Acme::CertificateManager).to have_received(:renew!).with(certificate: due, acme_client: nil)
      expect(deferred).to eq([ due.id ])
    end

    it "reports a certificate outside the sweep's window as not yet due rather than deferred" do
      later = create(:system_acme_certificate, :valid, account: account) # expires in 90 days

      result = rotate(exec, certificate_id: later.id)

      expect(::Acme::CertificateManager).not_to have_received(:renew!)
      expect(payload(result)[:deferred_to_renewal_sweep]).to be_empty
      expect(payload(result)[:not_yet_due].map { |r| r[:id] }).to eq([ later.id ])
    end
  end

  describe "an explicit request without a certificate_id" do
    it "does not renew the whole window inline; it defers to the sweep" do
      result = rotate(described_class.new(account: account, user: renewer))

      expect(::Acme::CertificateManager).not_to have_received(:renew!)
      expect(payload(result)[:deferred_to_renewal_sweep].map { |r| r[:id] }).to eq([ due.id ])
    end
  end
end
