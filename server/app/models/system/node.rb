# frozen_string_literal: true

require "openssl"
require "base64"

module System
  class Node < BaseRecord
    include System::Base
    include OpensshKeyValidatable

    # === Constants ===
    SSH_KEY_TYPES = %w[ed25519 rsa].freeze
    RSA_KEY_BITS = 2048

    # RETIRED COLUMN, NOW DROPPED — `system_nodes.lifecycle_class` no longer
    # exists. Do not bring it back, and do not build on the name.
    #
    # It was added in Phase 2.5 so the platform and the agent COULD
    # short-circuit expensive bootstrap for short-lived instances. That was
    # never built: nothing in server/, extensions/, worker/ or the Go agent ever
    # read a Node's lifecycle_class, no node-facing payload carried it, and no
    # REST or MCP surface accepted it — the column recorded no intent anybody
    # had chosen. IMP-19843220ac68 settled the wire-or-retire fork as RETIRE
    # and took step 1 (db/migrate/20260902160000_retire_lifecycle_class_default_on_system_nodes.rb):
    # both writers stopped, column nullable with a NULL default, one deploy
    # window of forward compatibility for the previous release.
    # IMP-f2a7a729d39b took step 2 (db/migrate/20260904100000_drop_lifecycle_class_from_system_nodes.rb):
    # the column, its chk_system_nodes_lifecycle_class CHECK constraint, its
    # index, the LIFECYCLE_CLASSES constant and the inclusion validation that
    # used to sit here are all gone, and the example_multi_tenant seed no
    # longer writes it. Supplying the attribute by name now raises
    # ActiveModel::UnknownAttributeError, which is the point: a reintroduced
    # writer fails loudly instead of writing to a column nothing reads.
    #
    # ROLLING THE EXTENSION BACK past step 2 requires that migration's `down`
    # FIRST. The step-1 model validates the column (allow_nil) and the
    # baseline model validates it NOT NULL, so either release raises
    # NoMethodError on the first Node validation while the attribute is
    # missing. `down` restores step 1's shape (nullable, no default, CHECK and
    # index back, values lost); step 1's own `down` then backfills from the
    # pool and restores NOT NULL.
    #
    # THE AUTHORITATIVE HOLDER IS THE POOL. system_instance_pools.lifecycle_class
    # (ephemeral|spot only — a pool of machines you intend to keep is a
    # contradiction) is settable, read and rotatable (GitOps apply_pool
    # "update"), and a member Node reaches it through config["instance_pool_id"],
    # which InstancePoolService#provision_warming_member! stamps at create time.
    # Anything that ever wants to branch on a machine's lifetime reads the pool.
    # system_node_instances.lease_class (IMP-1e2e7b43b083) is a different axis
    # — lease provenance, value "task_scoped" — not a lifecycle class.
    # Guards: spec/models/system/node_lifecycle_class_retirement_spec.rb,
    # spec/models/system/lifecycle_class_value_space_spec.rb.

    # Encryption for sensitive fields
    encrypts :ssh_key
    encrypts :ssh_host_key

    # Associations
    belongs_to :account
    belongs_to :node_template, class_name: "System::NodeTemplate"
    belongs_to :worker, optional: true
    has_many :node_instances, class_name: "System::NodeInstance", dependent: :destroy

    # Module associations (Release 3)
    has_many :node_module_assignments, class_name: "System::NodeModuleAssignment", dependent: :destroy
    has_many :node_modules, through: :node_module_assignments

    # Task associations (Release 4)
    # Task association + removal policy: see System::PreservesTaskHistory.
    # Tasks are TRANSITIONED on removal, never deleted — a deleted task is
    # indistinguishable from one that never ran.
    include System::PreservesTaskHistory

    # Validations
    validates :name, presence: true, uniqueness: { scope: :account_id }
    validates :ssh_key_type, inclusion: { in: SSH_KEY_TYPES }, allow_nil: true

    # Callbacks
    before_create :initialize_ssh_keys

    # Config accessors
    store_accessor :config

    # Scopes
    scope :with_worker, -> { where.not(worker_id: nil) }
    scope :without_worker, -> { where(worker_id: nil) }
    scope :with_public_ip, -> { where(allocate_public_ip: true) }
    scope :with_tmpfs, -> { where(tmpfs_store: true) }
    scope :without_tmpfs, -> { where(tmpfs_store: false) }

    # === Runtime Tracking Methods ===
    def increment_runtime!(minutes = 1)
      increment!(:runtime_amount, minutes)
    end

    def runtime_hours
      (runtime_amount || 0) / 60.0
    end

    def runtime_days
      runtime_hours / 24.0
    end

    def reset_runtime!
      update!(runtime_amount: 0)
    end

    # === Storage Methods ===
    def uses_tmpfs?
      tmpfs_store == true
    end

    def enable_tmpfs!
      update!(tmpfs_store: true)
    end

    def disable_tmpfs!
      update!(tmpfs_store: false)
    end

    # === Default Script Delegation ===
    # Legacy parity (`powernode-server/app/models/node.rb:32-35`):
    # Node delegates default build/init/sync scripts to its platform (via template).
    # The platform stores these inline as TEXT (System::NodePlatform#build_script,
    # init_script, sync_script). Per-Node override of sync_script (legacy
    # custom_sync_script flag) is deferred until needed.
    delegate :build_script, :init_script, :sync_script,
             to: :node_platform, allow_nil: true

    # Convenience accessor that walks Node -> NodeTemplate -> NodePlatform.
    # Returns nil if either link is missing (e.g. during build before associations
    # are populated).
    def node_platform
      node_template&.node_platform
    end

    # === SSH Key Methods ===

    # Aggregated authorized_keys for SSH access to instances of this node.
    # Returns an array of public-key strings suitable for ~/.ssh/authorized_keys.
    # Pulls from three sources, in this order:
    #   1. operator-supplied keys on `config["authorized_keys"]` (per-node)
    #   2. operator-supplied keys on each active user in the owning account
    #      (account-wide — replaces the legacy CanCan-based aggregation
    #      from powernode-server's node.rb:50-58)
    # Output is filtered to OpenSSH `authorized_keys`-format lines only —
    # sshd silently drops PEM-PKIX or otherwise-malformed lines, so we
    # drop them here too.
    #
    # The node's own identity public key (`ssh_public_key`) is intentionally
    # excluded: it's a PEM-PKIX Ed25519 key used for mTLS and outbound
    # signing, not an operator login credential.
    def authorized_keys
      keys = []
      if config.is_a?(Hash) && config["authorized_keys"].present?
        keys.concat(Array(config["authorized_keys"]))
      end
      if account
        account.users.active.find_each do |user|
          keys.concat(Array(user.authorized_keys)) if user.authorized_keys.present?
        end
      end
      keys.compact.uniq.select { |k| self.class.openssh_authorized_key?(k) }
    end

    # Newline-joined authorized_keys content. Returns "" when there are no keys.
    def authorized_keys_text
      keys = authorized_keys
      return "" if keys.empty?

      "#{keys.join("\n")}\n"
    end

    # Public key in PEM format derived from the encrypted private identity key.
    def ssh_public_key
      derive_public_key_pem(ssh_key)
    end

    # Public host key in PEM format derived from the encrypted private host key.
    def ssh_host_public_key
      derive_public_key_pem(ssh_host_key)
    end

    private

    # Auto-generates an SSH identity keypair and host keypair on first save.
    # Defaults to Ed25519. Falls back to RSA 2048 when the node's template config
    # has `"legacy_rsa_keys" => true` (for hardware/tooling that lacks Ed25519).
    def initialize_ssh_keys
      # If both keys are pre-set by caller, leave the record alone — including
      # ssh_key_type (caller is presumed to know what they're doing).
      return if ssh_key.present? && ssh_host_key.present?

      use_rsa = node_template&.config.is_a?(Hash) && node_template.config["legacy_rsa_keys"] == true
      # Unconditional assignment: the column has a default of 'ed25519' which
      # means `||=` would always short-circuit and never honor legacy_rsa_keys.
      self.ssh_key_type = use_rsa ? "rsa" : "ed25519"

      if ssh_key.blank?
        identity = generate_keypair(ssh_key_type)
        self.ssh_key = identity[:pem]
        self.ssh_key_fingerprint = identity[:fingerprint]
      end

      return if ssh_host_key.present?

      host = generate_keypair(ssh_key_type)
      self.ssh_host_key = host[:pem]
      self.ssh_host_key_fingerprint = host[:fingerprint]
    end

    def generate_keypair(type)
      pkey = case type
      when "ed25519" then OpenSSL::PKey.generate_key("ED25519")
      when "rsa"     then OpenSSL::PKey::RSA.new(RSA_KEY_BITS)
      else raise ArgumentError, "Unsupported ssh_key_type: #{type}"
      end
      # `private_to_pem` is the universal accessor across all OpenSSL::PKey subclasses
      # (RSA, EC, Ed25519). The legacy code used `to_pem` which only worked on RSA.
      { pem: pkey.private_to_pem, fingerprint: compute_fingerprint(pkey) }
    end

    def derive_public_key_pem(private_pem)
      return nil if private_pem.blank?

      pkey = OpenSSL::PKey.read(private_pem)
      pkey.respond_to?(:public_to_pem) ? pkey.public_to_pem : pkey.public_key.to_pem
    rescue OpenSSL::PKey::PKeyError, ArgumentError => e
      Rails.logger.error("[System::Node ##{id}] Failed to derive public key: #{e.message}")
      nil
    end

    # SHA-256 fingerprint over the public-key DER.
    # Format: "SHA256:<base64-no-padding>" — same prefix shape as OpenSSH but
    # computed over PEM/DER bytes rather than the SSH wire format.
    # The on-node agent recomputes the OpenSSH-format fingerprint client-side
    # if it needs the canonical openssh string.
    def compute_fingerprint(pkey)
      pub_pem = pkey.respond_to?(:public_to_pem) ? pkey.public_to_pem : pkey.public_key.to_pem
      digest = OpenSSL::Digest::SHA256.digest(pub_pem)
      "SHA256:#{Base64.strict_encode64(digest).delete('=')}"
    end
  end
end
