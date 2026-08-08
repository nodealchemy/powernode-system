# frozen_string_literal: true

require "rails_helper"

# The public, GitHub-mirrored system extension must not disclose a private
# extension's namespaces or class names — not even in doc comments. This is
# the comment-level analog of the core-purity rule: core-purity-check.sh and
# the pattern-validation mirror scan CORE source for private-extension names,
# but nothing scanned the public extensions themselves, so a comment saying
# "mirrors <PrivateNs>::SomeService" shipped straight to the public mirror.
#
# Forbidden namespaces are derived dynamically from extensions/private/* (the
# same derivation core-purity-check.sh uses) so this file never has to name
# one itself — hardcoding a name here would recreate the exact leak this spec
# guards against. On a public clone no private extensions are present and the
# example skips.
RSpec.describe "private-extension isolation (public mirror hygiene)" do
  it "never references a private extension namespace anywhere in the mirrored server tree" do
    server_root = Pathname.new(File.expand_path("../..", __dir__))
    private_dir = server_root.join("..", "..", "private")
    skip "no private extensions present (public clone)" unless private_dir.directory?

    namespaces = private_dir.children.select(&:directory?).map { |d| d.basename.to_s.camelize }
    skip "no private extensions present (public clone)" if namespaces.empty?

    this_file = File.expand_path(__FILE__)
    offenders = Dir.glob(server_root.join("**", "*.rb")).flat_map do |path|
      next [] if File.expand_path(path) == this_file

      File.foreach(path).with_index(1).filter_map do |line, lineno|
        hit = namespaces.find { |ns| line.match?(/\b#{Regexp.escape(ns)}::/) }
        "#{path}:#{lineno} references #{hit}::" if hit
      end
    end

    expect(offenders).to be_empty,
                         "private-extension names leak into the public mirror:\n#{offenders.join("\n")}"
  end
end
