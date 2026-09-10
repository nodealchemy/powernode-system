# frozen_string_literal: true

require "rails_helper"

# IMP-01a07042. SystemFleetTool advertises one MCP tool per action, and each
# action's `parameters:` hash IS the inputSchema a caller reads
# (platform.describe_tool confirms it: system_get_provider answered
# {"required":["id"]}). 28 actions named their target with a bare `id` while 93
# siblings named it `<noun>_id`.
#
# NOTHING WAS BROKEN ABOUT ANY ONE OF THEM — measured across every action, zero
# declared a `<noun>_id` while reading `params[:id]`, so no key was ever dropped
# relative to its own schema. The cost was to a caller pattern-matching across
# the catalog: guessing `provider_id` on system_get_provider produced
# ActiveRecord's own "Couldn't find System::Provider without an ID", which names
# neither the key it wanted nor the key it got. For a surface whose callers are
# mostly LLMs generalising from sibling tools, that is a trap the catalog sets.
#
# The canonical name is `<noun>_id`; `id` stays declared and accepted as a
# deprecated alias so cached client schemas keep working.
#
# THIS GUARD IS ABOUT NEW ACTIONS. The alias is grandfathered wherever it
# already exists (required: false, alongside a required `<noun>_id`); what it
# refuses is a bare REQUIRED `id`, which is how the 28 arrived.
RSpec.describe "SystemFleetTool action id-parameter naming" do
  let(:definitions) { ::Ai::Tools::SystemFleetTool.action_definitions }

  def id_param(action_def)
    action_def[:parameters].is_a?(Hash) ? action_def[:parameters][:id] : nil
  end

  it "has real inputs — a registry that failed to load would pass every example below" do
    expect(definitions.size).to be >= 100
    expect(definitions.keys).to all(start_with("system_"))
  end

  it "declares no action whose target id is a bare required `id`" do
    offenders = definitions.select { |_, d| id_param(d).is_a?(Hash) && id_param(d)[:required] }.keys

    expect(offenders).to be_empty,
      "these actions name their target with a bare required `id` while 93 siblings use " \
      "`<noun>_id`:\n  #{offenders.join("\n  ")}\n\n" \
      "A caller generalising from the catalog sends `<noun>_id`, gets it dropped, and reads " \
      "ActiveRecord's \"Couldn't find X without an ID\". Declare `<noun>_id` as the required " \
      "parameter and keep `id` as an optional alias (see #resolved_id)."
  end

  # The other half: an `id` that survives must be the deprecated alias of a
  # required `<noun>_id`, never an orphan. Without this, "delete the id entry"
  # passes the example above while breaking every existing caller.
  it "keeps every surviving `id` as the optional alias of a required <noun>_id" do
    orphans = definitions.select { |_, d|
      next false unless id_param(d).is_a?(Hash)

      others = d[:parameters].keys.select { |k| k.to_s.end_with?("_id") }
      others.none? { |k| d[:parameters][k][:required] }
    }.keys

    expect(orphans).to be_empty,
      "these actions declare `id` with no required `<noun>_id` beside it:\n  #{orphans.join("\n  ")}"
  end

  # A sample of the rename, pinned by name so a bulk revert is visible as more
  # than a count. Both halves for each: the canonical is required, the alias is
  # accepted.
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
      params = definitions.fetch(action)[:parameters]

      expect(params[canonical]).to be_present, "#{action} does not declare #{canonical}"
      expect(params[canonical][:required]).to be(true), "#{action}: #{canonical} is not required"
      expect(params[:id]).to be_present, "#{action} dropped the `id` alias existing callers send"
      expect(params[:id][:required]).to be(false), "#{action}: the `id` alias must not be required"
    end
  end
end
