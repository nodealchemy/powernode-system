# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Api::V1::System::WorkerApi::ClusterMemberPgReplica", type: :request do
  let(:worker) { create(:worker) }
  let(:token)  { ::Security::JwtService.encode({ sub: worker.id, type: "worker" }) }
  let(:headers) { { "X-Worker-Token" => token, "Content-Type" => "application/json" } }

  let(:account) { create(:account) }
  let(:peer) do
    create(:system_federation_peer, :platform,
           account: account,
           spawn_mode: "cluster_member",
           spawn_role: "parent",
           status: "proposed",
           remote_instance_url: "https://child.example.com")
  end
  let(:path) { "/api/v1/system/worker_api/cluster_member/pg_replica_setup" }

  describe "POST /cluster_member/pg_replica_setup" do
    context "happy path" do
      let(:result) do
        ::System::ClusterMember::PgReplicaSetupService::Result.new(
          ok?: true,
          slot_name: "powernode_repl_abc123",
          credential_id: peer.id,
          already_prepared: false
        )
      end

      before do
        allow_any_instance_of(::System::ClusterMember::PgReplicaSetupService)
          .to receive(:run!).and_return(result)
      end

      it "invokes the service + returns slot_name + credential_id" do
        post path, params: { peer_id: peer.id }.to_json, headers: headers
        expect(response).to have_http_status(:ok)
        body = JSON.parse(response.body)
        data = body["data"]
        expect(data["ok"]).to be true
        expect(data["peer_id"]).to eq(peer.id)
        expect(data["slot_name"]).to eq("powernode_repl_abc123")
        expect(data["credential_id"]).to eq(peer.id)
        expect(data["already_prepared"]).to be false
      end
    end

    context "validation" do
      it "returns 422 when peer_id is missing" do
        post path, params: {}.to_json, headers: headers
        expect(response).to have_http_status(:unprocessable_entity)
        expect(response.body).to include("peer_id required")
      end

      it "returns 404 when peer does not exist" do
        post path, params: { peer_id: "00000000-0000-0000-0000-000000000000" }.to_json,
                   headers: headers
        expect(response).to have_http_status(:not_found)
      end

      it "returns 422 when peer is not cluster_member" do
        peer.update!(spawn_mode: "managed_child")
        post path, params: { peer_id: peer.id }.to_json, headers: headers
        expect(response).to have_http_status(:unprocessable_entity)
        expect(response.body).to include("not a cluster_member")
      end
    end

    context "auth" do
      it "401 without worker token" do
        post path, params: { peer_id: peer.id }.to_json,
                   headers: { "Content-Type" => "application/json" }
        expect(response).to have_http_status(:unauthorized)
      end
    end

    context "service failure" do
      let(:result) do
        ::System::ClusterMember::PgReplicaSetupService::Result.new(
          ok?: false,
          error: "replication slot create failed: permission denied",
          already_prepared: false
        )
      end

      before do
        allow_any_instance_of(::System::ClusterMember::PgReplicaSetupService)
          .to receive(:run!).and_return(result)
      end

      it "surfaces the service error as 422" do
        post path, params: { peer_id: peer.id }.to_json, headers: headers
        expect(response).to have_http_status(:unprocessable_entity)
        expect(response.body).to include("PG replica setup failed")
        expect(response.body).to include("permission denied")
      end
    end

    context "service raises" do
      before do
        allow_any_instance_of(::System::ClusterMember::PgReplicaSetupService)
          .to receive(:run!).and_raise(StandardError, "PG unreachable")
      end

      it "returns 500" do
        post path, params: { peer_id: peer.id }.to_json, headers: headers
        expect(response).to have_http_status(:internal_server_error)
      end
    end
  end
end
