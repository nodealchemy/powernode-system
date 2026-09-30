# frozen_string_literal: true

# IMP-1e5db5e6aefb — the git host's SSH PUBLIC key(s) a GitopsRepository's
# clone/pull is verified against. Same document shape as
# NodeInstance#ssh_host_keys ({ "keys" => [{type, key, fingerprint}], ... }),
# validated by System::SshHostKeys on the way in and again on the way out, so
# System::Gitops::RepoSyncService can render it into a per-call known_hosts
# and run ssh with StrictHostKeyChecking=yes instead of =no.
#
# NULL means no key has been recorded yet: the next sync keyscans the host and
# pins what it finds (trust on first use). A recorded key is never replaced by
# the sync itself; a changed host key fails the sync instead. Public keys and
# fingerprints only; never private material.
class AddSshHostKeysToSystemGitopsRepositories < ActiveRecord::Migration[8.1]
  def change
    return if column_exists?(:system_gitops_repositories, :ssh_host_keys)

    add_column :system_gitops_repositories, :ssh_host_keys, :jsonb
  end
end
