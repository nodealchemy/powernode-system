# frozen_string_literal: true

module System
  module Status
    # WHERE THIS EXTENSION'S STATUS KINDS COME FROM (design §4.4, increment B1).
    #
    # Core's Platform::Status::Registry never names an extension; an extension
    # registers itself from its engine's `to_prepare`. This is the one call the
    # engine makes, and it is DERIVED: every class file under `contributors/`
    # is registered under its own `KIND`, so adding a kind is adding a file.
    # There is no list here to forget to update.
    #
    # NO `defined?(Platform::Status::Registry)` GUARD. The system extension
    # requires a core carrying increment A1; a guard that let it boot silently
    # against an older core would be a compatibility shim whose only observable
    # effect is a status plane with no kinds in it and nothing saying why.
    #
    # CONSTANTIZE, NEVER `require`. These files live under an autoload root, so
    # requiring them by path would create a second, Zeitwerk-invisible copy of
    # each class — the shadow-load hazard `pattern-validation.sh` has its own
    # check for. Constantizing also means a dev-mode reload hands us the FRESH
    # class on the next `to_prepare`, which is the whole reason registration
    # runs there rather than once at boot.
    #
    # IDEMPOTENT because `Registry.register` is last-write-wins on the kind.
    # `to_prepare` fires on every reload, so a second call must replace the
    # contributor rather than accumulate a second registration.
    module Contributors
      CONTRIBUTOR_GLOB = File.expand_path("contributors/*.rb", __dir__).freeze

      class << self
        # @return [Array<String>] the kinds registered, in file order.
        def register_all!
          contributor_classes.map do |klass|
            ::Platform::Status::Registry.register(klass::KIND, klass.new)
            klass::KIND
          end
        end

        def contributor_classes
          Dir.glob(CONTRIBUTOR_GLOB).sort.map do |path|
            "#{name}::#{File.basename(path, '.rb').camelize}".constantize
          end
        end

        def kinds
          contributor_classes.map { |klass| klass::KIND }
        end
      end
    end
  end
end
