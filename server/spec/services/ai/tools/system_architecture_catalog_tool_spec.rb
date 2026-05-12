# frozen_string_literal: true

require "rails_helper"

# T1.A — MCP parity for the architecture catalog. Covers:
#   - all 6 actions (list/get/create/update/delete/propose)
#   - permission gating (read vs manage vs propose)
#   - canonical-row mutation guard (update/delete reject is_canonical:true)
#   - propose flow creating Ai::AgentProposal (not a NodeArchitecture row)
#   - usage counter surfacing in the serialized output
RSpec.describe Ai::Tools::SystemArchitectureCatalogTool do
  include PermissionTestHelpers

  let(:account) { create(:account) }
  let(:tool_internal) { described_class.new(account: account) } # internal bypass — no @user
  let(:read_user)    { user_with_permissions("system.architectures.read", account: account) }
  let(:propose_user) { user_with_permissions("system.architectures.read", "system.architectures.propose", account: account) }
  let(:manage_user)  { user_with_permissions("system.architectures.read", "system.architectures.manage", account: account) }

  before do
    # Most actions assume the canonical 7 are seeded. ensure_canonical_seed!
    # is idempotent — safe to call here even if the suite-level before(:suite)
    # already ran it.
    System::NodeArchitecture.ensure_canonical_seed!

    # The propose path falls back to the account's Fleet Autonomy agent
    # when @agent isn't set. Seed a minimal one so propose works regardless
    # of whether the example explicitly tests that path.
    provider = ::Ai::Provider.first || create(:ai_provider)
    ::Ai::Agent.find_or_create_by!(account: account, name: "Fleet Autonomy") do |a|
      a.agent_type = "monitor"
      a.status = "active"
      a.creator = account.users.first || create(:user, account: account)
      a.provider = provider
    end
  end

  def call_as(user, action, **rest)
    described_class.new(account: account, user: user)
      .execute(params: { action: action }.merge(rest))
  end

  # ── action_definitions registration ────────────────────────────────────

  describe ".action_definitions" do
    it "registers all 6 catalog actions" do
      keys = described_class.action_definitions.keys.sort
      expect(keys).to eq(%w[
        system_create_architecture
        system_delete_architecture
        system_get_architecture
        system_list_architectures
        system_propose_architecture
        system_update_architecture
      ])
    end
  end

  # ── list ───────────────────────────────────────────────────────────────

  describe "system_list_architectures" do
    it "returns canonical rows + usage counters" do
      r = call_as(read_user, "system_list_architectures")
      expect(r[:success]).to be true
      names = r[:data][:architectures].map { |a| a[:name] }
      expect(names).to include("amd64", "arm64", "riscv64")
      first = r[:data][:architectures].find { |a| a[:name] == "amd64" }
      expect(first[:usage]).to include(:node_platforms, :package_repositories, :packages)
      expect(first[:is_canonical]).to be true
    end

    it "filters by family" do
      r = call_as(read_user, "system_list_architectures", family: "arm")
      names = r[:data][:architectures].map { |a| a[:name] }
      expect(names).to match_array(%w[arm64 armhf])
    end

    it "filters canonical-only with is_canonical:true" do
      # Add a custom row so we have a contrast
      create(:system_node_architecture, name: "custom_arch", family: "other", is_canonical: false,
                                         apt_name: "customapt", rpm_name: "customrpm",
                                         display_name: "Custom Arch", description: "...")
      r = call_as(read_user, "system_list_architectures", is_canonical: true)
      expect(r[:data][:architectures]).to all(include(is_canonical: true))
      expect(r[:data][:architectures].map { |a| a[:name] }).not_to include("custom_arch")
    end
  end

  # ── get ────────────────────────────────────────────────────────────────

  describe "system_get_architecture" do
    let(:arch) { System::NodeArchitecture.find_by!(name: "amd64") }

    it "returns the row by id" do
      r = call_as(read_user, "system_get_architecture", architecture_id: arch.id)
      expect(r[:success]).to be true
      expect(r[:data][:architecture][:name]).to eq("amd64")
      expect(r[:data][:architecture][:rpm_name]).to eq("x86_64")
    end

    it "returns an error for unknown id" do
      r = call_as(read_user, "system_get_architecture", architecture_id: "00000000-0000-0000-0000-000000000000")
      expect(r[:success]).to be false
      expect(r[:error]).to match(/not found|Couldn't find/i)
    end
  end

  # ── permission gating ──────────────────────────────────────────────────

  describe "permission gating" do
    it "read user can list but cannot create" do
      list_r = call_as(read_user, "system_list_architectures")
      create_r = call_as(read_user, "system_create_architecture", name: "custom1", family: "other")

      expect(list_r[:success]).to be true
      expect(create_r[:success]).to be false
      expect(create_r[:error]).to match(/permission denied.*manage/i)
    end

    it "propose user cannot create directly but CAN propose" do
      direct = call_as(propose_user, "system_create_architecture", name: "custom2", family: "other")
      proposal = call_as(propose_user, "system_propose_architecture",
                          name: "custom2", family: "other",
                          justification: "Needed for our fleet")

      expect(direct[:success]).to be false
      expect(direct[:error]).to match(/permission denied/i)
      expect(proposal[:success]).to be true
    end

    it "manage user can create directly" do
      r = call_as(manage_user, "system_create_architecture",
                   name: "managed_arch", family: "other",
                   apt_name: "managed_apt", rpm_name: "managed_rpm",
                   display_name: "Managed Arch")
      expect(r[:success]).to be true
      arch = System::NodeArchitecture.find(r[:data][:architecture][:id])
      expect(arch.name).to eq("managed_arch")
      expect(arch.is_canonical).to be false # agents can never fabricate canonicals
    end

    it "internal call (no user) bypasses permission checks" do
      r = tool_internal.execute(params: { action: "system_create_architecture",
                                            name: "internal_arch", family: "other",
                                            apt_name: "intapt", rpm_name: "intrpm",
                                            display_name: "Internal" })
      expect(r[:success]).to be true
    end
  end

  # ── canonical-row mutation guard ───────────────────────────────────────

  describe "canonical-row immutability" do
    let(:canonical_amd64) { System::NodeArchitecture.find_by!(name: "amd64") }

    it "update_architecture rejects canonical rows even with manage permission" do
      r = call_as(manage_user, "system_update_architecture",
                   architecture_id: canonical_amd64.id,
                   attributes: { description: "tampered" })
      expect(r[:success]).to be false
      expect(r[:error]).to match(/canonical.*immutable/i)
      expect(canonical_amd64.reload.description).not_to eq("tampered")
    end

    it "delete_architecture rejects canonical rows even with manage permission" do
      r = call_as(manage_user, "system_delete_architecture", architecture_id: canonical_amd64.id)
      expect(r[:success]).to be false
      expect(r[:error]).to match(/canonical.*immutable/i)
      expect(System::NodeArchitecture.exists?(canonical_amd64.id)).to be true
    end

    it "update and delete WORK on non-canonical custom rows" do
      custom = call_as(manage_user, "system_create_architecture",
                        name: "custom_for_mutation", family: "other",
                        apt_name: "cforma", rpm_name: "cformr",
                        display_name: "Mutation Target")
      id = custom[:data][:architecture][:id]

      upd = call_as(manage_user, "system_update_architecture",
                     architecture_id: id,
                     attributes: { description: "updated" })
      expect(upd[:success]).to be true
      expect(System::NodeArchitecture.find(id).description).to eq("updated")

      del = call_as(manage_user, "system_delete_architecture", architecture_id: id)
      expect(del[:success]).to be true
      expect(System::NodeArchitecture.exists?(id)).to be false
    end
  end

  # ── aliases (T2.C) ─────────────────────────────────────────────────────

  describe "aliases" do
    let(:custom_arch) do
      create(:system_node_architecture, name: "custom-#{SecureRandom.hex(3)}",
                                         family: "arm",
                                         apt_name: "custarm-#{SecureRandom.hex(2)}",
                                         rpm_name: "custarmr-#{SecureRandom.hex(2)}",
                                         display_name: "Custom ARM",
                                         is_canonical: false,
                                         enabled: true)
    end

    it "stores aliases lowercased + deduplicated on create" do
      r = call_as(manage_user, "system_create_architecture",
                    name: "alias-create-#{SecureRandom.hex(3)}",
                    family: "arm",
                    apt_name: "ac-#{SecureRandom.hex(2)}",
                    rpm_name: "acr-#{SecureRandom.hex(2)}",
                    display_name: "Alias Create",
                    aliases: ["Vendor-X", "vendor-x", "VENDOR-Y"])
      expect(r[:success]).to be true
      expect(r[:data][:architecture][:aliases]).to match_array(%w[vendor-x vendor-y])
    end

    it "updates aliases via update_architecture attributes" do
      r = call_as(manage_user, "system_update_architecture",
                    architecture_id: custom_arch.id,
                    attributes: { aliases: ["Foo-Bar", "foo-bar, baz"] })
      expect(r[:success]).to be true
      expect(custom_arch.reload.aliases).to match_array(%w[foo-bar baz])
    end

    it "find_normalized resolves a custom alias case-insensitively to its canonical row" do
      custom_arch.update!(aliases: ["amd64-graviton", "x86_64-v3"])
      # Re-fetch fresh, no memoization
      expect(::System::NodeArchitecture.find_normalized("AMD64-Graviton")&.id).to eq(custom_arch.id)
      expect(::System::NodeArchitecture.find_normalized("X86_64-V3")&.id).to eq(custom_arch.id)
      expect(::System::NodeArchitecture.find_normalized("not-an-alias")).to be_nil
    end

    it "rejects aliases that shadow a canonical name" do
      # amd64 is a canonical name; can't alias it onto a custom row.
      r = call_as(manage_user, "system_update_architecture",
                    architecture_id: custom_arch.id,
                    attributes: { aliases: ["amd64"] })
      expect(r[:success]).to be false
      expect(r[:error]).to match(/canonical names/i)
    end

    it "surfaces aliases in serialize output" do
      custom_arch.update!(aliases: ["my-vendor-tag"])
      r = call_as(read_user, "system_get_architecture", architecture_id: custom_arch.id)
      expect(r[:data][:architecture][:aliases]).to eq(["my-vendor-tag"])
    end
  end

  # ── propose flow creates an Ai::AgentProposal, not a row ───────────────

  describe "system_propose_architecture" do
    it "creates an Ai::AgentProposal and does NOT materialize a NodeArchitecture" do
      before_count = System::NodeArchitecture.count
      r = call_as(propose_user, "system_propose_architecture",
                   name: "proposed_arch", family: "arm",
                   apt_name: "parch", rpm_name: "parchr",
                   display_name: "Proposed Arch",
                   description: "Needed for $vendor's new boards",
                   justification: "Three operators have asked over the past month")
      expect(r[:success]).to be true
      expect(r[:data][:proposal_id]).to be_present
      expect(r[:data][:status]).to eq("pending_review")

      # Arch NOT materialized
      expect(System::NodeArchitecture.count).to eq(before_count)
      expect(System::NodeArchitecture.find_by(name: "proposed_arch")).to be_nil

      # Proposal IS persisted
      proposal = Ai::AgentProposal.find(r[:data][:proposal_id])
      expect(proposal.proposal_type).to eq("configuration")
      expect(proposal.proposed_changes["resource"]).to eq("system.node_architecture")
      expect(proposal.proposed_changes["attributes"]["name"]).to eq("proposed_arch")
      expect(proposal.description).to match(/Justification: Three operators/)
    end
  end
end
