# frozen_string_literal: true

require "rails_helper"

# IMP-074fcd68284f — stage 1 of 3 for per-service Linux capabilities
# (module security.capabilities is a CEILING; a service's own
# capabilities is its effective set and must be a SUBSET; absent means
# inherit the whole ceiling; explicit [] means zero).
#
# Before this fix, `capabilities: svc.capabilities || []` collapsed
# "never declared" and "declared empty" into the identical wire value —
# both rendered as JSON `[]`. This is the CONTRACT test the agent-side
# stage (IMP-caef5c00d63f) consumes as its fixture: without it, the two
# halves can drift and each keeps passing its own suite while the shape
# between them silently changes (a parity spec blind to a stage it
# never calls).
#
# Pinned at the JSON string level, not just the Ruby hash: the agent
# parses bytes over HTTP, not an intermediate Ruby object, and
# ApiResponse#sanitize_for_json / Rails' JSON renderer are both real
# steps this value passes through before a Go process ever sees it.
RSpec.describe System::NodeModuleNodeApiSerializer, type: :serializer do
  let(:account)     { create(:account) }
  let(:node_module) { create(:system_node_module, account: account) }

  def emitted_services
    described_class.new(node_module.reload).full[:services]
  end

  def service_hash_for(name)
    svc = emitted_services.find { |s| s[:name] == name }
    expect(svc).not_to be_nil, "service #{name.inspect} missing from the node payload"
    svc
  end

  describe "#full — the capabilities presence/absence contract" do
    it "emits nil for a service that never declared capabilities (inherit the module ceiling)" do
      create(:system_module_service, node_module: node_module, account: account,
             name: "absent-caps", capabilities: nil)

      expect(service_hash_for("absent-caps")[:capabilities]).to be_nil
    end

    it "emits [] for a service that explicitly declares zero capabilities" do
      create(:system_module_service, node_module: node_module, account: account,
             name: "zero-caps", capabilities: [])

      expect(service_hash_for("zero-caps")[:capabilities]).to eq([])
    end

    it "emits the exact declared array for a service with a non-empty capability set" do
      create(:system_module_service, node_module: node_module, account: account,
             name: "granted-caps", capabilities: %w[CAP_CHOWN CAP_FOWNER])

      expect(service_hash_for("granted-caps")[:capabilities]).to eq(%w[CAP_CHOWN CAP_FOWNER])
    end

    it "pins the exact wire JSON for all three states — a `null`/absent-key distinction the Ruby hash alone doesn't prove" do
      create(:system_module_service, node_module: node_module, account: account,
             name: "absent-caps", capabilities: nil)
      create(:system_module_service, node_module: node_module, account: account,
             name: "zero-caps", capabilities: [])
      create(:system_module_service, node_module: node_module, account: account,
             name: "granted-caps", capabilities: %w[CAP_CHOWN])

      parsed = JSON.parse(described_class.new(node_module.reload).full.to_json)
      by_name = parsed["services"].index_by { |s| s["name"] }

      # `has_key?` + explicit nil, not just a truthiness check: this is
      # exactly what distinguishes "key present with JSON null" from a
      # hash lookup returning nil because the key was never emitted at
      # all — both read as `nil` in Ruby, but Go's json.Unmarshal
      # resolves either shape identically for a []string field, so
      # either is an acceptable wire form here. Asserting has_key? is
      # what would catch a FUTURE regression to `.compact`-ing the hash
      # before render, which would drop the key entirely and is still
      # fine for Go but would be a silent contract change worth noticing.
      expect(by_name["absent-caps"]).to have_key("capabilities")
      expect(by_name["absent-caps"]["capabilities"]).to be_nil
      expect(by_name["zero-caps"]["capabilities"]).to eq([])
      expect(by_name["granted-caps"]["capabilities"]).to eq(%w[CAP_CHOWN])
    end
  end
end
