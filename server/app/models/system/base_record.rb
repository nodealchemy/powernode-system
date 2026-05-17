# frozen_string_literal: true

module System
  # Base class for all System:: namespaced models
  # Provides common functionality and table naming conventions
  class BaseRecord < ApplicationRecord
    self.abstract_class = true

    # Table-name convention: `system_<demodulized name pluralized>`.
    # E.g. System::Node → system_nodes, System::AcmeCertificate →
    # system_acme_certificates.
    #
    # Why `compute_table_name` and not `self.table_name`: ActiveRecord's
    # `self.table_name` getter checks the explicit setter first
    # (`@table_name`, set via `self.table_name = "..."` in the child),
    # and falls back to `compute_table_name` when the setter wasn't
    # called. Overriding the getter directly (as this class previously
    # did) breaks doubly-nested classes like System::Slo::Definition
    # whose explicit `self.table_name = "system_slo_definitions"` gets
    # silently ignored — the convention drops the middle module (`Slo`)
    # since `name.demodulize` only keeps the leaf, producing the wrong
    # `system_definitions`. Hooking `compute_table_name` instead lets
    # children opt out by setting an explicit table name.
    def self.compute_table_name
      "system_#{name.demodulize.underscore.pluralize}"
    end
  end
end
