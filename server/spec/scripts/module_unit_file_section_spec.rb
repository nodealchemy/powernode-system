# frozen_string_literal: true

require "spec_helper"

# Static lint over every systemd unit file the modules SHIP in their rootfs.
#
# Motivating defect (2026-07-27, dev-cell): StartLimitIntervalSec=/StartLimitBurst=
# were written under [Service]. systemd parses start rate limiting on the UNIT,
# so it dropped them with "Unknown key name 'StartLimitIntervalSec' in section
# 'Service', ignoring" — three units that documented themselves as bounded were
# in fact crash-looping unbounded, and nothing failed to make that visible.
#
# The failure mode is what makes this worth a spec rather than a code review
# note: a misplaced key is not a syntax error, does not fail the build, does not
# fail at attach time, and only whispers once into the journal at boot.
#
# Scope note: only regular files are scanned. The multi-user.target.wants/
# entries are enablement symlinks with ABSOLUTE targets (/etc/systemd/system/...)
# that resolve against the running host, not this repo — following them would
# lint whatever the local machine happens to have composed.
RSpec.describe "shipped systemd unit files" do
  MODULES_DIR = File.expand_path("../../../modules", __dir__)

  # Keys systemd only honors in [Unit], and which are silently ignored (not
  # rejected) anywhere else — the exact shape that made this defect invisible.
  # StartLimitInterval is the pre-v230 spelling, still accepted in [Unit].
  UNIT_ONLY_KEYS = %w[StartLimitIntervalSec StartLimitInterval StartLimitBurst].freeze

  unit_files = Dir.glob(File.join(MODULES_DIR, "*", "rootfs", "etc", "systemd", "system", "**", "*.{service,socket,timer,mount,target}"))
                  .reject { |p| File.symlink?(p) }
                  .sort

  it "finds unit files to lint (guards against the glob silently going stale)" do
    expect(unit_files).not_to be_empty
  end

  unit_files.each do |path|
    rel = path.sub("#{MODULES_DIR}/", "")

    it "#{rel} declares start rate limiting in [Unit], where systemd reads it" do
      section = nil
      offenders = []

      File.readlines(path).each_with_index do |line, idx|
        stripped = line.strip
        section = stripped if stripped.start_with?("[") && stripped.end_with?("]")
        next unless stripped.include?("=")

        key = stripped.split("=", 2).first.strip.sub(/\A-/, "")
        next unless UNIT_ONLY_KEYS.include?(key)
        next if section == "[Unit]"

        offenders << "line #{idx + 1}: #{key} under #{section || '(no section)'}"
      end

      expect(offenders).to be_empty, <<~MSG
        #{rel} declares unit-only key(s) outside [Unit]:
          #{offenders.join("\n  ")}
        systemd ignores these silently ("Unknown key name ... ignoring") — the
        intended restart bound is NOT in effect. Move them under [Unit], or drop
        them if the bound isn't actually wanted.
      MSG
    end
  end
end
