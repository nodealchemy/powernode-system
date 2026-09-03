# frozen_string_literal: true

require "rails_helper"

# IMP-f95b4efbdc44 — what system_gitops_apply_proposal ADVERTISES must match
# what System::Gitops::ApplyService actually APPLIES, kind by kind AND
# change-type by change-type.
#
# THE FINDING. The action description ended "v1 supports template/module/
# assignment kinds; destroy + provider_config remain follow-ups" while
# ApplyService#apply_diff dispatched FIVE kinds — template, module, assignment,
# pool, platform — with full create+update implementations for pool and
# platform. An agent holding an approved pool or platform proposal reads the
# description and concludes the verb cannot apply it, so a declarative
# instance-topology or replica-count change sits unapplied with no error
# anywhere (the same surface/executor split as IMP-4a3a45df69bc, pointing the
# other way: under-promise instead of over-promise).
#
# THE CAVEAT WAS WRONG THE SAME WAY. "destroy ... remain follow-ups" is false
# for assignments: apply_assignment's `when "destroy"` arm really destroys the
# TemplateModule join rows (apply_service.rb) and only template/module/pool/
# platform destroys raise UnsupportedDiffError. A fix that widened the kind list
# while keeping that clause would have re-committed the defect one clause to the
# right — an operator-approved assignment destroy reads as inapplicable.
#
# THE ORACLE IS THE DISPATCHER, NOT A LITERAL. Both halves are parsed out of
# ApplyService's source: the applicable kinds from #apply_diff's
# `return apply_<kind>(...) if kind == "<kind>"` arms, and each kind's destroy
# support from whether its own `when "destroy"` arm raises UnsupportedDiffError.
# Every assertion below is an EQUALITY (match_array) against that parse, so a
# sixth kind — or an implemented pool destroy — reddens this spec instead of
# silently re-opening the finding.
RSpec.describe Ai::Tools::SystemFleetTool, "GitOps apply advertised kinds (IMP-f95b4efbdc44)" do
  let(:description) do
    described_class.action_definitions.fetch("system_gitops_apply_proposal").fetch(:description)
  end

  let(:service_source) do
    ::System::Gitops::ApplyService # autoload before asking for the source path
    File.read(Object.const_source_location("System::Gitops::ApplyService").first)
  end

  let(:dispatch_body) do
    body = service_source[/def apply_diff\(.*?\n\s*end\n/m]
    expect(body).not_to be_nil, "ApplyService#apply_diff not found"
    body
  end

  # Kinds #apply_diff routes to a real apply_* implementation.
  let(:applied_kinds) do
    dispatch_body.scan(/return apply_(\w+)\(.*?\)\s+if kind == "(\w+)"/).map(&:last)
  end

  # Per-kind destroy support, read off each apply_<kind> method's own
  # `when "destroy"` arm: an arm that raises UnsupportedDiffError refuses,
  # anything else applies.
  let(:destroy_support) do
    applied_kinds.index_with do |kind|
      method_body = service_source[/^      def apply_#{kind}\(.*?^      end$/m]
      expect(method_body).not_to be_nil, "ApplyService#apply_#{kind} not found"
      arm = method_body[/^        when "destroy"$(.*?)^        (?:when |else$)/m]
      expect(arm).not_to be_nil, "apply_#{kind} has no `when \"destroy\"` arm"
      arm.include?("raise UnsupportedDiffError") ? :refused : :applied
    end
  end

  let(:destroy_applied) { destroy_support.select { |_k, v| v == :applied }.keys }
  let(:destroy_refused) { destroy_support.select { |_k, v| v == :refused }.keys }

  it "parses the service correctly (sanity: five applied kinds; assignment destroy is the implemented one)" do
    expect(applied_kinds).to include("pool", "platform")
    expect(applied_kinds.size).to be >= 5
    expect(destroy_applied).to eq(["assignment"])
    expect(destroy_refused).to match_array(%w[template module pool platform])
    # provider_config is routed to #informational — accepted, nothing written.
    expect(dispatch_body).to match(/return informational\(.*?\)\s+if kind == "provider_config"/)
  end

  it "names every kind the ApplyService applies" do
    missing = applied_kinds.reject { |kind| description.match?(/\b#{Regexp.escape(kind)}\b/) }
    expect(missing).to be_empty,
                       "description omits applicable kinds #{missing.inspect}: #{description.inspect}"
  end

  it "does not advertise a supported-kinds list that omits an applicable kind" do
    advertised = description[%r{supports ([a-z_/]+) kinds}, 1]
    expect(advertised).not_to be_nil, "description no longer states the supported kinds: #{description.inspect}"
    expect(advertised.split("/")).to match_array(applied_kinds)
  end

  it "advertises destroy support for exactly the kinds whose destroy arm is implemented" do
    advertised = description[%r{plus ([a-z_/]+) destroy}, 1]
    expect(advertised).not_to be_nil,
                             "description states no applied-destroy clause (`plus <kinds> destroy`): #{description.inspect}"
    expect(advertised.split("/")).to match_array(destroy_applied),
                                     "advertised applied-destroy kinds disagree with ApplyService: #{description.inspect}"
  end

  it "advertises destroy refusal for exactly the kinds whose destroy arm raises" do
    advertised = description[%r{([a-z_/]+) destroy returns an explicit not-yet-implemented error}, 1]
    expect(advertised).not_to be_nil,
                             "description states no refused-destroy clause: #{description.inspect}"
    expect(advertised.split("/")).to match_array(destroy_refused),
                                     "advertised refused-destroy kinds disagree with ApplyService: #{description.inspect}"
  end

  it "describes provider_config as informational rather than unimplemented" do
    expect(description).to match(/provider_config[^.]*informational/),
                           "provider_config diffs are accepted (no action taken), not a follow-up: #{description.inspect}"
    expect(description).not_to match(/destroy \+ provider_config remain follow-ups/)
  end
end
