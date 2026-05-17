# frozen_string_literal: true

# P3.2 — `subject_kind` distinguishes node-agent certs (subject = instance)
# from federation-peer certs (subject = a remote Powernode platform).
# Used by Api::V1::System::FederationApi::BaseController's mTLS auth chain
# to refuse node-agent certs presented at federation_api endpoints (and
# vice-versa).
#
# Plan reference: Decentralized Federation §C + P3.2.
class AddSubjectKindToSystemNodeCertificates < ActiveRecord::Migration[8.0]
  def change
    add_column :system_node_certificates, :subject_kind, :string,
      null: false, default: "instance", limit: 32
    add_index :system_node_certificates, :subject_kind

    add_check_constraint :system_node_certificates,
      "subject_kind IN ('instance', 'federation_peer')",
      name: "node_certificates_subject_kind_enum"
  end
end
