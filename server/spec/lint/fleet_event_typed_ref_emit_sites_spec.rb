# frozen_string_literal: true

require "rails_helper"
require "ripper"

# Every fleet event that names an instance, module or certificate in its
# payload also carries that id in the TYPED column (design §6, signals ruling).
#
# The component drawer's per-component signals view filters the signals
# endpoint by System::FleetEvent#node_instance_id / #node_module_id /
# #certificate_id, never by matching payload keys. A producer that bound its
# subject only inside `payload` is invisible to that filter: the drawer shows
# "no signals" for a component the feed is full of. Five producers did exactly
# that (three sdwan/storage sensors, the k8s cluster provisioner and the
# physical-device claim), so this guard is DERIVED from the tree, not a list.
#
# What it checks, per emit site, LEXED with Ripper (a comment or a string
# mention is not a site):
#
#   sites    System::Fleet::EventBroadcaster.emit!(...), FleetEvent.create!(...),
#            System::Fleet::Signal.new(...) and the BaseSensor `signal(...)`
#            helper inside a sensors directory.
#   subject  a literal payload key naming the event's own ref for one of the
#            three drawer columns: instance_id / node_instance_id,
#            module_id / node_module_id, certificate_id.
#   rule     the column is reached — by an explicit kwarg for that column, or
#            (for sites that go through the broadcaster) by a key the LIVE
#            mapper maps. The mapper is PROBED, not restated here, so a mapper
#            change is judged by what it does. FleetEvent.create! bypasses the
#            mapper and therefore needs the kwarg.
#
# KNOWN HOLES, recorded rather than pretended away:
#   * A payload built from a variable (a wrapper's `payload:` argument, a hash
#     assembled earlier) has no literal keys to read. Those sites are lexed,
#     not judged.
#   * A qualified key (failed_instance_id, caller_instance_id, cloud_instance_id,
#     failed_instance_ids) names a DIFFERENT role than the event's subject — a
#     cloud provider id, a list, the peer of a call — and is deliberately not a
#     subject key. Writing it into the column would bind the event to the wrong
#     component.
module FleetEventTypedRefEmitSites
  SERVER_ROOT = File.expand_path("../..", __dir__)

  SUBJECT_KEYS = {
    "instance_id" => :node_instance_id,
    "node_instance_id" => :node_instance_id,
    "module_id" => :node_module_id,
    "node_module_id" => :node_module_id,
    "certificate_id" => :certificate_id
  }.freeze

  Site = Struct.new(:file, :line, :shape, :kwargs, :payload_keys, keyword_init: true)

  module Scanner
    module_function

    def scan_source(source, file:)
      sexp = Ripper.sexp(source)
      return [] unless sexp

      sites = []
      walk(sexp, file, sites)
      sites
    end

    def walk(node, file, sites)
      return unless node.is_a?(Array)

      site = site_for(node, file)
      sites << site if site
      node.each { |child| walk(child, file, sites) }
    end

    # [:method_add_arg, [:call, recv, op, [:@ident, name, pos]] | [:fcall, [:@ident, name, pos]], args]
    def site_for(node, file)
      return unless node[0] == :method_add_arg && node[1].is_a?(Array)

      callee = node[1]
      shape =
        case callee[0]
        when :call
          name = ident_name(callee[3])
          recv = const_text(callee[1])
          if recv.end_with?("EventBroadcaster") && name == "emit!" then :broadcaster
          elsif recv.end_with?("FleetEvent") && %w[create! create new].include?(name) then :direct
          elsif recv.end_with?("Fleet::Signal") && name == "new" then :signal
          end
        when :fcall
          :signal if ident_name(callee[1]) == "signal" && file.include?("/sensors/")
        end
      return unless shape

      assocs = top_level_assocs(node[2])
      Site.new(
        file: file,
        line: first_line(callee),
        shape: shape,
        kwargs: assocs.filter_map { |a| key_name(a[1]) if a[0] == :assoc_new },
        payload_keys: payload_keys(assocs)
      )
    end

    def unwrap_args(args)
      args = args[1] if args.is_a?(Array) && args[0] == :arg_paren
      args = args[1] if args.is_a?(Array) && args[0] == :args_add_block
      args.is_a?(Array) ? args : []
    end

    def top_level_assocs(args)
      bare = unwrap_args(args).find { |x| x.is_a?(Array) && x[0] == :bare_assoc_hash }
      bare ? bare[1] : []
    end

    # nil when no payload is given; [] when given but not a literal.
    def payload_keys(assocs)
      pay = assocs.find { |a| a[0] == :assoc_new && key_name(a[1]) == "payload" }
      pay ? literal_keys(pay[2]) : nil
    end

    # Keys of a hash literal, also through `{...}.merge(...)` chains.
    def literal_keys(node)
      return [] unless node.is_a?(Array)

      case node[0]
      when :hash then node[1] ? assoc_keys(node[1][1]) : []
      when :bare_assoc_hash then assoc_keys(node[1])
      when :method_add_arg
        literal_keys(node[1]) + unwrap_args(node[2]).flat_map { |n| n.is_a?(Array) ? literal_keys(n) : [] }
      when :call then literal_keys(node[1])
      else []
      end
    end

    def assoc_keys(assocs) = Array(assocs).filter_map { |a| key_name(a[1]) if a[0] == :assoc_new }

    def key_name(key)
      return unless key.is_a?(Array)

      case key[0]
      when :@label then key[1].delete_suffix(":")
      when :string_literal, :symbol_literal, :dyna_symbol
        key.dig(1, 1, 1) if key.dig(1, 1, 0).in?(%i[@tstring_content @ident])
      end
    end

    def ident_name(node) = node.is_a?(Array) ? node[1] : nil

    def const_text(node)
      node.is_a?(Array) ? node.flatten.select { |x| x.is_a?(String) }.join("::") : ""
    end

    # The first [line, column] pair in the callee's position data.
    def first_line(node)
      node.flatten.each_cons(2).find { |a, b| a.is_a?(Integer) && b.is_a?(Integer) }&.first
    end
  end

  module_function

  def mapped_by_broadcaster?(key, column)
    uuid = SecureRandom.uuid
    System::Fleet::EventBroadcaster.send(:resource_refs_from_payload, { key => uuid })[column] == uuid
  end

  def violations_in(sites)
    sites.flat_map do |site|
      Array(site.payload_keys).filter_map do |key|
        column = SUBJECT_KEYS[key]
        next unless column
        next if site.kwargs.include?(column.to_s)
        next if %i[broadcaster signal].include?(site.shape) && mapped_by_broadcaster?(key, column)

        "#{site.file.sub("#{SERVER_ROOT}/", '')}:#{site.line} (#{site.shape}) payload \"#{key}\" never reaches #{column}"
      end
    end
  end

  def source_files
    Dir.glob(File.join(SERVER_ROOT, "{app,lib}", "**", "*.rb")).sort.select do |f|
      src = File.read(f)
      %w[EventBroadcaster FleetEvent Signal signal(].any? { |needle| src.include?(needle) }
    end
  end
end

RSpec.describe "FleetEvent typed entity refs at every emit site", type: :lint do
  let(:guard) { FleetEventTypedRefEmitSites }
  let(:source_files) { guard.source_files }
  let(:sites) { source_files.flat_map { |f| guard::Scanner.scan_source(File.read(f), file: f) } }

  it "reaches the typed column for every literal subject key at every emit site" do
    expect(guard.violations_in(sites)).to eq([])
  end

  # ── Presence floor: a moved tree or a broken glob must not pass vacuously ──
  it "lexes an emit site in every file that calls the broadcaster outside a comment" do
    callers = source_files.select do |f|
      File.readlines(f).any? { |l| l !~ /\A\s*#/ && l.include?("EventBroadcaster.emit!(") }
    end
    expect(callers.size).to be > 40

    lexed = sites.select { |s| s.shape == :broadcaster }.map(&:file).uniq
    expect(callers - lexed).to eq([])
  end

  it "sees the sensor signal helper sites" do
    expect(sites.count { |s| s.shape == :signal && s.file.include?("/sensors/") }).to be > 20
  end

  # ── Scanner oracles: the rule can fail, and fails for the right reason ─────
  describe "the scanner on synthetic sources" do
    def scan(src) = FleetEventTypedRefEmitSites::Scanner.scan_source(src, file: "/virtual/app/x.rb")

    it "flags a direct create! whose payload names the instance and passes no column" do
      src = %(::System::FleetEvent.create!(account: a, kind: "k", payload: { "node_instance_id" => i }))
      expect(guard.violations_in(scan(src)).size).to eq(1)
    end

    it "accepts the same create! once the column kwarg is passed" do
      src = %(::System::FleetEvent.create!(account: a, kind: "k", node_instance_id: i, payload: { "node_instance_id" => i }))
      expect(guard.violations_in(scan(src))).to eq([])
    end

    it "reads keys through a literal .merge chain" do
      src = %(::System::FleetEvent.create!(account: a, kind: "k", payload: { peer: p }.merge(certificate_id: c)))
      expect(guard.violations_in(scan(src)).size).to eq(1)
    end

    it "does not treat a qualified key as the subject" do
      src = %(::System::FleetEvent.create!(account: a, kind: "k", payload: { failed_instance_id: i, cloud_instance_id: c }))
      expect(guard.violations_in(scan(src))).to eq([])
    end

    it "does not count a comment or a string as a site" do
      src = <<~RUBY
        # ::System::FleetEvent.create!(account: a, payload: { "node_instance_id" => i })
        x = "::System::FleetEvent.create!(payload: { node_instance_id: i })"
      RUBY
      expect(scan(src)).to eq([])
    end

    it "judges a broadcaster site by the live mapper, not a list" do
      site = scan(%(::System::Fleet::EventBroadcaster.emit!(account: a, kind: "k", payload: { instance_id: i })))
      expect(site.size).to eq(1)
      expect(guard.violations_in(site)).to eq([])

      allow(System::Fleet::EventBroadcaster).to receive(:resource_refs_from_payload).and_return({})
      expect(guard.violations_in(site).size).to eq(1)
    end
  end
end
