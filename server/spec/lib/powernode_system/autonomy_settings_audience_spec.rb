# frozen_string_literal: true

require "rails_helper"

# fc-30 — WHO CAN STILL OPEN THE AUTONOMY SETTINGS.
#
# The Operations hub's autonomy settings used to call this extension's own
# endpoint, gated on system.infra_tasks.read / .control. They now call core's
# intervention-policy endpoints, gated on core's ai.intervention_policies.manage
# (the only action that resource declares, so it gates the grouped read too).
#
# The ruling: an operator role that reached the settings before must reach them
# after. If a role holding system.infra_tasks.* lacked the core permission, this
# extension would grant it to that role in its own registration (an extension
# may name a core permission; core may not name an extension's).
#
# RESULT, recorded 2026-09-25: no grant is needed. system.infra_tasks.* is
# granted to `admin` alone (engine.rb), and core's catalog already grants
# ai.intervention_policies.manage to owner, admin, manager and ai_specialist.
# This spec is the record, and it reds the day a role gains the extension
# permission without the core one.
RSpec.describe "Autonomy settings audience after the move to core's policy endpoints", type: :lib do
  let(:core_permission) { "ai.intervention_policies.manage" }

  let(:settings_roles) do
    Permissions.all_roles.keys.select do |role|
      Permissions.permissions_for_role(role).include?("system.infra_tasks.read")
    end
  end

  it "grants core's policy permission to every role that holds system.infra_tasks.read" do
    stranded = settings_roles.reject { |role| Permissions.permissions_for_role(role).include?(core_permission) }

    expect(stranded).to be_empty,
                        "role(s) #{stranded.join(', ')} could open the old System autonomy settings but lack " \
                        "#{core_permission}, which core's grouped view and bulk save require. Grant it to them " \
                        "in lib/powernode_system/engine.rb."
  end

  # Vacuity guard: the example above is trivially green if no role holds the
  # extension permission at all (a renamed permission, an engine that did not load).
  it "has a real audience to check" do
    expect(settings_roles).to include("admin")
  end

  # The catalog is what Role.sync_from_config! materialises, so an assignable
  # role's USER must actually pass both gates, not just its config list.
  it "lets a real admin user through both the old and the new gate" do
    admin = create(:user, :admin)

    expect(admin.has_permission?("system.infra_tasks.read")).to be(true)
    expect(admin.has_permission?(core_permission)).to be(true)
  end
end
