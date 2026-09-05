# frozen_string_literal: true

require "rails_helper"

# Domain-purity guard: the system extension's skill executors must NOT bind
# their infra skills to generic core agents. A strategy/research agent owning
# `system-platform-deploy` / `system-attribute-failure` etc. is a domain
# mismatch — those skills belong to the system agents (Concierge / CVE
# Responder / Fleet Autonomy). This pins the corrected `binds_to` declarations
# at the registry level (the source of truth materialized by
# system_skill_bindings_seed.rb).
RSpec.describe "System SkillBindings registry — no core-agent leak" do
  # The (pre-rename and post-rename) names a generic core planning/research
  # agent could carry. None may appear as a binding target in the registry.
  FORBIDDEN_AGENT_NAMES = [
    "Strategic Planner", "Research Analyst",
    "Claude Strategic Planner", "Claude Research Analyst"
  ].freeze

  before(:all) do
    glob = Rails.root.join("../extensions/system/server/app/services/system/ai/skills/**/*_executor.rb")
    Dir.glob(glob).each { |f| require_dependency f }
  end

  let(:registry) { System::Ai::Skills::SkillBindings.discover }

  it "is populated" do
    expect(registry.size).to be > 30
  end

  it "binds no skill to a generic core planning/research agent" do
    leaked = registry.select { |e| FORBIDDEN_AGENT_NAMES.include?(e[:agent_key]) }
    expect(leaked).to be_empty,
      "system skills leaked to core agents: #{leaked.map { |e| "#{e[:skill_slug]}→#{e[:agent_key]}" }.inspect}"
  end

  it "keeps the formerly-leaked skills bound to their system agents" do
    formerly_leaked = %w[
      system-capacity-recommend system-platform-deploy system-platform-resilience
      system-runbook-generate system-attribute-failure system-cve-runbook-generate
      system-suggest-architectures-for-fleet system-discover-packages-by-intent
    ]
    formerly_leaked.each do |slug|
      owners = registry.select { |e| e[:skill_slug] == slug }.map { |e| e[:agent_key] }
      expect(owners).to include("system-concierge"),
        "#{slug} should still be bound to System Concierge (owners=#{owners.inspect})"
    end
  end
end
