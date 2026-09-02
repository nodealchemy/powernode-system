# frozen_string_literal: true

require "rails_helper"

# APO-8b (IMP-c5a62a32d3bb) — pagination and a consistent truncation signal on
# the extension's list surface.
#
# The finding: across the extension tool files, zero list actions paginated.
# Two accepted a `limit`, about eleven applied a hard-coded cap, and the rest
# serialized every matching row. Worse, the `count` beside the rows did not
# mean the same thing twice:
#
#   system_list_tasks     rebound the scope to .limit(100) and then reported
#                         `count: scope.size` off the CAPPED relation, so an
#                         account with 100 tasks and one with 10,000 answered
#                         identically.
#   system_list_instances capped the serialized rows at 200 but reported the
#                         UNCAPPED count — a different meaning for the same key.
#   system_list_volumes   returned no count at all.
#
# An agent reading these had no page two and no way to tell a complete answer
# from a truncated one. These examples pin the fixed contract on the three tool
# files the finding names, plus a ratchet so a new list action cannot be added
# without the two parameters.
RSpec.describe "extension list-action pagination" do
  let(:account) { create(:account) }
  let(:user)    { create(:user, :super_admin, account: account) }

  describe Ai::Tools::SystemFleetTool do
    subject(:tool) { described_class.new(account: account, user: user) }

    def call(action, params = {})
      tool.execute(params: { action: action }.merge(params))
    end

    describe "system_list_tasks" do
      let!(:node)  { create(:system_node, account: account) }
      let!(:tasks) { Array.new(5) { create(:system_task, account: account, operable: node) } }

      it "reports the UNCAPPED total rather than the size of the page it returned" do
        result = call("system_list_tasks", limit: 2)

        expect(result[:success]).to be(true)
        expect(result[:data][:tasks].size).to eq(2)
        expect(result[:data][:returned]).to eq(2)
        expect(result[:data][:count]).to eq(5)
      end

      it "signals truncation and offers a cursor to the rest" do
        result = call("system_list_tasks", limit: 2)

        expect(result[:data][:has_more]).to be(true)
        expect(result[:data][:next_cursor]).to be_present
      end

      it "walks every task exactly once through next_cursor" do
        seen   = []
        cursor = nil

        10.times do
          result = call("system_list_tasks", { limit: 2, cursor: cursor }.compact)
          seen.concat(result[:data][:tasks].map { |t| t[:id] })
          cursor = result[:data][:next_cursor]
          break if cursor.nil?
        end

        expect(cursor).to be_nil
        expect(seen.uniq.size).to eq(5)
        expect(seen.sort).to eq(tasks.map(&:id).sort)
      end
    end

    describe "system_list_nodes" do
      let!(:nodes) { Array.new(4) { |n| create(:system_node, account: account, name: "node-#{n}") } }

      it "honours limit on an action that used to serialize the whole table" do
        result = call("system_list_nodes", limit: 2)

        expect(result[:success]).to be(true)
        expect(result[:data][:nodes].size).to eq(2)
        expect(result[:data][:count]).to eq(4)
        expect(result[:data][:has_more]).to be(true)
      end
    end

    describe "system_list_volumes" do
      it "reports a count, which this action never did" do
        result = call("system_list_volumes")

        expect(result[:success]).to be(true)
        expect(result[:data]).to have_key(:count)
        expect(result[:data]).to have_key(:has_more)
      end
    end
  end

  describe Ai::Tools::SdwanTool do
    subject(:tool) { described_class.new(account: account, user: user) }

    let!(:networks) { Array.new(3) { create(:sdwan_network, account: account) } }

    it "paginates system_sdwan_list_networks" do
      result = tool.execute(params: { action: "system_sdwan_list_networks", limit: 2 })

      expect(result[:success]).to be(true)
      expect(result[:data][:networks].size).to eq(2)
      expect(result[:data][:count]).to eq(3)
      expect(result[:data][:has_more]).to be(true)
    end

    # SdwanTool#call rescues RecordNotFound/RecordInvalid and two domain
    # errors, but NOT ArgumentError — a raise here would escape to
    # StreamableHttpController's generic handler and reach the agent as a
    # JSON-RPC -32603 internal error instead of a readable refusal.
    it "refuses a malformed cursor as a result rather than raising" do
      result = nil
      expect {
        result = tool.execute(params: { action: "system_sdwan_list_networks", cursor: "not-a-cursor" })
      }.not_to raise_error

      expect(result[:success]).to be(false)
      expect(result[:error]).to include("cursor")
    end
  end

  # RATCHET. The finding was a CONSISTENCY defect, so the guard has to be a
  # completeness check over the WHOLE extension tool surface — the eight files
  # in app/services/ai/tools — not a spot check on the actions this spec
  # happens to exercise, and not a hand-written class list that a ninth tool
  # file could quietly sit outside of. The classes are therefore DISCOVERED
  # from the directory.
  #
  # `system_list_isolation_tiers` is the one exemption: it serializes a frozen
  # in-code catalog (System::IsolationTier.catalog), not a relation, so there is
  # nothing to page and no total that could differ from what it returned.
  #
  # SCOPE OF THE PREDICATE, stated so the guard is not read as claiming more
  # than it checks: it matches actions whose name contains "list_". A get_*
  # verb that hand-rolls its own `limit` (system_sdwan_get_audit_log,
  # system_get_silent_instances) is NOT covered here and still reports
  # truncation its own way.
  describe "every relation-backed list action declares the page parameters" do
    # Methods, not constants: a constant assigned inside an RSpec block lands
    # on Object, where any other spec file could collide with it.
    def static_catalog_actions
      %w[system_list_isolation_tiers]
    end

    def tool_classes
      dir = File.expand_path("../../../../app/services/ai/tools", __dir__)
      Dir.glob(File.join(dir, "*_tool.rb")).sort.map do |path|
        "Ai::Tools::#{File.basename(path, '.rb').camelize}".constantize
      end
    end

    it "discovers every tool file in the extension, so a new one cannot sit outside this guard" do
      # A floor, not a count — a ninth tool file must be COVERED, not a red.
      expect(tool_classes.size).to be >= 8
      expect(tool_classes).to include(Ai::Tools::SystemFleetTool, Ai::Tools::SdwanTool)
    end

    it "declares limit + cursor on each of them, across every extension tool" do
      missing = {}

      tool_classes.each do |klass|
        list_actions = klass.action_definitions.keys.select { |name| name.include?("list_") } -
                       static_catalog_actions

        list_actions.each do |name|
          params = klass.action_definitions.dig(name, :parameters) || {}
          missing[klass.name] = (missing[klass.name] || []) << name unless params.key?(:limit) && params.key?(:cursor)
        end
      end

      expect(missing).to eq({}),
                         "list actions missing limit/cursor: " \
                         "#{missing.map { |k, v| "#{k}: #{v.join(', ')}" }.join(' | ')}"
    end

    # Positive control: the walk must actually SEE actions. An enumeration that
    # silently found none would report a clean sheet for doing nothing.
    it "walks a list surface materially larger than the three files this change rewrote" do
      seen = tool_classes.sum { |k| k.action_definitions.keys.count { |n| n.include?("list_") } }

      # A FLOOR, materially below the live 38 (37 relation-backed + the static
      # catalog, counted 2026-09-02), so retiring an action is not a red for a
      # reason unrelated to the invariant.
      expect(seen).to be >= 34
    end
  end
end
