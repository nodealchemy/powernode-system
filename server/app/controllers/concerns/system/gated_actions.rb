# frozen_string_literal: true

module System
  # Thin alias for the core ::Ai::GatedActions concern. The original
  # implementation was promoted to core 2026-05-10 so non-System controllers
  # (Devops::Kubernetes::ClustersController, etc.) can also gate destructive
  # operations without depending on the System extension.
  #
  # System extension controllers can include either ::System::GatedActions
  # or ::Ai::GatedActions interchangeably — the behavior is identical.
  module GatedActions
    extend ActiveSupport::Concern

    included do
      include ::Ai::GatedActions
    end
  end
end
