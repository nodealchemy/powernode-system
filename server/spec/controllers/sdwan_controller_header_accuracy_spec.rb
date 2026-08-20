# frozen_string_literal: true

require "rails_helper"

# IMP-0b9a99fec04a — two SDWAN controllers carried a header opening
# "Operator-facing read API … Read-only" while defining write verbs:
# host_bridges#destroy force-releases a bridge (skipping the draining grace
# window) and ipfix_collectors#update/#destroy toggle and delete a collector.
# A header that understates a controller's write surface misdirects exactly
# the person who most needs it right — someone auditing what can mutate.
#
# The drift had already recurred across two files, so this guards the CLASS
# rather than patching the two instances.
#
# WRITE-NESS IS READ FROM THE ROUTING TABLE, not from method names. A
# name-based check (`def create|update|destroy`) would have passed this very
# directory's custom write verbs — access_grants#revoke, user_devices#revoke,
# virtual_ips#failover — so a controller claiming read-only while offering
# only a custom POST would satisfy it. What makes an action a write is the
# HTTP verb routed to it, and that is what this reads.
RSpec.describe "SDWAN controller header accuracy" do
  # Controller key as Rails records it, e.g.
  # "api/v1/system/sdwan/host_bridges" -> ["destroy", "revoke"].
  let(:write_actions_by_controller) do
    Rails.application.routes.routes.each_with_object(Hash.new { |h, k| h[k] = [] }) do |route, acc|
      controller = route.defaults[:controller]
      action     = route.defaults[:action]
      next if controller.blank? || action.blank?
      next unless controller.start_with?("api/v1/system/sdwan/")

      # verb is "" for a route matching any method — treat that as a write,
      # since it admits POST/PATCH/DELETE.
      verb = route.verb.to_s
      next if verb == "GET"

      acc[controller] << action unless acc[controller].include?(action)
    end
  end

  let(:controller_files) do
    dir = Rails.root.join("../extensions/system/server/app/controllers/api/v1/system/sdwan")
    files = Dir.glob("#{dir}/*_controller.rb").sort
    raise "no SDWAN controllers found at #{dir}" if files.empty?

    files
  end

  # The contiguous comment block before the first `module`/`class` line — a
  # claim buried in a method comment is not the file's header.
  def header_comment(content)
    content.split(/^\s*(?:module|class)\b/).first.to_s
  end

  def controller_key(path)
    "api/v1/system/sdwan/#{File.basename(path, '_controller.rb')}"
  end

  it "does not let a controller claim read-only while routing a write verb" do
    offenders = controller_files.filter_map do |path|
      next unless header_comment(File.read(path)).match?(/read[\s\-_]?only/i)

      writes = write_actions_by_controller[controller_key(path)]
      next if writes.empty?

      "#{File.basename(path)} (routes writes: #{writes.sort.join(', ')})"
    end

    expect(offenders).to be_empty,
                         "these controllers claim read-only in their header but route write verbs — " \
                         "the header understates what can mutate:\n  #{offenders.join("\n  ")}"
  end

  # Non-vacuity: the guard is worthless if it reads no routes or no files. A
  # typo'd path or an engine whose routes never loaded would otherwise make
  # every example above pass by finding nothing to check.
  it "reads real controllers and a populated routing table" do
    expect(controller_files.size).to be >= 10

    expect(write_actions_by_controller).not_to be_empty,
                                               "no SDWAN write routes found — the routing table did not load, " \
                                               "so the guard above cannot fail for the right reason"
    # A known custom write verb, to prove the routing read catches actions a
    # create/update/destroy name-match would miss.
    expect(write_actions_by_controller["api/v1/system/sdwan/virtual_ips"]).to include("failover")
  end
end
