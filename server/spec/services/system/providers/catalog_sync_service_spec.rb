# frozen_string_literal: true

require "rails_helper"

# IMP-156eb1a7bdbc — CatalogSyncService's Result.error is rendered verbatim to
# the caller by ProviderConnectionsController#sync_catalog. Both rescue arms
# interpolated the raised exception's text into it: the generic arm forwarded
# whatever a cloud SDK / adapter / PG raised, the resolution arm forwarded
# Registry's own message. The error is now a fixed, classified message; the
# exception's class rides in `data[:exception]` and the raw text goes to the
# log only.
RSpec.describe System::Providers::CatalogSyncService do
  let(:account)    { create(:account) }
  let(:connection) { create(:system_provider_connection, account: account) }
  let(:marker)     { "MARKER-156eb1 sdk said: https://internal.example/v2?token=abc" }

  it "withholds a raising adapter's text, keeping the exception class" do
    adapter = double("adapter")
    allow(adapter).to receive(:list_regions).and_raise(StandardError, marker)
    allow(System::Providers::Registry).to receive(:for).and_return(adapter)
    allow(Rails.logger).to receive(:error).and_call_original

    result = described_class.sync_for(connection)

    expect(Rails.logger).to have_received(:error).with(/MARKER-156eb1/)

    expect(result.success?).to be false
    expect(result.error).to eq("Catalog sync failed")
    expect(result.error).not_to include("MARKER-156eb1")
    expect(result.data).to eq(exception: "StandardError")
  end

  it "withholds a provider-resolution failure's text" do
    allow(System::Providers::Registry).to receive(:for)
      .and_raise(System::Providers::Registry::UnknownProviderError, marker)

    result = described_class.sync_for(connection)

    expect(result.success?).to be false
    expect(result.error).to start_with("Provider resolution failed")
    expect(result.error).not_to include("MARKER-156eb1")
    expect(result.data).to eq(exception: "System::Providers::Registry::UnknownProviderError")
  end
end
