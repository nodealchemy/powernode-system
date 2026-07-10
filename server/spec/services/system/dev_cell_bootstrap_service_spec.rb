# frozen_string_literal: true

require "rails_helper"

# Unit gate for DevCellBootstrapService#ssh_clone_url endpoint derivation.
#
# Regression: Gitea self-reports its CONTAINER-INTERNAL SSH_PORT (e.g. :220),
# which is usually NOT the published/reachable port — cloning against it fails
# "connect to <host> port 220: Connection refused". The clone endpoint must
# instead be consistent with the host-key pinned in dev_cell_gitea_known_hosts.
#
# Tests exercise the private derivation directly via `.allocate` + `send` so no
# DB / real credential is needed — pure host/port logic.
RSpec.describe System::DevCellBootstrapService do
  subject(:service) { described_class.allocate }

  # Gitea reports the correct HOST but its internal port :220.
  let(:gitea_ssh_url) { "ssh://git@git.powernode.net:220/powernode/powernode-platform.git" }
  let(:client) { instance_double("Devops::Git::ApiClient") }
  let(:provider) { double("provider", effective_web_base_url: "https://git.powernode.org") }
  let(:credential) { double("credential", provider: provider) }

  before do
    allow(client).to receive(:get_repository).and_return("ssh_url" => gitea_ssh_url)
    # No SiteSetting/ENV port override unless a test sets one.
    allow(::SiteSetting).to receive(:get).with("dev_cell_gitea_ssh_port").and_return(nil)
  end

  def clone_url(known_hosts:)
    allow(service).to receive(:known_hosts_for).and_return(known_hosts)
    service.send(:ssh_clone_url, client, credential, "powernode", "powernode-platform")
  end

  describe "#ssh_clone_url" do
    it "derives host+port from the known_hosts pin (standard port 22 → scp form)" do
      pin = "git.powernode.net ssh-ed25519 AAAAC3Nz..."
      expect(clone_url(known_hosts: pin))
        .to eq("git@git.powernode.net:powernode/powernode-platform.git")
    end

    it "derives a non-standard pinned port into an ssh:// URL" do
      pin = "[git.powernode.net]:2222 ssh-ed25519 AAAAC3Nz..."
      expect(clone_url(known_hosts: pin))
        .to eq("ssh://git@git.powernode.net:2222/powernode/powernode-platform.git")
    end

    it "IGNORES Gitea's self-reported :220 and defaults to :22 when unpinned (the bug)" do
      expect(clone_url(known_hosts: ""))
        .to eq("git@git.powernode.net:powernode/powernode-platform.git")
    end

    it "honors a config-driven port override when unpinned" do
      allow(::SiteSetting).to receive(:get).with("dev_cell_gitea_ssh_port").and_return("2200")
      expect(clone_url(known_hosts: nil))
        .to eq("ssh://git@git.powernode.net:2200/powernode/powernode-platform.git")
    end

    it "falls back to the provider web host when Gitea has no ssh_url and nothing is pinned" do
      allow(client).to receive(:get_repository).and_return({})
      expect(clone_url(known_hosts: nil))
        .to eq("git@git.powernode.org:powernode/powernode-platform.git")
    end

    it "falls back to the https web URL when no host can be derived at all" do
      allow(client).to receive(:get_repository).and_return({})
      allow(provider).to receive(:effective_web_base_url).and_return("https://")
      expect(clone_url(known_hosts: nil))
        .to eq("https:///powernode/powernode-platform.git")
    end

    it "tolerates a Gitea ApiError and still derives from the pin" do
      allow(client).to receive(:get_repository).and_raise(::Devops::Git::ApiClient::ApiError.new("boom"))
      pin = "git.powernode.net ssh-ed25519 AAAAC3Nz..."
      expect(clone_url(known_hosts: pin))
        .to eq("git@git.powernode.net:powernode/powernode-platform.git")
    end
  end

  describe "#endpoint_from_known_hosts" do
    it "parses [host]:port form" do
      expect(service.send(:endpoint_from_known_hosts, "[h.example]:2222 ssh-ed25519 AAAA"))
        .to eq([ "h.example", 2222 ])
    end

    it "parses bare host as port 22" do
      expect(service.send(:endpoint_from_known_hosts, "h.example ssh-ed25519 AAAA"))
        .to eq([ "h.example", 22 ])
    end

    it "takes the first of comma-separated host aliases" do
      expect(service.send(:endpoint_from_known_hosts, "h.example,10.0.0.1 ssh-ed25519 AAAA"))
        .to eq([ "h.example", 22 ])
    end

    it "skips comment and blank lines" do
      expect(service.send(:endpoint_from_known_hosts, "\n# a comment\n[h.example]:44 ssh-rsa BBBB\n"))
        .to eq([ "h.example", 44 ])
    end

    it "returns [nil, nil] for blank input" do
      expect(service.send(:endpoint_from_known_hosts, "")).to eq([ nil, nil ])
      expect(service.send(:endpoint_from_known_hosts, nil)).to eq([ nil, nil ])
    end
  end

  describe "#gitea_ssh_host" do
    it "extracts the host from an ssh:// url (ignoring the port)" do
      allow(client).to receive(:get_repository).and_return("ssh_url" => "ssh://git@h.example:220/o/r.git")
      expect(service.send(:gitea_ssh_host, client, "o", "r")).to eq("h.example")
    end

    it "extracts the host from an scp-style url" do
      allow(client).to receive(:get_repository).and_return("ssh_url" => "git@h.example:o/r.git")
      expect(service.send(:gitea_ssh_host, client, "o", "r")).to eq("h.example")
    end

    it "returns nil when Gitea reports no ssh_url" do
      allow(client).to receive(:get_repository).and_return({})
      expect(service.send(:gitea_ssh_host, client, "o", "r")).to be_nil
    end
  end

  describe "#configured_ssh_port" do
    it "defaults to 22" do
      expect(service.send(:configured_ssh_port)).to eq(22)
    end

    it "uses the SiteSetting override when a positive integer" do
      allow(::SiteSetting).to receive(:get).with("dev_cell_gitea_ssh_port").and_return("2222")
      expect(service.send(:configured_ssh_port)).to eq(2222)
    end

    it "ignores a non-positive/garbage override and falls back to 22" do
      allow(::SiteSetting).to receive(:get).with("dev_cell_gitea_ssh_port").and_return("nope")
      expect(service.send(:configured_ssh_port)).to eq(22)
    end
  end
end
