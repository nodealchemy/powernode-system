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

    # Get price for a specific region
    def price_in_region(region)
      rit = region_instance_types.find_by(provider_region: region)
      rit&.hourly_price || hourly_price
    end
  end
end
