# frozen_string_literal: true

require "rails_helper"

# APO increment 3a (scale arm) — IMP-a343c2bf2fc9.
#
# The scale-IN arm clamped every mission at the executor's own platform-wide
# `MIN_REPLICAS` constant, so a project that must never drop below N replicas
# had nowhere to say so: `InstancePool` carries min_size/max_size, a mission
# carried no floor at all. The floor now comes from the mission's declared
# per-project bounds (`Ai::Mission#scaling_bounds`), with the executor constant
# as the last-resort platform minimum that a project may raise but never lower.
RSpec.describe System::Ai::Skills::ScaleProjectExecutor, "per-project replica floor" do
  let(:account)        { create(:account) }
  let(:platform)       { create(:system_node_platform, account: account) }
  let(:template)       { create(:system_node_template, account: account, node_platform: platform) }
  let(:provider)       { create(:system_provider, account: account) }
  let(:region)         { create(:system_provider_region, account: account, provider: provider) }
  let(:instance_type)  { create(:system_provider_instance_type, account: account, provider: provider) }
  let(:exec)           { described_class.new(account: account) }

  let(:prefix) { "dryrun-bounds-01" }
  let(:declared_floor) { 3 }

  let(:mission) do
    create(:ai_mission, account: account, mission_type: "infrastructure",
                        configuration: {
                          "name_prefix" => prefix,
                          "watch_policies" => { "auto_scale_min_replicas" => declared_floor,
                                                "auto_scale_max_replicas" => 10 }
                        })
  end

  let(:provider_adapter) do
    instance_double(::System::Providers::MockProvider,
                    terminate_instance: { success: true },
                    attach_volume: { success: true, device: "/dev/sdb" },
                    detach_volume: { success: true },
                    delete_volume: { success: true })
  end

  before do
    allow(::System::Providers::Registry).to receive(:for_instance).and_return(provider_adapter)
    allow(::System::Providers::Registry).to receive(:for_volume).and_return(provider_adapter)
  end

  def replica!(minutes_old:)
    node = create(:system_node, account: account, node_template: template,
                                name: "#{prefix}-web-#{SecureRandom.hex(3)}",
                                config: { "mission_id" => mission.id })
    create(:system_node_instance, :running, node: node,
           provider_region: region, provider_instance_type: instance_type,
           name: "#{node.name}-instance-#{SecureRandom.hex(2)}",
           created_at: minutes_old.minutes.ago)
  end

  def statuses_of(*instances)
    instances.map { |i| ::System::NodeInstance.find(i.id).status }
  end

  it "clamps a removal at the mission's DECLARED floor, not the platform minimum" do
    keep_a = replica!(minutes_old: 50)
    keep_b = replica!(minutes_old: 40)
    keep_c = replica!(minutes_old: 30)
    victim = replica!(minutes_old: 10)

    r = exec.execute(project_id: mission.id, target_count: 3, scaling_strategy: "remove_replicas")

    expect(r[:success]).to be true
    # 4 live - floor 3 = exactly ONE removable, though three were requested.
    expect(r[:data][:count]).to eq(1)
    expect(statuses_of(victim)).to eq(%w[terminated])
    expect(statuses_of(keep_a, keep_b, keep_c)).to eq(%w[running running running])
  end

  it "removes NOTHING once the mission sits at its declared floor" do
    standing = 3.times.map { |i| replica!(minutes_old: (i + 1) * 10) }

    r = exec.execute(project_id: mission.id, target_count: 1, scaling_strategy: "remove_replicas")

    expect(r[:success]).to be true
    expect(r[:data][:count]).to eq(0)
    expect(r[:data][:outputs][:floor_reached]).to be true
    expect(statuses_of(*standing)).to eq(%w[running running running])
    # The recorded no-op must name the floor it actually honoured, otherwise an
    # operator reading the action cannot tell a per-project floor from the
    # platform default.
    floor_action = Array(r[:data][:planned_actions]).find { |a| a[:step] == "remove_replicas_floor" }
    expect(floor_action[:floor]).to eq(declared_floor)
  end

  context "when the mission declares no floor" do
    let(:mission) do
      create(:ai_mission, account: account, mission_type: "infrastructure",
                          configuration: { "name_prefix" => prefix })
    end

    it "falls back to the platform minimum" do
      keep   = replica!(minutes_old: 50)
      victim = replica!(minutes_old: 10)

      r = exec.execute(project_id: mission.id, target_count: 5, scaling_strategy: "remove_replicas")

      expect(r[:success]).to be true
      expect(r[:data][:count]).to eq(2 - described_class::MIN_REPLICAS)
      expect(statuses_of(victim)).to eq(%w[terminated])
      expect(statuses_of(keep)).to eq(%w[running])
    end
  end
end
