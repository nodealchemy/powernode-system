# frozen_string_literal: true

require "rails_helper"

# fc-47 — the Compute › Platform › Health sub-tab (HealthPanel) was the only
# caller of GET /system/platform/health. Platform subsystem health is on
# /app/status through the platform_subsystem contributor, which reads the same
# CompositeHealthProbe snapshots; the panel and the endpoint were deleted.
RSpec.describe "Deleted platform health route", type: :routing do
  it "does not route GET /api/v1/system/platform/health" do
    expect(get: "/api/v1/system/platform/health").not_to be_routable
  end
end
