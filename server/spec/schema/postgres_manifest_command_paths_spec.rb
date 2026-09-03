# frozen_string_literal: true

require "rails_helper"
require "yaml"

# IMP-5b38cd356010 — every command the postgres module manifests declare must
# name a binary the module actually CARVES.
#
# postgres-primary's `stop_command` invoked /usr/bin/pg_ctl. The Debian
# postgresql-16 layout ships no such file — /usr/bin carries pg_ctlcluster and
# the real pg_ctl lives under /usr/lib/postgresql/16/bin/ — and the manifest's
# own file_spec says so (it lists /usr/bin/pg_ctlcluster and the
# /usr/lib/postgresql/16/** glob, never /usr/bin/pg_ctl). A stop that fails
# command-not-found is not a stop; systemd falls back to SIGTERM, which is a
# different shutdown mode from the `-m fast` the manifest asked for. The same
# defect was caught on fence_command during IMP-93b83b5c82d8's review and left
# on stop_command "for its own task". This is that task.
#
# Checked STRUCTURALLY, for both postgres manifests and every command-bearing
# key at once, so the next command someone adds is held to the same rule.
RSpec.describe "postgres module manifests: declared commands resolve inside file_spec" do
  extension_root = File.expand_path("../../..", __dir__)

  manifests = %w[postgres-primary postgres-replica].to_h do |name|
    [ name, YAML.safe_load(File.read(File.join(extension_root, "modules", name, "manifest.yaml"))) ]
  end

  # Service-level lifecycle commands plus the metadata-declared DR contract
  # PromoteReplicaExecutor resolves. Absent keys are simply not checked.
  # LOCALS, not constants: a constant assigned in a describe body lands at top
  # level and can be clobbered by another spec file in the same run.
  service_command_keys  = %w[start_command stop_command]
  metadata_command_keys = %w[promote_command fence_command]

  carved = lambda do |file_spec, path|
    file_spec.any? { |entry| entry == path || File.fnmatch(entry, path) }
  end

  manifests.each do |name, manifest|
    describe name do
      services  = Array(manifest["services"])
      file_spec = Array(manifest["file_spec"]).map(&:to_s)

      it "carves files at all (the oracle below is not vacuous)" do
        expect(file_spec.size).to be > 50
        expect(services).not_to be_empty
      end

      services.each do |service|
        commands = service_command_keys.filter_map { |k| [ k, service[k] ] if service[k] } +
                   metadata_command_keys.filter_map { |k| [ k, service.dig("metadata", k) ] if service.dig("metadata", k) }

        commands.each do |key, command|
          it "#{service['name']}.#{key} names a binary the module delivers (#{command.split.first})" do
            binary = command.to_s.split.first
            expect(binary).to start_with("/"), "#{key} must be an absolute path: #{command.inspect}"
            expect(carved.call(file_spec, binary)).to be(true),
              "#{name} #{service['name']}.#{key} invokes #{binary}, which no file_spec entry carves — " \
              "the command fails command-not-found on the node"
          end
        end
      end

      # The specific defect, named so its absence is asserted rather than
      # inferred from the structural check's silence.
      it "never invokes /usr/bin/pg_ctl anywhere in its services" do
        expect(services.to_yaml).not_to include("/usr/bin/pg_ctl ")
      end
    end
  end
end
