# frozen_string_literal: true

require "rails_helper"

RSpec.describe System::Providers::Proxmox::Client do
  subject(:client) do
    described_class.new(
      endpoint: "https://pve.test:8006",
      token_id: "root@pam!powernode",
      token_secret: "00000000-0000-0000-0000-000000000000",
      verify_ssl: false
    )
  end

  describe "#upload_file" do
    let(:upload_url) { "https://pve.test:8006/api2/json/nodes/dna/storage/dna-data/upload" }

    before do
      stub_request(:post, upload_url)
        .to_return(status: 200, body: { "data" => "UPID:dna:001:001:001:imgcopy:200:root@pam!powernode:" }.to_json,
                   headers: { "Content-Type" => "application/json" })
    end

    it "POSTs a multipart upload with content=import and returns the task UPID" do
      upid = client.upload_file(
        node: "dna", storage: "dna-data", filename: "uefi-uki.img",
        io: StringIO.new("uki-bytes"), content: "import"
      )

      expect(upid).to eq("UPID:dna:001:001:001:imgcopy:200:root@pam!powernode:")
      expect(a_request(:post, upload_url).with { |req|
        req.headers["Content-Type"].to_s.start_with?("multipart/form-data") &&
          req.body.include?('name="content"') && req.body.include?("import") &&
          req.body.include?('filename="uefi-uki.img"')
      }).to have_been_made
    end

    it "includes the checksum fields when a sha256 is supplied" do
      client.upload_file(
        node: "dna", storage: "dna-data", filename: "uefi-uki.img",
        io: StringIO.new("uki-bytes"), content: "import",
        checksum: "a" * 64, checksum_algorithm: "sha256"
      )

      expect(a_request(:post, upload_url).with { |req|
        req.body.include?('name="checksum"') && req.body.include?("a" * 64) &&
          req.body.include?('name="checksum-algorithm"') && req.body.include?("sha256")
      }).to have_been_made
    end
  end

  describe "#wait_task" do
    let(:status_url) { %r{\Ahttps://pve\.test:8006/api2/json/nodes/dna/tasks/.+/status\z} }
    let(:upid) { "UPID:dna:001B5861:0844EF54:6A4B9CB3:imgcopy::admin@pam!powernode:" }
    let(:not_found_body) { { "errors" => { "upid" => "no such task" } }.to_json }
    let(:done_body) { { "data" => { "status" => "stopped", "exitstatus" => "OK", "type" => "imgcopy" } }.to_json }

    it "tolerates a transient 'no such task' while the just-returned UPID registers, then completes" do
      stub_request(:get, status_url).to_return(
        { status: 400, body: not_found_body, headers: { "Content-Type" => "application/json" } },
        { status: 400, body: not_found_body, headers: { "Content-Type" => "application/json" } },
        { status: 200, body: done_body, headers: { "Content-Type" => "application/json" } }
      )

      result = client.wait_task(node: "dna", upid: upid, poll_every: 0)
      expect(result["exitstatus"]).to eq("OK")
    end

    it "re-raises immediately on a non-'no such task' error (does not mask real failures)" do
      stub_request(:get, status_url).to_return(
        status: 500, body: { "message" => "internal boom" }.to_json,
        headers: { "Content-Type" => "application/json" }
      )

      expect {
        client.wait_task(node: "dna", upid: upid, poll_every: 0)
      }.to raise_error(System::Providers::Proxmox::Client::Error, /boom/)
    end
  end

  # IMP-019fe64b: PVE answers a request for a vmid it has no config for with
  # 500 + "Configuration file '...' does not exist", NOT 404. handle_response
  # mapped only 404 to NotFoundError, so a gone VM surfaced as a generic Error.
  # Two callers key their behaviour on that class: terminate_instance's
  # idempotent "already gone -> success" branch, and get_instance's
  # ResourceNotFoundError, which ProvisionVerifier turns into the actionable
  # "provider has no record" detail. Both degraded to opaque failure.
  describe "a gone VM (PVE 500 with no config file)" do
    let(:status_url) { "https://pve.test:8006/api2/json/nodes/rna/qemu/9009/status/current" }

    it "classifies it as NotFoundError, not a generic Error" do
      stub_request(:get, status_url).to_return(
        status: 500,
        body: { "message" => "Configuration file 'nodes/rna/qemu-server/9009.conf' does not exist" }.to_json,
        headers: { "Content-Type" => "application/json" }
      )

      expect { client.get("/api2/json/nodes/rna/qemu/9009/status/current") }
        .to raise_error(System::Providers::Proxmox::Client::NotFoundError, /does not exist/)
    end

    it "still treats an unrelated 500 as a generic Error" do
      stub_request(:get, status_url).to_return(
        status: 500, body: { "message" => "internal boom" }.to_json,
        headers: { "Content-Type" => "application/json" }
      )

      # Assert the class is Error and NOT the NotFoundError subclass. A bare
      # `not_to raise_error(NotFoundError)` would pass on any other exception,
      # including one raised before the request is ever made.
      expect { client.get("/api2/json/nodes/rna/qemu/9009/status/current") }
        .to raise_error(System::Providers::Proxmox::Client::Error, /boom/) { |e|
          expect(e).not_to be_a(System::Providers::Proxmox::Client::NotFoundError)
        }
    end
  end
end
