# frozen_string_literal: true

require "rails_helper"

# IMP-01a07042 renamed the target parameter of 28 SystemFleetTool actions from a
# bare `id` to `<noun>_id`, matching their 93 siblings: each action's
# `parameters:` hash IS the inputSchema a caller reads, and a caller
# pattern-matching across the catalog guesses `provider_id`, which the bare-`id`
# actions answered with ActiveRecord's "Couldn't find System::Provider without
# an ID" — naming neither the key it wanted nor the key it got.
#
# That rename kept `id` as an optional deprecated alias. IMP-01a08c71 removed
# all 28 aliases (operator decision: no compatibility shims), so the catalog
# now has ONE name per target and this guard says so: no action declares a
# bare `id` parameter at all, required or optional.
RSpec.describe "SystemFleetTool action id-parameter naming" do
  let(:definitions) { ::Ai::Tools::SystemFleetTool.action_definitions }

  def params_of(action_def)
    action_def[:parameters].is_a?(Hash) ? action_def[:parameters] : {}
  end

  it "has real inputs — a registry that failed to load would pass every example below" do
    expect(definitions.size).to be >= 100
    expect(definitions.keys).to all(start_with("system_"))
  end

  it "declares no bare `id` parameter on any action" do
    offenders = definitions.select { |_, d| params_of(d).key?(:id) }.keys

    expect(offenders).to be_empty,
      "these actions declare a bare `id` parameter:\n  #{offenders.join("\n  ")}\n\n" \
      "Name the target `<noun>_id`, as every other action does — a caller generalising " \
      "from the catalog sends `<noun>_id`. There is no `id` alias to keep (IMP-01a08c71)."
  end

  # A sample of the rename, pinned by name so a bulk revert is visible as more
  # than a count: the canonical is required and nothing else names the target.
  it "names the renamed actions' targets after their models" do
    {
      "system_get_provider" => :provider_id,
      "system_get_task" => :task_id,
      "system_drain_instance_pool" => :pool_id,
      "system_update_volume" => :volume_id,
      "system_get_storage_migration" => :migration_id,
      "system_gitops_get_repository" => :repository_id,
      "system_get_provider_connection" => :connection_id,
      "system_restore_volume_snapshot" => :snapshot_id
    }.each do |action, canonical|
      params = params_of(definitions.fetch(action))

      expect(params[canonical]).to be_present, "#{action} does not declare #{canonical}"
      expect(params[canonical][:required]).to be(true), "#{action}: #{canonical} is not required"
      expect(params).not_to have_key(:id), "#{action} still declares the removed `id` alias"
    end
  end
end
