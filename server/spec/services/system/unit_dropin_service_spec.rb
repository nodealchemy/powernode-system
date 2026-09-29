# frozen_string_literal: true

require "rails_helper"

# IMP-9951cbf20bb0 — System::UnitDropinService, the ONE author of what
# system_apply_unit_dropin may write (a runtime drop-in under
# /run/systemd/system/<unit>.d/zz-operator-<name>.conf) and of the unit.dropin
# task and its audit row. The agent's UnitDropinHandler re-validates every
# field independently; the shared table in
# agent/internal/runtime/tasks/handlers/testdata/unit_dropin_cases.json holds
# the two allow-lists and the two renderers to the same answers.
#
# ORACLE SHAPE: every refusal asserts NO task row, never only the message.
# A uniquely-named module rather than constants inside the example group: a
# constant assigned in an RSpec block lands on Object.
module UnitDropinSharedCases
  PATH = Rails.root.join("..", "extensions", "system", "agent", "internal", "runtime", "tasks",
                         "handlers", "testdata", "unit_dropin_cases.json")

  # A string is literal; {prefix, repeat, times, suffix} is built here, so a
  # token-shaped value never sits in the tree for a scanner to flag.
  def self.expand(value)
    case value
    when Hash
      if value.key?("repeat")
        "#{value['prefix']}#{value['repeat'] * value['times']}#{value['suffix']}"
      else
        value.transform_values { |v| expand(v) }
      end
    when Array then value.map { |v| expand(v) }
    else value
    end
  end

  ALL = expand(JSON.parse(PATH.read)).freeze
end

