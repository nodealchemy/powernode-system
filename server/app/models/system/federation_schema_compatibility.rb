# frozen_string_literal: true

module System
  # P9.3 — Schema compatibility matrix between platform versions.
  #
  # Each row declares: "platform version `local_version` running on
  # this peer can federate with platform version `remote_version` on
  # the other peer, with `status` outcome and `notes` describing any
  # caveats." The matrix is consulted on every heartbeat to verify
  # the pair is still compatible; drift triggers a governance finding.
  #
  # The default rule per Social Contract #10 is N-1 compatibility:
  # any prior minor version on the same major track is compatible
  # unless explicitly marked otherwise. Operator overrides (source:
  # "operator") take precedence over default rules.
  #
  # Statuses:
  #   compatible   — pair can exchange resources via federation_api
  #   degraded     — handshake works but some capability kinds are blocked
  #   incompatible — only heartbeat survives; capabilities frozen
  #
  # Plan reference: Decentralized Federation Social Contract #10 + P9.3.
  class FederationSchemaCompatibility < BaseRecord
    STATUSES = %w[compatible degraded incompatible].freeze
    SOURCES  = %w[default operator].freeze

    self.table_name = "system_federation_schema_compatibility"

    belongs_to :account, optional: true

    validates :local_version,  presence: true, length: { maximum: 64 }
    validates :remote_version, presence: true, length: { maximum: 64 }
    validates :status,         inclusion: { in: STATUSES }
    validates :source,         inclusion: { in: SOURCES }
    validates :local_version, uniqueness: { scope: :remote_version }

    scope :for_pair, ->(local, remote) {
      where(local_version: local, remote_version: remote)
    }
    scope :compatible, -> { where(status: "compatible") }

    def compatible?
      status == "compatible"
    end

    def degraded?
      status == "degraded"
    end

    def incompatible?
      status == "incompatible"
    end
  end
end
