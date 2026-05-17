# frozen_string_literal: true

require "rails_helper"

RSpec.describe System::ClusterMember::PgReplicaSetupService, type: :service do
  let(:account) { create(:account) }
  let(:peer) do
    create(:system_federation_peer, :platform,
           account: account,
           spawn_mode: "cluster_member",
           spawn_role: "parent",
           status: "proposed",
           remote_instance_url: "https://child.example.com")
  end

  # SQL executor recorder. The service calls `sql_executor.call(sql, binds)`.
  # We record invocations and return an empty result by default.
  let(:sql_calls) { [] }
  let(:sql_executor) do
    ->(sql, binds = []) { sql_calls << [ sql, binds ]; [] }
  end

  # Vault stub captures the store_credential call so we can verify the
  # right payload was stashed (replication username + password + slot
  # name + primary endpoint).
  let(:vault_calls) { [] }
  let(:vault) do
    instance_double(::Security::VaultCredentialProvider).tap do |stub|
      allow(stub).to receive(:store_credential) do |**args|
        vault_calls << args
        true
      end
    end
  end

  describe "#run!" do
    context "happy path — fresh setup" do
      it "creates the replication slot via SQL" do
        described_class.new(peer: peer, sql_executor: sql_executor, vault: vault).run!

        slot_sql = sql_calls.find { |sql, _| sql.include?("pg_create_physical_replication_slot") }
        expect(slot_sql).not_to be_nil
        sql, binds = slot_sql
        expect(sql).to match(/SELECT pg_create_physical_replication_slot/)
        expect(binds.first).to match(/\Apowernode_repl_[a-f0-9]+\z/)
      end

      it "creates the replication role via SQL" do
        described_class.new(peer: peer, sql_executor: sql_executor, vault: vault).run!

        role_sql = sql_calls.find { |sql, _| sql.include?("CREATE ROLE") }
        expect(role_sql).not_to be_nil
        sql, = role_sql
        expect(sql).to match(/CREATE ROLE powernode_repl_[a-f0-9]+/)
        expect(sql).to include("LOGIN REPLICATION PASSWORD")
        # password is single-quoted; verify the quoting layer is in place
        expect(sql).to match(/PASSWORD '[^']+'/)
      end

      it "stores the credential in Vault keyed by peer.id" do
        described_class.new(peer: peer, sql_executor: sql_executor, vault: vault).run!

        expect(vault_calls.size).to eq(1)
        call = vault_calls.first
        expect(call[:credential_type]).to eq(:cluster_member_pg_replica)
        expect(call[:credential_id]).to eq(peer.id)
        expect(call[:record]).to eq(peer)
        data = call[:data]
        expect(data[:username]).to match(/\Apowernode_repl_[a-f0-9]+\z/)
        expect(data[:password]).to be_present
        expect(data[:slot_name]).to match(/\Apowernode_repl_[a-f0-9]+\z/)
        expect(data[:primary_host]).to be_present
        expect(data[:primary_port]).to be_a(Integer)
      end

      it "stamps cluster_pg metadata as ready on the peer" do
        result = described_class.new(peer: peer, sql_executor: sql_executor, vault: vault).run!

        expect(result.ok?).to be true
        expect(result.already_prepared).to be false

        peer.reload
        cluster_pg = peer.metadata["cluster_pg"]
        expect(cluster_pg).to be_a(Hash)
        expect(cluster_pg["state"]).to eq("ready")
        expect(cluster_pg["slot_name"]).to eq(result.slot_name)
        expect(cluster_pg["credential_id"]).to eq(peer.id)
        expect(cluster_pg["prepared_at"]).to be_present
      end

      it "does NOT leak the password into peer.metadata" do
        described_class.new(peer: peer, sql_executor: sql_executor, vault: vault).run!
        peer.reload
        # Password is in Vault only; nowhere in plaintext metadata
        expect(peer.metadata.to_s).not_to include(vault_calls.first[:data][:password])
      end
    end

    context "idempotency — peer already prepared" do
      before do
        peer.update!(metadata: peer.metadata.merge(
          "cluster_pg" => {
            "state" => "ready",
            "slot_name" => "powernode_repl_existing",
            "credential_id" => peer.id
          }
        ))
      end

      it "skips SQL execution + Vault writes" do
        result = described_class.new(peer: peer, sql_executor: sql_executor, vault: vault).run!

        expect(result.ok?).to be true
        expect(result.already_prepared).to be true
        expect(result.slot_name).to eq("powernode_repl_existing")
        expect(sql_calls).to be_empty
        expect(vault_calls).to be_empty
      end
    end

    context "guard clauses" do
      it "rejects when spawn_mode is not cluster_member" do
        peer.update!(spawn_mode: "managed_child")
        result = described_class.new(peer: peer, sql_executor: sql_executor, vault: vault).run!

        expect(result.ok?).to be false
        expect(result.error).to match(/spawn_mode must be cluster_member/)
        expect(sql_calls).to be_empty
      end

      it "rejects when spawn_role is not parent" do
        peer.update!(spawn_role: "child")
        result = described_class.new(peer: peer, sql_executor: sql_executor, vault: vault).run!

        expect(result.ok?).to be false
        expect(result.error).to match(/spawn_role must be parent/)
        expect(sql_calls).to be_empty
      end
    end

    context "PG already-exists handling" do
      let(:sql_executor) do
        ->(sql, _binds = []) do
          sql_calls << [ sql, _binds ]
          if sql.include?("pg_create_physical_replication_slot")
            raise ActiveRecord::StatementInvalid.new("ERROR: replication slot \"foo\" already exists")
          end
          if sql.include?("CREATE ROLE")
            raise ActiveRecord::StatementInvalid.new("ERROR: role \"foo\" already exists")
          end
          []
        end
      end

      it "treats 'already exists' as benign and proceeds" do
        result = described_class.new(peer: peer, sql_executor: sql_executor, vault: vault).run!

        expect(result.ok?).to be true
        expect(vault_calls.size).to eq(1)
        peer.reload
        expect(peer.metadata.dig("cluster_pg", "state")).to eq("ready")
      end
    end

    context "PG hard error" do
      let(:sql_executor) do
        ->(_sql, _binds = []) do
          raise ActiveRecord::StatementInvalid.new("ERROR: permission denied to create role")
        end
      end

      it "returns ok?=false with the SQL error surfaced" do
        result = described_class.new(peer: peer, sql_executor: sql_executor, vault: vault).run!

        expect(result.ok?).to be false
        expect(result.error).to match(/replication slot create failed|permission denied/)
        # No Vault write on hard error
        expect(vault_calls).to be_empty
        peer.reload
        # No cluster_pg state stamped
        expect(peer.metadata["cluster_pg"]).to be_nil.or(eq({}))
      end
    end
  end
end
