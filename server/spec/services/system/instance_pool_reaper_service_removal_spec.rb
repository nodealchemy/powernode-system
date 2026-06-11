# frozen_string_literal: true

require "rails_helper"

# Audit F5-13 — System::InstancePoolReaperService was a dead direct-DB
# duplicate of the live recycle+replenish loop: zero callers, and its header
# claimed invocation "via SystemInstancePoolReaperJob" — a class that exists
# nowhere. The real 60s path is the worker's API-only
# System::InstancePoolReplenisherJob (cron in sidekiq.yml). Two divergent
# implementations meant a fix could land in the dead one. The service was
# removed; this pins that the duplicate stays gone.
RSpec.describe "InstancePoolReaperService removal (F5-13)" do
  it "no longer defines the dead direct-DB reaper duplicate" do
    expect(System.const_defined?(:InstancePoolReaperService)).to be(false)
  end
end
