# frozen_string_literal: true

require "rails_helper"

# IMP-f1f96c292991 — role modules used ONLY by smoke seeds (docker-runtime,
# python-runtime, postgres-server, redis-cache) are sample content, behind
# Powernode::SampleContentGate, default OFF. `nodejs-runtime` is DELIBERATELY
# EXCLUDED from the gate: verified 2026-09-18 that the live "powernode-
# ops-cell" NodeTemplate carries 14 real System::NodeModuleAssignment rows
# for it (the only one of the five with any), so it stays baseline product
# content and is seeded unconditionally.
RSpec.describe "role_modules_seed.rb sample-content gating" do
  def load_seed!
    silence_warnings { load Rails.root.join("../extensions/system/server/db/seeds/role_modules_seed.rb") }
  end

  let!(:account) { create(:account) }

  GATED_ROLE_MODULE_NAMES = %w[docker-runtime python-runtime postgres-server redis-cache].freeze

  context "when sample content is disabled (default)" do
    it "creates nodejs-runtime only" do
      load_seed!
      names = ::System::NodeModule.where(account: account, name: GATED_ROLE_MODULE_NAMES + %w[nodejs-runtime]).pluck(:name)
      expect(names).to eq(%w[nodejs-runtime])
    end
  end

  context "when sample content is enabled" do
    before { SiteSetting.set(Powernode::SampleContentGate::SETTING_KEY, "true", setting_type: "boolean") }

    it "creates all 5 role modules, including nodejs-runtime" do
      load_seed!
      names = ::System::NodeModule.where(account: account, name: GATED_ROLE_MODULE_NAMES + %w[nodejs-runtime]).pluck(:name)
      expect(names).to match_array(GATED_ROLE_MODULE_NAMES + %w[nodejs-runtime])
    end

    it "is idempotent — running twice does not duplicate rows" do
      load_seed!
      load_seed!
      expect(::System::NodeModule.where(account: account, name: GATED_ROLE_MODULE_NAMES).count).to eq(4)
    end
  end
end
