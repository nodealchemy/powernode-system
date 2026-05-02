# frozen_string_literal: true

require "rails_helper"

# Golden Eclipse M1.C — RsyncSpecCompiler + ModuleBuildDispatchService.
RSpec.describe System::RsyncSpecCompiler do
  let(:account)  { create(:account) }
  let(:platform) { create(:system_node_platform, account: account) }
  let(:category) { create(:system_node_module_category, account: account) }

  let(:node_module) do
    mod = create(:system_node_module,
                 account: account, node_platform: platform, category: category,
                 variety: "subscription", name: "compiled-mod")
    mod.update!(
      mask: "/etc/secret",
      file_spec: "/etc/desired",
      package_spec: "nginx\nlibpcre3"
    )
    mod
  end

  describe ".compile" do
    it "produces rsync_spec + package_spec strings + fingerprint" do
      result = described_class.compile(node_module: node_module)
      expect(result.rsync_spec).to include("- /etc/secret\n", "+ /etc/desired\n", "- *\n")
      expect(result.package_spec).to eq("libpcre3\nnginx\n") # sorted by encode_specs
      expect(result.fingerprint).to match(/\A[a-f0-9]{64}\z/)
    end

    it "emits empty package_spec when none set" do
      mod = create(:system_node_module, account: account, node_platform: platform,
                   category: category, variety: "subscription", name: "no-pkg-mod")
      result = described_class.compile(node_module: mod)
      expect(result.package_spec).to eq("")
    end

    it "fingerprint is deterministic for identical inputs" do
      a = described_class.compile(node_module: node_module)
      b = described_class.compile(node_module: node_module)
      expect(a.fingerprint).to eq(b.fingerprint)
    end
  end
end

RSpec.describe System::ModuleBuildDispatchService do
  before { described_class.reset! }
  after  { described_class.reset! }

  let(:account)  { create(:account) }
  let(:platform) { create(:system_node_platform, account: account) }
  let(:category) { create(:system_node_module_category, account: account) }
  let(:node_module) do
    create(:system_node_module,
           account: account, node_platform: platform, category: category,
           variety: "subscription", name: "build-mod",
           gitea_repo_full_name: "ipnode-acme/build-mod")
  end

  describe ".dispatch_build!" do
    it "dispatches with compiled rsync_spec + package_spec inputs" do
      node_module.update!(mask: "/m", file_spec: "/f", package_spec: "pkg")
      result = described_class.dispatch_build!(node_module: node_module)

      expect(result.ok?).to be true
      expect(result.dispatch_id).to start_with("local-")
      expect(result.rsync_spec).to include("+ /f\n", "- /m\n", "- *\n")
      expect(result.package_spec).to eq("pkg\n")

      adapter = described_class.adapter
      expect(adapter.dispatched.size).to eq(1)
      payload = adapter.dispatched.last
      expect(payload[:repository]).to eq("ipnode-acme/build-mod")
      expect(payload[:workflow]).to eq("build.yaml")
      expect(payload[:inputs][:module_id]).to eq(node_module.id)
      expect(payload[:inputs][:fingerprint]).to eq(result.fingerprint)
    end

    it "fails clearly when gitea_repo_full_name is missing" do
      orphan = create(:system_node_module, account: account, node_platform: platform,
                      category: category, variety: "subscription", name: "orphan",
                      gitea_repo_full_name: nil)
      result = described_class.dispatch_build!(node_module: orphan)
      expect(result.ok?).to be false
      expect(result.error).to match(/gitea_repo_full_name/)
    end

    it "honors a custom ref + workflow filename" do
      described_class.dispatch_build!(node_module: node_module, ref: "release/2.0", workflow: "custom.yaml")
      payload = described_class.adapter.dispatched.last
      expect(payload[:ref]).to eq("release/2.0")
      expect(payload[:workflow]).to eq("custom.yaml")
    end

    it "selects LocalDispatchAdapter in test by default" do
      expect(described_class.adapter).to be_a(described_class::LocalDispatchAdapter)
    end

    it "honors POWERNODE_BUILD_DISPATCH_MODE=gitea" do
      stub_const("ENV", ENV.to_h.merge("POWERNODE_BUILD_DISPATCH_MODE" => "gitea"))
      described_class.reset!
      expect(described_class.adapter).to be_a(described_class::GiteaDispatchAdapter)
    end
  end
end
