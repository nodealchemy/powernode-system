# frozen_string_literal: true

require "rails_helper"

# Shared class-level adapter selection for the gitea/local dual-mode services
# (IMP-c5a311bdfd46 — previously duplicated ~25 lines each in
# ManifestFetchService and ModuleBuildDispatchService, and a third
# env-switched service would have cloned it again).
RSpec.describe System::EnvSwitchedAdapter do
  let(:gitea_adapter) { Class.new }
  let(:local_adapter) { Class.new }
  let(:error_class)   { Class.new(StandardError) }

  let(:host) do
    g, l = gitea_adapter, local_adapter
    e = error_class
    Class.new do
      extend System::EnvSwitchedAdapter
    end.tap do |klass|
      # Adapter names resolve lazily via const_get: in the real services the
      # adapter classes are defined BELOW the declaration in the same file.
      klass.const_set(:GiteaTestAdapter, g)
      klass.const_set(:LocalTestAdapter, l)
      klass.env_switched_adapter(
        env_var: "POWERNODE_TEST_ADAPTER_MODE",
        adapters: { "gitea" => "GiteaTestAdapter", "local" => "LocalTestAdapter" },
        error_class: e
      )
    end
  end

  it "defaults to the local adapter outside production and memoizes it" do
    first = host.adapter

    expect(first).to be_a(local_adapter)
    expect(host.adapter).to equal(first)
  end

  it "honors the declared env var for gitea mode" do
    stub_const("ENV", ENV.to_h.merge("POWERNODE_TEST_ADAPTER_MODE" => "gitea"))

    expect(host.adapter).to be_a(gitea_adapter)
  end

  it "defaults to gitea in production" do
    allow(Rails.env).to receive(:production?).and_return(true)

    expect(host.adapter).to be_a(gitea_adapter)
  end

  it "raises the HOST's error class naming the HOST's env var on an unknown mode" do
    stub_const("ENV", ENV.to_h.merge("POWERNODE_TEST_ADAPTER_MODE" => "bogus"))

    expect { host.adapter }
      .to raise_error(error_class, /POWERNODE_TEST_ADAPTER_MODE.*"bogus"/)
  end

  it "supports test injection via adapter= and clears it with reset!" do
    injected = Object.new
    host.adapter = injected

    expect(host.adapter).to equal(injected)

    host.reset!
    expect(host.adapter).to be_a(local_adapter)
  end
end
