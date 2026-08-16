# frozen_string_literal: true

require "rails_helper"

# IMP-35bc8eda71ad — an approval card must say WHAT a parked operation changes,
# not only WHICH row it changes.
#
# The anchor: `system_sdwan_update_peer_lan_subnets` and
# `system_sdwan_set_peer_tags` share one executor (Sdwan::Executors::UpdatePeer),
# one #summarize, and one gate `description:` — and no update executor overrode
# #impact with field information, so Base#impact returned nil and the card had no
# Impact line at all. A change that rewrites AllowedIPs for every peer routing to
# this one (lan_subnets) and a cosmetic tag relabel therefore rendered a
# BYTE-IDENTICAL card, and an approver rubber-stamping the trivial-looking one
# reroutes LAN traffic. Pre-existing on the REST twin; the MCP update-verb parity
# work (IMP-c9798d9d5671) doubled the conflated surface.
#
# KEYS ONLY, never values — a redaction property, not a style choice. See
# "keys only, never values" below and Base#changed_field_impact.
RSpec.describe "approval-card changed-field naming" do
  let(:account) { create(:account) }
  let!(:network)  { create(:sdwan_network, account: account, name: "wan-core") }
  let!(:instance) { create(:system_node_instance, account: account, name: "edge-01") }
  let!(:peer) do
    create(:sdwan_peer, account: account, network: network, node_instance: instance)
  end

  def operation_for(executor_class, action_category, params)
    ::Ai::DeferredOperation.create!(
      account: account,
      action_category: action_category,
      executor_class: executor_class,
      params: params
    )
  end

  # The HUMAN surface, not merely the payload. Ai::DeferredOperationApprovalContent
  # composes the notification an approver actually reads, and appends the impact
  # only `if impact.present?` — so a nil impact is not a blank line, it is a card
  # with one fewer line. That is precisely how the two arms became identical, and
  # asserting on the rendered card is what pins the operator-visible difference
  # rather than an internal hash key.
  def card_for(operation)
    request = create(:ai_approval_request, account: account,
                                           source_type: "Ai::DeferredOperation",
                                           source_id: operation.id)
    ::Ai::DeferredOperationApprovalContent.message(request, request.step_statuses.first)
  end

  # ---------------------------------------------------------------- the anchor

  describe "the two conflated peer arms" do
    let(:mesh_rewrite) do
      operation_for("Sdwan::Executors::UpdatePeer", "sdwan.peer_update",
                    { peer_id: peer.id, attributes: { lan_subnets: [ "10.9.0.0/24" ] } })
    end
    let(:cosmetic_relabel) do
      operation_for("Sdwan::Executors::UpdatePeer", "sdwan.peer_update",
                    { peer_id: peer.id, attributes: { tags: [ "prod" ] } })
    end

    it "renders different cards for a mesh-rewriting update and a cosmetic relabel" do
      expect(card_for(mesh_rewrite)).not_to eq(card_for(cosmetic_relabel))
    end

    it "names lan_subnets on the routing change" do
      preview = mesh_rewrite.preview

      expect(preview[:error]).to be_nil
      expect(preview[:impact]).to include("lan_subnets")
      expect(preview[:impact]).not_to include("tags")
    end

    it "names tags on the relabel" do
      preview = cosmetic_relabel.preview

      expect(preview[:error]).to be_nil
      expect(preview[:impact]).to include("tags")
      expect(preview[:impact]).not_to include("lan_subnets")
    end

    # CONTROL. IMP-ee57d0fbe859's invariant — the update and delete cards for one
    # peer name it identically — must not be traded away to buy this one. The
    # SUMMARY stays the same sentence on both arms; only the impact line moves.
    it "still names the peer identically on both arms" do
      expect(mesh_rewrite.preview[:summary]).to eq(cosmetic_relabel.preview[:summary])
      expect(mesh_rewrite.preview[:summary]).to eq("Update SDWAN peer #{peer.operator_label}")
    end
  end

  # -------------------------------------------------- keys only, never values

  # Ai::AutonomyApprovalActions#serialize_deferred_operation emits
  # `params: Ai::SensitiveParams.filter(op.params)` and `preview: op.preview`
  # side by side on the approvals detail endpoint, and only the FIRST is
  # filtered. A card that rendered attribute VALUES would therefore serve, one
  # key over, the plaintext the filter had just masked — to an audience defined
  # by the approval permissions rather than by whatever permission authorised the
  # original call. Rendering keys makes that leak impossible by construction.
  describe "keys only, never values" do
    let(:secret_bearing) do
      operation_for(
        "System::Executors::Runtime::BootstrapK3sCluster",
        "system.runtime_k8s_cluster_bootstrap",
        { instance_id: instance.id,
          attributes: { server_token: "K10-plaintext-server-token", k8s_version: "v1.31.2" } }
      )
    end

    it "names the secret-bearing field without rendering its value" do
      preview = secret_bearing.preview

      expect(preview[:error]).to be_nil
      expect(preview[:impact]).to include("server_token")
      expect(preview[:impact]).not_to include("K10-plaintext-server-token")
    end

    # POSITIVE CONTROL for the refusal above: the value really is parked, so
    # `not_to include` is refusing something present rather than passing on an
    # empty fixture — and the neighbouring serializer field masks it, which is
    # the standard the preview must not undercut.
    it "refuses a value that is present in params and masked by the sibling field" do
      expect(secret_bearing.params.dig("attributes", "server_token"))
        .to eq("K10-plaintext-server-token")
      expect(::Ai::SensitiveParams.filter(secret_bearing.params).dig("attributes", "server_token"))
        .to eq(::Ai::SensitiveParams::MASK)
    end
  end

  # ------------------------------------------------------- the existing prose

  describe "an executor that already writes its own impact prose" do
    it "keeps the prose AND gains the field names" do
      operation = operation_for(
        "Sdwan::Executors::CreatePeer", "sdwan.peer_create",
        { network_id: network.id,
          attributes: { node_instance_id: instance.id, endpoint_port: 51_820 } }
      )
      preview = operation.preview

      expect(preview[:error]).to be_nil
      expect(preview[:impact]).to include("Onboards a new node into the overlay network")
      expect(preview[:impact]).to include("node_instance_id")
      expect(preview[:impact]).to include("endpoint_port")
    end

    # CONTROL — an operation carrying no attributes at all must render its
    # executor's impact byte-for-byte as before. The field phrase is additive,
    # so an empty payload adds nothing rather than an empty "Sets fields:".
    it "leaves an attribute-less operation's impact exactly as its executor wrote it" do
      operation = operation_for("Sdwan::Executors::DeleteNetwork", "sdwan.network_delete",
                                { network_id: network.id })

      expect(operation.preview[:impact])
        .to eq("Cascade-destroys all peers, firewall rules, VIPs, and route policies in this network")
    end
  end

  # ------------------------------------------------------------- what NOT to say

  # `attrs` strips TENANCY_ATTRIBUTE_KEYS before any write, so naming them would
  # tell the approver the operation changes an account it will provably not
  # change. The card is composed from the same hash the executor will write.
  it "does not name a tenancy key the executor will refuse to write" do
    operation = operation_for(
      "Sdwan::Executors::UpdatePeer", "sdwan.peer_update",
      { peer_id: peer.id, attributes: { account_id: SecureRandom.uuid, tags: [ "prod" ] } }
    )

    expect(operation.preview[:impact]).to include("tags")
    expect(operation.preview[:impact]).not_to include("account_id")
  end

  # The field phrase is composed on EVERY preview now, so a malformed
  # params[:attributes] became a new way to blank the WHOLE card:
  # Ai::DeferredOperation#preview rescues StandardError into
  # `{ summary: action_category }`, losing the row's name along with the impact.
  # Name nothing rather than raise.
  it "still names the row when params[:attributes] is not a hash" do
    operation = operation_for("Sdwan::Executors::UpdatePeer", "sdwan.peer_update",
                              { peer_id: peer.id, attributes: "lan_subnets" })
    preview = operation.preview

    expect(preview[:error]).to be_nil
    expect(preview[:summary]).to eq("Update SDWAN peer #{peer.operator_label}")
    expect(preview[:impact]).to be_nil
  end

  # A card is a HUMAN gate. An unbounded field list does not inform an approver,
  # it buries the "Requested by:" line under a wall of identifiers — so the
  # payload's own width cannot be what decides how much of the card is readable.
  # base.rb's standing threat model for params (caller-influenced, stored
  # verbatim, replayed with no re-validation) is why this is bounded here rather
  # than trusted to each surface's permit list.
  it "bounds the list so a wide payload cannot bury the rest of the card" do
    wide = (1..30).to_h { |i| [ "field_#{format('%02d', i)}", i ] }
    operation = operation_for("Sdwan::Executors::UpdatePeer", "sdwan.peer_update",
                              { peer_id: peer.id, attributes: wide })
    impact = operation.preview[:impact]

    expect(impact).to include("field_01")
    expect(impact).not_to include("field_30")
    expect(impact).to include("+18 more")
  end

  # ------------------------------------------------------ composition mechanics

  # How the two halves join is a property of Base, so it is driven over
  # CONSTRUCTED executors: pinning it on whichever real executor happens to
  # write blank prose today would be pinning a coincidence. Anonymous on
  # purpose — a stub_const'd subclass keeps its `.name` after teardown and
  # would leak into the sweep below.
  describe "how the prose and the field list compose" do
    def executor_with_impact(prose)
      Class.new(::System::Executors::Base) do
        define_method(:summarize) { "Constructed executor" }
        define_method(:impact) { prose }
      end
    end

    it "renders the prose, then the fields, separated once" do
      payload = executor_with_impact("Reroutes the mesh")
                .preview({ attributes: { lan_subnets: [ "10.0.0.0/8" ] } })

      expect(payload[:impact]).to eq("Reroutes the mesh — Sets fields: lan_subnets")
    end

    # A blank override must not leave a dangling separator. `impact` is a
    # subclass hook returning caller-free prose, so "" is a plausible way to
    # write "nothing to add" — and " — Sets fields: lan_subnets" reads to the
    # approver as a truncated sentence.
    it "leaves no dangling separator when the prose is blank" do
      payload = executor_with_impact("").preview({ attributes: { lan_subnets: [ "10.0.0.0/8" ] } })

      expect(payload[:impact]).to eq("Sets fields: lan_subnets")
    end

    it "renders no impact at all when there is neither prose nor an attribute" do
      expect(executor_with_impact("").preview({ peer_id: peer.id })[:impact]).to be_nil
    end
  end

  # Two requests naming the same fields must render the same line whatever order
  # the surface built its hash in: an approver comparing two pending cards is
  # reading for a DIFFERENCE, and an incidental key order would manufacture one.
  #
  # Driven through the executor rather than a persisted operation on purpose —
  # `params` is JSONB and Postgres normalises key order on the way back out, so
  # the round trip would hide an unsorted list behind its own ordering.
  it "renders the same line regardless of the order the surface built the hash" do
    forward = ::Sdwan::Executors::UpdatePeer.preview(
      { peer_id: peer.id, attributes: { tags: [ "a" ], lan_subnets: [ "10.0.0.0/8" ] } }
    )
    reverse = ::Sdwan::Executors::UpdatePeer.preview(
      { peer_id: peer.id, attributes: { lan_subnets: [ "10.0.0.0/8" ], tags: [ "a" ] } }
    )

    expect(forward[:impact]).to eq("Sets fields: lan_subnets, tags")
    expect(reverse[:impact]).to eq(forward[:impact])
  end

  # `attrs` symbolizes what it can, and a key that cannot be symbolized survives
  # as its original type — so sorting the keys unconverted raises ArgumentError
  # comparing Integer with Symbol, and Ai::DeferredOperation#preview's rescue
  # would blank the card down to its bare action_category. Same class of defect
  # as the non-Hash guard above: a malformed payload may cost the field list, it
  # may never cost the row's name.
  it "still names the row when a key is not a string" do
    payload = ::Sdwan::Executors::UpdatePeer.preview(
      { peer_id: peer.id, attributes: { 1 => "x", "tags" => [ "a" ] } }
    )

    expect(payload[:summary]).to eq("Update SDWAN peer #{peer.id}")
    expect(payload[:impact]).to include("tags")
  end

  # -------------------------------------------------------- THE ADDITION CASE

  # Everything above is behavioural on the executors that exist TODAY. What makes
  # the fix hold for one added TOMORROW is that the composition lives on
  # Base#preview_payload rather than on each executor: a new update executor
  # inherits the field naming without doing anything, and — unlike a per-executor
  # override — cannot forget it.
  #
  # So the addition-shaped regression is not "a new executor omits the field
  # list", it is "a new executor OPTS OUT of the seam". That is what this sweep
  # checks, and it checks it BEHAVIOURALLY over a DERIVED list: every live
  # subclass is driven through preview with a marker attribute, so an added
  # subclass is in scope the moment it is defined. No count is asserted anywhere
  # — a count floor is exactly what an addition walks past.
  describe "the seam a new executor inherits" do
    before(:all) { Rails.application.eager_load! }

    # `Class#subclasses` is LIVE, so executors constructed by a spec — this
    # file's anonymous ones, another file's stub_const'd ones (which keep their
    # `.name` after teardown) — remain reachable in the same process and would
    # make the sweep order-dependent. A real executor is a constant that still
    # resolves back to itself; nothing built by a spec does.
    def live_executors
      ::System::Executors::Base.descendants.select do |klass|
        klass.name.present? && klass.name.safe_constantize.equal?(klass)
      end
    end

    it "has executors to sweep" do
      # Guards the sweep below against a load failure quietly turning it into a
      # vacuous pass over an empty list.
      expect(live_executors.size).to be > 10
    end

    it "names a marker attribute on the card of EVERY executor, without exception" do
      offenders = live_executors.filter_map do |klass|
        impact =
          begin
            klass.preview({ attributes: { spec_marker_attribute: "x" } })[:impact]
          rescue StandardError => e
            "raised #{e.class}"
          end

        next if impact.to_s.include?("spec_marker_attribute")

        "#{klass.name} rendered #{impact.inspect}"
      end

      expect(offenders).to be_empty, <<~MSG
        An executor's approval card does not name the attributes it will write.
        The field list is composed once, on System::Executors::Base#preview_payload,
        so this can only happen when a subclass overrides the composition itself
        (#preview_payload / #full_impact / #changed_field_impact) rather than the
        #impact hook it is meant to override.

        #{offenders.join("\n")}
      MSG
    end
  end
end
