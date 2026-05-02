# frozen_string_literal: true

require "rails_helper"

# Golden Eclipse M0.I — Node delegates default build/init/sync scripts to its
# platform via the template. Reference legacy node.rb:32-35 (delegate ... to: :node_platform).
RSpec.describe System::Node, "default script delegation", type: :model do
  let(:account) { create(:account) }
  let(:platform) do
    create(
      :system_node_platform,
      account: account,
      build_script: "#!/bin/bash\necho BUILD",
      init_script:  "#!/bin/bash\necho INIT",
      sync_script:  "#!/bin/bash\necho SYNC"
    )
  end
  let(:template) { create(:system_node_template, account: account, node_platform: platform) }
  let(:node)     { create(:system_node, account: account, node_template: template) }

  describe "#node_platform" do
    it "walks node_template -> node_platform" do
      expect(node.node_platform).to eq(platform)
    end

    it "returns nil when template is missing" do
      orphan = build(:system_node, account: account, node_template: nil, name: "orphan")
      expect(orphan.node_platform).to be_nil
    end
  end

  describe "#build_script / #init_script / #sync_script" do
    it "delegates each to the platform" do
      expect(node.build_script).to eq("#!/bin/bash\necho BUILD")
      expect(node.init_script).to  eq("#!/bin/bash\necho INIT")
      expect(node.sync_script).to  eq("#!/bin/bash\necho SYNC")
    end

    it "returns nil for each when template is missing" do
      orphan = build(:system_node, account: account, node_template: nil, name: "orphan")
      expect(orphan.build_script).to be_nil
      expect(orphan.init_script).to be_nil
      expect(orphan.sync_script).to be_nil
    end

    it "tracks platform updates" do
      platform.update!(init_script: "REPLACED")
      expect(node.reload.init_script).to eq("REPLACED")
    end
  end
end
