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

  # Preview/summarize run through Base.preview, which hardcodes
  # deferred_operation: nil — so the create attributes are the only account a
  # label can be scoped by, and stripping account_id out of `attrs` must not
  # take that away (see Sdwan::Executors::CreatePeer#summarize).
  describe "#requested_account_id" do
    it "exposes the account the caller named, for label scoping only" do
      exec = executor({ attributes: { account_id: account.id, name: "edge" } })

      expect(exec.send(:requested_account_id)).to eq(account.id)
      expect(exec.send(:attrs)).not_to have_key(:account_id)
    end

    it "is nil when the request named none" do
      expect(executor({}).send(:requested_account_id)).to be_nil
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

    it "still raises RecordNotFound for an id that does not exist" do
      exec = executor({}, deferred_operation: operation_for(account))

      expect { exec.send(:resolve_scoped, ::Sdwan::Network, SecureRandom.uuid) }
        .to raise_error(ActiveRecord::RecordNotFound)
    end
  end
end
