# frozen_string_literal: true

require "rails_helper"

# IMP-9ce0ed39c557 — ssh_exec/ssh_sync/ssh_cleanse were unrouted dead code
# (confirmed against config/routes.rb and a repo-wide spec search before
# removal) and, for ssh_exec specifically, an ungated arbitrary-command-
# execution door behind worker-token auth alone. Removed rather than
# resurrected as the governed door — see the controller's own comment for
# where that lives now (System::Executors::OutOfBandExec).
RSpec.describe Api::V1::Internal::System::NodeInstancesController do
  it "no longer implements ssh_exec, ssh_sync or ssh_cleanse" do
    %w[ssh_exec ssh_sync ssh_cleanse].each do |action|
      expect(described_class.action_methods).not_to include(action)
      expect(described_class.instance_methods(false).map(&:to_s)).not_to include(action)
    end
  end

  it "still routes no request to any of the three names" do
    %w[ssh_exec ssh_sync ssh_cleanse].each do |action|
      expect {
        Rails.application.routes.recognize_path(
          "/api/v1/internal/system/node_instances/#{SecureRandom.uuid}/#{action}", method: :post
        )
      }.to raise_error(ActionController::RoutingError)
    end
  end
end
