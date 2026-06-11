# frozen_string_literal: true

require "rails_helper"

# Audit F6-04 — the latency SLO chain is dark: TelemetryAdapter reads
# FleetEvents of kind "metric.latency_ms" but NO producer anywhere
# (server, worker, Go agent) emits them, so latency_p99_ms is always nil
# and ProjectSloSensor's latency-breach branch can never fire. The
# mission template advertising a p99_latency_ms target therefore told
# operators a lie: it implied latency violations are detected. This spec
# pins the honest contract — the default targets carry only enforceable
# metrics, and the unsupported one is machine-readably documented.
RSpec.describe "system_provisioning mission template seed" do
  def load_seed!
    silence_warnings do
      load Rails.root.join("..", "extensions", "system", "server", "db", "seeds",
                           "system_provisioning_mission_template.rb")
    end
  end

  let(:template) do
    load_seed!
    Ai::MissionTemplate.find_by!(name: "system_provisioning", template_type: "system")
  end

  it "does not advertise a p99_latency_ms target (no metric.latency_ms producer exists)" do
    slo_targets = template.default_configuration["slo_targets"]

    expect(slo_targets.keys).to contain_exactly("availability_pct")
    expect(slo_targets["availability_pct"]).to eq(99.5)
  end

  it "documents the latency SLO as unsupported with the reason" do
    unsupported = template.default_configuration["unsupported_slo_targets"]

    expect(unsupported).to have_key("p99_latency_ms")
    expect(unsupported["p99_latency_ms"]).to match(/no .*producer|metric\.latency_ms/i)
  end

  it "is idempotent across re-runs" do
    template # first load
    expect { load_seed! }.not_to change { Ai::MissionTemplate.where(name: "system_provisioning").count }
  end
end