RSpec.describe System::UnitDropinService do
  let(:account)   { create(:account) }
  let(:node)      { create(:system_node, account: account) }
  let(:instance)  { create(:system_node_instance, :running, node: node, account: account, last_heartbeat_at: Time.current) }
  let(:user)      { create(:user, account: account) }
  let(:fence_key) { System::Autonomy::SelfManagementFence::SELF_HOSTING_NODE_ID_KEY }
  let(:decoy)     { create(:system_node, account: create(:account)) }

  def compose!(inst, *names)
    mod = create(:system_node_module, account: account)
    svcs = names.map { |n| create(:system_module_service, node_module: mod, name: n) }
    create(:system_node_module_assignment, node: inst.node, node_module: mod)
    svcs.map { |s| System::RestartAfterUpdate.unit_name(mod.id, s.name) }
  end

  def dropin_tasks
    System::Task.where(command: described_class::COMMAND)
  end


  before { ::SiteSetting.set(fence_key, decoy.id, setting_type: "string") }

  describe "the shared table (agent parity)" do
    it "is not empty in any section" do
      %w[name_ok name_refused accepted refused capability_subset render].each do |k|
        expect(UnitDropinSharedCases::ALL[k]).to be_present, "fixture section #{k} is empty"
      end
    end

    UnitDropinSharedCases::ALL["name_ok"].each do |name|
      it "accepts the name #{name.inspect}" do
        expect(described_class.name_refusal(name)).to be_nil
      end
    end

    UnitDropinSharedCases::ALL["name_refused"].each do |name|
      it "refuses the name #{name.inspect}" do
        expect(described_class.name_refusal(name)).to be_present
      end
    end

    UnitDropinSharedCases::ALL["accepted"].each do |directives|
      it "accepts #{directives.inspect}" do
        expect { described_class.normalize_directives(directives) }.not_to raise_error
      end
    end

    UnitDropinSharedCases::ALL["refused"].each do |entry|
      it "refuses #{entry['why']}" do
        expect { described_class.normalize_directives(entry["directives"]) }
          .to raise_error(described_class::Invalid)
      end
    end

    UnitDropinSharedCases::ALL["capability_subset"].each do |entry|
      it "#{entry['ok'] ? 'accepts' : 'refuses'} #{entry['why']} against the unit's resolved set" do
        pairs = described_class.normalize_directives(entry["directives"])
        refusal = described_class.capability_subset_refusal(pairs, entry["resolved"])
        entry["ok"] ? expect(refusal).to(be_nil) : expect(refusal).to(be_present)
      end
    end

    UnitDropinSharedCases::ALL["render"].each do |entry|
      it "renders #{entry['name']} byte-for-byte as the agent does" do
        pairs = described_class.normalize_directives(entry["directives"])
        expect(described_class.render(entry["name"], pairs)).to eq(entry["content"])
      end
    end
  end

  describe ".normalize_directives" do
    it "accepts symbol-keyed entries (an in-process caller) and returns string pairs" do
      expect(described_class.normalize_directives([ { key: "MemoryMax", value: "1G" } ]))
        .to eq([ %w[MemoryMax 1G] ])
    end

    it "refuses more than MAX_DIRECTIVES entries" do
      many = Array.new(described_class::MAX_DIRECTIVES + 1) { { "key" => "MemoryMax", "value" => "1G" } }
      expect { described_class.normalize_directives(many) }.to raise_error(described_class::Invalid, /at most/)
    end

    it "refuses a non-array" do
      expect { described_class.normalize_directives("MemoryMax=1G") }.to raise_error(described_class::Invalid)
      expect { described_class.normalize_directives(nil) }.to raise_error(described_class::Invalid)
    end

    it "names the injection it refuses" do
      expect { described_class.normalize_directives([ { "key" => "MemoryMax", "value" => "1G\nExecStart=/bin/sh" } ]) }
        .to raise_error(described_class::Invalid, /control character/)
    end

    # F1: a name denylist is incomplete by construction (LD_*, NODE_OPTIONS,
    # BASH_ENV, PATH, a module's own DATABASE_URL), so Environment= is off the
    # list entirely until manifests declare tunable names.
    it "refuses Environment= outright, benign or not, and says why" do
      [ "LOG_LEVEL=debug", "LD_PRELOAD=/persist/x/evil.so", "NODE_OPTIONS=--inspect" ].each do |value|
        expect { described_class.normalize_directives([ { "key" => "Environment", "value" => value } ]) }
          .to raise_error(described_class::Invalid, /Environment= is not settable through this verb; env tuning needs manifest-declared tunables/)
      end
    end
  end

  describe "#refusal" do
    subject(:service) { described_class.new }

    let!(:units) { compose!(instance, "sidekiq", "rails", "node-exporter") }
    let(:sidekiq) { units[0] }
    let(:rails) { units[1] }
    let(:exporter) { units[2] }
    let(:directives) { [ { "key" => "MemoryMax", "value" => "1G" } ] }

    def refusal(unit: sidekiq, name: "trial", dirs: directives, revert: false)
      service.refusal(instance: instance, unit: unit, name: name, directives: dirs, revert: revert)
    end

    it "permits a composed unit, a valid name and valid directives" do
      expect(refusal).to be_nil
    end

    it "refuses an invalid name" do
      expect(refusal(name: "../etc")).to match(/name/)
      expect(refusal(name: "")).to match(/name/)
    end

    it "refuses directives on a revert, and permits a revert with none" do
      expect(refusal(revert: true)).to match(/revert/)
      expect(refusal(revert: true, dirs: [])).to be_nil
      expect(refusal(revert: true, dirs: nil)).to be_nil
    end

    it "refuses an invalid directive" do
      expect(refusal(dirs: [ { "key" => "ExecStart", "value" => "/bin/sh" } ])).to match(/ExecStart/)
    end

    # The unit checks are System::UnitRestartService's, not a copy of them.
    describe "the unit refusals shared with system_restart_unit" do
      it "consults UnitRestartService#target_refusal" do
        restart = System::UnitRestartService.new
        allow(System::UnitRestartService).to receive(:new).and_return(restart)
        allow(restart).to receive(:target_refusal).and_call_original

        refusal

        expect(restart).to have_received(:target_refusal).with(instance: instance, unit: sidekiq, act: kind_of(String))
      end

      it "refuses the agent's own unit" do
        expect(refusal(unit: "powernode-agent.service")).to match(/agent.*out-of-band/i)
      end

      it "refuses a unit outside powernode-*" do
        expect(refusal(unit: "sshd.service")).to match(/powernode-\*/)
      end

      it "refuses a unit that is not composed on this instance" do
        expect(refusal(unit: System::RestartAfterUpdate.unit_name(SecureRandom.uuid, "sidekiq")))
          .to match(/not composed on this instance/)
      end

      it "refuses every unit on the control plane's own hosting node (INV-1)" do
        ::SiteSetting.set(fence_key, node.id, setting_type: "string")
        [ sidekiq, rails, exporter ].each do |u|
          expect(refusal(unit: u)).to match(/INV-1|self-management/i)
        end
      end

      it "fails closed on a critical service while the fence is unconfigured, and not on the rest" do
        ::SiteSetting.where(key: fence_key).delete_all
        expect(refusal(unit: rails)).to match(/self_hosting_node_id/)
        expect(refusal(unit: exporter)).to be_nil
      end

      it "refuses an instance whose agent is silent or not running" do
        instance.update_columns(last_heartbeat_at: 1.hour.ago)
        expect(refusal).to match(/went silent/)
        instance.update_columns(last_heartbeat_at: Time.current, status: "stopped")
        expect(refusal).to match(/stopped/)
      end
    end
  end

  # F2: a capability directive may only NARROW. The drop-in's
  # AmbientCapabilities / CapabilityBoundingSet must be a subset of the set the
  # agent renders into that unit's capabilities.conf, resolved here from the
  # module's security block and the service row exactly as the agent resolves
  # it; a set that cannot be resolved accepts only the empty (zero-caps) list.
  describe "capability narrowing against the service's resolved set" do
    subject(:service) { described_class.new }

    def compose_caps!(security:, own: :absent, presence: true)
      mod = create(:system_node_module, account: account, config: { "security" => security })
      attrs = { node_module: mod, name: "web" }
      attrs[:capabilities] = own unless own == :absent
      svc = create(:system_module_service, **attrs)
      svc.update_columns(capabilities_presence_recorded: presence)
      create(:system_node_module_assignment, node: instance.node, node_module: mod)
      System::RestartAfterUpdate.unit_name(mod.id, svc.name)
    end

    def caps_refusal(unit, key, value)
      service.refusal(instance: instance, unit: unit, name: "trial",
                      directives: [ { "key" => key, "value" => value } ], revert: false)
    end

    it "refuses CAP_SYS_ADMIN on a unit whose manifest lacks it, accepts a subset and the empty list" do
      unit = compose_caps!(security: { "capabilities" => %w[CAP_NET_BIND_SERVICE CAP_CHOWN] })

      expect(caps_refusal(unit, "AmbientCapabilities", "CAP_SYS_ADMIN")).to match(/CAP_SYS_ADMIN/)
      expect(caps_refusal(unit, "CapabilityBoundingSet", "CAP_NET_BIND_SERVICE CAP_SYS_ADMIN")).to match(/CAP_SYS_ADMIN/)
      expect(caps_refusal(unit, "CapabilityBoundingSet", "CAP_NET_BIND_SERVICE")).to be_nil
      expect(caps_refusal(unit, "AmbientCapabilities", "")).to be_nil
    end

    it "normalizes the manifest's spellings as the agent does (cap_chown, chown)" do
      unit = compose_caps!(security: { "capabilities" => %w[cap_chown net_bind_service] })

      expect(caps_refusal(unit, "CapabilityBoundingSet", "CAP_CHOWN CAP_NET_BIND_SERVICE")).to be_nil
    end

    it "uses the service's own declared list when it declares one" do
      unit = compose_caps!(security: { "capabilities" => %w[CAP_CHOWN CAP_NET_RAW] }, own: %w[CAP_CHOWN])

      expect(caps_refusal(unit, "AmbientCapabilities", "CAP_NET_RAW")).to match(/CAP_NET_RAW/)
      expect(caps_refusal(unit, "AmbientCapabilities", "CAP_CHOWN")).to be_nil
    end

    it "treats a declared [] as zero only under the presence marker, as the agent does" do
      zero = compose_caps!(security: { "capabilities" => %w[CAP_CHOWN] }, own: [])
      expect(caps_refusal(zero, "AmbientCapabilities", "CAP_CHOWN")).to match(/CAP_CHOWN/)
    end

    it "inherits the ceiling for a legacy [] with no presence marker" do
      legacy = compose_caps!(security: { "capabilities" => %w[CAP_CHOWN] }, own: [], presence: false)
      expect(caps_refusal(legacy, "AmbientCapabilities", "CAP_CHOWN")).to be_nil
    end

    it "treats a module with no security block as zero capabilities" do
      unit = compose_caps!(security: nil)
      expect(caps_refusal(unit, "AmbientCapabilities", "CAP_CHOWN")).to match(/CAP_CHOWN/)
      expect(caps_refusal(unit, "AmbientCapabilities", "")).to be_nil
    end

    it "fails closed when the set cannot be resolved (privileged, or a service outside its ceiling)" do
      privileged = compose_caps!(security: { "privileged" => true })
      outside = compose_caps!(security: { "capabilities" => %w[CAP_CHOWN] }, own: %w[CAP_NET_RAW])

      [ privileged, outside ].each do |unit|
        expect(caps_refusal(unit, "CapabilityBoundingSet", "CAP_CHOWN")).to match(/cannot resolve/)
        expect(caps_refusal(unit, "CapabilityBoundingSet", "")).to be_nil
      end
    end
  end

  describe "#apply!" do
    let!(:unit) { compose!(instance, "sidekiq").first }

    it "creates exactly one unit.dropin task and an audit row carrying the rendered diff" do
      task = nil
      expect {
        task = described_class.new.apply!(
          instance: instance, unit: unit, name: "trial",
          directives: [ { "key" => "TasksMax", "value" => "64" }, { "key" => "MemoryMax", "value" => "1G" } ],
          revert: false, initiated_by: user
        )
      }.to change { dropin_tasks.count }.by(1)

      expect(task.operable).to eq(instance)
      expect(task.status).to eq("pending")
      expect(task.options).to include("unit" => unit, "name" => "trial", "revert" => false)
      expect(task.options["directives"]).to eq([
        { "key" => "TasksMax", "value" => "64" }, { "key" => "MemoryMax", "value" => "1G" }
      ])

      audit = AuditLog.find_by!(action: described_class::AUDIT_ACTION, resource_id: instance.id.to_s)
      expect(audit.user_id).to eq(user.id)
      expect(audit.metadata).to include("unit" => unit, "name" => "trial", "task_id" => task.id, "revert" => false,
                                        "path" => "/run/systemd/system/#{unit}.d/zz-operator-trial.conf")
      expect(audit.metadata["diff"]).to include("+TasksMax=64", "+MemoryMax=1G")
    end

    it "addresses ONLY zz-operator-<name>.conf on a revert, and carries no directives" do
      task = described_class.new.apply!(instance: instance, unit: unit, name: "trial", directives: nil,
                                        revert: true, initiated_by: user)

      expect(task.options).to eq("unit" => unit, "name" => "trial", "revert" => true, "directives" => [])
      audit = AuditLog.find_by!(action: described_class::AUDIT_ACTION, resource_id: instance.id.to_s)
      expect(audit.metadata["path"]).to eq("/run/systemd/system/#{unit}.d/zz-operator-trial.conf")
      expect(audit.metadata["diff"]).to start_with("--- /run/systemd/system/#{unit}.d/zz-operator-trial.conf")
    end

    it "raises Refused and creates nothing for what #refusal refuses" do
      expect {
        described_class.new.apply!(instance: instance, unit: unit, name: "trial",
                                   directives: [ { "key" => "User", "value" => "root" } ], revert: false, initiated_by: user)
      }.to raise_error(described_class::Refused)
      expect(dropin_tasks).to be_empty
      expect(AuditLog.where(action: described_class::AUDIT_ACTION)).to be_empty
    end

    it "creates no task when the audit row cannot be written" do
      allow(AuditLog).to receive(:create!).and_raise(ActiveRecord::RecordInvalid)

      expect {
        described_class.new.apply!(instance: instance, unit: unit, name: "trial",
                                   directives: [ { "key" => "MemoryMax", "value" => "1G" } ], revert: false, initiated_by: user)
      }.to raise_error(ActiveRecord::RecordInvalid)
      expect(dropin_tasks).to be_empty
    end
  end
end
