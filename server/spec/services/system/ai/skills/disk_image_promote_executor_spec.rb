# frozen_string_literal: true

require "rails_helper"

# HIER-P2F — the Disk Image Manager's promote skill. A thin executor over
# System::Executors::DiskImage::PromotePublication (the same transaction the
# system_set_default_disk_image_publication MCP verb runs), gated on the agent's
# own `system.disk_image_publication_promote` row.
# Since HIER-P2H that row governs TWO doors, not one: the MCP verb declares the
# same category (SystemFleetTool::DISK_IMAGE_PROMOTE_CATEGORY) and replays
# through Ai::Executors::DeferredToolCall, so this executor is one of the two
# sites that consult it — and the only two. There is no REST promote door:
# DiskImagePublicationsController serves index/show/rollback only, and no
# controller calls PromotePublication.
RSpec.describe System::Ai::Skills::DiskImagePromoteExecutor do
  let(:account)  { create(:account) }
  let(:platform) { create(:system_node_platform, account: account) }
  let(:exec)     { described_class.new(account: account) }

  describe ".descriptor" do
    it "gates on the Disk Image Manager's declared promote category and binds to that agent" do
      d = described_class.descriptor
      expect(d[:name]).to eq("disk_image_promote")
      expect(d[:category]).to eq("fleet")
      expect(d[:requires_approval]).to be true
      expect(d[:inputs].keys).to eq([ :publication_id ])
      expect(d[:outputs].keys).to include(:promoted, :publication_id, :node_platform_id, :previous_publication_id)

      expect(described_class.action_category).to eq("system.disk_image_publication_promote")
      expect(System::Governance::PolicyDeclarations::DISK_IMAGE_MANAGER_POLICIES)
        .to have_key(described_class.action_category)

      reg = System::Ai::Skills::SkillBindings.all.find { |r| r[:executor] == described_class }
      expect(reg).to be_present
      expect(reg[:agents]).to eq([ "Disk Image Manager" ])
    end
  end

  describe "#execute (policy auto-executes)" do
    before { auto_execute_skill_policy!(account, described_class) }

    it "promotes a published publication to the platform default and retires the prior one" do
      prior = create(:system_disk_image_publication, :published, account: account, node_platform: platform)
      platform.update!(disk_image_file_object_id: prior.file_object_id)
      candidate = create(:system_disk_image_publication, :published, account: account, node_platform: platform)

      r = exec.execute(publication_id: candidate.id)

      expect(r[:success]).to be true
      expect(r.dig(:data, :promoted)).to be true
      expect(r.dig(:data, :publication_id)).to eq(candidate.id)
      expect(r.dig(:data, :node_platform_id)).to eq(platform.id)
      expect(r.dig(:data, :previous_publication_id)).to eq(prior.id)
      expect(r.dig(:data, :git_sha)).to eq(candidate.git_sha)

      platform.reload
      expect(platform.disk_image_file_object_id).to eq(candidate.file_object_id)
      expect(platform.disk_image_publication_status).to eq("published")
      expect(prior.reload.status).to eq("retired")
    end

    it "refuses a publication that is not published, leaving the pointer untouched" do
      queued = create(:system_disk_image_publication, account: account, node_platform: platform)

      r = exec.execute(publication_id: queued.id)

      expect(r[:success]).to be false
      expect(r[:error]).to match(/status="queued"/)
      expect(platform.reload.disk_image_file_object_id).to be_nil
    end

    it "refuses a publication that belongs to another account" do
      foreign = create(:system_disk_image_publication, :published)

      r = exec.execute(publication_id: foreign.id)

      expect(r[:success]).to be false
      expect(r[:error]).to match(/not found/)
      expect(foreign.node_platform.reload.disk_image_file_object_id).to be_nil
    end
  end

  describe "the approval gate" do
    it "parks the promote (no write) when no policy auto-executes it" do
      candidate = create(:system_disk_image_publication, :published, account: account, node_platform: platform)

      r = exec.execute(publication_id: candidate.id)

      expect(r[:pending]).to be true
      expect(r.dig(:data, :action_category)).to eq("system.disk_image_publication_promote")
      expect(platform.reload.disk_image_file_object_id).to be_nil
      expect(Ai::DeferredOperation.where(account: account, action_category: described_class.action_category).count).to eq(1)
    end
  end

  # HIER-P2F review — admission runs BEFORE the approval gate. BaseSkillExecutor
  # calls #validate_inputs! first precisely so "a call that could only ever fail
  # must not park an approval an operator then has to dispose of"; the MCP door
  # pre-validates for the same reason. These run with NO auto-execute policy, so
  # a check that ran inside #perform would park a deferred operation instead.
  describe "admission before the approval gate" do
    it "refuses an unknown publication without parking an approval" do
      r = exec.execute(publication_id: SecureRandom.uuid)

      expect(r[:success]).to be false
      expect(r[:pending]).to be_falsey
      expect(r[:error]).to match(/not found/)
      expect(Ai::DeferredOperation.where(account: account).count).to eq(0)
    end

    it "refuses a publication that is not published without parking an approval" do
      queued = create(:system_disk_image_publication, account: account, node_platform: platform)

      r = exec.execute(publication_id: queued.id)

      expect(r[:success]).to be false
      expect(r[:error]).to match(/status="queued"/)
      expect(Ai::DeferredOperation.where(account: account).count).to eq(0)
      expect(platform.reload.disk_image_file_object_id).to be_nil
    end
  end

end
