# frozen_string_literal: true

require "rails_helper"

# The tenancy seam on System::Executors::Base.
#
# Executors are INTENTIONALLY unscoped — ownership is enforced upstream by the
# controllers' set_* guards, documented at trust_boundary_executors_spec.rb:9-11
# and revoke_user_device.rb:56-59 — and a blanket `where(account_id:)` would
# break the callers that reach an executor with a literal
# `deferred_operation: nil` (Base.preview, Ai::Tools::SystemFleetTool,
# ServiceDiscoveryComposerExecutor), silently turning every find into
# `where(account_id: nil)`: fail-open dressed as fail-closed. The duck-typed
# Struct contexts are a different shape — they DO carry an account, and are
# anchored on it like any operation (pinned below).
#
# So the invariant is defended at two anchors instead. Ai::DeferredOperation
# asserts the source_type/source_id pair the gate recorded; this seam covers the
# other anchor — the records an executor resolves FOR ITSELF during perform,
# from caller-supplied params that the gate stored verbatim and replays with no
# re-validation.
RSpec.describe System::Executors::Base do
  let(:account) { create(:account) }
  let(:foreign_account) { create(:account) }

  let(:klass) do
    Class.new(described_class) do
      def perform = attrs
    end
  end

  def executor(params, deferred_operation: nil)
    klass.new(params, deferred_operation: deferred_operation)
  end

  def operation_for(owner)
    ::Ai::DeferredOperation.create!(
      account: owner, action_category: "test.act",
      executor_class: "System::Executors::Base", params: {}
    )
  end

  # account_id is mass-assignable on every SDWAN model, `attrs` fed
  # params[:attributes] straight to create!/update!, and the gate stores those
  # attributes verbatim — so a caller could name their own account on the
  # request and move a record into it at execution time.
  describe "#attrs" do
    it "strips the tenancy-bearing keys a caller must never mass-assign" do
      coerced = executor({ attributes: {
        "name" => "edge", "account_id" => foreign_account.id, "account" => foreign_account
      } }).send(:attrs)

      expect(coerced).to eq(name: "edge"),
                         "a caller-supplied account is mass-assignable into create!/update!"
    end

    it "still coerces everything else to a symbol-keyed Hash" do
      expect(executor({ attributes: { "listen_port" => 51_820 } }).send(:attrs))
        .to eq(listen_port: 51_820)
    end
  end

  # IMP-4a5094b22df0 replaced `#requested_account_id` — which handed a label the
  # account_id the CALLER put in params[:attributes], the one hash `attrs` above
  # strips those very keys out of. An id a caller supplies cannot be trusted to
  # SELECT an owner any more than to assign one. The operation now carries the
  # anchor, and this is the single seam every card label resolves through.
  describe "#scoped_label_record" do
    let!(:network) { create(:sdwan_network, account: account, name: "ours") }
    let!(:foreign_network) { create(:sdwan_network, account: foreign_account, name: "theirs") }

    it "returns a row the operation's account owns" do
      exec = executor({}, deferred_operation: operation_for(account))

      expect(exec.send(:scoped_label_record, ::Sdwan::Network, network.id)).to eq(network)
    end

    it "returns nil for a row belonging to another account, rather than raising" do
      exec = executor({}, deferred_operation: operation_for(account))

      expect(exec.send(:scoped_label_record, ::Sdwan::Network, foreign_network.id)).to be_nil
    end

    # The difference from #resolve_scoped that matters most: that one passes
    # through unanchored (the write was authorised upstream), this one refuses.
    # A disclosure has no upstream authorisation to inherit.
    it "returns nil when there is no operation to anchor on" do
      expect(executor({}).send(:scoped_label_record, ::Sdwan::Network, network.id)).to be_nil
    end

    it "returns nil for a blank id" do
      exec = executor({}, deferred_operation: operation_for(account))

      expect(exec.send(:scoped_label_record, ::Sdwan::Network, nil)).to be_nil
    end

    # A model with no account of its own cannot be anchored; asking PostgreSQL
    # for the column would raise inside a card render.
    it "returns nil for a model that carries no account_id" do
      exec = executor({}, deferred_operation: operation_for(account))

      expect(exec.send(:scoped_label_record, ::Account, account.id)).to be_nil
    end

    it "no longer exposes the caller-supplied account id" do
      exec = executor({ attributes: { account_id: account.id, name: "edge" } })

      expect(exec.respond_to?(:requested_account_id, true)).to be(false)
      expect(exec.send(:attrs)).not_to have_key(:account_id)
    end
  end

  describe "#resolve_scoped" do
    let(:network) { create(:sdwan_network, account: account) }

    it "returns the record when the operation's account owns it" do
      exec = executor({}, deferred_operation: operation_for(account))

      expect(exec.send(:resolve_scoped, ::Sdwan::Network, network.id)).to eq(network)
    end

    it "raises rather than resolving a record belonging to another account" do
      exec = executor({}, deferred_operation: operation_for(foreign_account))

      expect { exec.send(:resolve_scoped, ::Sdwan::Network, network.id) }
        .to raise_error(::Ai::DeferredOperation::CrossAccountError, /#{network.id}/)
    end

    # Base.preview builds with a literal nil, as do SystemFleetTool and the
    # service-discovery composer. Scoping on a nil account would be
    # `where(account_id: nil)` — worse than not scoping at all.
    it "passes through unscoped when there is no deferred operation to anchor on" do
      expect(executor({}).send(:resolve_scoped, ::Sdwan::Network, network.id)).to eq(network)
    end

    it "anchors on a duck-typed composition context that carries an account" do
      context = Struct.new(:account).new(foreign_account)

      expect { executor({}, deferred_operation: context).send(:resolve_scoped, ::Sdwan::Network, network.id) }
        .to raise_error(::Ai::DeferredOperation::CrossAccountError)
    end

    # IMP-dae0de4e562b: an id that exists nowhere and an id that exists in
    # SOMEONE ELSE'S account must be ONE observable. This example previously
    # pinned the opposite — `raise_error(ActiveRecord::RecordNotFound)` for the
    # missing id, while the foreign id above raises CrossAccountError — and
    # that PAIR was an existence oracle: a caller who could not learn WHOSE a
    # row was could still learn THAT it existed, by telling the two refusals
    # apart. The old pin is why IMP-973670faeba9 converted inside ExecuteTask
    # instead of here; unifying at the seam supersedes that local conversion,
    # so the pin is retargeted rather than kept.
    #
    # Anchored refusals are therefore CrossAccountError on BOTH arms. The class
    # rather than RecordNotFound because it is the shape every caller of this
    # seam already rescues (ExecuteTask#operable_display, the SDWAN executor
    # specs), and because Ai::AutonomyGate rescues StandardError and renders
    # e.message regardless of class — so widening the class would have changed
    # nothing a caller sees while breaking every handler that names it.
    it "refuses an id that exists nowhere as a cross-account refusal, not a RecordNotFound" do
      exec = executor({}, deferred_operation: operation_for(account))

      expect { exec.send(:resolve_scoped, ::Sdwan::Network, SecureRandom.uuid) }
        .to raise_error(::Ai::DeferredOperation::CrossAccountError)
    end

    # The class alone is not the oracle. Ai::AutonomyGate rescues StandardError
    # and returns `error: e.message` to the caller, so the MESSAGE is the
    # observable that actually reaches a prober; a unified class carrying two
    # different messages is the same oracle with an extra step. The two must be
    # identical up to the id the caller themselves supplied.
    it "refuses an id that exists nowhere exactly as it refuses a foreign one" do
      exec = executor({}, deferred_operation: operation_for(foreign_account))
      missing_id = SecureRandom.uuid

      missing = refusal_from(exec, missing_id)
      foreign = refusal_from(exec, network.id)

      expect(missing.class).to eq(foreign.class),
                               "a missing id raises #{missing.class} and a foreign id #{foreign.class} — " \
                               "a caller can tell them apart"
      expect(missing.message.sub(missing_id, "<id>"))
        .to eq(foreign.message.sub(network.id, "<id>")),
            "the two refusals differ by more than the caller's own id: " \
            "#{missing.message.inspect} vs #{foreign.message.inspect}"
    end

    # Neither refusal may name the OWNER either — that is the disclosure the
    # raise/log split in #resolve_scoped exists for, and unifying the two arms
    # must not quietly reintroduce it.
    it "names neither the owning account nor anything the caller did not supply" do
      exec = executor({}, deferred_operation: operation_for(foreign_account))

      expect(refusal_from(exec, network.id).message).not_to include(account.id),
                                                            "the refusal echoes the victim's account id back to the caller"
    end

    # With no anchor there is only ONE possible refusal — the row either exists
    # or it does not — so there is no pair to tell apart and nothing to unify.
    # Left as the bare RecordNotFound `find` raises, matching the unscoped
    # passthrough directly above.
    it "leaves an unanchored miss as the RecordNotFound find raises" do
      expect { executor({}).send(:resolve_scoped, ::Sdwan::Network, SecureRandom.uuid) }
        .to raise_error(ActiveRecord::RecordNotFound)
    end
  end

  # Returns the exception rather than asserting on it inline: the two refusals
  # have to be COMPARED, which `raise_error` cannot do.
  def refusal_from(exec, id)
    exec.send(:resolve_scoped, ::Sdwan::Network, id)
    nil
  rescue StandardError => e
    e
  end
end
