# frozen_string_literal: true

require "rails_helper"
require "tmpdir"
require "json"

RSpec.describe Federation::TcpForwarderConfigWriter, type: :service do
  let(:account) { create(:account) }
  let(:tmp_dir) { Dir.mktmpdir("tcpfwd-config") }
  let(:config_path) { File.join(tmp_dir, "forwards.json") }

  after { FileUtils.rm_rf(tmp_dir) if Dir.exist?(tmp_dir) }

  describe ".write!" do
    context "with no active site-local subscriptions" do
      it "writes {\"forwards\": []} rather than omitting the file" do
        result = described_class.write!(account: account, config_path: config_path)
        expect(result[:forward_count]).to eq(0)
        expect(File.exist?(result[:output_path])).to be true
        parsed = JSON.parse(File.read(result[:output_path]))
        expect(parsed).to eq("forwards" => [])
      end
    end

    context "with an active site-local subscription (localhost: hostname)" do
      let!(:sub) do
        create(:system_federation_service_subscription, :active, :site_local, account: account,
                                                                                local_hostname: "localhost:5432",
                                                                                backend_vip: "fd00:b0b::20",
                                                                                backend_port: 5432)
      end

      it "renders one forward with the exact tcpfwd contract keys" do
        result = described_class.write!(account: account, config_path: config_path)
        expect(result[:forward_count]).to eq(1)

        parsed = JSON.parse(File.read(result[:output_path]))
        expect(parsed.keys).to eq([ "forwards" ])

        forward = parsed["forwards"].first
        expect(forward.keys.sort).to eq(%w[backend listen protocol subscription_id])
        expect(forward).to eq(
          "listen" => "127.0.0.1:5432",
          "backend" => "[fd00:b0b::20]:5432",
          "protocol" => "tcp",
          "subscription_id" => sub.id
        )
      end
    end

    context "with a backend_vip the remote peer already bracketed" do
      let!(:sub) do
        create(:system_federation_service_subscription, :active, :site_local, account: account,
                                                                                local_hostname: "localhost:5433",
                                                                                backend_vip: "[fd00:b0b::30]",
                                                                                backend_port: 5433)
      end

      it "does not double-bracket it" do
        # backend_vip is an unvalidated string column populated from a REMOTE
        # peer's offering, so the bracketed form is not ours to rule out.
        # The Go forwarder dials Backend verbatim (net.Dial in
        # agent/internal/tcpfwd/forwarder.go), which rejects
        # "[[fd00:b0b::30]]:5433".
        # Guard shared with Sdwan::HostPort (IMP-9537a74e50fa).
        result = described_class.write!(account: account, config_path: config_path)
        forward = JSON.parse(File.read(result[:output_path]))["forwards"].first

        expect(forward["backend"]).to eq("[fd00:b0b::30]:5433")
      end
    end

    context "with an active site-local subscription (127.0.0.1: hostname)" do
      let!(:sub) do
        create(:system_federation_service_subscription, :active, :site_local, account: account,
                                                                                local_hostname: "127.0.0.1:6379",
                                                                                backend_vip: "fd00:b0b::21",
                                                                                backend_port: 6379)
      end

      it "keeps the listen host as-is (no double-mapping)" do
        result = described_class.write!(account: account, config_path: config_path)
        parsed = JSON.parse(File.read(result[:output_path]))
        expect(parsed["forwards"].first["listen"]).to eq("127.0.0.1:6379")
      end
    end

    context "with a mix of site-local and public subscriptions" do
      let!(:public_sub) do
        create(:system_federation_service_subscription, :active, account: account,
                                                                  protocol: "https",
                                                                  local_hostname: "git.alice.tld")
      end
      let!(:site_local_sub) do
        create(:system_federation_service_subscription, :active, :site_local, account: account,
                                                                                backend_vip: "fd00:b0b::22",
                                                                                backend_port: 5432)
      end

      it "excludes the public subscription and includes only the site-local one" do
        result = described_class.write!(account: account, config_path: config_path)
        expect(result[:forward_count]).to eq(1)
        parsed = JSON.parse(File.read(result[:output_path]))
        expect(parsed["forwards"].first["subscription_id"]).to eq(site_local_sub.id)
      end
    end

    context "with an active NON-site-local tcp-protocol subscription (increment 4 cutover)" do
      let!(:tcp_sub) do
        create(:system_federation_service_subscription, :active, :tcp, account: account,
                                                                        local_hostname: "pg.alice.tld",
                                                                        backend_vip: "fd00:abc::20",
                                                                        backend_port: 5432,
                                                                        acme_certificate: nil)
      end

      it "includes it -- ServiceRouteWriter's HostSNI routing can never match plaintext TCP, so it rides tcpfwd instead" do
        result = described_class.write!(account: account, config_path: config_path)
        expect(result[:forward_count]).to eq(1)
        parsed = JSON.parse(File.read(result[:output_path]))
        expect(parsed["forwards"].first["subscription_id"]).to eq(tcp_sub.id)
      end

      it "derives listen by pairing local_hostname (bare, no embedded port for non-site-local subs) with backend_port" do
        result = described_class.write!(account: account, config_path: config_path)
        parsed = JSON.parse(File.read(result[:output_path]))
        forward = parsed["forwards"].first
        expect(forward["listen"]).to eq("pg.alice.tld:5432")
        expect(forward["backend"]).to eq("[fd00:abc::20]:5432")
      end
    end

    context "with site-local subscriptions in non-active states" do
      let!(:pending_sub) do
        create(:system_federation_service_subscription, :site_local, account: account,
                                                                       backend_vip: "fd00:b0b::23")
      end
      let!(:suspended_sub) do
        create(:system_federation_service_subscription, :suspended, :site_local, account: account,
                                                                                  backend_vip: "fd00:b0b::24")
      end
      let!(:cancelled_sub) do
        create(:system_federation_service_subscription, :cancelled, :site_local, account: account,
                                                                                  backend_vip: "fd00:b0b::25")
      end

      it "excludes pending, suspended, and cancelled subscriptions" do
        result = described_class.write!(account: account, config_path: config_path)
        expect(result[:forward_count]).to eq(0)
      end
    end

    it "always emits protocol \"tcp\" (v1), even if the subscription's own protocol field differs" do
      create(:system_federation_service_subscription, :active, :site_local, account: account,
                                                                              protocol: "https",
                                                                              backend_vip: "fd00:b0b::26",
                                                                              backend_port: 8443)
      result = described_class.write!(account: account, config_path: config_path)
      parsed = JSON.parse(File.read(result[:output_path]))
      expect(parsed["forwards"].first["protocol"]).to eq("tcp")
    end

    it "produces output satisfying the Go side's validation contract (config.go#Validate)" do
      create(:system_federation_service_subscription, :active, :site_local, account: account,
                                                                              backend_vip: "fd00:b0b::27",
                                                                              backend_port: 5432)
      result = described_class.write!(account: account, config_path: config_path)
      parsed = JSON.parse(File.read(result[:output_path]))
      expect(parsed["forwards"]).to all(
        include("listen" => be_present, "backend" => be_present, "protocol" => "tcp")
      )
    end

    it "creates config_path's parent directory if missing" do
      nested = File.join(tmp_dir, "nested", "dir", "forwards.json")
      result = described_class.write!(account: account, config_path: nested)
      expect(Dir.exist?(File.dirname(nested))).to be true
      expect(File.exist?(result[:output_path])).to be true
    end

    it "writes atomically -- no leftover temp files in the target directory" do
      described_class.write!(account: account, config_path: config_path)
      entries = Dir.children(File.dirname(config_path))
      expect(entries).to eq([ File.basename(config_path) ])
    end

    it "raises WriteError when the target directory can't be created" do
      locked_parent = File.join(tmp_dir, "locked")
      FileUtils.mkdir_p(locked_parent)
      FileUtils.chmod(0o000, locked_parent)
      unwritable_path = File.join(locked_parent, "nested", "forwards.json")

      begin
        expect {
          described_class.write!(account: account, config_path: unwritable_path)
        }.to raise_error(Federation::TcpForwarderConfigWriter::WriteError)
      ensure
        FileUtils.chmod(0o755, locked_parent)
      end
    end

    describe "ENV path override" do
      after { ENV.delete("POWERNODE_TCPFWD_CONFIG_PATH") }

      it "writes to the ENV-overridden path when config_path isn't given" do
        env_path = File.join(tmp_dir, "env-forwards.json")
        ENV["POWERNODE_TCPFWD_CONFIG_PATH"] = env_path
        result = described_class.write!(account: account)
        expect(result[:output_path]).to eq(env_path)
        expect(File.exist?(env_path)).to be true
      end
    end
  end

  describe "#render_config" do
    it "returns a plain hash with no filesystem side effects" do
      sub = create(:system_federation_service_subscription, :active, :site_local, account: account,
                                                                                    local_hostname: "localhost:5432",
                                                                                    backend_vip: "fd00:b0b::28",
                                                                                    backend_port: 5432)
      writer = described_class.new(account: account, config_path: config_path)
      hash = writer.render_config([ sub ])

      expect(hash).to eq(
        "forwards" => [
          {
            "listen" => "127.0.0.1:5432",
            "backend" => "[fd00:b0b::28]:5432",
            "protocol" => "tcp",
            "subscription_id" => sub.id
          }
        ]
      )
      expect(File.exist?(config_path)).to be false
    end
  end
end
