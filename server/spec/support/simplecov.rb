# frozen_string_literal: true

# SimpleCov configuration for the system extension.
#
# Opt-in via COVERAGE=1. If COVERAGE=1 is set but the simplecov gem isn't
# installed (i.e., the parent platform's Gemfile doesn't include it), the
# require fails gracefully with a warning — tests still run, just no coverage.
#
# To enable coverage in CI or locally:
#   1. Add to the parent platform's server/Gemfile:
#        gem 'simplecov', require: false, group: :test
#   2. Run: bundle install
#   3. Require this file at the top of spec_helper.rb (FIRST require), e.g.:
#        require_relative '../../extensions/system/server/spec/support/simplecov'
#   4. Invoke:
#        COVERAGE=1 bundle exec rspec ../extensions/system/server/spec
#   5. Open coverage/system_extension/index.html
#
# The minimum_coverage gate starts permissive (60%) so the gate doesn't block
# while the test pyramid is being built out (per audit plan P0.1, P0.2, P2.1,
# P2.2). Tighten to 70% after wave 3 of P0.1 controllers, 80% after wave 5.

if ENV["COVERAGE"] == "1"
  begin
    require "simplecov"
  rescue LoadError
    warn "[simplecov] COVERAGE=1 set but simplecov gem unavailable — " \
         "add `gem 'simplecov', require: false, group: :test` to the parent " \
         "platform's server/Gemfile to enable coverage tracking."
  end

  if defined?(SimpleCov)
    SimpleCov.start "rails" do
      command_name "system-extension"

      # Coverage scope: this extension's app/ + lib/, NOT the parent platform
      # or other extensions. Use root paths relative to where rspec is invoked
      # from (parent platform's server/). Both relative paths and absolute paths
      # work; relative survives the CI mount-into-parent dance.
      add_filter "/spec/"
      add_filter "/db/"
      add_filter "/config/"
      add_filter "/vendor/"

      # Include only the extension's source. The CI workflow mounts the
      # extension at powernode-platform/extensions/system/; locally the path
      # is /home/.../extensions/system/. Match both via the trailing segment.
      ext_root = File.expand_path("../../../..", __dir__)  # → extensions/system
      track_files "#{ext_root}/server/app/**/*.rb"
      track_files "#{ext_root}/server/lib/**/*.rb"

      # Per-domain groups so the HTML report surfaces hotspots quickly.
      add_group "Controllers", "#{ext_root}/server/app/controllers"
      add_group "Services - SDWAN", "#{ext_root}/server/app/services/sdwan"
      add_group "Services - System (CVE)", "#{ext_root}/server/app/services/system/cve_ops"
      add_group "Services - System (Fleet)", "#{ext_root}/server/app/services/system/fleet"
      add_group "Services - System (Federation)", "#{ext_root}/server/app/services/system/federation"
      add_group "Services - System (Skills)", "#{ext_root}/server/app/services/system/ai/skills"
      add_group "Services - System (Other)", "#{ext_root}/server/app/services/system"
      add_group "Services - ACME", "#{ext_root}/server/app/services/acme"
      add_group "Services - Federation", "#{ext_root}/server/app/services/federation"
      add_group "Models", "#{ext_root}/server/app/models"
      add_group "Lib", "#{ext_root}/server/lib"

      coverage_dir "#{ext_root}/coverage"

      # Permissive gate until the test pyramid catches up. Bump after P0.1 + P0.2.
      minimum_coverage 60
    end
  end
end
