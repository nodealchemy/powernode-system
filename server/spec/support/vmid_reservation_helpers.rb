# frozen_string_literal: true

# The ProxmoxProvider vmid reservation ledger (F1, IMP 019fe4c4-b373) is
# deliberately PROCESS-GLOBAL — that is the race it closes. Left alone it
# would leak reservations across examples: any two examples whose stubbed
# /cluster/nextid returns the same id would see the second allocation skip
# forward, failing assertions that pin exact vmids (band specs, create specs).
# Reset it per example, same hygiene as DatabaseCleaner.
RSpec.configure do |config|
  config.before(:each) do
    if defined?(System::Providers::ProxmoxProvider)
      System::Providers::ProxmoxProvider.reset_vmid_reservations!
    end
  end
end
