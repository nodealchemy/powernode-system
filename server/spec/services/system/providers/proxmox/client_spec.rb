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
end
