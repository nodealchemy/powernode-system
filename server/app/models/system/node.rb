# frozen_string_literal: true

require "openssl"
require "base64"

module System
  class Node < BaseRecord
    include System::Base

    # === Constants ===
    SSH_KEY_TYPES = %w[ed25519 rsa].freeze
    RSA_KEY_BITS = 2048

    # Phase 2.5 hardening — lifecycle_class disambiguates "long-lived
    # vs ephemeral" so the platform + agent can short-circuit
    # expensive bootstrap for short-lived instances. See migration
    # 20260505000500_add_lifecycle_class_to_system_nodes.rb.
    LIFECYCLE_CLASSES = %w[persistent ephemeral spot].freeze
    validates :lifecycle_class, inclusion: { in: LIFECYCLE_CLASSES }, allow_nil: false

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
    has_many :tasks, class_name: "System::Task", as: :operable, dependent: :destroy

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
    # Legacy parity (`~/Drive/Projects/powernode-server/app/models/node.rb:32-35`):
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
    # Currently includes the node's own public key plus any operator-supplied
    # keys from `config["authorized_keys"]`.
    # CORE-MIGRATION pending: legacy node.rb:50-58 also aggregated permitted users'
    # keys via Ability.can?(:control_node, self) and account_delegations.
    # That requires a `User#authorized_keys` field which the platform User model
    # does not yet have — restore as a separate core migration before adopting here.
    def authorized_keys
      keys = []
      keys << ssh_public_key if ssh_public_key.present?
      if config.is_a?(Hash) && config["authorized_keys"].present?
        keys.concat(Array(config["authorized_keys"]))
      end
      keys.compact.uniq
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
