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

        # Only the files that ARE contributors, mirroring core's twin registrar.
        #
        # Both filters are load-bearing and neither is defensive programming.
        #
        # `is_a?(Class)` + `const_defined?(:KIND, ...)`: this directory will hold
        # ten contributors, and core needed a shared helper at two. The first
        # lane to drop `contributors/enum_conditions.rb` here would otherwise
        # send `::KIND` to a module, raise, and — because the engine rescues —
        # leave the registry with ZERO extension kinds. One unrelated helper
        # file would remove every system kind from the plane, with a log line as
        # the only trace.
        #
        # The `false` on const_defined? is the sharper of the two: without it a
        # SUBCLASS of a contributor inherits its parent's KIND and re-registers
        # under it, and since Registry.register is last-write-wins the subclass
        # would silently overwrite its parent with no error anywhere.
        #
        # `constantize`, not core's `safe_constantize`: a file that names a
        # constant nothing defines is a genuine defect and must raise. Skipping
        # is for files that resolve to something which is not a contributor,
        # never for files that do not resolve at all.
        def contributor_classes
          Dir.glob(CONTRIBUTOR_GLOB).sort.filter_map do |path|
            klass = "#{name}::#{File.basename(path, '.rb').camelize}".constantize
            next unless klass.is_a?(Class) && klass.const_defined?(:KIND, false)

            klass
          end
        end

        def kinds
          contributor_classes.map { |klass| klass::KIND }
        end
      end
    end
  end
end
