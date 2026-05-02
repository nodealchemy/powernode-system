# frozen_string_literal: true

module System
  module Slo
    class Definition < BaseRecord
      self.table_name = "system_slo_definitions"

      WINDOWS = %w[1h 6h 1d 7d 30d].freeze

      belongs_to :node_module, class_name: "System::NodeModule"
      delegate :account, to: :node_module

      validates :name, presence: true
      validates :window, inclusion: { in: WINDOWS }
      validates :uptime_target_pct,
                numericality: { greater_than_or_equal_to: 0, less_than_or_equal_to: 100 },
                allow_nil: true
      validates :error_rate_max_pct,
                numericality: { greater_than_or_equal_to: 0, less_than_or_equal_to: 100 },
                allow_nil: true

      attribute :metadata, :json, default: -> { {} }

      scope :enforcing,        -> { where(enforces_autonomy: true) }
      scope :for_module,       ->(id) { where(node_module_id: id) }

      def window_seconds
        case window
        when "1h"  then 1.hour.to_i
        when "6h"  then 6.hours.to_i
        when "1d"  then 1.day.to_i
        when "7d"  then 7.days.to_i
        when "30d" then 30.days.to_i
        end
      end
    end
  end
end
