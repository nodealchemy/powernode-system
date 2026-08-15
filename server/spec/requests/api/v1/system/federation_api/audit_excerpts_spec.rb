# frozen_string_literal: true

require "rails_helper"

# P9.2 — Cross-peer audit excerpt endpoint (Social Contract #5).
#
# The compliance contract (operator ruling on IMP-79b5bb5fee24): the
# excerpt API captures ALL FleetEvents referencing a federation peer
# regardless of kind — its kind-agnostic predicate is deliberate
# (completeness bias for compliance). These examples cross the
# writer/reader seam by driving a REAL emitter rather than fabricating
# rows with the key the query already uses.
RSpec.describe "Api::V1::System::FederationApi::AuditExcerpts", type: :request do
  let(:account) { create(:account) }
  let(:path)    { "/api/v1/system/federation_api/audit_excerpts" }

  # IMP-79b5bb5fee24: PgReplicaSetupService#emit_event! stamped its
  # payload with `peer_id`, so its pg_replica_ready event was persisted
  # but invisible to this endpoint's federation_peer_id predicate.
  it "returns the pg_replica_ready event the cluster_member setup service emits" do
    member_peer = enrolled_federation_peer(
      account: account,
      status: "active",
      spawn_mode: "cluster_member",
      spawn_role: "parent",
      remote_instance_url: "https://child.example.com"
    )
    vault = instance_double(::Security::VaultCredentialProvider, store_credential: true)
    result = ::System::ClusterMember::PgReplicaSetupService.new(
      peer: member_peer,
      sql_executor: ->(_sql, _binds = []) { [] },
      vault: vault
    ).run!
    expect(result.ok?).to be(true)

    emitted = ::System::FleetEvent.where(
      account: account, kind: "platform.cluster_member.pg_replica_ready"
    ).last
    expect(emitted).to be_present,
                       "expected PgReplicaSetupService#run! to emit a pg_replica_ready FleetEvent"

    get path, headers: federation_mtls_headers(member_peer)

    expect(response).to have_http_status(:ok)
    body = JSON.parse(response.body)
    event_ids = body["data"]["events"].map { |e| e["id"] }
    expect(event_ids).to include(emitted.id),
                         "pg_replica_ready event missing from the audit excerpt — the writer stamps payload " \
                         "#{emitted.payload.keys.sort.inspect}, events_for_peer filters on federation_peer_id"
  end

  it "401s without an mTLS subject" do
    get path
    expect(response).to have_http_status(:unauthorized)
  end
end
