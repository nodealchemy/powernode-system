# frozen_string_literal: true

require "rails_helper"

# Campaign 01a08c9b increment B2 — InstancePool as a status component.
RSpec.describe System::Status::Contributors::InstancePoolContributor do
  let(:account)     { create(:account) }
  let(:contributor) { described_class.new }
  let(:template)    { create(:system_node_template, account: account) }
  let(:node)        { create(:system_node, account: account) }

  # No factory exists for System::InstancePool anywhere in either spec tree;
  # specs build them directly, and so does this one.
  def pool!(status: "active", target_size: 2, **attrs)
    System::InstancePool.create!(
      account: account, node_template: template, name: "pool-#{SecureRandom.hex(4)}",
      status: status, target_size: target_size, **attrs
    )
  end

  # Both pool columns must be set together — a database CHECK constraint
  # rejects one without the other.
  def member!(pool, pool_state:, status: "running")
    create(:system_node_instance, account: account, node: node, status: status,
                                  instance_pool_id: pool.id, pool_state: pool_state)
  end

  def components
    [].tap { |acc| contributor.each_component(account) { |record| acc << record } }
  end

  def condition(record, type)
    contributor.conditions_for(record).find { |c| c["type"] == type }
  end

  def verdict(record)
    Platform::Status::Condition.verdict_for_set(contributor.conditions_for(record))
  end

  describe "scope — what counts as gone" do
    it "excludes archived pools and keeps every other status" do
      live = System::InstancePool::STATUSES - described_class::GONE_STATUSES
      live.each { |status| pool!(status: status) }
      archived = pool!(status: "archived")

      expect(components.size).to eq(live.size)
      expect(components.map(&:id)).not_to include(archived.id)
    end

    it "keeps a draining pool, which is the one an operator is watching wind down" do
      draining = pool!(status: "draining")

      expect(components.map(&:id)).to include(draining.id)
    end

    it "does not enumerate another account's pools" do
      other_account = create(:account)
      other = System::InstancePool.create!(
        account: other_account, node_template: create(:system_node_template, account: other_account),
        name: "other-pool", target_size: 1
      )

      expect(components.map(&:id)).not_to include(other.id)
    end
  end

  describe "Lifecycle maps every value of the status enum" do
    it "has a branch for each STATUSES value" do
      expect(described_class::LIFECYCLE.keys).to match_array(System::InstancePool::STATUSES)
    end

    System::InstancePool::STATUSES.each do |status|
      next if status == "archived"

      it "maps #{status}" do
        record = pool!(status: status, target_size: 0)

        expect(condition(record, "Lifecycle")["reason"])
          .to eq(described_class::LIFECYCLE.fetch(status)[:reason])
      end
    end

    it "reports an unrecognised status as unknown, never ok" do
      record = pool!(target_size: 0)
      allow(record).to receive(:status).and_return("hibernating")

      lifecycle = condition(record, "Lifecycle")

      expect(lifecycle["status"]).to eq("unknown")
      expect(lifecycle["reason"]).to eq("UnknownStatus")
    end
  end

  describe "Held is operator intent" do
    it "is true for a paused pool and the verdict is held" do
      record = pool!(status: "paused", target_size: 0)

      expect(condition(record, "Held")["reason"]).to eq("Paused")
      expect(verdict(record)).to eq(Platform::ComponentStatus::HELD)
    end

    it "is true for a draining pool" do
      record = pool!(status: "draining", target_size: 0)

      expect(condition(record, "Held")["reason"]).to eq("Draining")
    end

    it "reports the failure, not the intent, for a paused pool that is also exhausted" do
      record = pool!(status: "paused", target_size: 2)

      expect(condition(record, "Held")["status"]).to be(true)
      expect(verdict(record)).to eq(Platform::ComponentStatus::DOWN)
    end

    it "is false with reason NotHeld for an active pool" do
      record = pool!(target_size: 0)

      expect(condition(record, "Held")["reason"]).to eq("NotHeld")
      expect(verdict(record)).to eq(Platform::ComponentStatus::OK)
    end
  end

  describe "Capacity, counted the way the pool counts itself" do
    it "is AtTarget when ready meets the target" do
      record = pool!(target_size: 2)
      2.times { member!(record, pool_state: "ready") }

      capacity = condition(record, "Capacity")

      expect(capacity["status"]).to be(true)
      expect(capacity["reason"]).to eq("AtTarget")
      expect(capacity["evidence"]).to include("ready_count" => 2, "target_size" => 2)
      expect(verdict(record)).to eq(Platform::ComponentStatus::OK)
    end

    it "counts warming toward the target and reports Progressing, not degraded" do
      # A pool filling to target is not short, it is filling.
      record = pool!(target_size: 2)
      member!(record, pool_state: "ready")
      member!(record, pool_state: "warming")

      expect(condition(record, "Capacity")["reason"]).to eq("FillingToTarget")
      expect(condition(record, "Progressing")["reason"]).to eq("Replenishing")
      expect(verdict(record)).to eq(Platform::ComponentStatus::PROGRESSING)
    end

    it "is BelowTarget and degraded when it is short even counting warming" do
      record = pool!(target_size: 3)
      member!(record, pool_state: "ready")

      expect(condition(record, "Capacity")["reason"]).to eq("BelowTarget")
      expect(condition(record, "Capacity")["severity"]).to be_nil
      expect(verdict(record)).to eq(Platform::ComponentStatus::DEGRADED)
    end

    it "is Exhausted and down with no ready member against a non-zero target" do
      # A claim cannot be served: that is a total loss of the pool's function.
      record = pool!(target_size: 2)
      member!(record, pool_state: "warming")

      expect(condition(record, "Capacity")["reason"]).to eq("Exhausted")
      expect(condition(record, "Capacity")["severity"]).to eq("down")
      expect(verdict(record)).to eq(Platform::ComponentStatus::DOWN)
    end

    it "treats a target of zero as legitimately empty, not exhausted" do
      record = pool!(target_size: 0)

      expect(condition(record, "Capacity")["reason"]).to eq("AtTarget")
      expect(verdict(record)).to eq(Platform::ComponentStatus::OK)
    end
  end

  describe "MembersHealthy" do
    it "is true when no member is errored" do
      record = pool!(target_size: 1)
      member!(record, pool_state: "ready")

      expect(condition(record, "MembersHealthy")["status"]).to be(true)
    end

    it "goes false when a member errored" do
      record = pool!(target_size: 1)
      member!(record, pool_state: "ready")
      member!(record, pool_state: "errored")

      members = condition(record, "MembersHealthy")

      expect(members["status"]).to be(false)
      expect(members["reason"]).to eq("MembersErrored")
      expect(members["evidence"]).to include("errored_count" => 1)
    end

    it "still reports when EVERY member errored, which active_member_count alone would hide" do
      # active_member_count spans warming/ready/claimed and excludes errored, so
      # gating on it would drop this condition in exactly the case it exists for.
      record = pool!(target_size: 1)
      member!(record, pool_state: "errored")

      expect(condition(record, "MembersHealthy")["reason"]).to eq("MembersErrored")
    end

    it "is omitted for a pool with no members at all" do
      record = pool!(target_size: 0)

      expect(condition(record, "MembersHealthy")).to be_nil
    end
  end

  describe "actions carry the permission the controller actually checks" do
    let(:record) { pool!(target_size: 1) }

    def controller_source
      @controller_source ||= File.read(
        Object.const_source_location("Api::V1::System::InstancePoolsController").first
      )
    end

    it "resolves every offered path against the real routes table" do
      contributor.actions_for(record).each do |action|
        recognized = Rails.application.routes.recognize_path(
          action["path"], method: action["method"].downcase.to_sym
        )

        expect(recognized[:controller]).to eq("api/v1/system/instance_pools")
        expect(recognized[:action]).to eq(action["key"])
      end
    end

    it "declares a permission the controller's write gate actually accepts" do
      # The gate is an OR, so the declared permission must be one of the two it
      # accepts — read out of the controller source, not copied as a string.
      gate = controller_source[/def authorize_write!.*?^\s*end/m]
      expect(gate).to be_present

      contributor.actions_for(record).each do |action|
        body = controller_source[/^\s*def #{action['key']}\b.*?^\s*end/m]

        expect(body).to include("authorize_write!"),
                        "#{action['key']} does not go through authorize_write!"
        expect(gate).to include(%("#{action['permission']}")),
                        "#{action['permission']} is not one of the permissions authorize_write! accepts"
      end
    end

    it "marks drain and recycle destructive, replenish not" do
      by_key = contributor.actions_for(record).index_by { |a| a["key"] }

      expect(by_key["replenish"]["destructive"]).to be(false)
      expect(by_key["drain"]["destructive"]).to be(true)
      expect(by_key["drain"]["confirm"]["requires_reason"]).to be(true)
      expect(by_key["recycle_stale"]["destructive"]).to be(true)
    end
  end

  describe "contract surface" do
    let(:record) { pool!(target_size: 0) }

    it "declares no dependencies, because its members declare the edge toward it" do
      expect(contributor.dependencies_for(record)).to eq([])
    end

    it "links to the real instance-pools page" do
      expect(contributor.links_for(record))
        .to eq([ { "label" => "Instance pools", "path" => "/app/system/instance-pools" } ])
    end

    it "uses updated_at as the generation, there being no version column" do
      expect(contributor.observed_generation_for(record)).to eq(record.updated_at.iso8601)
    end
  end
end
