# frozen_string_literal: true

require "rails_helper"
require "logger"
require "tmpdir"

# D12: platform-injected enrolment keys per provider. Mock adapters / stubbed
# clients only - no cloud calls. Placeholders are low-entropy on purpose.
RSpec.describe "Platform-injected enrolment seed per provider" do
  let(:ca) { self_signed_ca_pem }
  let(:instance) { create(:system_node_instance) }
  let(:cloud_id) { "cloud-id-1" }

  before do
    stub_enroll_settings(ca: ca)
    instance.merge_config!("cloud_instance_id" => cloud_id)
  end

  def issued_rows
    AuditLog.where(resource_type: "System::BootstrapToken", action: "system.bootstrap_token.issued")
  end

  def doc_of(user_data)
    JSON.parse(user_data[/^\{.*\}$/])
  end

  # Collects everything the logger sees (Rails + the provider's own).
  def capture_logs(provider)
    io = StringIO.new
    sink = Logger.new(io)
    Rails.logger.broadcast_to(sink)
    allow(provider).to receive(:logger).and_return(sink)
    yield
    io.string
  ensure
    Rails.logger.stop_broadcasting_to(sink)
  end

  shared_examples "never logs the seed" do |key_pattern = /"key":"[^"]+"/|
    it "keeps user_data and the minted key out of the logs" do
      logs = capture_logs(provider) { exercise }
      expect(logs).not_to match(key_pattern)
      expect(logs).not_to include("ca_fingerprint")
      expect(logs).not_to include(@minted_key.to_s) if @minted_key
    end
  end

  # ---------------------------------------------------------------- AWS
  describe System::Providers::AwsProvider do
    let(:connection) do
      instance_double("System::ProviderConnection", access_key: "not-a-real-access", secret_key: "not-a-real-secret", config: {})
    end
    let(:region) { instance_double("System::ProviderRegion", region_code: "us-east-1") }
    let(:ec2) { double("Aws::EC2::Client") }
    subject(:provider) { described_class.new(connection, region: region) }

    before do
      # aws-sdk-ec2 is an optional gem; the rescue clause names its error class.
      stub_const("Aws::EC2::Errors::ServiceError", Class.new(StandardError)) unless defined?(Aws::EC2::Errors::ServiceError)
      allow(provider).to receive(:ec2_client).and_return(ec2)
      allow(provider).to receive(:describe_instance).and_return({ success: false })
    end

    it "carries the v1 document in the RunInstances user_data" do
      seed = System::EnrollmentSeed.render_user_data(instance: instance)
      run = provider.send(:build_run_instance_params, { image_id: "ami-1", instance_type: "t3.micro", user_data: seed.user_data })
      expect(doc_of(Base64.decode64(run[:user_data]))).to include("version" => 1, "purpose" => "cloud_seed")
    end

    context "on start" do
      before { allow(ec2).to receive(:start_instances) }

      it "re-mints: replaces the stopped instance's user-data BEFORE starting, one audit row per mint" do
        calls = []
        allow(ec2).to receive(:modify_instance_attribute) { |**kw| calls << [ :modify, kw ] }
        allow(ec2).to receive(:start_instances) { |**kw| calls << [ :start, kw ] }

        expect { provider.start_instance(cloud_id) }.to change { issued_rows.count }.by(1)
        expect { provider.start_instance(cloud_id) }.to change { issued_rows.count }.by(1)

        modifies = calls.select { |c, _| c == :modify }
        expect(calls.map(&:first)).to eq(%i[modify start modify start])
        expect(modifies.map { |_, kw| kw[:instance_id] }.uniq).to eq([ cloud_id ])
        keys = modifies.map { |_, kw| doc_of(kw[:user_data][:value])["key"] }
        expect(keys.uniq.size).to eq(2)
      end

      it "starts a VM the platform did not seed without touching user-data" do
        expect(ec2).not_to receive(:modify_instance_attribute)
        provider.start_instance("i-unknown")
      end

      it "fails closed (no start) when no CA is configured" do
        stub_enroll_settings(ca: nil)
        expect(ec2).not_to receive(:start_instances)
        expect { provider.start_instance(cloud_id) }.to raise_error(System::EnrollmentSeed::SeedError)
      end

      it_behaves_like "never logs the seed" do
        def exercise
          allow(ec2).to receive(:modify_instance_attribute) { |**kw| @minted_key = doc_of(kw[:user_data][:value])["key"] }
          provider.start_instance(cloud_id)
        end
      end
    end

    it "excludes user_data from the create_instance log" do
      allow(ec2).to receive(:run_instances).and_raise(StandardError, "stop here")
      logs = capture_logs(provider) do
        provider.create_instance(name: "n", image_id: "ami-1", instance_type: "t3.micro", user_data: "SEED-PAYLOAD-PLACEHOLDER") rescue nil
      end
      expect(logs).not_to include("SEED-PAYLOAD-PLACEHOLDER")
    end
  end

  # ---------------------------------------------------------- OpenStack
  describe System::Providers::OpenStackProvider do
    let(:connection) do
      instance_double("System::ProviderConnection", access_key: "u", secret_key: "p", tenant: "t",
                      endpoint_url: "https://openstack.example.test:5000/v3", config: {}, account: nil, provider: nil)
    end
    let(:region) { instance_double("System::ProviderRegion", region_code: "RegionOne") }
    let(:server) { double("server", start: true, addresses: {}) }
    let(:servers) { double("servers", get: server) }
    subject(:provider) { described_class.new(connection, region: region) }

    before { allow(provider).to receive(:compute_client).and_return(double("compute", servers: servers)) }

    it "carries the v1 document (MIME-composed with the init script) in the server user_data" do
      seed = System::EnrollmentSeed.render_user_data(instance: instance, extra: "#cloud-config\nruncmd: [ls]")
      params = provider.send(:build_server_params, { name: "n", image_id: "img", instance_type: "m1", user_data: seed.user_data })
      decoded = Base64.decode64(params[:user_data])
      expect(decoded).to include("application/x-powernode-provision+json").and include("runcmd")
      expect(doc_of(decoded)).to include("version" => 1)
    end

    it "does NOT re-mint on start (Nova cannot change user_data after create): no mint, no audit row" do
      allow(provider).to receive(:extract_private_ip).and_return(nil)
      allow(provider).to receive(:extract_public_ip).and_return(nil)
      expect { provider.start_instance(cloud_id) }.not_to change { issued_rows.count }
    end

    it "excludes user_data from the create_instance log" do
      allow(provider).to receive(:compute_client).and_raise(StandardError, "stop here")
      logs = capture_logs(provider) do
        provider.create_instance(name: "n", user_data: "SEED-PAYLOAD-PLACEHOLDER") rescue nil
      end
      expect(logs).not_to include("SEED-PAYLOAD-PLACEHOLDER")
    end
  end

  # ---------------------------------------------------------------- GCP
  describe System::Providers::GcpProvider do
    let(:connection) do
      instance_double("System::ProviderConnection", tenant: "test-project", secret_key: "{}",
                      config: { "project_id" => "test-project", "default_zone" => "us-central1-a" })
    end
    let(:region) { instance_double("System::ProviderRegion", region_code: "us-central1") }
    let(:client) { double("instances") }
    let(:item_struct) { Struct.new(:key, :value, keyword_init: true) }
    let(:metadata_struct) { Struct.new(:fingerprint, :items, keyword_init: true) }
    subject(:provider) { described_class.new(connection, region: region) }

    before do
      stub_const("Google::Cloud::Compute::V1::Items", item_struct)
      stub_const("Google::Cloud::Compute::V1::Metadata", metadata_struct)
      allow(provider).to receive(:instances_client).and_return(client)
      allow(provider).to receive(:project_id).and_return("test-project")
      allow(provider).to receive(:wait_for_operation)
    end

    it "writes the seed to the `user-data` metadata key and keeps startup-script for operator scripts only" do
      seed = System::EnrollmentSeed.render_user_data(instance: instance)
      meta = provider.send(:build_metadata, { user_data: seed.user_data, startup_script: "echo operator" })
      by_key = meta.items.to_h { |i| [ i.key, i.value ] }

      expect(doc_of(by_key.fetch("user-data"))).to include("version" => 1)
      expect(by_key.fetch("startup-script")).to eq("echo operator")
    end

    it "never copies user_data into startup-script" do
      meta = provider.send(:build_metadata, { user_data: "SEED-PLACEHOLDER" })
      expect(meta.items.map(&:key)).to eq([ "user-data" ])
    end

    context "on start" do
      let(:current) do
        double("instance", metadata: metadata_struct.new(
          fingerprint: "fp-1",
          items: [ item_struct.new(key: "user-data", value: "stale"), item_struct.new(key: "startup-script", value: "echo operator") ]
        ))
      end

      before do
        allow(client).to receive(:get).and_return(current)
        allow(client).to receive(:start)
        allow(provider).to receive(:extract_private_ip).and_return(nil)
        allow(provider).to receive(:extract_public_ip).and_return(nil)
        allow(provider).to receive(:build_instance_response).and_return({ success: true })
      end

      it "re-mints: setMetadata replaces only user-data (fingerprint kept) before start, one audit row per mint" do
        sent = []
        order = []
        allow(client).to receive(:set_metadata) { |**kw| order << :set; sent << kw[:metadata_resource] }
        allow(client).to receive(:start) { order << :start }

        expect { 2.times { provider.start_instance(cloud_id) } }.to change { issued_rows.count }.by(2)

        expect(order).to eq(%i[set start set start])
        expect(sent.map(&:fingerprint).uniq).to eq([ "fp-1" ])
        sent.each do |m|
          by_key = m.items.to_h { |i| [ i.key, i.value ] }
          expect(doc_of(by_key.fetch("user-data"))).to include("version" => 1)
          expect(by_key.fetch("startup-script")).to eq("echo operator")
        end
        expect(sent.map { |m| doc_of(m.items.find { |i| i.key == "user-data" }.value)["key"] }.uniq.size).to eq(2)
      end

      it_behaves_like "never logs the seed" do
        def exercise
          allow(client).to receive(:set_metadata) do |**kw|
            @minted_key = doc_of(kw[:metadata_resource].items.find { |i| i.key == "user-data" }.value)["key"]
          end
          provider.start_instance(cloud_id)
        end
      end
    end

    it "excludes user_data and startup_script from the create_instance log" do
      allow(provider).to receive(:build_instance_resource).and_raise(StandardError, "stop here")
      logs = capture_logs(provider) do
        provider.create_instance(name: "n", user_data: "SEED-PAYLOAD-PLACEHOLDER", startup_script: "OPERATOR-SCRIPT-PLACEHOLDER") rescue nil
      end
      expect(logs).not_to include("SEED-PAYLOAD-PLACEHOLDER")
      expect(logs).not_to include("OPERATOR-SCRIPT-PLACEHOLDER")
    end
  end

  # -------------------------------------------------------------- Azure
  describe System::Providers::AzureProvider do
    let(:connection) do
      instance_double("System::ProviderConnection", access_key: "id", secret_key: "s", tenant: "t",
                      config: { "subscription_id" => "sub-12345", "resource_group" => "test-rg" })
    end
    let(:region) { instance_double("System::ProviderRegion", region_code: "eastus") }
    let(:stubs) { Faraday::Adapter::Test::Stubs.new }
    let(:arm) do
      s = stubs
      Faraday.new(url: System::Providers::AzureProvider::MGMT_BASE) { |f| f.response :json, content_type: /\bjson$/; f.adapter :test, s }
    end
    let(:vm_path) { "/subscriptions/sub-12345/resourceGroups/test-rg/providers/Microsoft.Compute/virtualMachines/#{cloud_id}" }
    subject(:provider) { described_class.new(connection, region: region) }

    before do
      allow(provider).to receive(:fetch_token!).and_return("fake-bearer-token")
      allow(provider).to receive(:arm_connection).and_return(arm)
    end

    it "wires the seed as properties.userData (what the agent reads) and the init script as osProfile.customData" do
      seed = System::EnrollmentSeed.render_user_data(instance: instance)
      payload = provider.send(:build_vm_payload, { name: "n", user_data: seed.user_data, init_script: "#cloud-config\nruncmd: [ls]" }, "n")

      expect(doc_of(Base64.decode64(payload[:properties][:userData]))).to include("version" => 1)
      custom = Base64.decode64(payload[:properties][:osProfile][:customData])
      expect(custom).to eq("#cloud-config\nruncmd: [ls]")
      expect(custom).not_to include("ca_fingerprint")
    end

    it "omits both when there is nothing to inject" do
      payload = provider.send(:build_vm_payload, { name: "n" }, "n")
      expect(payload[:properties]).not_to have_key(:userData)
      expect(payload[:properties][:osProfile]).not_to have_key(:customData)
    end

    context "on start" do
      def stub_start
        stubs.post("#{vm_path}/start") { [ 200, {}, {} ] }
      end

      it "re-mints: PATCHes a fresh userData before the start POST, one audit row per mint" do
        bodies = []
        order = []
        2.times do
          stubs.patch(vm_path) { |env| order << :patch; bodies << JSON.parse(env.body); [ 200, {}, {} ] }
          stubs.post("#{vm_path}/start") { order << :start; [ 200, {}, {} ] }
        end

        expect { 2.times { provider.start_instance(cloud_id) } }.to change { issued_rows.count }.by(2)

        expect(order).to eq(%i[patch start patch start])
        keys = bodies.map { |b| doc_of(Base64.decode64(b.dig("properties", "userData")))["key"] }
        expect(keys.uniq.size).to eq(2)
        expect(bodies.first["properties"].keys).to eq([ "userData" ])
      end

      it "fails closed without a CA: no PATCH, no start" do
        stub_enroll_settings(ca: nil)
        expect { provider.start_instance(cloud_id) }.to raise_error(System::EnrollmentSeed::SeedError)
      end

      it_behaves_like "never logs the seed" do
        def exercise
          stubs.patch(vm_path) { |env| @minted_key = doc_of(Base64.decode64(JSON.parse(env.body).dig("properties", "userData")))["key"]; [ 200, {}, {} ] }
          stub_start
          provider.start_instance(cloud_id)
        end
      end
    end

    it "excludes user_data from the create_instance log" do
      allow(provider).to receive(:build_vm_payload).and_raise(StandardError, "stop here")
      logs = capture_logs(provider) do
        provider.create_instance(name: "n", user_data: "SEED-PAYLOAD-PLACEHOLDER") rescue nil
      end
      expect(logs).not_to include("SEED-PAYLOAD-PLACEHOLDER")
    end
  end

  # ------------------------------------------------------------ Proxmox
  describe System::Providers::ProxmoxProvider do
    let(:tmp) { Dir.mktmpdir }
    let(:connection) do
      instance_double("System::ProviderConnection", access_key: "root@pam!powernode", secret_key: "00000000-0000-0000-0000-000000000000",
                      endpoint_url: "https://pve.example:8006", provider: instance_double("System::Provider", config: {}),
                      config: { "verify_ssl" => "false", "snippets_storage" => "snip", "snippets_local_path" => tmp })
    end
    let(:region) { instance_double("System::ProviderRegion", region_code: "pve1") }
    let(:client) { instance_double(System::Providers::Proxmox::Client, post: "UPID:start", wait_task: nil) }
    let(:cloud_id) { "pve1/qemu/100" }
    subject(:provider) { described_class.new(connection, region: region) }

    before do
      allow(System::Providers::Proxmox::Client).to receive(:new).and_return(client)
      allow(client).to receive(:get).with(%r{/status/current}).and_return("status" => "running")
      instance.merge_config!("boot_mode" => "uefi_disk")
    end

    after { FileUtils.remove_entry(tmp) }

    def seed_file
      Dir[File.join(tmp, "*-user.yml")].first
    end

    it "re-mints on start for a pivot-boot VM: rewrites the SAME per-instance seed with a fresh v1 key (0600)" do
      expect { provider.start_instance(cloud_id) }.to change { issued_rows.count }.by(1)
      first = doc_of(File.read(seed_file))
      expect { provider.start_instance(cloud_id) }.to change { issued_rows.count }.by(1)
      second = doc_of(File.read(seed_file))

      expect(Dir[File.join(tmp, "*-user.yml")].size).to eq(1)
      expect(File.basename(seed_file)).to include(instance.id.delete("-").first(12))
      expect(second["key"]).not_to eq(first["key"])
      expect(second).to include("version" => 1, "purpose" => "proxmox_uefi_provision")
      expect(File.stat(seed_file).mode & 0o777).to eq(0o600)
    end

    it "skips VMs that are not platform-seeded pivot boots (no mint, no file)" do
      instance.merge_config!("boot_mode" => "cloud_init")
      expect { provider.start_instance(cloud_id) }.not_to change { issued_rows.count }
      expect(seed_file).to be_nil
    end

    it "keeps the key out of the logs" do
      logs = capture_logs(provider) { provider.start_instance(cloud_id) }
      key = doc_of(File.read(seed_file))["key"]
      expect(logs).not_to include(key)
      expect(logs).not_to include("ca_fingerprint")
    end
  end

  # ---------------------------------------------------------- local_qemu
  describe System::Providers::LocalQemu::CloudSeed do
    before do
      allow(System::InternalCaService).to receive(:ca_chain_pem).and_return(ca)
    end

    it "mints through the single issuer: one audit row per build, 1h, fresh key each time" do
      builds = nil
      expect {
        builds = 2.times.map { described_class.build(instance: instance, options: { skip_fwcfg_stage: true }) }
      }.to change { issued_rows.count }.by(2)

      tokens = builds.map { |b| System::BootstrapToken.find(b[:bootstrap_token_id]) }
      expect(tokens.map(&:purpose).uniq).to eq([ "local_qemu_provision" ])
      expect(tokens.first.expires_at).to be_within(5.seconds).of(1.hour.from_now)
      keys = builds.map { |b| b[:fw_cfg_entries]["opt/com.powernode/bootstrap_token"] }
      expect(keys.uniq.size).to eq(2)
    end

    it "fails closed on an audit failure instead of seeding a placeholder token" do
      allow(AuditLog).to receive(:log_action).and_raise(StandardError, "audit down")
      expect { described_class.build(instance: instance, options: { skip_fwcfg_stage: true }) }
        .to raise_error(System::BootstrapToken::AuditFailure)
    end
  end
end
