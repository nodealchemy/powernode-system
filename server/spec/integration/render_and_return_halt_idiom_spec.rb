# frozen_string_literal: true

require "rails_helper"
require "tmpdir"

# IMP-ce5d320d3e4e — `render_error(...) and return` inside a PRIVATE HELPER is
# an authorization bypass, and it reads as correct.
#
# Rails halts a request when a *filter* renders: the filter chain checks
# `performed?` between callbacks and abandons the action. It does NOT halt an
# action because a helper the action called rendered. `and return` returns from
# the HELPER frame only; control resumes on the next line of the action and runs
# straight into whatever the helper was guarding. The second render raises
# ActionController::DoubleRenderError, which ApiResponse's rescue swallows via
# `unless performed?` — so the caller sees a clean 403 over a committed write
# and nothing in the response says otherwise.
#
# The DISCRIMINATOR this guard has to get right: the same idiom inside a method
# that IS registered as a before_action/around_action is fine, because there
# Rails really does halt — Api::V1::System::ProviderCredentialsController's
# `set_provider` relies on exactly that and must not trip this check. So a
# method is an offender only when it is BOTH below `private`/`protected` AND
# not registered as a filter in its own file. Public methods are actions, where
# `and return` returns from the action itself and is correct too.
#
# Scope is every api controller tree in the checkout (core + all extensions),
# not just this extension: the trap is a Rails-wide idiom, and a guard watching
# only its own tree would let the next controller anywhere else reintroduce it.
# One consequence worth naming: this submodule's suite therefore goes red on a
# file it does not own, and FIXING a baselined core site turns the stale-entry
# example red here until KNOWN_UNFIXED is pruned. That is the intended
# discipline, not a bug.
#
# IMP-563999967998 EXTENDED THIS GUARD to the sibling spelling: a bare
# `render_error(...)` with NO return at all. That form is strictly worse (there
# is not even a helper-frame return) and was the more common spelling here —
# Api::V1::System::Federation::ServiceOfferingsController's authorize_manage!
# rendered a bare 403 and #create went straight on to save the offering.
#
# It needs a DIFFERENT discriminator, because the helper body alone is
# ambiguous: several correct controllers pair a bare-render helper with a call
# site that consumes the outcome. So the second check is decided at the CALL
# SITE. A bare-render private non-filter helper is an offender only where it is
# invoked as a BARE STATEMENT (its value discarded) and the next line of code is
# not a control transfer. The correct shapes all pass:
#   peer = find_peer / return unless peer   — value-consuming call site
#   return unless validate_spawn_payload!   — value-consuming call site
#   authorize! then `return if performed?`  — explicit halt at the call site
# …as does a call whose next line is `end` / `else` / `when` / `rescue`, where
# nothing the helper was guarding can run after it (case-dispatch handlers such
# as Internal::DataDeletionRequestsController's approve_request are that shape).
#
# WHAT THIS GUARD STILL DOES NOT COVER — read before trusting a green run.
#   - A helper defined in one file (a concern) and called from another: both
#     halves of the discriminator are harvested per-file, so a cross-file pair
#     is invisible.
#   - A helper that renders only TRANSITIVELY, by calling another rendering
#     helper — only a literal `render*` in the body marks a helper.
#   - A call site that is not a BARE, ARGUMENT-LESS statement. `authorize!(:x)`,
#     `authorize_manage! unless current_worker`, and any parenthesised or
#     argument-bearing invocation are invisible, because the call-site match is
#     an exact-line match on the helper name. Widening it was tried and changed
#     the offender set across the whole checkout by more than this task could
#     validate, so it is named here rather than half-done.
#   - A helper registered as a before_action for SOME actions and also called
#     inline from others: the filter registration whitelists it wholesale.
#   - extensions/private/* is deliberately NOT scanned by this second check —
#     see the note above public_controller_roots.
#
# Known blind spots in the discriminator itself, all with the same escape
# hatch (KNOWN_UNFIXED, which demands a written reason):
#   - a helper registered as a before_action for SOME actions and also called
#     inline from others is whitelisted wholesale;
#   - a filter registered as a block/lambda (`before_action { authorize! }`)
#     or as a String rather than a Symbol is not recognized;
#   - `def`s inside `class << self` or a second class in the same file;
#   - the idiom inside a heredoc or string literal (only `#` comments are
#     skipped) — which is why this must never be pointed at spec/ or docs/.
RSpec.describe "render-and-return halt idiom (authorization bypass guard)" do
  # `render_error("nope", :forbidden) and return`, `render_success(...) and return`, …
  def idiom_regex       = /\brender[a-z_]*\s*\(.*\)\s+and\s+return\b/
  def def_regex         = /^\s*(private\s+|protected\s+|public\s+)?def\s+([a-zA-Z_][a-zA-Z0-9_]*[?!=]?)/
  def visibility_regex  = /^\s*(private|protected|public)\s*$/
  def filter_regex      = /^\s*(?:prepend_|append_)?(?:before|around|after)_action\b(.*)$/
  # Everything from the first option keyword on names ACTIONS, not the callback.
  def filter_opts_regex = /\b(?:only|except|if|unless|raise):/
  # `rescue_from Foo, with: :handler` — a handler is terminal (nothing runs
  # after it), so the idiom inside one is harmless and must not be flagged.
  def rescue_from_regex = /^\s*rescue_from\b.*\bwith:\s*:([a-zA-Z_][a-zA-Z0-9_]*[?!]?)/

  # Method names registered as callbacks in this file. Only the LEADING symbol
  # arguments name callbacks; `only: %i[show update]` lists actions, so
  # harvesting it would whitelist every action in the file.
  #
  # A registration may span lines — `before_action :a,\n              :b` is
  # common formatting for long filter lists — so a trailing comma carries the
  # harvest onto the next line. It stops at the first option keyword, because
  # everything from there on names actions rather than callbacks.
  def filter_methods(lines)
    acc = Set.new
    continuing = false

    lines.each do |line|
      if (m = line.match(rescue_from_regex))
        acc << m[1]
        next
      end

      segment =
        if (m = line.match(filter_regex))
          m[1]
        elsif continuing
          line
        end
      next if segment.nil?

      before_opts = segment.split(filter_opts_regex).first.to_s
      before_opts.scan(/:([a-zA-Z_][a-zA-Z0-9_]*[?!]?)/) { |(name)| acc << name }
      # Only a bare trailing comma continues the harvest; once an option
      # keyword appears, any continuation lines are option values (action
      # names), never callback names.
      continuing = before_opts == segment && segment.rstrip.end_with?(",")
    end

    acc
  end

  # Filters declared on the inheritance spine (ApplicationController and the
  # per-namespace BaseControllers). A subclass that OVERRIDES an inherited
  # filter — e.g. Api::V1::System::BaseController's `require_system_permission`,
  # whose own comment says "Override in subclasses" — registers it in a
  # DIFFERENT file, so a strictly per-file harvest would flag the override.
  # The spine declares a handful of authenticate_*/set_* names, none of them
  # authorization helpers, so unioning them whitelists nothing this guard
  # exists to catch.
  def spine_filter_methods
    @spine_filter_methods ||= controller_roots.flat_map { |root|
      Dir.glob(root.join("**", "{application_controller,*base_controller}.rb"))
    }.each_with_object(Set.new) { |path, acc| acc.merge(filter_methods(File.readlines(path))) }
  end

  def offenders_in(path)
    lines = File.readlines(path)
    filters = filter_methods(lines) | spine_filter_methods

    visibility = "public"
    current_def = nil
    hits = []

    lines.each_with_index do |line, idx|
      stripped = line.strip
      next if stripped.start_with?("#")

      if line.match?(visibility_regex)
        visibility = stripped
        next
      end
      if (m = line.match(def_regex))
        current_def = { name: m[2], visibility: m[1]&.strip || visibility }
        next
      end
      next unless line.match?(idiom_regex)
      next if current_def && current_def[:visibility] == "public"
      next if current_def && filters.include?(current_def[:name])

      hits << { path: path, line: idx + 1,
                method: current_def ? current_def[:name] : "(class body)",
                source: stripped }
    end

    hits
  end

  # Sites that are real instances of the idiom but sit OUTSIDE this change's
  # approved scope (IMP-ce5d320d3e4e was pinned to the two system-extension
  # controllers, and core lives in the parent repo, not this submodule). Keyed
  # by repo-relative path + method so it does not rot on a line shift.
  #
  # Discipline: an entry that no longer matches anything is a FAILURE, not a
  # silent pass — fixing the site means deleting its line here. Nothing is
  # allowed to sit on this list without a reason and an owner.
  KNOWN_UNFIXED = {
    "server/app/controllers/api/v1/ai/workspaces_controller.rb#find_workspace_conversation!" =>
      "core (parent repo), out of IMP-ce5d320d3e4e's pinned scope; 404-guard rather than " \
      "an authz bypass — queued as its own improvement"
  }.freeze

  def baseline_key(path, method_name)
    repo_root = Pathname.new(File.expand_path("../../../../..", __dir__))
    "#{Pathname.new(path).relative_path_from(repo_root)}##{method_name}"
  end

  def controller_roots
    repo_root = Pathname.new(File.expand_path("../../../../..", __dir__))
    ([ repo_root.join("server", "app", "controllers") ] +
      Pathname.glob(repo_root.join("extensions", "*", "server", "app", "controllers")) +
      Pathname.glob(repo_root.join("extensions", "private", "*", "server", "app", "controllers")))
      .select(&:directory?)
  end

  it "resolves the controller trees it claims to scan (the guard is not vacuous)" do
    roots = controller_roots.map(&:to_s)
    expect(roots).to include(a_string_matching(%r{/server/app/controllers\z}))
    expect(roots).to include(a_string_matching(%r{extensions/system/server/app/controllers\z}))
  end

  def all_offenders
    controller_roots.flat_map do |root|
      Dir.glob(root.join("**", "*.rb")).flat_map { |path| offenders_in(path) }
    end
  end

  it "never renders-and-returns from a non-filter helper" do
    offenders = all_offenders
      .reject { |h| KNOWN_UNFIXED.key?(baseline_key(h[:path], h[:method])) }
      .map { |h| "#{h[:path]}:#{h[:line]} in #{h[:method]} — #{h[:source]}" }

    expect(offenders).to be_empty, <<~MSG
      `render_...(...) and return` returns from the HELPER, not from the action —
      the action continues into whatever the helper was guarding, and the second
      render is swallowed as a DoubleRenderError. Raise instead (for permission
      checks: Authentication::PermissionDenied, which rescue_from turns into the
      canonical 403), or register the method as a before_action, where Rails
      really does halt.

      #{offenders.join("\n")}
    MSG
  end

  it "carries no stale baseline entries" do
    live = all_offenders.map { |h| baseline_key(h[:path], h[:method]) }
    stale = KNOWN_UNFIXED.keys - live

    expect(stale).to be_empty,
                     "KNOWN_UNFIXED names sites that no longer render-and-return. If you fixed " \
                     "them, delete their lines from KNOWN_UNFIXED — a baseline nobody prunes " \
                     "stops being a decision and becomes permission:\n#{stale.join("\n")}"
  end

  # The guard is only worth having if it can tell the two cases apart, so both
  # arms of the discriminator are exercised against synthesized files rather
  # than trusted by inspection.
  describe "the filter-vs-helper discriminator" do
    def offenders_for(body)
      Dir.mktmpdir do |dir|
        path = File.join(dir, "zz_guard_fixture_controller.rb")
        File.write(path, body)
        offenders_in(path)
      end
    end

    it "flags the idiom in a private non-filter helper" do
      offenders = offenders_for(<<~RB)
        class ZzGuardFixtureController < ApplicationController
          def create
            authorize_write!
            Thing.create!(name: "written anyway")
          end

          private

          def authorize_write!
            unless current_user.has_permission?("x")
              render_error("nope", :forbidden) and return
            end
          end
        end
      RB

      expect(offenders.map { |h| h[:method] }).to include("authorize_write!")
    end

    it "does not flag the idiom in a method registered as a before_action" do
      offenders = offenders_for(<<~RB)
        class ZzGuardFixtureController < ApplicationController
          before_action :set_provider, only: %i[create test]

          def create
            head :ok
          end

          private

          def set_provider
            if params[:provider_id].blank?
              render_error("provider_id is required", status: :bad_request) and return
            end
            @provider = Provider.find(params[:provider_id])
          end
        end
      RB

      expect(offenders).to be_empty
    end

    it "does not flag the idiom inside a public action, where it returns from the action" do
      offenders = offenders_for(<<~RB)
        class ZzGuardFixtureController < ApplicationController
          def create
            render_error("nope", :forbidden) and return
          end
        end
      RB

      expect(offenders).to be_empty
    end

    # P1 — `before_action :a,\n              :b` is ordinary formatting for a
    # long filter list. A line-anchored harvest sees only :a and flags :b.
    it "recognizes a callback named on a continuation line of the registration" do
      offenders = offenders_for(<<~RB)
        class ZzGuardFixtureController < ApplicationController
          before_action :set_thing,
                        :authorize_write!

          private

          def set_thing
            @thing = Thing.find(params[:id])
          end

          def authorize_write!
            render_error("nope", :forbidden) and return
          end
        end
      RB

      expect(offenders).to be_empty
    end

    # …but a continuation line AFTER an option keyword lists ACTIONS, so its
    # names must not be harvested as callbacks.
    it "still does not harvest action names from a wrapped only: list" do
      offenders = offenders_for(<<~RB)
        class ZzGuardFixtureController < ApplicationController
          before_action :set_thing, only: %i[show
                                             authorize_write]

          private

          def set_thing
            @thing = Thing.find(params[:id])
          end

          def authorize_write
            render_error("nope", :forbidden) and return
          end
        end
      RB

      expect(offenders.map { |h| h[:method] }).to include("authorize_write")
    end

    # P3 — a rescue_from handler is terminal; nothing runs after it.
    it "does not flag the idiom in a rescue_from handler" do
      offenders = offenders_for(<<~RB)
        class ZzGuardFixtureController < ApplicationController
          rescue_from ActiveRecord::RecordNotFound, with: :handle_missing

          private

          def handle_missing
            render_error("Not found", :not_found) and return
          end
        end
      RB

      expect(offenders).to be_empty
    end

    # P4 — an override of a filter registered in a PARENT controller file.
    it "does not flag an override of a filter declared on the inheritance spine" do
      offenders = offenders_for(<<~RB)
        class ZzGuardFixtureController < Api::V1::System::BaseController
          private

          def require_system_permission
            render_error("nope", :forbidden) and return
          end
        end
      RB

      expect(offenders).to be_empty
    end

    it "does not treat an only:-listed action name as a registered filter" do
      offenders = offenders_for(<<~RB)
        class ZzGuardFixtureController < ApplicationController
          before_action :set_pool, only: %i[show authorize_write]

          private

          def set_pool
            @pool = Pool.find(params[:id])
          end

          def authorize_write
            render_error("nope", :forbidden) and return
          end
        end
      RB

      expect(offenders.map { |h| h[:method] }).to include("authorize_write")
    end
  end

  # ══════════════════════════════════════════════════════════════════════
  # IMP-563999967998 — the BARE-RENDER form (no return at all).
  # ══════════════════════════════════════════════════════════════════════

  # `render_forbidden`, `render_error("x", status: :forbidden)`,
  # `render_success foo` — but NOT `rendered_at = Time.current`.
  def bare_render_regex = /^\s*render[a-z_]*(?:\s*\(|\s+[^=\s]|\s*$)/

  # A call site is harmless when the next line of code cannot fall through into
  # the guarded work: the end of the method or branch, the next arm of a
  # case/if, a rescue/ensure, or an UNCONDITIONAL control transfer.
  #
  # "Unconditional" matters. An earlier draft treated any leading `return` as
  # safe, which let the bug through one rewrite away from the real thing:
  #
  #   authorize_cancel!
  #   return render_error("conflict") if @subscription.terminal?
  #   @subscription.cancel!              # still reached by a refused caller
  #
  # A modifier `if`/`unless` on the transfer means control CAN continue, so it
  # is not a halt. `return if performed?` is the one conditional form that is a
  # halt — it is conditional on exactly the thing being checked — so it is
  # matched explicitly.
  def branch_end_regex = /\A(?:end\b|else\b|elsif\b|when\b|in\b|rescue\b|ensure\b|\}|\])/
  def performed_guard_regex = /\Areturn\s+if\s+performed\?/
  def unconditional_transfer_regex = /\A(?:return|next|break|raise)\b/

  def control_transfer?(line)
    return true if line.match?(branch_end_regex)
    return true if line.match?(performed_guard_regex)

    line.match?(unconditional_transfer_regex) && !line.match?(/\s(?:if|unless)\s/)
  end

  # Private/protected non-filter methods in this file whose body renders
  # directly. The `and return` spelling is excluded — it belongs to the example
  # above, and double-reporting one line would make both baselines rot together.
  def rendering_helpers(lines, filters)
    visibility = "public"
    current = nil
    found = Set.new

    lines.each do |line|
      stripped = line.strip
      next if stripped.start_with?("#")

      if line.match?(visibility_regex)
        visibility = stripped
        next
      end
      if (m = line.match(def_regex))
        current = { name: m[2], visibility: m[1]&.strip || visibility }
        next
      end
      next if current.nil?
      next if current[:visibility] == "public"
      next if filters.include?(current[:name])
      next unless line.match?(bare_render_regex)
      next if line.match?(idiom_regex)

      found << current[:name]
    end

    found
  end

  # The call-site half of the discriminator. Only a BARE STATEMENT call counts:
  # `peer = find_peer` and `return unless validate!` consume the helper's
  # outcome and are the correct shapes, so they are not call sites for this
  # purpose.
  def bare_render_call_offenders_in(path)
    lines = File.readlines(path)
    filters = filter_methods(lines) | spine_filter_methods
    helpers = rendering_helpers(lines, filters)
    return [] if helpers.empty?

    helpers.to_a.flat_map do |helper|
      call_regex = /\A#{Regexp.escape(helper)}(?:\(\))?\z/
      hits = []

      lines.each_with_index do |line, idx|
        stripped = line.strip
        next if stripped.start_with?("#")
        next unless stripped.match?(call_regex)

        j = idx + 1
        j += 1 while j < lines.size && (lines[j].strip.empty? || lines[j].strip.start_with?("#"))
        following = j < lines.size ? lines[j].strip : "end"
        next if control_transfer?(following)

        hits << { path: path, line: idx + 1, method: helper,
                  source: "#{stripped}  ->  #{following}" }
      end

      hits
    end
  end

  # This file is mirrored to a PUBLIC remote. A baseline entry is a literal
  # path, so baselining an offender inside extensions/private/* would print a
  # private extension's directory and method names into the public mirror —
  # exactly the leak spec/integration/private_extension_isolation_spec.rb
  # exists to prevent, and which it asks to be avoided by DERIVING the private
  # locations rather than naming them. So they are derived and excluded here.
  # Private extensions live in their own repositories and carry their own copy
  # of this guard; nothing about them is decided, or disclosed, in this file.
  def private_extension_root
    Pathname.new(File.expand_path("../../../../..", __dir__)).join("extensions", "private")
  end

  def public_controller_roots
    prefix = private_extension_root.to_s
    controller_roots.reject { |root| root.to_s.start_with?(prefix) }
  end

  def all_bare_render_call_offenders
    public_controller_roots.flat_map do |root|
      Dir.glob(root.join("**", "*.rb")).flat_map { |path| bare_render_call_offenders_in(path) }
    end
  end

  # Every call site of one helper in one file collapses to a single entry, so
  # the baseline stays readable; the cost, named here so nobody is surprised, is
  # that a NEW call site added to an already-listed helper is not caught.
  #
  # IMP-563999967998 was pinned to the two federation controllers. Everything
  # below is the SAME defect class, surfaced by generalizing this guard, and is
  # reported for its own improvement rather than swept in — a wider sweep is a
  # separate offer, and batch-fixing auto-discovered authorization sites is
  # exactly what the bulk-operation rule forbids.
  KNOWN_UNFIXED_BARE_RENDER = {
    "server/app/controllers/api/v1/ai/team_templates_reviews_controller.rb#authorize_code_reviews_read!" =>
      "core (parent repo), outside IMP-563999967998's pinned federation scope - queued",
    "server/app/controllers/api/v1/ai/team_templates_reviews_controller.rb#authorize_code_reviews_manage!" =>
      "core (parent repo); create_review_comment/update_review_comment write behind the 403 - queued",

    "extensions/marketing/server/app/controllers/api/v1/marketing/campaign_contents_controller.rb#authorize_read!" =>
      "marketing extension, outside this task's scope - queued",
    "extensions/marketing/server/app/controllers/api/v1/marketing/campaign_contents_controller.rb#authorize_manage!" =>
      "marketing extension; create/update/destroy/generate write behind the 403 - queued",
    "extensions/marketing/server/app/controllers/api/v1/marketing/campaign_contents_controller.rb#authorize_approve!" =>
      "marketing extension; approve!/reject! run behind the 403 - queued",
    "extensions/marketing/server/app/controllers/api/v1/marketing/campaigns_controller.rb#authorize_read!" =>
      "marketing extension, outside this task's scope - queued",
    "extensions/marketing/server/app/controllers/api/v1/marketing/campaigns_controller.rb#authorize_manage!" =>
      "marketing extension; create/update/destroy write behind the 403 - queued",
    "extensions/marketing/server/app/controllers/api/v1/marketing/campaigns_controller.rb#authorize_execute!" =>
      "marketing extension; campaign execution runs behind the 403 - queued",
    "extensions/marketing/server/app/controllers/api/v1/marketing/content_calendar_controller.rb#authorize_read!" =>
      "marketing extension, outside this task's scope - queued",
    "extensions/marketing/server/app/controllers/api/v1/marketing/content_calendar_controller.rb#authorize_manage!" =>
      "marketing extension; create/update/destroy write behind the 403 - queued",
    "extensions/marketing/server/app/controllers/api/v1/marketing/email_lists_controller.rb#authorize_read!" =>
      "marketing extension, outside this task's scope - queued",
    "extensions/marketing/server/app/controllers/api/v1/marketing/email_lists_controller.rb#authorize_manage!" =>
      "marketing extension; list + subscriber writes run behind the 403 - queued",
    "extensions/marketing/server/app/controllers/api/v1/marketing/social_media_accounts_controller.rb#authorize_read!" =>
      "marketing extension, outside this task's scope - queued",
    "extensions/marketing/server/app/controllers/api/v1/marketing/social_media_accounts_controller.rb#authorize_manage!" =>
      "marketing extension; account writes + adapter posts run behind the 403 - queued"
  }.freeze

  it "never calls a bare-render helper as a statement that falls through" do
    offenders = all_bare_render_call_offenders
      .reject { |h| KNOWN_UNFIXED_BARE_RENDER.key?(baseline_key(h[:path], h[:method])) }
      .map { |h| "#{h[:path]}:#{h[:line]} in #{h[:method]} - #{h[:source]}" }

    expect(offenders).to be_empty, <<~MSG
      A bare `render_...(...)` in a private helper does not halt anything: the
      helper simply returns and the action runs on into whatever the helper was
      guarding, with the second render swallowed as a DoubleRenderError. Either
      raise (for permission checks: Authentication::PermissionDenied, which
      rescue_from turns into the canonical 403), register the method as a
      before_action, or consume its outcome at the call site
      (`return if performed?`, or a truthy return value).

      #{offenders.join("\n")}
    MSG
  end

  it "carries no stale bare-render baseline entries" do
    live = all_bare_render_call_offenders.map { |h| baseline_key(h[:path], h[:method]) }
    stale = KNOWN_UNFIXED_BARE_RENDER.keys - live

    expect(stale).to be_empty,
                     "KNOWN_UNFIXED_BARE_RENDER names call sites that no longer fall through. " \
                     "If you fixed them, delete their lines - a baseline nobody prunes stops " \
                     "being a decision and becomes permission:\n#{stale.join("\n")}"
  end

  describe "the bare-render call-site discriminator" do
    def bare_offenders_for(body)
      Dir.mktmpdir do |dir|
        path = File.join(dir, "zz_guard_fixture_controller.rb")
        File.write(path, body)
        bare_render_call_offenders_in(path)
      end
    end

    it "flags a bare-render helper called as a statement before the guarded write" do
      offenders = bare_offenders_for(<<~RB)
        class ZzGuardFixtureController < ApplicationController
          def create
            authorize_manage!
            Thing.create!(name: "written anyway")
          end

          private

          def authorize_manage!
            return if current_user.has_permission?("x")
            render_error("Forbidden", status: :forbidden)
          end
        end
      RB

      expect(offenders.map { |h| h[:method] }).to include("authorize_manage!")
    end

    # The exemption that matters: core's Api::V1::Ai::WorkspacesController
    # renders bare from authorize_ai_conversations, and it is SAFE precisely
    # because it is a before_action, where Rails really does halt.
    it "does not flag a bare-render helper registered as a before_action" do
      offenders = bare_offenders_for(<<~RB)
        class ZzGuardFixtureController < ApplicationController
          before_action :authorize_ai_conversations

          def index
            authorize_ai_conversations
            render_success(things: [])
          end

          private

          def authorize_ai_conversations
            return if current_user.has_permission?("ai.conversations.read")
            render_forbidden
          end
        end
      RB

      expect(offenders).to be_empty
    end

    it "does not flag a call site paired with `return if performed?`" do
      offenders = bare_offenders_for(<<~RB)
        class ZzGuardFixtureController < ApplicationController
          def create
            authorize_manage!
            return if performed?

            Thing.create!(name: "guarded")
          end

          private

          def authorize_manage!
            return if current_user.has_permission?("x")
            render_error("Forbidden", status: :forbidden)
          end
        end
      RB

      expect(offenders).to be_empty
    end

    # The shape used correctly across the federation tree: the helper renders
    # AND reports, and the call site consumes what it reported.
    it "does not flag a value-consuming call site" do
      offenders = bare_offenders_for(<<~RB)
        class ZzGuardFixtureController < ApplicationController
          def create
            return unless validate_payload!

            peer = find_peer
            return unless peer

            Thing.create!(name: "guarded")
          end

          private

          def validate_payload!
            render_error("Missing fields", status: :bad_request)
            false
          end

          def find_peer
            peer = Peer.find_by(id: params[:peer_id])
            unless peer
              render_error("Peer not found", status: :not_found)
              return nil
            end
            peer
          end
        end
      RB

      expect(offenders).to be_empty
    end

    it "does not flag a case-dispatch handler, where nothing follows in the branch" do
      offenders = bare_offenders_for(<<~RB)
        class ZzGuardFixtureController < ApplicationController
          def update
            case params[:action_type]
            when "approve"
              approve_request
            when "reject"
              reject_request
            end
          end

          private

          def approve_request
            render_success(ok: true)
          end

          def reject_request
            render_success(ok: false)
          end
        end
      RB

      expect(offenders).to be_empty
    end

    it "does not flag a bare render inside a public action" do
      offenders = bare_offenders_for(<<~RB)
        class ZzGuardFixtureController < ApplicationController
          def create
            render_error("Forbidden", status: :forbidden)
          end
        end
      RB

      expect(offenders).to be_empty
    end

    it "does not mistake an assignment whose name starts with render for a render call" do
      offenders = bare_offenders_for(<<~RB)
        class ZzGuardFixtureController < ApplicationController
          def create
            stamp_render_time
            Thing.create!(name: "fine")
          end

          private

          def stamp_render_time
            rendered_at = Time.current
            @meta = { rendered_at: rendered_at }
          end
        end
      RB

      expect(offenders).to be_empty
    end
  end
end
