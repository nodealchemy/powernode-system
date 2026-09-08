# frozen_string_literal: true

require "rails_helper"
require "yaml"

# Frontend/backend route parity for the system extension (IMP-f3e7f5d9d0cd).
#
# A one-off sweep found 0 frontend calls to a route that does not exist, and 76
# operator-facing routes with no UI caller at all. (That 76 counted verb+path pairs
# on the tree as it stood; this lint counts controller ACTIONS on today's tree, and
# the drain that followed the sweep wired a lot of them, so the two numbers are not
# meant to reconcile.) Nothing in the gate could see either direction, and they fail
# differently:
#
#   * a call to a renamed or removed route is a runtime 404 that no spec catches,
#     because the frontend suite mocks apiClient;
#   * a route no page calls is a capability an operator cannot reach — the gap
#     this whole drain existed to close — and it stays invisible forever.
#
# So both directions are checked, with different remedies. An unmatched CALL has
# no allowlist: it is always a defect. An uncalled ROUTE may be legitimate (a
# machine endpoint, an MCP-only verb, a UI that is still queued), so those live
# in route_parity_allowlist.yml WITH A REASON and an unlisted one fails. The list
# is the point: it turns "nothing calls this" from silence into a decision
# somebody wrote down and has to keep true.
#
# WHAT THIS CAN AND CANNOT SEE. The frontend is TypeScript and this is a Ruby
# lint, so call URLs are recovered by scanning, not by parsing. It resolves
# literals, template literals, module- and function-local `const` bindings, the
# `const base = (id) => `/system/x/${id}`` path-builder idiom, and ternaries
# between two literals. It CANNOT resolve a URL that arrives as a function
# parameter (`apiClient.post(endpoint, ...)`); those files are pinned by name in
# the allowlist's `unresolvable_call_files`, so a NEW blind spot fails here
# rather than quietly turning a wired route into a phantom gap.
#
# IT ALSO READS THE CORE FRONTEND TREE, because a few /system routes are called only
# from core pages (onboarding, the provisioning wizard, the mention picker). That
# couples this extension spec to a repo it does not pin: the extension's own CI checks
# core out at its floating default branch, so a core-side change that unwires a
# /system route turns this red on an unrelated extension PR. That failure is TRUE — an
# operator surface really did disappear — but it is found in the wrong repo, and the
# allowlist edit that answers it lands here while the cause lands there. Nothing
# asserts a set of core file names, precisely so a core rename cannot do the same for
# no reason at all.
#
# The allowlist sits beside this spec rather than at the path the approving
# direction named (extensions/system/spec/lint/): that directory does not exist,
# the extension's spec tree is rooted at server/spec, and the codebase precedent
# is a baseline yml beside its spec, read through __dir__ (core's
# server/spec/lint/no_bare_fact_baseline.yml).
module FrontendRouteParity
  # extensions/system/server/spec/lint -> repo root
  REPO_ROOT = File.expand_path("../../../../..", __dir__)
  ALLOWLIST_PATH = File.join(__dir__, "route_parity_allowlist.yml")

  # apiClient is `api` re-exported (frontend/src/shared/services/apiClient.ts),
  # and `api` is built with a "/api/v1" base, so the call literal
  # "/system/nodes" is the route "/api/v1/system/nodes".
  API_PREFIX = "/api/v1"

  # Both trees: a handful of /system calls live in core pages (onboarding, the
  # provisioning wizard, the agent conversation mention picker).
  FRONTEND_ROOTS = [
    File.join(REPO_ROOT, "extensions/system/frontend/src"),
    File.join(REPO_ROOT, "frontend/src")
  ].freeze

  # Namespaces that are not operator-facing: the agent on a node, the Sidekiq
  # worker, a federated peer, an inbound provider webhook, internal plumbing,
  # first-boot setup. None is meant to have a UI caller, so listing them would
  # bury the real gaps under 150 lines of noise.
  NON_OPERATOR_SEGMENTS = %w[node_api worker_api federation_api webhooks internal setup].freeze

  # `apiClient.get<Envelope<T>>('/system/x')`, `apiClient\n  .get('/system/x')`,
  # `apiClient.delete(BASE)`, `apiClient.post(base(id), body)`. The generic may
  # not contain a paren: with `.*?` there it happily ran from one call's verb to
  # a LATER call's argument, reporting a GET of a URL that only a POST ever used.
  CALL_RE = /
    \b(?:api|apiClient)\s*\.\s*(get|post|put|patch|delete)
    (?:<[^()]*>)?
    \(\s*
    (?:([`'"])(.*?)\2 | ([A-Za-z_][A-Za-z0-9_]*)\s*[,)(])
  /xm

  BINDING_RE = /\b(?:const|let|var)\s+([A-Za-z_][A-Za-z0-9_]*)\s*(?::[^=\n]*)?=/

  # Every place that LOOKS like a client call, matched loosely. CALL_RE is the
  # strict reader; anything this finds that CALL_RE did not is a call site the
  # scanner failed to parse rather than a call it decided to ignore. Without the
  # comparison such a site vanishes silently — and a dropped call turns a wired
  # route into a phantom gap in the allowlist, which is the failure mode with the
  # highest cost here. Both patterns start at the same token, so their match
  # offsets are directly comparable.
  CALL_SHAPE_RE = /\b(?:api|apiClient)\s*\.\s*(?:get|post|put|patch|delete)\s*[<(]/

  module_function

  # Comment lines become BLANK lines rather than disappearing, so reported line
  # numbers still point at the real source. Stripping them at all is deliberate:
  # a commented-out call is not a UI caller, and `//`-commenting a line is
  # exactly how a call gets hidden from a checker.
  def strip_comments(source)
    source
      .gsub(%r{/\*.*?\*/}m) { |block| "\n" * block.count("\n") }
      .lines.map { |line| line.strip.start_with?("//", "*") ? "\n" : line }.join
  end

  # Every string literal in a slice of source, as [offset, body]. Written as a
  # scanner rather than a regex because a template literal can contain another
  # template inside `${...}`; a regex splits that into three fragments, and one
  # of the fragments is an empty string that resolves to an empty path.
  def literals_in(source, from = 0, to = source.length)
    found = []
    i = from
    while i < to
      quote = source[i]
      unless ["'", '"', "`"].include?(quote)
        i += 1
        next
      end

      start = i
      i += 1
      body = +""
      depth = 0
      while i < to
        char = source[i]
        if char == "\\"
          body << char << source[i + 1].to_s
          i += 2
          next
        end
        if quote == "`" && char == "$" && source[i + 1] == "{"
          depth += 1
          body << "${"
          i += 2
          next
        end
        if quote == "`" && depth.positive?
          depth += 1 if char == "{"
          depth -= 1 if char == "}"
          body << char
          i += 1
          next
        end
        break if char == quote
        break if quote != "`" && char == "\n"

        body << char
        i += 1
      end
      i += 1
      found << [start, body]
    end
    found
  end

  # name => [[offset, [literal, ...]], ...]: every string literal on the
  # right-hand side of a binding. A list rather than one value because
  # `const url = cond ? '/system/a' : '/system/b'` reaches BOTH routes, and
  # because the same name is rebound in file after file (`const url = ...` twice
  # in one module) — the call site takes the NEAREST PRECEDING binding, so a
  # local rebinding shadows a module-level constant the way it does at runtime.
  # The whole list is expanded only where the identifier IS the argument; a
  # `${NAME}` INTERPOLATION substitutes the first literal, since one interpolation
  # cannot yield two paths. No two-branch binding is interpolated today.
  def bindings_in(source)
    bindings = Hash.new { |hash, key| hash[key] = [] }
    source.to_enum(:scan, BINDING_RE).each do
      match = Regexp.last_match
      rhs = match.end(0)
      stop = [(source.index(";", rhs) || (rhs + 300)), rhs + 300].min
      literals = literals_in(source, rhs, stop).map(&:last)
      bindings[match[1]] << [match.begin(0), literals] unless literals.empty?
    end
    bindings
  end

  # A template body becomes a route-shaped path: `${id}` is a parameter, a
  # `${BASE}` or `${base(id)}` is substituted and re-resolved, and a query string
  # is dropped. A `?` inside an interpolation is a ternary building an OPTIONAL
  # QUERY (`${qs ? `?${qs}` : ''}`), which ends the path just as a bare `?` does.
  def resolve(raw, lookup, depth = 0)
    out = +""
    i = 0
    while i < raw.length
      char = raw[i]
      if char == "?"
        break
      elsif char == "$" && raw[i + 1] == "{"
        nesting = 1
        j = i + 2
        while j < raw.length && nesting.positive?
          nesting += 1 if raw[j] == "{"
          nesting -= 1 if raw[j] == "}"
          j += 1
        end
        expression = raw[(i + 2)...(j - 1)].to_s.strip
        break if expression.include?("?")

        name = expression[/\A([A-Za-z_][A-Za-z0-9_]*)\s*(?:\(|\z)/, 1]
        substitution = (depth < 4 && name) ? lookup.call(name) : nil
        out << (substitution ? resolve(substitution, lookup, depth + 1) : ":param")
        i = j
      else
        out << char
        i += 1
      end
    end
    out
  end

  # Every dynamic segment flattens to :param so a route's parameter NAME cannot
  # make it look different from the call that reaches it.
  def normalise(path)
    path.sub(/\(\.:format\)\z/, "").sub(%r{/\z}, "").gsub(/:[A-Za-z_][A-Za-z0-9_]*/, ":param")
  end

  def system_path?(path)
    path.start_with?("/system/", "#{API_PREFIX}/system/") || ["/system", "#{API_PREFIX}/system"].include?(path)
  end

  def with_prefix(path)
    path.start_with?(API_PREFIX) ? path : "#{API_PREFIX}#{path}"
  end

  # One entry per operator-facing endpoint, carrying every verb that reaches the
  # SAME controller action at the same path. Rails' `resources` declares both
  # PATCH and PUT for #update; a frontend picks one. Keyed per verb, 42 of those
  # twins showed up as gaps that do not exist — and an allowlist that has to
  # absorb 42 non-gaps is where a real one goes to hide.
  def route_entries
    grouped = Hash.new { |hash, key| hash[key] = [] }
    Rails.application.routes.routes.each do |route|
      spec = route.path.spec.to_s
      next unless spec.start_with?("#{API_PREFIX}/system")

      verb = route.verb.to_s.upcase
      next if verb.empty?

      path = normalise(spec)
      next if (path.split("/") & NON_OPERATOR_SEGMENTS).any?

      defaults = route.defaults
      grouped[[path, "#{defaults[:controller]}##{defaults[:action]}"]] << verb
    end

    grouped.map do |(path, action), verbs|
      unique = verbs.uniq.sort
      { path: path, verbs: unique, action: action, key: "#{unique.join('|')} #{path}" }
    end
  end

  # Returns [calls, unresolvable], where a call is {verb:, path:, location:} and
  # an unresolvable is a call site whose URL this scanner could not recover.
  def frontend_calls
    calls = []
    unresolvable = []

    FRONTEND_ROOTS.select { |root| Dir.exist?(root) }.each do |root|
      Dir.glob(File.join(root, "**/*.{ts,tsx}")).reject { |f| f.match?(/\.(test|spec)\.tsx?\z/) }.sort.each do |file|
        source = strip_comments(File.read(file))
        bindings = bindings_in(source)
        relative = file.delete_prefix("#{REPO_ROOT}/")
        parsed_at = []

        source.to_enum(:scan, CALL_RE).each do
          match = Regexp.last_match
          verb = match[1].upcase
          literal = match[3]
          identifier = match[4]
          at = match.begin(0)
          parsed_at << at
          location = "#{relative}:#{source[0...at].count("\n") + 1}"
          lookup = ->(name) { (bindings[name] || []).select { |off, _| off < at }.max_by(&:first)&.last&.first }

          candidates = literal ? [literal] : ((bindings[identifier] || []).select { |off, _| off < at }.max_by(&:first)&.last || [])
          if candidates.empty?
            unresolvable << { file: relative, location: location, detail: "URL comes from #{identifier.inspect}" }
            next
          end

          candidates.each do |candidate|
            path = resolve(candidate, lookup)
            unless path.start_with?("/")
              unresolvable << { file: relative, location: location, detail: "URL starts with an unresolved #{candidate[0, 40].inspect}" }
              next
            end
            next unless system_path?(path)

            calls << { verb: verb, path: normalise(with_prefix(path)), location: location }
          end
        end

        source.to_enum(:scan, CALL_SHAPE_RE).each do
          at = Regexp.last_match.begin(0)
          next if parsed_at.include?(at)

          unresolvable << {
            file: relative,
            location: "#{relative}:#{source[0...at].count("\n") + 1}",
            detail: "call site the scanner could not parse at all"
          }
        end
      end
    end

    [calls, unresolvable]
  end

  # An unresolvable call site only matters where a /system URL could be hiding,
  # so it is judged per file: a file that never writes a /system URL literal is
  # not a place a system route can be wired.
  def files_with_system_urls
    @files_with_system_urls ||= FRONTEND_ROOTS.select { |root| Dir.exist?(root) }.flat_map do |root|
      Dir.glob(File.join(root, "**/*.{ts,tsx}")).select do |file|
        File.read(file).match?(%r{['"`]/(api/v1/)?system/})
      end.map { |file| file.delete_prefix("#{REPO_ROOT}/") }
    end.to_set
  end
end

RSpec.describe "frontend/backend route parity", type: :lint do
  let(:entries) { FrontendRouteParity.route_entries }
  let(:extracted) { FrontendRouteParity.frontend_calls }
  let(:calls) { extracted.first }
  let(:unresolvable) { extracted.last }
  let(:allowlist_file) { YAML.safe_load_file(FrontendRouteParity::ALLOWLIST_PATH) || {} }
  let(:allowlist) { allowlist_file.fetch("routes", {}) }
  let(:relative_allowlist) { FrontendRouteParity::ALLOWLIST_PATH.delete_prefix("#{FrontendRouteParity::REPO_ROOT}/") }

  def covered?(entry, calls)
    calls.any? { |call| call[:path] == entry[:path] && entry[:verbs].include?(call[:verb]) }
  end

  # Every assertion below is an emptiness check, and an extractor that returns
  # nothing satisfies all of them. These anchors are what makes the greens mean
  # something: a wholesale break leaves the counts plausible and the content
  # wrong, so specific known routes and calls are pinned by name.
  it "extracts both sides, so the emptiness checks below cannot pass vacuously" do
    expect(entries.size).to be > 300
    expect(calls.size).to be > 300
    expect(entries.map { |e| e[:key] }).to include(
      "GET /api/v1/system/nodes",
      "PATCH|PUT /api/v1/system/nodes/:param"
    )
    call_pairs = calls.map { |c| "#{c[:verb]} #{c[:path]}" }
    expect(call_pairs).to include(
      "GET /api/v1/system/nodes",                              # plain literal
      "GET /api/v1/system/platform/migration_chains",          # `const BASE` identifier
      "GET /api/v1/system/acme_dns_credentials/:param/zones",  # `${base(credId)}` path builder
      "GET /api/v1/system/platform/deployments/wizard",        # apiClient on its own line
      "GET /api/v1/system/marketplace"                         # query string dropped
    )
  end

  # DIRECTION 1 — no allowlist: an unmatched call is a 404 waiting to happen.
  it "has no frontend apiClient call to a route that does not exist" do
    unmatched = calls
                .reject { |call| entries.any? { |e| e[:path] == call[:path] && e[:verbs].include?(call[:verb]) } }
                .uniq { |call| [call[:verb], call[:path]] }
                .map { |call| "#{call[:verb]} #{call[:path]}  (#{call[:location]})" }

    expect(unmatched).to be_empty, <<~MSG
      #{unmatched.size} frontend call(s) target a route that does not exist. Each is a
      runtime 404 no spec can see, because the frontend suite mocks apiClient. Fix the
      URL or add the route — there is deliberately no allowlist for this direction:

      #{unmatched.sort.join("\n      ")}
    MSG
  end

  # DIRECTION 2 — allowlisted, because an uncalled route can be legitimate.
  it "has no operator-facing route without a UI caller outside the allowlist" do
    unlisted = entries.reject { |entry| covered?(entry, calls) }
                      .reject { |entry| allowlist.key?(entry[:key]) }
                      .map { |entry| "#{entry[:key]}   [#{entry[:action]}]" }

    expect(unlisted).to be_empty, <<~MSG
      #{unlisted.size} operator-facing route(s) have no frontend caller and are not listed
      in #{relative_allowlist}:

      #{unlisted.sort.join("\n      ")}

      A route an operator cannot reach from the UI is the gap this lint exists for. Wire
      it up, or add it to the allowlist WITH A REASON that says which it is: a machine
      endpoint, an MCP-only verb, a deliberate API-only surface, or a UI task still queued.
      Before you conclude "nothing calls this", check the call sites this lint cannot
      resolve — it is blind to a URL passed in as a parameter:

      #{unresolvable.map { |u| "#{u[:location]} — #{u[:detail]}" }.uniq.sort.join("\n      ")}
    MSG
  end

  # The list has to shrink as UI lands, or it becomes the place routes go to
  # hide. A stale entry is as much a defect as a missing one.
  it "carries no allowlist entry that is now wired, or that names a route that no longer exists" do
    keys = entries.map { |e| e[:key] }
    now_wired = entries.select { |entry| allowlist.key?(entry[:key]) && covered?(entry, calls) }.map { |e| e[:key] }
    vanished = allowlist.keys - keys

    expect(now_wired).to be_empty, <<~MSG
      #{now_wired.size} allowlist entr(y/ies) now HAVE a frontend caller. Delete them — an
      allowlist nobody prunes stops meaning "no UI for this yet":

      #{now_wired.sort.join("\n      ")}
    MSG

    expect(vanished).to be_empty, <<~MSG
      #{vanished.size} allowlist entr(y/ies) name a route that no longer exists (the path,
      the verbs, or the controller action changed). Delete or re-key them, or a future
      route that reuses the path inherits an exemption nobody chose:

      #{vanished.sort.join("\n      ")}
    MSG
  end

  it "gives every allowlist entry a reason" do
    unexplained = allowlist.reject { |_key, reason| reason.is_a?(String) && reason.strip.length > 20 }.keys

    expect(unexplained).to be_empty, <<~MSG
      #{unexplained.size} allowlist entr(y/ies) have no usable reason. The reason IS the
      value of this list — without one it is just a list of routes somebody silenced:

      #{unexplained.sort.join("\n      ")}
    MSG
  end

  # The scanner's own blind spot, pinned by file. A URL that arrives as a
  # function parameter cannot be recovered, and such a call makes a WIRED route
  # look like a gap — which is how a false reason ends up in the allowlist above.
  # Pinning the files by name means a new one fails here, where the fix is to
  # teach the scanner or to note the indirection, instead of silently widening
  # the list of phantom gaps.
  #
  # EXTENSION FILES ONLY. The core tree is scanned but not pinned: extension CI
  # floats core's default branch, so pinning core file names would turn extension
  # PRs red on a core rename that changes nothing here. A core indirection is
  # recorded on the allowlist entry for the route it reaches instead.
  it "pins the extension files whose call URLs this scanner cannot resolve" do
    known = allowlist_file.fetch("unresolvable_call_files", {}) || {}
    offenders = unresolvable.map { |u| u[:file] }.uniq
                            .select { |file| file.start_with?("extensions/") }
                            .select { |file| FrontendRouteParity.files_with_system_urls.include?(file) }

    expect(offenders.sort).to eq(known.keys.sort), <<~MSG
      The set of EXTENSION files that write a /system URL AND make an apiClient call
      this lint cannot resolve has changed.

        now:      #{offenders.sort.join(', ')}
        expected: #{known.keys.sort.join(', ')}

      A new entry here means a system call became invisible to the lint, so some route it
      reaches will show up as an uncalled gap that is not real. Either teach the scanner
      the shape, or add the file to `unresolvable_call_files` with a note naming the
      indirection. A removed entry just means the indirection is gone — drop the line.
    MSG
  end
end
