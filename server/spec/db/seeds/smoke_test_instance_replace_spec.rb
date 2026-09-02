# frozen_string_literal: true

require "rails_helper"

# IMP-555db48d41f1 (APO-4) — the DR replace smoke seed, RUN.
#
# WHY THIS SPEC EXISTS AND IS NOT REDUNDANT with
# replace_instance_executor_spec.rb. That spec drives the executor against
# factory-built rows it controls; the smoke seed drives it against the graph an
# OPERATOR has — a real System::InstancePool, a real Sdwan::PeerEnroller run,
# a ProviderVolume with a provider identity — and asserts the four steps agree
# with each other in that graph. A smoke seed nobody runs is the classic false
# success: it reads as coverage while its first line has been raising for
# months (the precedent is IMP-de7b0ec66dea, whose federation smoke drove three
# executors through a constructor they had never had).
#
# The seed is a straight-line script that `abort`s on any failed assertion, so
# running it IS the oracle: a SystemExit here means one of its five tests
# failed, and the message says which.
RSpec.describe "smoke_test_instance_replace seed" do
  # ActiveSupport's Kernel#silence_stream was removed in Rails 5 and this
  # extension has no global replacement, so the seed's progress output is
  # captured locally rather than left to flood the spec run.
  def run_seed!
    original = $stdout
    $stdout = StringIO.new
    load seed_path
  ensure
    $stdout = original
  end

  let(:seed_path) do
    Rails.root.join("../extensions/system/server/db/seeds/smoke_test_instance_replace.rb").to_s
  end

  # The seed resolves its fixtures off `Account.first` / the first provider,
  # so the world it runs in has to be exactly one of each.
  let!(:account)  { create(:account) }
  let!(:provider) { create(:system_provider, account: account, provider_type: "local_qemu") }
  let!(:region)   { create(:system_provider_region, account: account, provider: provider) }
  let!(:itype)    { create(:system_provider_instance_type, account: account, provider: provider) }
  # No template is created here: the account factory bootstraps the platform's
  # own templates (AccountBootstrapService.seed_templates_for), and the seed
  # resolves "base" from them — which is the graph a real install has.

  it "runs green end to end against the live object graph" do
    expect { run_seed! }.not_to raise_error
  end

  # The seed cleans up after itself unless SMOKE_KEEP=1. A seed that leaves its
  # pool, peers and volumes behind is not safe to re-run on a real install,
  # which is the property that makes it usable as an operator drill at all.
  it "leaves no fixtures behind" do
    run_seed!

    expect(System::InstancePool.where(name: "smoke-replace-pool")).to be_empty
    expect(System::ProviderVolume.where(name: "smoke-replace-volume")).to be_empty
    expect(Sdwan::Network.where(name: "smoke-replace-network")).to be_empty
    expect(System::NodeInstance.where("name LIKE ?", "smoke-replace-%")).to be_empty
  end

  # THE RESTORE, pinned separately. The seed swaps
  # System::Providers::Registry.for_volume / .for_instance for a mock and puts
  # them back in an ensure block. A leaked swap would silently mock the
  # provider registry for every spec that ran after it in the same process —
  # a cross-file corruption that no failure in this file would reveal.
  it "restores the provider registry it swapped" do
    original_volume   = System::Providers::Registry.method(:for_volume)
    original_instance = System::Providers::Registry.method(:for_instance)

    run_seed!

    expect(System::Providers::Registry.method(:for_volume)).to eq(original_volume)
    expect(System::Providers::Registry.method(:for_instance)).to eq(original_instance)
    expect(System::Providers::Registry.singleton_class.private_method_defined?(:__smoke_orig_for_volume))
      .to be(false)
    expect(System::Providers::Registry.singleton_class.method_defined?(:__smoke_orig_for_volume))
      .to be(false)
  end
end
