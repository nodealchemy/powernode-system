# frozen_string_literal: true

module System
  # Versioned snapshot of the social contract. Operators acknowledge a
  # specific contract version at federation handshake; the digest +
  # contract_text are stored verbatim so the platform can prove (years
  # later) what was agreed to at signup.
  #
  # Plan reference: Decentralized Federation §"Social Contracts" + P4.3.
  class FederationContractVersion < ApplicationRecord
    self.table_name = "system_federation_contract_versions"

    attribute :metadata, :jsonb, default: -> { {} }

    validates :version,         presence: true, uniqueness: true,
                                numericality: { only_integer: true, greater_than: 0 }
    validates :contract_text,   presence: true
    validates :contract_digest, presence: true, length: { is: 64 },
                                uniqueness: true
    validates :effective_at,    presence: true
    validate  :digest_matches_text

    before_validation :compute_digest

    scope :current,    -> { where(deprecated_at: nil).order(version: :desc) }
    scope :deprecated, -> { where.not(deprecated_at: nil) }

    def self.latest
      current.first
    end

    def deprecate!(at: Date.current)
      return false if deprecated_at.present?
      update!(deprecated_at: at)
    end

    def deprecated?
      deprecated_at.present?
    end

    private

    def compute_digest
      return if contract_text.blank?
      self.contract_digest = ::Digest::SHA256.hexdigest(contract_text)
    end

    def digest_matches_text
      return if contract_text.blank? || contract_digest.blank?
      computed = ::Digest::SHA256.hexdigest(contract_text)
      return if computed == contract_digest
      errors.add(:contract_digest, "does not match SHA-256 of contract_text")
    end
  end
end
