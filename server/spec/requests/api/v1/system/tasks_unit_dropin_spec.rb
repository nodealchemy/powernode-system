# frozen_string_literal: true

require "rails_helper"

# IMP-9951cbf20bb0 — POST /api/v1/system/tasks must not become a second door
# onto unit.dropin. That door gates on system.task.<command> with no person's
# own-session confirmation and none of System::UnitDropinService's unit checks,
# so it refuses the command BEFORE the gate: no approval an operator could
# grant and the model would then refuse, and no row.
RSpec.describe "POST /api/v1/system/tasks unit.dropin", type: :request do
  let(:user)      { user_with_permissions("system.infra_tasks.create", "system.instances.read") }
  let(:account)   { user.account }
  let(:node)      { create(:system_node, account: account) }
  let!(:instance) { create(:system_node_instance, :running, node: node, account: account, last_heartbeat_at: Time.current) }

  before do
    allow_any_instance_of(::Ai::InterventionPolicyService).to receive(:resolve).and_return(
      { policy: "auto_approve", channels: [], conditions: {}, record: nil }
    )
  end

  it "is refused before the gate, naming the governed verb, and creates nothing" do
    body = { command: "unit.dropin", operable_type: "System::NodeInstance", operable_id: instance.id,
             options: { unit: "powernode-x-sidekiq.service", name: "trial", revert: false,
                        directives: [ { key: "MemoryMax", value: "1G" } ] } }

    expect {
      post "/api/v1/system/tasks", params: { task: body }.to_json,
                                   headers: auth_headers_for(user).merge("Content-Type" => "application/json")
    }.not_to change { account.system_tasks.count }

    expect(response).to have_http_status(:unprocessable_content)
    expect(response.parsed_body.to_json).to include("system_apply_unit_dropin")
    expect(Ai::DeferredOperation.where(account: account)).to be_empty
  end
end
