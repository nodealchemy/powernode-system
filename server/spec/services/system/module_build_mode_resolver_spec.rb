# frozen_string_literal: true

require "rails_helper"

# Campaign 019f5885 inc10 — System::ModuleBuildModeResolver, the single
# source of truth for system.module_builds.mode. Fail-safe default is
# "gitea" — an operator must explicitly opt into "dual" or "native".
RSpec.describe System::ModuleBuildModeResolver do
  describe ".current" do
    it "defaults to gitea when the SiteSetting has never been set" do
      expect(described_class.current).to eq("gitea")
    end

    it "returns dual once the SiteSetting is set to dual" do
      SiteSetting.set("system.module_builds.mode", "dual")
      expect(described_class.current).to eq("dual")
    end

    it "returns native once the SiteSetting is set to native" do
      SiteSetting.set("system.module_builds.mode", "native")
      expect(described_class.current).to eq("native")
    end

    it "falls back to gitea for an unrecognized value (fail-safe, never fail-open)" do
      SiteSetting.set("system.module_builds.mode", "bogus")
      expect(described_class.current).to eq("gitea")
    end

    it "falls back to gitea for a blank value" do
      # SiteSetting.set validates value presence, so a blank string can't be
      # persisted through the normal API — stub .get directly to exercise
      # the resolver's own blank-handling (raw.presence) branch.
      allow(SiteSetting).to receive(:get).with("system.module_builds.mode").and_return("")
      expect(described_class.current).to eq("gitea")
    end
  end

  describe "predicates" do
    it "gitea? is true by default" do
      expect(described_class).to be_gitea
      expect(described_class).not_to be_dual
      expect(described_class).not_to be_native
    end

    it "dual? is true only in dual mode" do
      SiteSetting.set("system.module_builds.mode", "dual")
      expect(described_class).to be_dual
      expect(described_class).not_to be_gitea
      expect(described_class).not_to be_native
    end

    it "native? is true only in native mode" do
      SiteSetting.set("system.module_builds.mode", "native")
      expect(described_class).to be_native
      expect(described_class).not_to be_gitea
      expect(described_class).not_to be_dual
    end
  end
end
