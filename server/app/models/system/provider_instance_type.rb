# frozen_string_literal: true

module System
  class ProviderInstanceType < BaseRecord
    include System::Base

    # Associations
    belongs_to :account
    belongs_to :provider, class_name: "System::Provider"
    has_many :region_instance_types, class_name: "System::RegionInstanceType", dependent: :destroy
    has_many :provider_regions, through: :region_instance_types
    has_many :node_instances, class_name: "System::NodeInstance"

    # Validations
    validates :name, presence: true, uniqueness: { scope: %i[account_id provider_id], case_sensitive: false }
    validates :instance_type_code, presence: true, uniqueness: { scope: :provider_id }

    # Scopes
    scope :for_provider, ->(provider) { where(provider: provider) }
    scope :by_vcpus, ->(min, max = nil) { max ? where(vcpus: min..max) : where("vcpus >= ?", min) }
    scope :by_memory, ->(min, max = nil) { max ? where(memory_mb: min..max) : where("memory_mb >= ?", min) }
    scope :with_gpu, -> { where("gpu_count > 0") }
    # GPU SKUs, optionally narrowed by accelerator type + a minimum GPU count.
    scope :by_gpu, ->(gpu_type = nil, min_count: 1) {
      rel = where("gpu_count >= ?", min_count)
      gpu_type.present? ? rel.where("LOWER(gpu_type) = LOWER(?)", gpu_type) : rel
    }

    # Specs accessor
    store_accessor :specs

    # Human-readable memory
    def memory_gb
      return nil unless memory_mb

      (memory_mb / 1024.0).round(1)
    end

    # True when this instance type carries one or more GPUs/accelerators.
    def gpu?
      gpu_count.to_i.positive?
    end

    # Per-GPU VRAM in GB (nil when unknown or no GPU).
    def gpu_memory_gb
      return nil unless gpu_memory_mb

      (gpu_memory_mb / 1024.0).round(1)
    end

    # Human-readable accelerator summary, e.g. "8x H100 80 GB" (nil when no GPU).
    def gpu_summary
      return nil unless gpu?

      vram = gpu_memory_gb ? " #{gpu_memory_gb.to_i} GB" : ""
      "#{gpu_count}x #{gpu_type.presence || 'GPU'}#{vram}"
    end

    # Display string
    def display_name
      parts = [ name ]
      parts << "#{vcpus} vCPUs" if vcpus
      parts << "#{memory_gb} GB" if memory_gb
      parts << gpu_summary if gpu?
      parts.join(" - ")
    end

    # Check availability in a specific region
    def available_in_region?(region)
      region_instance_types.exists?(
        provider_region: region,
        available: true
      )
    end

    # The catalog row that PRICES this SKU in `region`: the region override
    # when it carries a rate of its own, otherwise this base row.
    #
    # ONE resolution, because a price and the currency it is quoted in must
    # come from the SAME row. Reading the number from the region override and
    # the currency from the base row (or the reverse) silently converts
    # between them, and a per-region rate quoted in another currency is
    # exactly where that would land. Both rows answer #hourly_price and
    # #effective_currency, so callers can take the pair off one object.
    #
    # A region override with a NULL hourly_price is not a price — it is an
    # availability row — so it falls through to the base rate, which is the
    # behaviour #price_in_region has always had.
    def pricing_row_for(region)
      rit = region ? region_instance_types.find_by(provider_region: region) : nil
      rit&.hourly_price ? rit : self
    end

    # Get price for a specific region
    def price_in_region(region)
      pricing_row_for(region).hourly_price
    end

    # The currency `hourly_price` is quoted in. Mirrors
    # System::RegionInstanceType#effective_currency so the two pricing rows
    # are interchangeable to a caller that resolved one via #pricing_row_for.
    def effective_currency
      currency.presence || "USD"
    end
  end
end
