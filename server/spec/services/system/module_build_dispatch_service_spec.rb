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

    # Cross-module verification: when a target node has multiple modules
    # assigned, lower-priority neighbors' protected_spec must end up in
    # the higher module's rsync_spec exclude list. This is the gate the
    # build pipeline relies on — without it, an apache layer could ship
    # /etc/shadow and silently override system-base at union mount time.
    context "with a target node and a lower-priority neighbor" do
      let(:cat_low)  { create(:system_node_module_category, account: account, name: "low",  position: 1) }
      let(:cat_high) { create(:system_node_module_category, account: account, name: "high", position: 10) }
      let(:template) { create(:system_node_template, account: account, node_platform: platform) }
      let(:node)     { create(:system_node, account: account, node_template: template) }

      let(:base_mod) do
        create(:system_node_module, account: account, node_platform: platform,
               category: cat_low, variety: "subscription", name: "base-mod").tap do |m|
          m.update!(protected_spec: "/etc/shadow\n/etc/sudoers")
        end
      end
      let(:service_mod) do
        create(:system_node_module, account: account, node_platform: platform,
               category: cat_high, variety: "subscription", name: "service-mod").tap do |m|
          m.update!(file_spec: "/etc/service/**", mask: "/var/cache/apt/**")
        end
      end

      before do
        System::NodeModuleAssignment.create!(node: node, node_module: base_mod, enabled: true)
        System::NodeModuleAssignment.create!(node: node, node_module: service_mod, enabled: true)
      end

      it "folds the lower-priority neighbor's protected_spec into the higher module's rsync_spec" do
        result = described_class.compile(node_module: service_mod, target: node)

        expect(result.rsync_spec).to include("- /etc/shadow\n")
        expect(result.rsync_spec).to include("- /etc/sudoers\n")
        expect(result.rsync_spec).to include("- /var/cache/apt/**\n")  # service_mod's own mask
        expect(result.rsync_spec).to include("+ /etc/service/**\n")    # service_mod's file_spec
      end

      it "the lower module's own rsync_spec does NOT exclude its own protected paths" do
        # base-mod ships /etc/shadow itself (file_spec /etc/**, say). Its
        # protected_spec is an outbound claim, not a self-exclude.
        base_mod.update!(file_spec: "/etc/**")
        result = described_class.compile(node_module: base_mod, target: node)

        expect(result.rsync_spec).not_to include("- /etc/shadow\n")
        expect(result.rsync_spec).to include("+ /etc/**\n")
      end
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

    # End-to-end CI verification: when a build is dispatched against a
    # target node, the workflow input rsync_spec MUST include neighbor
    # modules' protected_spec entries. This is the gate the .gitea/
    # workflows/build.yaml relies on — it merges the supplied filter
    # via `rsync -aH --filter="merge rsync_spec.filter"`, so any path
    # we want to keep out of the blob must reach the dispatched input.
    it "dispatches with neighbor protected_spec folded into the workflow rsync_spec input" do
      cat_low  = create(:system_node_module_category, account: account, name: "low",  position: 1)
      cat_high = create(:system_node_module_category, account: account, name: "high", position: 10)
      template = create(:system_node_template, account: account, node_platform: platform)
      target_node = create(:system_node, account: account, node_template: template)

      base_mod = create(:system_node_module, account: account, node_platform: platform,
                        category: cat_low, variety: "subscription", name: "base-target",
                        gitea_repo_full_name: "ipnode-acme/base-target")
      base_mod.update!(protected_spec: "/etc/shadow\n/etc/ssh/ssh_host_*_key")

      service_mod = create(:system_node_module, account: account, node_platform: platform,
                           category: cat_high, variety: "subscription", name: "service-target",
                           gitea_repo_full_name: "ipnode-acme/service-target")
      service_mod.update!(file_spec: "/etc/service/**")

      [base_mod, service_mod].each do |m|
        System::NodeModuleAssignment.create!(node: target_node, node_module: m, enabled: true)
      end

      described_class.dispatch_build!(node_module: service_mod, target: target_node)
      payload = described_class.adapter.dispatched.last

      expect(payload[:inputs][:rsync_spec]).to include("- /etc/shadow\n")
      expect(payload[:inputs][:rsync_spec]).to include("- /etc/ssh/ssh_host_*_key\n")
      expect(payload[:inputs][:rsync_spec]).to include("+ /etc/service/**\n")
    end
  end
end
