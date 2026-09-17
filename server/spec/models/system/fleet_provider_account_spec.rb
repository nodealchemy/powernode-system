# frozen_string_literal: true

require "rails_helper"

# IMP-b9f4b900f00b — a fleet row may not point at another account's provider
# catalog.
#
# ProviderRegion and ProviderInstanceType rows are per-account (account_id is
# NOT NULL; catalog sync and account bootstrap create them under the account
# that owns the provider). NodeInstance and InstancePool referenced them with
# no account check, so an instance or pool could be placed in, and provisioned
# as, another tenant's region and SKU. The template checks on Node and
# InstancePool are pinned in fleet_environment_spec.rb; this file pins the
# provider-catalog half.
RSpec.describe "fleet rows use their own account's provider catalog" do
  let(:account) { create(:account) }
  let(:foreign_account) { create(:account) }
  let(:template) { create(:system_node_template, account: account) }
  let(:node) { create(:system_node, account: account, node_template: template) }

  let(:own_region) { create(:system_provider_region, account: account) }
  let(:own_type) { create(:system_provider_instance_type, account: account) }
  let(:foreign_region) { create(:system_provider_region, account: foreign_account) }
  let(:foreign_type) { create(:system_provider_instance_type, account: foreign_account) }

  def pool(**attrs)
    System::InstancePool.new(account: account, node_template: template, name: "pool-#{SecureRandom.hex(3)}",
                             lifecycle_class: "ephemeral", status: "active",
                             target_size: 0, min_size: 0, max_size: 1, **attrs)
  end

  describe System::NodeInstance do
    it "builds its default provider region and instance type on the instance's own account" do
      instance = create(:system_node_instance, node: node)
      expect(instance.provider_region.account_id).to eq(account.id)
      expect(instance.provider_instance_type.account_id).to eq(account.id)
    end

    it "accepts its own account's region and instance type" do
      instance = build(:system_node_instance, node: node, provider_region: own_region, provider_instance_type: own_type)
      expect(instance).to be_valid, instance.errors.full_messages.inspect
    end

    it "refuses another account's provider region" do
      instance = build(:system_node_instance, node: node, provider_region: foreign_region, provider_instance_type: own_type)
      expect(instance).not_to be_valid
      expect(instance.errors[:provider_region]).to include("must belong to the instance's account")
      expect(instance.errors[:provider_instance_type]).to be_empty
    end

    it "refuses another account's instance type" do
      instance = build(:system_node_instance, node: node, provider_region: own_region, provider_instance_type: foreign_type)
      expect(instance).not_to be_valid
      expect(instance.errors[:provider_instance_type]).to include("must belong to the instance's account")
      expect(instance.errors[:provider_region]).to be_empty
    end

    it "refuses repointing a saved instance at another account's region" do
      instance = create(:system_node_instance, node: node)
      instance.provider_region = foreign_region
      expect(instance).not_to be_valid
      expect(instance.errors[:provider_region]).to include("must belong to the instance's account")
    end

    it "stays valid without a region or instance type" do
      instance = build(:system_node_instance, node: node, provider_region: nil, provider_instance_type: nil)
      expect(instance).to be_valid, instance.errors.full_messages.inspect
    end

    # THE RULING'S OWN PREMISE (operator decision 2026-09-13/2026-09-17,
    # option a): the check runs only on create or when region/type/account
    # change, precisely so an EXISTING mismatched row (one saved before this
    # validation existed, or force-written out of band) does not become
    # unsaveable on every later touch. CloudSyncService's bare update!
    # (cloud_sync_service.rb:128/130/306/308/344), the heartbeat in
    # status_controller.rb:37, and InstancePoolService#replenish!/#drain!
    # all save this row unrescued on a hot path; without the on-change guard
    # the first hourly sync or heartbeat against a legacy mismatched row
    # would abort it — reinstating the outage this ruling exists to prevent.
    it "still saves an already-mismatched row on an unrelated attribute change" do
      instance = create(:system_node_instance, node: node, provider_region: own_region, provider_instance_type: own_type)
      # Force the row into a mismatched state OUT OF BAND (bypassing
      # validation), simulating a pre-existing bad row or one written before
      # this validation shipped.
      instance.update_column(:provider_region_id, foreign_region.id)
      instance.reload

      expect { instance.update!(status: "running") }.not_to raise_error
    end
  end

  describe System::InstancePool do
    it "accepts its own account's region and instance type" do
      expect(pool(provider_region: own_region, provider_instance_type: own_type)).to be_valid
    end

    it "refuses another account's provider region" do
      bad = pool(provider_region: foreign_region, provider_instance_type: own_type)
      expect(bad).not_to be_valid
      expect(bad.errors[:provider_region]).to include("must belong to the pool's account")
      expect(bad.errors[:provider_instance_type]).to be_empty
    end

    it "refuses another account's instance type" do
      bad = pool(provider_region: own_region, provider_instance_type: foreign_type)
      expect(bad).not_to be_valid
      expect(bad.errors[:provider_instance_type]).to include("must belong to the pool's account")
      expect(bad.errors[:provider_region]).to be_empty
    end

    it "stays valid without a region or instance type" do
      expect(pool).to be_valid
    end

    # Same premise as the NodeInstance example above: the on-change guard is
    # what keeps InstancePoolService#replenish!/#drain! (instance_pool.rb
    # :521/:545, bare update! unrescued on every tick) from aborting on a
    # legacy mismatched pool.
    it "still saves an already-mismatched pool on an unrelated attribute change" do
      saved = pool(provider_region: own_region, provider_instance_type: own_type)
      saved.save!
      saved.update_column(:provider_region_id, foreign_region.id)
      saved.reload

      expect { saved.update!(status: "paused") }.not_to raise_error
    end
  end

  # D1 (review 2026-09-18) — preferred_regions_belong_to_account had zero
  # coverage: nothing pinned it, so inverting the predicate to
  # `where(account_id: account_id)` or dropping the errors.add entirely left
  # the whole suite green, while InstancePoolService#pick_region_for_slot
  # (instance_pool_service.rb:2038-2046) would keep round-robining a foreign
  # tenant's region into ProvisioningService.
  describe "System::InstancePool#preferred_regions" do
    it "refuses a preferred_regions entry naming another account's region" do
      bad = pool(preferred_regions: [ foreign_region.id ])
      expect(bad).not_to be_valid
      expect(bad.errors[:preferred_regions].join).to match(/must all belong to the pool's account/)
      expect(bad.errors[:preferred_regions].join).to include(foreign_region.id)
    end

    it "accepts a preferred_regions entry naming the pool's own account's region" do
      good = pool(preferred_regions: [ own_region.id ])
      expect(good).to be_valid, good.errors.full_messages.inspect
    end

    it "accepts an empty preferred_regions" do
      expect(pool(preferred_regions: [])).to be_valid
    end

    # Same on-change premise as provider_region/provider_instance_type: a
    # legacy pool with a foreign id already in preferred_regions must not be
    # bricked by an unrelated save.
    it "still saves an already-mismatched preferred_regions on an unrelated attribute change" do
      saved = pool(provider_region: own_region, provider_instance_type: own_type)
      saved.save!
      saved.update_column(:preferred_regions, [ foreign_region.id ])
      saved.reload

      expect { saved.update!(status: "paused") }.not_to raise_error
    end
  end
end
