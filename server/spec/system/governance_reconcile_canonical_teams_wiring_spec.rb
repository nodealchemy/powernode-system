# frozen_string_literal: true

require "rails_helper"

# IMP-01a06cd4 — the boot-time governance reconcile lands the CANONICAL TEAMS.
#
# `system:governance:reconcile` (lib/tasks/governance_reconcile.rake) carries
# four passes: declared policy rows, skill bindings, core's account-wide
# engineering floors and the per-account materialisation of every canonical
# Ai::TeamTemplate. The hub image's per-boot governance-reconcile.rb carried
# only the first three, so a drifted canonical team — a seat removed, a role
# changed, a team never materialised on an install whose first boot predates
# the team seeds — was repaired ONLY by an operator running the rake task by
# hand. `db:seed` is first-boot only on a deployed hub, so nothing else
# converged it.
#
# That divergence was ASSERTED AWAY: the rake file's own header said it
# "carries the same steps as the hub image's per-boot governance-reconcile.rb
# — declared policy rows, skill bindings, canonical teams and core's
# account-wide engineering floors", which was false for the boot door. A
# comment claiming parity is read instead of the two files being compared, so
# the pass is pinned HERE, against the runner, rather than left to that
# sentence.
#
# THE WRITE SET IS NOT Account.all. Materialising a canonical team MINTS an
# account principal per seat, so a walk over every account would create a team
# and a clone per seat in every tenant on every boot. The runner uses
# Ai::Teams::CanonicalTeamReconciler.reconcilable_accounts — the accounts that
# already hold a canonical team, plus the primary account the seeds
# materialise in — exactly as the rake task does. The last example is that
# half, and it is what stops this wiring from being a per-tenant agent factory.
#
# The runner is LOADED against the real seam rather than grepped, so the
# assertions are on the rows the boot leaves behind and the line the journal
# would carry.
#
# `type: :lib` is explicit and load-bearing — see
# governance_reconcile_release_floor_wiring_spec.rb.
RSpec.describe "hub-backend governance reconcile canonical-teams wiring (IMP-01a06cd4)", type: :lib do
  let(:runner) do
    File.expand_path("../../../modules/powernode-hub-backend/rootfs/usr/local/bin/governance-reconcile.rb", __dir__)
  end

  # Named "Powernode Admin" so it is CanonicalTeamReconciler.primary_account,
  # the account the boot pass is allowed to materialise into.
  let!(:account)  { create(:account, name: "Powernode Admin") }
  let!(:user)     { create(:user, account: account, email: "admin@powernode.org") }
  let!(:provider) { create(:ai_provider, account: account, provider_type: "anthropic", is_active: true) }

  def canonical(name:, slug:, agent_type:)
    create(:ai_agent, :global, owner_account: account, name: name, slug: slug, source_key: slug,
                               agent_type: agent_type, is_system: true)
  end

  let!(:manager) { canonical(name: "Boot Lead",    slug: "boot-lead",    agent_type: "assistant") }
  let!(:worker)  { canonical(name: "Boot Worker",  slug: "boot-worker",  agent_type: "monitor") }

  let(:members) do
    [
      { slug: "boot-lead",   name: "Boot Lead",   role: "manager", lead: true },
      { slug: "boot-worker", name: "Boot Worker", role: "executor" }
    ]
  end

  let!(:template) do
    Ai::Teams::CanonicalTeamSeeder.seed!(
      slug: "boot-crew", name: "Boot Crew", description: "The boot crew",
      category: "operations", members: members
    )
  end

  def team_for(acct) = acct.ai_agent_teams.find_by(template_id: template.id)

  def member_slugs(acct)
    team = team_for(acct)
    return [] if team.nil?

    team.members.includes(:agent).map { |member| member.agent&.source_key || member.agent&.slug }.compact.sort
  end

  def load_runner
    silence_warnings { load runner }
  end

  it "materialises a canonical team the primary account never had, and prints its summary line" do
    expect(team_for(account)).to be_nil

    expect { load runner }
      .to output(a_string_including("[governance-reconcile] canonical-teams"))
      .to_stderr

    expect(team_for(account)).to be_present
    expect(member_slugs(account)).to eq(%w[boot-lead boot-worker])
  end

  it "repairs a team an operator drifted — the seat comes back on the next boot" do
    Ai::Teams::CanonicalTeamReconciler.new(account: account, template: template).reconcile!
    expect(member_slugs(account)).to eq(%w[boot-lead boot-worker])

    team_for(account).members.joins(:agent).where(ai_agents: { source_key: "boot-worker" }).destroy_all
    expect(member_slugs(account)).to eq(%w[boot-lead])

    load_runner

    expect(member_slugs(account)).to eq(%w[boot-lead boot-worker])
  end

  it "prints the steady-state line — the positive per-boot artifact, never silence" do
    load_runner
    expect(member_slugs(account)).to eq(%w[boot-lead boot-worker])

    expect { load runner }
      .to output(a_string_including("[governance-reconcile] canonical-teams accounts="))
      .to_stderr
    expect(member_slugs(account)).to eq(%w[boot-lead boot-worker])
  end

  # THE HALF THAT KEEPS THE WIRING SAFE. A tenant that holds no canonical team
  # is outside `reconcilable_accounts`, so the boot pass must leave it with no
  # team and mint it no principal. An Account.all walk would pass every example
  # above and fail only this one.
  it "leaves a tenant holding no canonical team untouched — no team, no minted principal" do
    tenant = create(:account, name: "Some Tenant")

    expect { load_runner }.not_to change { tenant.ai_agents.count }

    expect(team_for(tenant)).to be_nil
    expect(Ai::Agents::AccountPrincipalResolver.existing(manager, account: tenant)).to be_nil
  end
end
