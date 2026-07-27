# frozen_string_literal: true

require "rails_helper"

# A UPID names the node its task runs on, and that is NOT always the node the
# request targeted.
#
# PVE runs a storage UPLOAD as an `imgcopy` task on the node that RECEIVES the
# API call (the endpoint host), then copies the bytes onto the target node's
# storage. Uploading to /nodes/rna/storage/local/upload against a dna endpoint
# therefore returns `UPID:dna:...:imgcopy:`, and polling /nodes/rna/tasks/<that>
# gets "no such task" — correctly, because the task belongs to dna.
#
# Observed live on PVE 9.2.3 while provisioning the first instance onto a node
# other than the API endpoint; it had stayed invisible for as long as every
# provision happened to target the endpoint host itself.
RSpec.describe System::Providers::Proxmox::Client do
  subject(:client) do
    described_class.new(endpoint_url: "https://dna.ipnode.net:8006",
                        token_id: "user@pve!tok", token_secret: "s3cr3t", verify_ssl: false)
  rescue ArgumentError
    described_class.allocate
  end

  describe "#upid_node" do
    it "extracts the owning node from a real upload UPID" do
      upid = "UPID:dna:00115C73:02BD9E4B:6A66E104:imgcopy::admin@pam!powernode:"
      expect(client.send(:upid_node, upid)).to eq("dna")
    end

    it "extracts it for an ordinary VM task too" do
      upid = "UPID:rna:000D6722:1867630E:6A0D37CC:qmstart:601:admin@pam!powernode:"
      expect(client.send(:upid_node, upid)).to eq("rna")
    end

    it "returns nil for anything that is not a UPID, so callers fall back" do
      [ nil, "", "not-a-upid", "UPID:", 42 ].each do |bad|
        expect(client.send(:upid_node, bad)).to be_nil, "expected nil for #{bad.inspect}"
      end
    end
  end

  describe "#wait_task node resolution" do
    let(:upload_upid) { "UPID:dna:00115C73:02BD9E4B:6A66E104:imgcopy::admin@pam!powernode:" }

    # THE regression. Called with the TARGET node (rna) but a UPID owned by dna,
    # wait_task must poll dna. Polling rna is what produced
    # "PVE 400: upid: no such task" and failed a provision whose upload had in
    # fact succeeded — the file was on disk the whole time.
    it "polls the node named in the UPID, not the node argument" do
      polled = []
      allow(client).to receive(:get) do |path|
        polled << path
        { "status" => "stopped", "exitstatus" => "OK" }
      end

      client.wait_task(node: "rna", upid: upload_upid)

      expect(polled.first).to include("/nodes/dna/tasks/")
      expect(polled.first).not_to include("/nodes/rna/tasks/")
    end

    it "falls back to the node argument when the UPID is unparseable" do
      polled = []
      allow(client).to receive(:get) do |path|
        polled << path
        { "status" => "stopped", "exitstatus" => "OK" }
      end

      client.wait_task(node: "rna", upid: "garbage")

      expect(polled.first).to include("/nodes/rna/tasks/")
    end

    it "still agrees with the node argument in the same-node case (no behaviour change)" do
      polled = []
      allow(client).to receive(:get) do |path|
        polled << path
        { "status" => "stopped", "exitstatus" => "OK" }
      end

      client.wait_task(node: "dna", upid: "UPID:dna:0001:0002:0003:qmstart:100:root@pam:")

      expect(polled.first).to include("/nodes/dna/tasks/")
    end
  end
end
