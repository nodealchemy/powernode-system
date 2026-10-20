# frozen_string_literal: true

require "rails_helper"
require Rails.root.join("..", "extensions", "system", "server", "db", "migrate",
                        "20261020130000_add_open_operator_key_unique_index_to_system_bootstrap_tokens.rb").to_s

# D4 review B1 - the index migration never mutates data: it aborts on duplicate
# open operator keys (revoking is an audited key operation) and builds the index
# when there are none.
RSpec.describe AddOpenOperatorKeyUniqueIndexToSystemBootstrapTokens do
  let(:account)  { create(:account) }
  let(:node)     { create(:system_node, account: account) }
  let(:instance) { create(:system_node_instance, node: node, account: account, status: "pending") }
  let(:index)    { described_class::INDEX }
  let(:conn)     { ActiveRecord::Base.connection }

  def migrate(direction)
    migration = described_class.new
    migration.exec_migration(conn, direction)
  end

  before { conn.remove_index :system_bootstrap_tokens, name: index } # DDL is transactional; rolled back per example

  def insert_open_key(digest)
    System::BootstrapToken.create!(node: node, node_instance: instance, intended_subject: instance.id,
                                   token_hash: digest, expires_at: 1.hour.from_now, purpose: "operator_key",
                                   sealed_plaintext: "plain-#{digest}")
  end

  it "builds the index when there are no duplicates, and down removes it" do
    insert_open_key("a")
    migrate(:up)
    expect(conn.index_exists?(:system_bootstrap_tokens, :node_instance_id, name: index)).to be(true)
    migrate(:down)
    expect(conn.index_exists?(:system_bootstrap_tokens, :node_instance_id, name: index)).to be(false)
  end

  it "aborts with a static error and changes NO data when duplicates exist" do
    a = insert_open_key("a")
    b = insert_open_key("b")
    audits = AuditLog.count

    expect { migrate(:up) }.to raise_error(StandardError, /revoke the extras through the audited path|Revoke the extras/)
    expect(conn.index_exists?(:system_bootstrap_tokens, :node_instance_id, name: index)).to be(false)
    [ a, b ].each do |k|
      k.reload
      expect(k.revoked_at).to be_nil
      expect(k.sealed_plaintext).to be_present
    end
    expect(AuditLog.count).to eq(audits)
  end
end
