# frozen_string_literal: true

require "rails_helper"

RSpec.describe Sdwan::ServiceBackend, type: :model do
  let(:account) { Account.first || create(:account) }

  def create_service(**attrs)
    Sdwan::Service.create!(
      { account: account, slug: "svc-#{SecureRandom.hex(3)}", name: "Svc",
        protocol: "https", backend_host: "10.20.0.5", backend_port: 3000 }.merge(attrs)
    )
  end

  describe "validations" do
    let(:service) { create_service }

    it "requires a vip or a host" do
      backend = described_class.new(service: service, backend_port: 3000)
      expect(backend).not_to be_valid
      expect(backend.errors[:base]).to include("a backend_vip or backend_host must be set")
    end

    it "rejects an out-of-range port" do
      backend = described_class.new(service: service, backend_host: "10.20.0.6", backend_port: 0)
      expect(backend).not_to be_valid
      expect(backend.errors[:backend_port]).to be_present
    end

    it "rejects a weight below the floor" do
      backend = described_class.new(service: service, backend_host: "10.20.0.6",
                                    backend_port: 3000, weight: 0)
      expect(backend).not_to be_valid
      expect(backend.errors[:weight]).to be_present
    end

    it "rejects an unknown status" do
      backend = described_class.new(service: service, backend_host: "10.20.0.6",
                                    backend_port: 3000, status: "parked")
      expect(backend).not_to be_valid
      expect(backend.errors[:status]).to be_present
    end

    it "refuses a duplicate address+port within the same service" do
      described_class.create!(service: service, backend_host: "10.20.0.6", backend_port: 3000)
      dup = described_class.new(service: service, backend_host: "10.20.0.6", backend_port: 3000)
      expect(dup).not_to be_valid
      expect(dup.errors[:base]).to include(/already a backend/)
    end

    # The model check alone races: two concurrent creates each see no sibling
    # and both insert. The functional unique index over
    # (sdwan_service_id, backend_port, COALESCE(backend_vip_id::text, backend_host))
    # is what actually makes that impossible — the plain multi-column index
    # could not, because Postgres treats the always-NULL half of the address
    # XOR as distinct. Asserted by bypassing validations, which is exactly what
    # a second connection racing the first amounts to.
    it "is protected in the DATABASE against a duplicate that skips validation" do
      described_class.create!(service: service, backend_host: "10.20.0.6", backend_port: 3000)

      expect do
        described_class.insert_all!(
          [ { account_id: service.account_id, sdwan_service_id: service.id,
              backend_host: "10.20.0.6", backend_port: 3000, weight: 1, status: "active",
              created_at: Time.current, updated_at: Time.current } ]
        )
      end.to raise_error(ActiveRecord::RecordNotUnique)
    end

    it "allows the same address+port on a DIFFERENT service" do
      described_class.create!(service: service, backend_host: "10.20.0.6", backend_port: 3000)
      other = described_class.new(service: create_service, backend_host: "10.20.0.6",
                                  backend_port: 3000)
      expect(other).to be_valid
    end

    it "inherits account_id from its service" do
      backend = described_class.create!(service: service, backend_host: "10.20.0.6", backend_port: 3000)
      expect(backend.account_id).to eq(service.account_id)
    end
  end

  describe "#address" do
    it "returns the backend_host when no vip is set" do
      backend = described_class.new(service: create_service, backend_host: "10.20.0.6",
                                    backend_port: 3000)
      expect(backend.address).to eq("10.20.0.6")
    end
  end

  describe "Sdwan::Service#load_balanced_backends" do
    it "falls back to the legacy single backend when the set is empty" do
      service = create_service(backend_host: "10.20.0.5", backend_port: 3000)

      targets = service.load_balanced_backends

      expect(targets.size).to eq(1)
      expect(targets.first.address).to eq("10.20.0.5")
      expect(targets.first.backend_port).to eq(3000)
      expect(targets.first.weight).to eq(Sdwan::ServiceBackend::DEFAULT_WEIGHT)
      expect(targets.first.url(scheme: "https")).to eq("https://10.20.0.5:3000")
    end

    it "returns the explicit backend set once one exists, ignoring the legacy columns" do
      service = create_service(backend_host: "10.20.0.5", backend_port: 3000)
      described_class.create!(service: service, backend_host: "10.20.0.11", backend_port: 8080)
      described_class.create!(service: service, backend_host: "10.20.0.12", backend_port: 8080)

      addresses = service.reload.load_balanced_backends.map(&:address)

      expect(addresses).to eq(%w[10.20.0.11 10.20.0.12])
    end

    it "omits a draining backend from the emitted set" do
      service = create_service
      described_class.create!(service: service, backend_host: "10.20.0.11", backend_port: 8080)
      described_class.create!(service: service, backend_host: "10.20.0.12", backend_port: 8080,
                              status: "draining")

      expect(service.reload.load_balanced_backends.map(&:address)).to eq([ "10.20.0.11" ])
    end

    # Operator ruling 2026-09-02 (APO-3d): an all-draining set is a service
    # OUT OF ROTATION, not a fallback to the legacy columns — after a replace
    # cycle those name exactly the host that died.
    it "resolves to NO backends when every explicit backend is draining" do
      service = create_service(backend_host: "10.20.0.5")
      described_class.create!(service: service, backend_host: "10.20.0.11", backend_port: 8080,
                              status: "draining")

      expect(service.reload.load_balanced_backends).to eq([])
    end

    it "is destroyed with its service" do
      service = create_service
      described_class.create!(service: service, backend_host: "10.20.0.11", backend_port: 8080)

      expect { service.destroy! }.to change(described_class, :count).by(-1)
    end
  end
end
