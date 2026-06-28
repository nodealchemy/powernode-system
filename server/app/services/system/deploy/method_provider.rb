# frozen_string_literal: true

module System
  module Deploy
    # Exposes this extension's deploy methods to the core Ai::Deploy::MethodRegistry via the
    # ExtensionRegistry :deploy_method_providers seam. Core resolves this provider by name
    # and calls #deploy_methods — it never references System:: directly, so core stays
    # extension-agnostic and the Kubernetes method is simply absent in core mode.
    module MethodProvider
      module_function

      def deploy_methods
        { kubernetes: ::System::Deploy::KubernetesMethod }
      end
    end
  end
end
