# frozen_string_literal: true

module System
  # Class-level adapter selection for the gitea/local dual-mode services
  # (ManifestFetchService, ModuleBuildDispatchService, ...). Extracted from
  # their previously-duplicated class-macro boilerplate (IMP-c5a311bdfd46).
  #
  #   extend System::EnvSwitchedAdapter
  #   env_switched_adapter env_var: "POWERNODE_<X>_MODE",
  #                        adapters: { "gitea" => "GiteaXAdapter",
  #                                    "local" => "LocalXAdapter" },
  #                        error_class: XError
  #
  # Provides `.adapter` (memoized), `.adapter=` (test injection), and
  # `.reset!`, with the shared default: production → "gitea", otherwise
  # "local". Adapter values are CONSTANT NAMES resolved lazily against the
  # host class (const_get at first use) — the adapter classes are defined
  # below the declaration in the same file.
  module EnvSwitchedAdapter
    def env_switched_adapter(env_var:, adapters:, error_class:)
      @adapter_env_var = env_var
      @adapter_registry = adapters
      @adapter_error_class = error_class
    end

    def adapter
      @adapter ||= build_adapter
    end

    def adapter=(replacement)
      @adapter = replacement
    end

    def reset!
      @adapter = nil
    end

    private

    def build_adapter
      mode = ENV.fetch(@adapter_env_var, default_mode_for_env)
      name = @adapter_registry[mode]
      raise @adapter_error_class, "Unknown #{@adapter_env_var}: #{mode.inspect}" unless name

      const_get(name).new
    end

    def default_mode_for_env
      Rails.env.production? ? "gitea" : "local"
    end
  end
end
