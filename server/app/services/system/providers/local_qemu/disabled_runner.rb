# frozen_string_literal: true

module System
  module Providers
    module LocalQemu
      # No-op runner that returns errors. Useful in CI/dev hosts where
      # libvirt isn't installed but you still want the provider class
      # to load + return predictable failures.
      class DisabledRunner
        Runner::REQUIRED.each do |meth|
          define_method(meth) { |**_args| { ok: false, error: "libvirt disabled (POWERNODE_LIBVIRT_MODE=disabled)" } }
        end
      end
    end
  end
end
