# frozen_string_literal: true

require "rails_helper"

# system_module_publish_target answers "where would a CI publish for this module
# land, and would the platform accept it" WITHOUT publishing anything.
#
# It exists because answering that on 2026-07-27 took a failed build, a CI log,
# and a hand-written query against the control plane's database. The chain —
# a one-off module holding the canonical OCI binding, the resolver matching the
# binding ahead of the name, ManifestImportService then refusing the mismatch —
# was observable nowhere until it produced a 422.
RSpec.describe Ai::Tools::SystemFleetTool do
  let(:account)  { create(:account) }
  let(:user)     { create(:user, account: account) }
  let(:platform) { create(:system_node_platform, account: account) }
  let(:category) { create(:system_node_module_category, account: account, variety: "subscription") }

  # The action is exercised directly rather than through execute(): this spec is
  # about the resolution preview's answers, not the permission plumbing that
  # every other action in this tool already shares.
  subject(:tool) { described_class.new(account: account, agent: nil, user: user) }

  def module_named(name, repo: nil)
    create(:system_node_module,
           account: account, node_platform: platform, category: category,
           name: name, variety: "subscription", gitea_repo_full_name: repo)
  end

  # success_result wraps payloads as { success:, data: }.
  def preview(module_name)
    tool.send(:module_publish_target, { module_name: module_name }).fetch(:data)
  end

  it "resolves to the module whose name matches" do
    canonical = module_named("powernode-system-base")

    result = preview("powernode-system-base")

    expect(result[:resolves_to][:id]).to eq(canonical.id)
    expect(result[:would_auto_create]).to be false
  end

  # THE ops-hub shape.
  it "flags a foreign repo binding held by a different module" do
    module_named("powernode-system-base")
    variant = module_named("powernode-system-base-vm104-devpin",
                           repo: "powernode/powernode-system-base")

    result = preview("powernode-system-base")

    expect(result[:foreign_repo_binding]).to be true
    expect(result[:repo_binding_holder][:id]).to eq(variant.id)
    expect(result[:advisory]).to match(/vm104-devpin/)
    # Still resolves correctly — the binding is drift, not a blocker.
    expect(result[:resolves_to][:name]).to eq("powernode-system-base")
  end

  it "stays quiet when the binding sits on the published module" do
    module_named("gitleaks", repo: "powernode/gitleaks")

    result = preview("gitleaks")

    expect(result[:foreign_repo_binding]).to be false
    expect(result[:advisory]).to be_nil
  end

  it "reports that an unknown module would be auto-created" do
    result = preview("brand-new-module")

    expect(result[:would_auto_create]).to be true
    expect(result[:resolves_to]).to be_nil
    expect(result[:advisory]).to match(/would\s+create/i)
  end

  # A preview that mutates is not a preview. The resolver's auto-create branch
  # must never run here.
  it "creates nothing" do
    expect { preview("nothing-should-appear") }
      .not_to change { System::NodeModule.where(account: account).count }
  end

  it "requires a module_name" do
    result = tool.send(:module_publish_target, {})
    expect(result[:success]).to be false
    expect(result[:error]).to match(/module_name required/)
  end
end
