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

  # The platform seeded this instance at create (a seed-purpose token exists);
  # `unseeded` examples opt out.
  let(:seeded) { true }

  before do
    stub_enroll_settings(ca: ca)
    instance.merge_config!("cloud_instance_id" => cloud_id)
    System::EnrollmentSeed.issue_token(instance: instance) if seeded
  end

  def issued_rows
    AuditLog.where(resource_type: "System::BootstrapToken", action: "system.bootstrap_token.issued")
  end

  def enroll!(record = instance)
    record.update_columns(mtls_subject: "CN=not-a-real-subject")
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
      instance_double("System::ProviderConnection", account_id: instance.account_id, provider_id: instance.provider_region.provider_id, access_key: "not-a-real-access", secret_key: "not-a-real-secret", config: {})
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

      it "ENROLLED: mints nothing, revokes nothing new, and overwrites the seed with the key-less placeholder" do
        enroll!
        sent = nil
        allow(ec2).to receive(:modify_instance_attribute) { |**kw| sent = kw[:user_data][:value] }
        expect { provider.start_instance(cloud_id) }.not_to change { issued_rows.count }
        expect(sent).to eq(System::EnrollmentSeed::NEUTRAL_USER_DATA)
        expect(sent).not_to match(/key|version/)
      end

      it "ENROLLED via an active NodeCertificate (no mtls_subject): same" do
        create(:system_node_certificate, node_instance: instance, account: instance.account)
        allow(ec2).to receive(:modify_instance_attribute)
        expect { provider.start_instance(cloud_id) }.not_to change { issued_rows.count }
        expect(ec2).to have_received(:modify_instance_attribute).with(hash_including(user_data: { value: System::EnrollmentSeed::NEUTRAL_USER_DATA }))
      end

      it "never crosses tenants: another account's instance with the same cloud id is not touched" do
        other = create(:system_node_instance)
        other.merge_config!("cloud_instance_id" => cloud_id)
        expect(ec2).to receive(:modify_instance_attribute).once { |**kw| expect(doc_of(kw[:user_data][:value])["instance_id"]).to eq(instance.id) }
        provider.start_instance(cloud_id)
      end

      it "refuses (error response, no start) when two live rows in the account match, and ignores terminated ones" do
        twin = create(:system_node_instance, node: instance.node, provider_region: instance.provider_region)
        twin.merge_config!("cloud_instance_id" => cloud_id)
        expect(ec2).not_to receive(:start_instances)
        result = provider.start_instance(cloud_id)
        expect(result).to include(success: false, error_code: "SeedUnavailable")
      end

      it "ignores a terminated row that shares the cloud id" do
        twin = create(:system_node_instance, node: instance.node, provider_region: instance.provider_region)
        twin.merge_config!("cloud_instance_id" => cloud_id)
        twin.update_columns(status: "terminated")
        allow(ec2).to receive(:modify_instance_attribute)
        expect(provider.start_instance(cloud_id)[:error_code]).to be_nil
        expect(ec2).to have_received(:modify_instance_attribute).once
      end

      it "turns a SeedError (no CA) into a provider error response and does not start" do
        stub_enroll_settings(ca: nil)
        expect(ec2).not_to receive(:start_instances)
        expect(provider.start_instance(cloud_id)).to include(success: false, error_code: "SeedUnavailable")
      end

      it "revokes the prior active seed key (audited, same purpose) when it re-mints" do
        allow(ec2).to receive(:modify_instance_attribute)
        provider.start_instance(cloud_id)
        first = System::BootstrapToken.where(node_instance_id: instance.id, purpose: "cloud_seed").order(:created_at).last
        expect { provider.start_instance(cloud_id) }
          .to change { AuditLog.where(action: "system.bootstrap_token.revoked").count }.by(1)
        expect(first.reload).to be_revoked
        expect(System::BootstrapToken.active.where(node_instance_id: instance.id, purpose: "cloud_seed").count).to eq(1)
      end

      context "an instance the platform never seeded (imported / enrolled another way)" do
        let(:seeded) { false }

        it "neither re-mints nor clears: user-data is left untouched, enrolled or not" do
          expect(ec2).not_to receive(:modify_instance_attribute)
          expect { provider.start_instance(cloud_id) }.not_to change { issued_rows.count }
          enroll!
          provider.start_instance(cloud_id)
        end
      end

      it "uses the instance the caller already holds: an in-account name collision no longer refuses the start" do
        twin = create(:system_node_instance, node: instance.node, provider_region: instance.provider_region)
        twin.merge_config!("cloud_instance_id" => cloud_id)
        allow(ec2).to receive(:modify_instance_attribute) { |**kw| expect(doc_of(kw[:user_data][:value])["instance_id"]).to eq(instance.id) }
        result = provider.with_known_instance(instance.reload) { provider.start_instance(cloud_id) }
        expect(result[:error_code]).to be_nil
        expect(provider.known_instance).to be_nil
      end

      it "names the ambiguity (not the CA) when the fallback lookup finds two rows" do
        twin = create(:system_node_instance, node: instance.node, provider_region: instance.provider_region)
        twin.merge_config!("cloud_instance_id" => cloud_id)
        expect(provider.start_instance(cloud_id)[:error]).to match(/more than one live instance/)
      end

      it "re-checks enrolled? under the instance lock: enrolled in the window => placeholder, no key" do
        calls = 0
        allow(System::EnrollmentSeed).to receive(:enrolled?).and_wrap_original do |m, inst|
          (calls += 1) == 1 ? false : true
        end
        sent = nil
        allow(ec2).to receive(:modify_instance_attribute) { |**kw| sent = kw[:user_data][:value] }
        expect { provider.start_instance(cloud_id) }.not_to change { issued_rows.count }
        expect(sent).to eq(System::EnrollmentSeed::NEUTRAL_USER_DATA)
      end

      it "turns a lock deadlock into a retryable error response and does not start" do
        allow(System::BootstrapToken).to receive(:issue!).and_raise(ActiveRecord::Deadlocked)
        expect(ec2).not_to receive(:start_instances)
        result = provider.start_instance(cloud_id)
        expect(result).to include(success: false, error_code: "SeedUnavailable")
        expect(result[:error]).to match(/retry the start/)
      end

      it "starts a VM the platform did not seed without touching user-data" do
        expect(ec2).not_to receive(:modify_instance_attribute)
        provider.start_instance("i-unknown")
      end

      it_behaves_like "never logs the seed" do
        def exercise
          allow(ec2).to receive(:modify_instance_attribute) { |**kw| @minted_key = doc_of(kw[:user_data][:value])["key"] }
          provider.start_instance(cloud_id)
        end
      end
    end

    context "clear_enrollment_seed! (D13)" do
      it "is a recorded no-op: user-data is only changeable while stopped, so nothing is sent" do
        enroll!
        expect(ec2).not_to receive(:modify_instance_attribute)
        result = provider.clear_enrollment_seed!(cloud_id, instance: instance)
        expect(result).to include(outcome: :noop)
        expect(result[:note]).to match(/aws.*stopped/i)
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
      instance_double("System::ProviderConnection", account_id: instance.account_id, provider_id: instance.provider_region.provider_id, access_key: "u", secret_key: "p", tenant: "t",
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

    it "clear_enrollment_seed! is a recorded no-op (Nova cannot change user_data after create)" do
      enroll!
      result = provider.clear_enrollment_seed!(cloud_id, instance: instance)
      expect(result).to include(outcome: :noop)
      expect(result[:note]).to match(/openstack.*create/i)
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
      instance_double("System::ProviderConnection", account_id: instance.account_id, provider_id: instance.provider_region.provider_id, tenant: "test-project", secret_key: "{}",
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

      it "ENROLLED: mints nothing and REMOVES user-data, keeping the operator startup-script" do
        enroll!
        sent = nil
        allow(client).to receive(:set_metadata) { |**kw| sent = kw[:metadata_resource] }
        expect { provider.start_instance(cloud_id) }.not_to change { issued_rows.count }
        expect(sent.items.map(&:key)).to eq([ "startup-script" ])
        expect(sent.fingerprint).to eq("fp-1")
      end

      it "ignores a same-named GCE instance that belongs to another account" do
        instance.update_columns(account_id: create(:account).id)
        expect(client).not_to receive(:set_metadata)
        provider.start_instance(cloud_id)
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

    context "clear_enrollment_seed! (D13)" do
      let(:current) do
        double("instance", metadata: metadata_struct.new(
          fingerprint: "fp-1",
          items: [ item_struct.new(key: "user-data", value: "stale"), item_struct.new(key: "startup-script", value: "echo operator") ]
        ))
      end

      before { allow(client).to receive(:get).and_return(current) }

      it "ENROLLED: removes only the user-data item (fingerprint kept), mints nothing, never starts" do
        enroll!
        sent = nil
        allow(client).to receive(:set_metadata) { |**kw| sent = kw[:metadata_resource] }
        expect(client).not_to receive(:start)

        result = nil
        expect { result = provider.clear_enrollment_seed!(cloud_id, instance: instance) }.not_to change { issued_rows.count }
        expect(result).to include(outcome: :cleared)
        expect(sent.items.map(&:key)).to eq([ "startup-script" ])
        expect(sent.fingerprint).to eq("fp-1")
      end

      it "NOT enrolled: does nothing (never re-mints, never clears a live seed)" do
        expect(client).not_to receive(:set_metadata)
        expect { expect(provider.clear_enrollment_seed!(cloud_id, instance: instance)).to include(outcome: :noop) }
          .not_to change { issued_rows.count }
      end

      context "an instance the platform never seeded" do
        let(:seeded) { false }

        it "leaves the metadata untouched" do
          enroll!
          expect(client).not_to receive(:set_metadata)
          expect(provider.clear_enrollment_seed!(cloud_id, instance: instance)).to include(outcome: :noop)
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
      instance_double("System::ProviderConnection", account_id: instance.account_id, provider_id: instance.provider_region.provider_id, access_key: "id", secret_key: "s", tenant: "t",
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

      it "fails closed without a CA: a provider error, no PATCH, no start" do
        stub_enroll_settings(ca: nil)
        expect { provider.start_instance(cloud_id) }.to raise_error(System::Providers::AzureProvider::AzureError, /could not be minted/)
      end

      it "ENROLLED: mints nothing and PATCHes the key-less placeholder" do
        enroll!
        body = nil
        stubs.patch(vm_path) { |env| body = JSON.parse(env.body); [ 200, {}, {} ] }
        stub_start
        expect { provider.start_instance(cloud_id) }.not_to change { issued_rows.count }
        expect(Base64.decode64(body.dig("properties", "userData"))).to eq(System::EnrollmentSeed::NEUTRAL_USER_DATA)
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
      instance_double("System::ProviderConnection", account_id: instance.account_id, provider_id: instance.provider_region.provider_id, access_key: "root@pam!powernode", secret_key: "00000000-0000-0000-0000-000000000000",
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

    # v1 is opt-in on Proxmox until rebuilt images are promoted (M2).
    around do |ex|
      ENV["POWERNODE_PVE_V1_CIDATA"] = "1"
      ex.run
    ensure
      ENV.delete("POWERNODE_PVE_V1_CIDATA")
    end

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

    it "ENROLLED: mints nothing and overwrites the seed IN PLACE with the key-less placeholder" do
      provider.start_instance(cloud_id)
      path = seed_file
      enroll!
      expect { provider.start_instance(cloud_id) }.not_to change { issued_rows.count }
      expect(seed_file).to eq(path)
      expect(File.read(path)).to eq(System::EnrollmentSeed::NEUTRAL_USER_DATA)
    end

    it "defaults to the LEGACY KEY= seed when v1 is not opted into (single issuer, audited)" do
      ENV.delete("POWERNODE_PVE_V1_CIDATA")
      expect { provider.start_instance(cloud_id) }.to change { issued_rows.count }.by(1)
      expect(File.read(seed_file)).to match(/\AID=#{instance.id}\nKEY=\S+\nSERVER=/)
    end

    it "skips VMs that are not platform-seeded pivot boots (no mint, no file)" do
      instance.merge_config!("boot_mode" => "cloud_init")
      expect { provider.start_instance(cloud_id) }.not_to change { issued_rows.count }
      expect(seed_file).to be_nil
    end

    context "clear_enrollment_seed! (D13)" do
      let(:disc) { instance.id.delete("-").first(12) }
      let(:config_path) { "/api2/json/nodes/pve1/qemu/100/config" }

      def attached_config(extra)
        { "name" => "vm", "ide2" => "local:cloudinit,media=cdrom" }.merge(extra)
      end

      before do
        enroll!
        allow(client).to receive(:put).and_return(nil)
        allow(client).to receive(:delete).and_return(nil)
        %w[user meta net].each { |k| File.write(File.join(tmp, "100-#{disc}-#{k}.yml"), "seed") }
      end

      def stub_config(*configs)
        allow(client).to receive(:get).with(config_path, { "current" => 1 }).and_return(*configs)
      end

      let(:cicustom_ref) { "snip:snippets/100-#{disc}-user.yml" }

      it "snippet transport: deletes cicustom, REGENERATES the cloudinit drive, then removes the snippets" do
        stub_config(attached_config("cicustom" => cicustom_ref), attached_config({}))
        order = []
        allow(client).to receive(:put) { |path, body = nil| order << [ path, body ]; nil }

        result = provider.clear_enrollment_seed!(cloud_id, instance: instance)

        expect(order).to eq([ [ config_path, { "delete" => "cicustom" } ],
                              [ "/api2/json/nodes/pve1/qemu/100/cloudinit", nil ] ])
        expect(result).to include(outcome: :cleared)
        expect(Dir[File.join(tmp, "*.yml")]).to be_empty
      end

      it "builds the client with short per-call timeouts (one item must stay far below the lease)" do
        stub_config(attached_config({}))
        provider.clear_enrollment_seed!(cloud_id, instance: instance)
        expect(System::Providers::Proxmox::Client).to have_received(:new)
          .with(hash_including(read_timeout: satisfy { |t| t <= 15 }, connect_timeout: satisfy { |t| t <= 10 })).at_least(:once)
      end

      it "never restarts the VM: no status endpoint is ever called" do
        stub_config(attached_config("cicustom" => cicustom_ref), attached_config({}))
        expect(client).not_to receive(:post)
        provider.clear_enrollment_seed!(cloud_id, instance: instance)
      end

      it "stays awaiting_stop (files kept) when the cloudinit regenerate fails" do
        stub_config(attached_config("cicustom" => cicustom_ref), attached_config({}))
        allow(client).to receive(:put).with("/api2/json/nodes/pve1/qemu/100/cloudinit")
                                      .and_raise(System::Providers::Proxmox::Client::Error, "boom")
        result = provider.clear_enrollment_seed!(cloud_id, instance: instance)

        expect(result).to include(outcome: :awaiting_stop)
        expect(Dir[File.join(tmp, "*.yml")].size).to eq(3)
      end

      it "stays awaiting_stop when PVE only queued the cicustom delete (still referenced), without regenerating" do
        stub_config(attached_config("cicustom" => cicustom_ref), attached_config("cicustom" => cicustom_ref))
        result = provider.clear_enrollment_seed!(cloud_id, instance: instance)

        expect(client).not_to have_received(:put).with("/api2/json/nodes/pve1/qemu/100/cloudinit")
        expect(result).to include(outcome: :awaiting_stop)
        expect(Dir[File.join(tmp, "*.yml")].size).to eq(3)
      end

      it "a later sweep (cicustom already gone) regenerates and removes the snippets" do
        stub_config(attached_config({}))
        result = provider.clear_enrollment_seed!(cloud_id, instance: instance)

        expect(client).to have_received(:put).with("/api2/json/nodes/pve1/qemu/100/cloudinit")
        expect(client).not_to have_received(:put).with(config_path, anything)
        expect(result).to include(outcome: :cleared)
      end

      it "skips the regenerate when the VM has no cloudinit drive" do
        stub_config({ "name" => "vm" })
        expect(provider.clear_enrollment_seed!(cloud_id, instance: instance)).to include(outcome: :cleared)
        expect(client).not_to have_received(:put)
      end

      context "ISO transport" do
        let(:iso) { "cidata-100-#{disc}.iso" }
        let(:upid) { "UPID:pve1:0000ABCD:00001234:5F000000:imgdel:100:root@pam!powernode:" }

        before do
          connection.config["cidata_transport"] = "iso"
          connection.config["cidata_iso_storage"] = "isos"
          allow(client).to receive(:delete).and_return(upid)
        end

        it "ejects the spent seed by a live media swap (ide2=none,media=cdrom), then deletes the ISO in the same pass" do
          allow(client).to receive(:get).with(config_path, { "current" => 1 })
            .and_return(attached_config("ide2" => "isos:iso/#{iso},media=cdrom"), attached_config("ide2" => "none,media=cdrom"))

          result = provider.clear_enrollment_seed!(cloud_id, instance: instance)

          expect(client).to have_received(:put).with(config_path, { "ide2" => "none,media=cdrom" })
          expect(client).not_to have_received(:put).with(config_path, hash_including("delete"))
          expect(client).to have_received(:delete)
            .with("/api2/json/nodes/pve1/storage/isos/content/isos%3Aiso%2F#{iso}")
          expect(client).to have_received(:wait_task).with(hash_including(node: "pve1", upid: upid))
          expect(result).to include(outcome: :cleared)
        end

        it "stays awaiting_stop, keeping the ISO, when PVE did not apply the swap (seed still current on ide2)" do
          allow(client).to receive(:get).with(config_path, { "current" => 1 })
            .and_return(attached_config("ide2" => "isos:iso/#{iso},media=cdrom"))

          result = provider.clear_enrollment_seed!(cloud_id, instance: instance)

          expect(result).to include(outcome: :awaiting_stop)
          expect(client).not_to have_received(:delete)
        end

        it "caps the awaited delete task well below the lease" do
          allow(client).to receive(:get).with(config_path, { "current" => 1 }).and_return(attached_config({}))
          provider.clear_enrollment_seed!(cloud_id, instance: instance)
          expect(client).to have_received(:wait_task).with(hash_including(timeout: satisfy { |t| t <= 20 }))
        end

        it "reports a failure (not cleared) when no ISO storage can be resolved" do
          connection.config.delete("cidata_iso_storage")
          allow(provider).to receive(:pve_credential).and_call_original
          allow(provider).to receive(:pve_credential).with("default_storage", "default_storage").and_return(nil)
          allow(client).to receive(:get).with(config_path, { "current" => 1 }).and_return(attached_config({}))
          expect { provider.clear_enrollment_seed!(cloud_id, instance: instance) }.to raise_error(StandardError, /storage/i)
          expect(client).not_to have_received(:delete)
        end

        it "treats an already-gone ISO as cleared" do
          allow(client).to receive(:get).with(config_path, { "current" => 1 }).and_return(attached_config({}))
          allow(client).to receive(:delete).and_raise(System::Providers::Proxmox::Client::NotFoundError, "gone")
          expect(provider.clear_enrollment_seed!(cloud_id, instance: instance)).to include(outcome: :cleared)
        end
      end

      it "NOT enrolled: does nothing" do
        instance.update_columns(mtls_subject: nil)
        expect(client).not_to receive(:put)
        expect(provider.clear_enrollment_seed!(cloud_id, instance: instance)).to include(outcome: :noop)
        expect(Dir[File.join(tmp, "*.yml")].size).to eq(3)
      end

      it "skips VMs that are not pivot-boot (no platform key rides that seed)" do
        instance.merge_config!("boot_mode" => "cloud_init")
        expect(client).not_to receive(:put)
        expect(provider.clear_enrollment_seed!(cloud_id, instance: instance)).to include(outcome: :noop)
      end

      it "skips federation spawns (their snippet slot carries the spawn payload)" do
        instance.merge_config!("federation_spawn" => { "x" => 1 })
        expect(client).not_to receive(:put)
        expect(provider.clear_enrollment_seed!(cloud_id, instance: instance)).to include(outcome: :noop)
      end

      it "skips LXC" do
        expect(client).not_to receive(:put)
        expect(provider.clear_enrollment_seed!("pve1/lxc/100", instance: instance)).to include(outcome: :noop)
      end
    end

    context "terminate_instance removes its own seed ISO (IMP-b7683fab758c)" do
      let(:disc) { instance.id.delete("-").first(12) }
      let(:own_iso) { "cidata-100-#{disc}.iso" }
      let(:destroy_upid) { "UPID:pve1:0000ABCD:00001234:5F000000:qmdestroy:100:root@pam!powernode:" }
      let(:del_upid) { "UPID:pve1:0000ABCD:00001235:5F000000:imgdel:100:root@pam!powernode:" }
      let(:iso_path) { "/api2/json/nodes/pve1/storage/isos/content/isos%3Aiso%2F#{own_iso}" }

      before do
        connection.config["cidata_transport"] = "iso"
        connection.config["cidata_iso_storage"] = "isos"
        allow(client).to receive(:put)
        allow(client).to receive(:get).with("/api2/json/nodes/pve1/qemu/100/config", { "current" => 1 }).and_return({})
        allow(client).to receive(:delete).with("/api2/json/nodes/pve1/qemu/100", anything).and_return(destroy_upid)
        allow(client).to receive(:delete).with(iso_path).and_return(del_upid)
      end

      it "deletes exactly cidata-<vmid>-<its discriminator>.iso after the VM destroy, never a vmid glob" do
        result = provider.terminate_instance(cloud_id)

        expect(result[:success]).to be true
        expect(client).to have_received(:delete).with(iso_path)
        expect(client).not_to have_received(:get).with(%r{/storage/})
        expect(client).to have_received(:delete).exactly(2).times
      end

      it "ends with no ISO left for a VM terminated while its seed cleanup was awaiting_stop" do
        instance.merge_config!("seed_cleanup" => { "state" => "awaiting_stop", "requested_at" => Time.current.utc.iso8601 })
        enroll!
        provider.terminate_instance(cloud_id)
        expect(client).to have_received(:delete).with(iso_path)
      end

      it "treats an ISO that is already gone as done" do
        allow(client).to receive(:delete).with(iso_path).and_raise(System::Providers::Proxmox::Client::NotFoundError, "gone")
        expect(provider.terminate_instance(cloud_id)).to include(success: true)
      end

      it "still reports the termination when the ISO delete fails (the reaper catches the leftover)" do
        allow(client).to receive(:delete).with(iso_path).and_raise(System::Providers::Proxmox::Client::Error, "boom")
        expect(provider.terminate_instance(cloud_id)).to include(success: true)
      end

      it "sends no ISO delete when the destroy itself failed" do
        allow(client).to receive(:delete).with("/api2/json/nodes/pve1/qemu/100", anything)
                                         .and_raise(System::Providers::Proxmox::Client::Error, "busy")
        provider.terminate_instance(cloud_id)
        expect(client).not_to have_received(:delete).with(iso_path)
      end

      it "also deletes the exact seed ISO the VM had attached when no instance row names its key (instance-less staging)" do
        orphan_key_iso = "cidata-100-0123456789ab.iso"
        allow(provider).to receive(:seed_instance_for).and_return(nil)
        allow(client).to receive(:get).with("/api2/json/nodes/pve1/qemu/100/config", { "current" => 1 })
          .and_return("ide2" => "isos:iso/#{orphan_key_iso},media=cdrom")
        allow(client).to receive(:delete).with("/api2/json/nodes/pve1/storage/isos/content/isos%3Aiso%2F#{orphan_key_iso}").and_return(del_upid)

        provider.terminate_instance(cloud_id)

        expect(client).to have_received(:delete).with("/api2/json/nodes/pve1/storage/isos/content/isos%3Aiso%2F#{orphan_key_iso}")
      end

      it "never deletes an attached ISO that belongs to another vmid" do
        allow(provider).to receive(:seed_instance_for).and_return(nil)
        allow(client).to receive(:get).with("/api2/json/nodes/pve1/qemu/100/config", { "current" => 1 })
          .and_return("ide2" => "isos:iso/cidata-101-0123456789ab.iso,media=cdrom")
        provider.terminate_instance(cloud_id)
        expect(client).to have_received(:delete).exactly(1).times # the VM destroy only
      end

      it "names the file (never contents) in the warn line when the ISO delete is swallowed" do
        allow(client).to receive(:delete).with(iso_path).and_raise(System::Providers::Proxmox::Client::Error, "boom")
        io = StringIO.new
        allow(provider).to receive(:logger).and_return(Logger.new(io))
        provider.terminate_instance(cloud_id)
        expect(io.string).to include(own_iso)
      end

      it "does nothing extra on the snippet transport" do
        connection.config.delete("cidata_transport")
        provider.terminate_instance(cloud_id)
        expect(client).not_to have_received(:delete).with(iso_path)
      end
    end

    context "D12 start vs the D13 cleanup state" do
      before do
        provider.start_instance(cloud_id)
        @path = seed_file
        File.delete(@path)
      end

      it "writes nothing for an enrolled VM whose seed was CLEARED" do
        enroll!
        instance.merge_config!("seed_cleanup" => { "state" => "done", "outcome" => "cleared" })
        provider.start_instance(cloud_id)
        expect(seed_file).to be_nil
      end

      it "still neutralises an enrolled VM when cleanup ended noop or abandoned" do
        enroll!
        %w[noop abandoned].each do |outcome|
          instance.merge_config!("seed_cleanup" => { "state" => "done", "outcome" => outcome })
          provider.start_instance(cloud_id)
          expect(File.read(seed_file)).to eq(System::EnrollmentSeed::NEUTRAL_USER_DATA)
          File.delete(seed_file)
        end
      end

      it "still mints for a NOT-enrolled VM even though an earlier cleanup finished (identity revoked, re-enrol)" do
        instance.merge_config!("seed_cleanup" => { "state" => "done", "outcome" => "cleared" })
        expect { provider.start_instance(cloud_id) }.to change { issued_rows.count }.by(1)
        expect(doc_of(File.read(seed_file))).to include("version" => 1)
      end

      it "skips the neutral re-write while the detach is queued for this very start (awaiting_stop)" do
        enroll!
        instance.merge_config!("seed_cleanup" => { "state" => "awaiting_stop" })
        provider.start_instance(cloud_id)
        expect(seed_file).to be_nil
      end

      it "still neutralises while cleanup has not detached anything yet (pending)" do
        enroll!
        instance.merge_config!("seed_cleanup" => { "state" => "pending" })
        provider.start_instance(cloud_id)
        expect(File.read(seed_file)).to eq(System::EnrollmentSeed::NEUTRAL_USER_DATA)
      end
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
