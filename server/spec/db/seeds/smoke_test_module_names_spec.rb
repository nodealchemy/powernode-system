# frozen_string_literal: true

require "rails_helper"

# Audit F7-05 — two tracked smoke tests still asserted pre-rename module
# names destroyed by the 2026-05-24 cutover (185bf70), so running them today
# fails with "module powernode-postgres not seeded". Pins that the smoke
# scripts reference only post-cutover names.
RSpec.describe "smoke-test module name currency (F7-05)" do
  SEED_DIR = Rails.root.join("../extensions/system/server/db/seeds")

  # The renamed modules these smoke tests reference (from
  # cutover_renamed_modules.rb OLD_NAMES → NEW_NAMES). Names NOT renamed
  # (powernode-hub-*, powernode-extension-system, reverse-proxy-traefik)
  # are intentionally excluded.
  RENAMED_AWAY = %w[
    powernode-postgres
    powernode-redis
    powernode-base-ruby
    powernode-pg-replica
  ].freeze

  %w[smoke_test_powernode_hub.rb smoke_test_cluster_member_ha.rb].each do |file|
    it "#{file} references no pre-cutover module names" do
      content = File.read(SEED_DIR.join(file))
      stale = RENAMED_AWAY.select { |name| content.include?(name) }
      expect(stale).to be_empty,
        "#{file} still references renamed-away modules: #{stale.join(', ')}"
    end
  end
end
