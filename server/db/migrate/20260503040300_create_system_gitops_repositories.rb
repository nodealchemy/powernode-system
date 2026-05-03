# frozen_string_literal: true

# GitOps repository registry. Each row represents a git repo whose contents
# describe a desired fleet state (templates, assignments, provider configs).
# A reconciler ticks every 5 minutes per enabled repo, compares parsed
# desired state to live state, and opens AgentProposal rows for diffs.
#
# Reference: comprehensive stabilization sweep P5; Golden Eclipse M-D2-3.
class CreateSystemGitopsRepositories < ActiveRecord::Migration[8.1]
  def change
    create_table :system_gitops_repositories, id: :uuid do |t|
      t.references :account, null: false, type: :uuid, foreign_key: true
      t.string :name, null: false
      t.string :repo_url, null: false
      t.string :branch, null: false, default: "main"
      t.string :vault_credential_path
      t.string :path_prefix, default: ""
      t.boolean :enabled, default: true, null: false
      t.boolean :auto_apply, default: false, null: false
      t.datetime :last_synced_at
      t.string :last_synced_revision
      t.integer :last_diff_count, default: 0, null: false
      t.string :last_status, default: "pending"
      t.text :last_error
      t.jsonb :metadata, default: {}

      t.timestamps
    end

    add_index :system_gitops_repositories, [:account_id, :name], unique: true
    add_index :system_gitops_repositories, :enabled
    add_index :system_gitops_repositories, :last_synced_at
  end
end
