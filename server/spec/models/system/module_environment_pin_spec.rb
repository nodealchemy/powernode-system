# frozen_string_literal: true

require "rails_helper"

# Environment campaign, increment 4 — the pin row: what one pinned plane
# runs of one module.
RSpec.describe System::ModuleEnvironmentPin do
  let(:account)  { create(:account) }
  let(:platform) { create(:system_node_platform, account: account) }
  let(:category) { create(:system_node_module_category, account: account) }
  let(:mod)      { create(:system_node_module, account: account, node_platform: platform, category: category) }
  let(:v1)       { create(:system_node_module_version, node_module: mod, version_number: 1) }
  let(:staging)  { account.environments.find_by!(slug: "staging") }

  it "is unique per module and environment" do
    described_class.create!(account: account, node_module: mod, environment: staging, node_module_version: v1)
    dup = described_class.new(account: account, node_module: mod, environment: staging, node_module_version: v1)
    expect(dup).not_to be_valid
    expect(dup.errors[:environment_id]).to be_present
  end

  it "refuses a version of another module and rows that straddle accounts" do
    other = create(:system_node_module, account: account, node_platform: platform, category: category)
    foreign_version = create(:system_node_module_version, node_module: other, version_number: 1)
    pin = described_class.new(account: account, node_module: mod, environment: staging, node_module_version: foreign_version)
    expect(pin).not_to be_valid
    expect(pin.errors[:node_module_version]).to include("belongs to a different module")

    other_account = create(:account)
    straddling = described_class.new(account: other_account, node_module: mod, environment: staging, node_module_version: v1)
    expect(straddling).not_to be_valid
    expect(straddling.errors[:node_module]).to be_present
    expect(straddling.errors[:environment]).to be_present
  end

  it "is destroyed with its module" do
    described_class.create!(account: account, node_module: mod, environment: staging, node_module_version: v1)
    expect { mod.destroy! }.to change(described_class, :count).by(-1)
  end
end
