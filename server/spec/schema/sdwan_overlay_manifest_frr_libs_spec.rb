# frozen_string_literal: true

require "rails_helper"
require "yaml"

# The sdwan-overlay module carves FRR's binaries (/usr/lib/frr/**) but its
# file_spec was authored without a dpkg admindir to derive from, and it missed
# the directory the Debian/Ubuntu `frr` package keeps its OWN shared objects
# in: /usr/lib/x86_64-linux-gnu/frr/ (libfrr.so.0, libfrrcares.so.0, and the
# daemon plugins under modules/). The binaries reach them via RUNPATH, so they
# are not on the linker cache either — without the carve every FRR daemon dies
# at exec. Observed 2026-09-22 on both sdwan-test nodes after a reboot:
#
#   /usr/lib/frr/watchfrr: error while loading shared libraries:
#     libfrr.so.0: cannot open shared object file: No such file or directory
#
# and frr.service failed with result 'protocol' on every ibgp-mode node.
RSpec.describe "sdwan-overlay module manifest: FRR's private shared libraries are carved" do
  extension_root = File.expand_path("../../..", __dir__)
  manifest  = YAML.safe_load(File.read(File.join(extension_root, "modules", "sdwan-overlay", "manifest.yaml")))
  file_spec = Array(manifest["file_spec"]).map(&:to_s)

  carved = lambda do |path|
    file_spec.any? { |entry| entry == path || File.fnmatch(entry, path) }
  end

  it "still carves the FRR binaries (the oracle below is not vacuous)" do
    expect(carved.call("/usr/lib/frr/watchfrr")).to be(true)
    expect(carved.call("/usr/lib/frr/bgpd")).to be(true)
  end

  %w[
    /usr/lib/x86_64-linux-gnu/frr/libfrr.so.0
    /usr/lib/x86_64-linux-gnu/frr/libfrr.so.0.0.0
    /usr/lib/x86_64-linux-gnu/frr/libfrrcares.so.0
    /usr/lib/x86_64-linux-gnu/frr/modules/zebra_fpm.so
  ].each do |path|
    it "carves #{path}" do
      expect(carved.call(path)).to be(true),
        "no sdwan-overlay file_spec entry carves #{path}; FRR daemons fail to load it at exec"
    end
  end
end
