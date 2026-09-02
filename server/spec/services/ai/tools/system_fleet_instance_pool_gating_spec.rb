# frozen_string_literal: true

require "rails_helper"

# IMP-067f39468350 — the MCP half of the instance-pool spend-ceiling gate.
#
# IMP-24daa05e7a22 gated the REST twins: PATCH /instance_pools/:id parks a
# target_size/max_size INCREASE under system.instance_pool_ceiling_raise and
# the transition to "archived" under system.instance_pool_archive, and POST
# /instance_pools parks under system.instance_pool_create. The MCP verbs onto
# the SAME columns were untouched: `system_update_instance_pool` ran
# `pool.update!(attrs)` over a slice carrying target_size/max_size/status, and
# `system_create_instance_pool` called `::System::InstancePool.create!`
# directly. Neither declaration carried the
# action_category/executor_class/gate_context/on_proceed quartet
# Ai::Tools::BaseTool#gated_action? reads, so #execute routed both straight to
# #call. A gate an agent walks around by naming a different door is decorative.
#
# THE ORACLE IS THE ROW, in every example. This repo has shipped a guard that
# rendered a refusal from an action body while the write landed
# (IMP-ce5d320d3e4e), so a `pending`-shaped response proves nothing on its own:
# each gated example reads the pool back, and each inline example proves the
# write DID land so "gated" cannot be satisfied by refusing everything.
#
# The NEGATIVE half is as load-bearing as the positive one. Decreases,
# min_size, description, regions and metadata stay inline by operator
# direction, exactly as on the REST route — an example that only proved "the
# MCP verb is gated" would pass for a tool that parked a description edit too.
RSpec.describe "SystemFleetTool instance-pool gating (IMP-067f39468350)" do
  let(:account)  { create(:account) }
  # system.nodes.read is carried deliberately alongside the two pool
  # permissions. It is SystemFleetTool::REQUIRED_PERMISSION — the tool floor —
  # and Ai::Executors::DeferredToolCall#authorized? re-asks for exactly that
  # (not the per-action permission) before it replays an approved call. So a
  # principal that could park a ceiling raise but does not hold the floor would
  # have its approval refused at replay time, and the "really writes when
  # approved" examples below would pass for the wrong reason if this fixture
  # quietly took that path. The per-action check still runs after it, inside
  # #execute -> #authorization_error, and is what the unauthorized example
  # exercises.
  let(:user) do
    create(:user, account: account,
                  permissions: %w[system.nodes.read system.instances.create
                                  system.instances.control])
  end
  let(:tool)     { Ai::Tools::SystemFleetTool.new(account: account, user: user) }
  let(:template) { create(:system_node_template, account: account) }

  let!(:pool) do
    ::System::InstancePool.create!(
      account: account, name: "ceiling-pool", node_template: template,
      target_size: 2, min_size: 0, max_size: 5,
      lifecycle_class: "ephemeral", status: "active", description: "before"
    )
  end

  def update!(attrs)
    tool.execute(params: { action: "system_update_instance_pool", id: pool.id }.merge(attrs))
  end

  def create!(attrs = {})
    tool.execute(params: {
      action: "system_create_instance_pool",
      name: "minted-over-mcp", template_id: template.id, target_size: 2
    }.merge(attrs))
  end

  def latest_deferred
    ::Ai::DeferredOperation.where(account_id: account.id).order(created_at: :desc).first
  end

  # The categories are pinned to the REST controller's own constants rather
  # than to literals repeated here: the load-bearing claim of this task is that
  # ONE operator-tuned policy row governs a ceiling raise whichever door it
  # arrives through, and two independently-typed literals can drift apart while
  # every behavioural example still passes (Ai::InterventionPolicyService
  # defaults EVERY unmatched category to require_approval, so a misspelling
  # still parks).
  describe "the declarations" do
    let(:rest) { Api::V1::System::InstancePoolsController }

    it "arms the gate on both pool verbs" do
      %w[system_create_instance_pool system_update_instance_pool].each do |action|
        declaration = Ai::Tools::SystemFleetTool.declared_action(action)

        expect(declaration).to be_present, "#{action} is not declared at all"
        aggregate_failures action do
          expect(declaration[:mutating]).to be(true)
          expect(declaration[:action_category]).to be_present
          expect(declaration[:executor_class]).to eq("Ai::Executors::DeferredToolCall")
          expect(declaration[:gate_context]).to be_present
          expect(declaration[:on_proceed]).to be_present
        end
      end
    end

    it "names the categories the REST twins gate on" do
      expect(Ai::Tools::SystemFleetTool.declared_action("system_create_instance_pool")[:action_category])
        .to eq("system.instance_pool_create")

      # The update verb resolves ONE of two categories per payload, so the
      # declaration carries the ceiling-raise one and the archive transition is
      # substituted per call; both must be the controller's.
      expect(Ai::Tools::SystemFleetTool.declared_action("system_update_instance_pool")[:action_category])
        .to eq(rest::GATED_UPDATE_CATEGORIES[:ceiling_raise])
    end

    # An agent reads the CATALOG, not the declaration. A gated verb whose
    # description reads as a plain write is one an agent reports as completed on
    # a pending envelope — the same class of defect as the frontend rendering a
    # parked approval as a failure. system_terminate_instance on this tool sets
    # the house style, and SdwanTool annotates all of its gated verbs.
    it "announces the gate in the description an agent reads" do
      definitions = Ai::Tools::SystemFleetTool.action_definitions

      aggregate_failures do
        create = definitions["system_create_instance_pool"][:description]
        expect(create).to include("system.instance_pool_create")
        expect(create).to match(/pending/i)

        update = definitions["system_update_instance_pool"][:description]
        expect(update).to include("system.instance_pool_ceiling_raise")
        expect(update).to include("system.instance_pool_archive")
        expect(update).to match(/pending/i)
      end
    end

    it "gates on categories the platform actually declares" do
      declared = ::System::Governance::PolicyDeclarations::INSTANCE_POOL_POLICIES

      expect(declared).to include("system.instance_pool_create")
      expect(declared).to include(rest::GATED_UPDATE_CATEGORIES[:ceiling_raise])
      expect(declared).to include(rest::GATED_UPDATE_CATEGORIES[:archive])
    end
  end

  describe "raising the ceiling over MCP" do
    it "parks a target_size increase instead of writing it" do
      expect { update!(target_size: 4) }.to change(::Ai::DeferredOperation, :count).by(1)

      expect(pool.reload.target_size).to eq(2), "the raise was written despite the gate"
      expect(latest_deferred.action_category).to eq("system.instance_pool_ceiling_raise")
      expect(latest_deferred.executor_class).to eq("Ai::Executors::DeferredToolCall")
    end

    it "answers the caller with the pending envelope" do
      response = update!(max_size: 40)

      expect(pool.reload.max_size).to eq(5)
      expect(response[:success]).to be(true)
      expect(response[:data][:pending]).to be(true)
      expect(response[:data][:action_category]).to eq("system.instance_pool_ceiling_raise")
      expect(response[:data][:deferred_operation_id]).to eq(latest_deferred.id)
    end

    # "It parks" and "the parked operation still performs the work" are two
    # different claims, and only the second says the verb still functions.
    # Nothing is stubbed between the operation and the replay, so a params-key
    # mismatch surfaces here rather than as a well-formed pending response.
    it "really raises the ceiling when the parked operation is approved" do
      update!(target_size: 4, description: "travelling companion")

      latest_deferred.execute_now!

      expect(pool.reload.target_size).to eq(4)
      expect(pool.description).to eq("travelling companion"),
                                 "the gate must replay the WHOLE payload, not just the ceiling"
    end

    it "gates the archive transition under its own category" do
      response = update!(status: "archived")

      expect(pool.reload.status).to eq("active")
      expect(latest_deferred.action_category).to eq("system.instance_pool_archive")
      expect(response[:data][:pending]).to be(true)
    end

    # One category's verdict must not carry the other transition through.
    it "refuses a payload that crosses both gates, and parks nothing" do
      expect { update!(target_size: 4, status: "archived") }
        .not_to change(::Ai::DeferredOperation, :count)

      expect(pool.reload.target_size).to eq(2)
      expect(pool.status).to eq("active")
    end
  end

  # PREMISE EXPIRY. A parked raise is a decision made against the pool as it
  # stood at request time; decreases are deliberately ungated, so the state it
  # was decided against can move underneath it. Replaying verbatim then writes
  # the old high number back over a reduction nobody re-approved — the defect
  # IMP-391525770512 closed on the REST twin, which this task would otherwise
  # have re-opened by adding a second door onto the same executor-less write.
  #
  # The oracle is the ROW at the end, never the refusal message: an assertion on
  # the error text alone passes for a guard that refuses AND writes.
  describe "an approval whose premise expired" do
    it "refuses a raise approved after the pool was lowered inline" do
      update!(target_size: 4)
      operation = latest_deferred

      expect(update!(target_size: 1)[:success]).to be(true)
      expect(pool.reload.target_size).to eq(1)

      operation.execute_now!

      expect(pool.reload.target_size).to eq(1),
                                        "the stale approval wrote the old ceiling back over the decrease"
    end

    it "says why, rather than failing silently" do
      update!(target_size: 4)
      operation = latest_deferred
      update!(target_size: 1)

      operation.execute_now!

      expect(operation.reload.result.to_h.to_s).to include("changed since this operation was requested")
    end

    # The mirror direction UpdatePool fingerprints status for: an archive
    # approved after the pool moved on elsewhere.
    it "refuses an archive approved after the pool status moved" do
      update!(status: "archived")
      operation = latest_deferred

      update!(status: "draining")
      operation.execute_now!

      expect(pool.reload.status).to eq("draining")
    end

    # The negative half: an untouched premise must still go through, or
    # "refuses a stale approval" would be satisfied by refusing everything.
    it "still applies an approval whose premise still holds" do
      update!(target_size: 4)
      update!(description: "an unfingerprinted field moved")

      latest_deferred.execute_now!

      expect(pool.reload.target_size).to eq(4)
    end

    # THE FENCE. The baseline rides inside caller-shaped params, so a caller
    # who could author it would author a guard that always passes.
    it "ignores a caller-supplied baseline and stamps its own" do
      update!(target_size: 4, replay_baseline: { target_size: 999, max_size: 999 })
      operation = latest_deferred

      expect(operation.params["tool_params"]["replay_baseline"])
        .to eq("target_size" => 2)

      update!(target_size: 1)
      operation.execute_now!

      expect(pool.reload.target_size).to eq(1)
    end

    # A forged baseline on a DIRECT (ungated, non-replay) call is inert — it is
    # honoured only on an #approved_replay?, and it is not a writable column.
    it "neither writes nor honours a baseline key on an inline call" do
      expect(update!(target_size: 1, replay_baseline: { target_size: 999 })[:success]).to be(true)

      expect(pool.reload.target_size).to eq(1)
      expect(pool).not_to respond_to(:replay_baseline)
    end
  end

  # ANCHORING. Ai::DeferredOperation#assert_source_within_account! no-ops for an
  # unrecorded source pair rather than guessing, so an operation parked without
  # one is unanchored — and the REST twin records it.
  describe "the parked operation's source" do
    it "anchors a gated update to the pool row" do
      update!(target_size: 4)

      expect(latest_deferred.source_type).to eq("System::InstancePool")
      expect(latest_deferred.source_id).to eq(pool.id)
    end
  end

  # THE KEY SHAPE IS THE GATE'S PREMISE. Ai::Tools::McpPlatformToolRegistrar
  # hands every real MCP call `params.with_indifferent_access`, and this tool
  # already carries a warning about exactly this hazard at
  # #authorization_error: "a symbol-only read here would let a string-keyed
  # caller be GATED while its permission check fell back". The mirror image is
  # what these pin — a payload the gate reads as EMPTY is applied inline, so a
  # symbol-only read of the attributes would leave the production caller
  # ungated while every symbol-keyed spec above stayed green.
  describe "the shape MCP actually calls with" do
    def indifferent_update!(attrs)
      tool.execute(params: { action: "system_update_instance_pool", id: pool.id }
                             .merge(attrs).with_indifferent_access)
    end

    it "gates a ceiling raise arriving with indifferent-access params" do
      expect { indifferent_update!(target_size: 4) }
        .to change(::Ai::DeferredOperation, :count).by(1)

      expect(pool.reload.target_size).to eq(2)
      expect(latest_deferred.action_category).to eq("system.instance_pool_ceiling_raise")
    end

    it "gates an archive arriving with indifferent-access params" do
      expect { indifferent_update!(status: "archived") }
        .to change(::Ai::DeferredOperation, :count).by(1)

      expect(pool.reload.status).to eq("active")
      expect(latest_deferred.action_category).to eq("system.instance_pool_archive")
    end

    it "still applies an ungated field inline, so the read is not just refusing" do
      expect { indifferent_update!(description: "after") }
        .not_to change(::Ai::DeferredOperation, :count)

      expect(pool.reload.description).to eq("after")
    end

    # The same read normalizes the cross-AZ list. With the payload reached
    # through symbol keys only, `attrs.key?(:preferred_regions)` was false for
    # every real MCP caller and the blank-clearing never ran.
    it "normalizes preferred_regions for an indifferent-access payload" do
      indifferent_update!(preferred_regions: [ "", nil ])

      expect(pool.reload.preferred_regions).to eq([])
    end
  end

  describe "what stays inline, by operator direction" do
    it "applies a DECREASE with no approval" do
      expect { update!(target_size: 1) }.not_to change(::Ai::DeferredOperation, :count)

      expect(pool.reload.target_size).to eq(1)
    end

    it "applies description, min_size and metadata with no approval" do
      expect { update!(description: "after", min_size: 1) }
        .not_to change(::Ai::DeferredOperation, :count)

      expect(pool.reload.description).to eq("after")
      expect(pool.min_size).to eq(1)
    end

    it "applies status paused with no approval" do
      expect { update!(status: "paused") }.not_to change(::Ai::DeferredOperation, :count)

      expect(pool.reload.status).to eq("paused")
    end

    it "re-sending the standing ceiling is not a raise" do
      expect { update!(target_size: 2, max_size: 5) }
        .not_to change(::Ai::DeferredOperation, :count)
    end
  end

  describe "creating a pool over MCP" do
    it "parks the create instead of minting a pool with an unapproved ceiling" do
      expect { create!(target_size: 7) }
        .to change(::Ai::DeferredOperation, :count).by(1)
      expect(::System::InstancePool.where(account_id: account.id, name: "minted-over-mcp"))
        .to be_empty, "the pool was minted despite the gate"

      expect(latest_deferred.action_category).to eq("system.instance_pool_create")
      expect(latest_deferred.executor_class).to eq("Ai::Executors::DeferredToolCall")
    end

    it "really creates the pool when the parked operation is approved" do
      create!(target_size: 7)

      latest_deferred.execute_now!

      created = ::System::InstancePool.find_by(account_id: account.id, name: "minted-over-mcp")
      expect(created).to be_present
      expect(created.target_size).to eq(7)
      expect(created.node_template_id).to eq(template.id)
    end

    # The REST twin validates the candidate BEFORE the gate (IMP-785d60f5ec3e)
    # so an unsaveable payload keeps its field-level error rather than parking
    # an approval that could only ever fail. Gating this verb must not lose
    # that: a bad template id used to come back as an error envelope from
    # #call's own rescue, and a gated action never reaches #call.
    it "refuses an unresolvable template without parking anything" do
      expect { create!(template_id: ::SecureRandom.uuid) }
        .not_to change(::Ai::DeferredOperation, :count)
    end

    it "refuses an invalid payload without parking anything" do
      expect { create!(name: "") }.not_to change(::Ai::DeferredOperation, :count)
    end
  end

  describe "a policy row for the declared category actually binds this tool" do
    before do
      ::Ai::InterventionPolicy.create!(
        account: account,
        action_category: "system.instance_pool_ceiling_raise",
        scope: "global", ai_agent_id: nil, user_id: nil,
        policy: "block", priority: 5, is_active: true,
        conditions: {}, preferred_channels: %w[notification]
      )
    end

    it "blocks the raise, writes nothing, and reports the refusal" do
      response = update!(target_size: 4)

      expect(pool.reload.target_size).to eq(2)
      expect(response[:success]).to be(false)
      expect(response[:error]).to be_present
    end
  end

  describe "the auto_approve tier" do
    before do
      allow_any_instance_of(::Ai::InterventionPolicyService).to receive(:resolve).and_return(
        { policy: "auto_approve", channels: [], conditions: {}, record: nil }
      )
    end

    # On :proceed the EXECUTOR is the actor — Ai::AutonomyGate calls
    # DeferredOperation#execute_now! itself — so the response must SERIALIZE
    # what it did rather than repeat the write.
    it "applies the raise once and answers exactly as the ungated arm did" do
      response = update!(target_size: 4)

      expect(pool.reload.target_size).to eq(4)
      expect(response[:success]).to be(true)
      expect(response[:data][:pool]).to be_present
      expect(response[:data][:pool][:target_size]).to eq(4)
    end

    it "creates the pool once and answers with it" do
      response = create!(target_size: 7)

      expect(::System::InstancePool.where(account_id: account.id, name: "minted-over-mcp").count)
        .to eq(1)
      expect(response[:success]).to be(true)
      expect(response[:data][:pool]).to be_present
    end
  end

  describe "authorization is not lost to the gate" do
    let(:user) { create(:user, account: account, permissions: []) }

    # A gated action never reaches #call, where this tool's per-action
    # permission check lives. Without BaseTool#authorization_error the gate
    # would ESCALATE privilege: an unauthorized caller could park (and have
    # approved) a ceiling raise it was never allowed to request.
    it "refuses an unauthorized caller and parks nothing" do
      response = update!(target_size: 4)

      expect(response[:success]).to be(false)
      expect(response[:error]).to include("permission denied")
      expect(::Ai::DeferredOperation.where(account_id: account.id)).to be_empty
      expect(pool.reload.target_size).to eq(2)
    end
  end

  describe "a cross-account target parks nothing" do
    let(:other_pool) do
      other = create(:account)
      ::System::InstancePool.create!(
        account: other, name: "other-pool",
        node_template: create(:system_node_template, account: other),
        target_size: 1, min_size: 0, max_size: 2, lifecycle_class: "ephemeral"
      )
    end

    it "returns an error envelope without creating a deferred operation" do
      response = tool.execute(params: { action: "system_update_instance_pool",
                                        id: other_pool.id, target_size: 4 })

      expect(response[:success]).to be(false)
      expect(::Ai::DeferredOperation.where(account_id: account.id)).to be_empty
      expect(other_pool.reload.target_size).to eq(1)
    end
  end
end
