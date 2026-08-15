# frozen_string_literal: true

module System
  # Compose-time prerequisite checks for provisioning plans (IMP 019fe647).
  # Registered as the core `Powernode::ExtensionRegistry.provider(
  # :provision_prerequisites)` so PlanComposerService can ask "can this
  # plan's skills actually run against this template?" WITHOUT naming
  # System:: — and surface the answer as a compose-time clarification
  # instead of a runtime step failure.
  #
  # First rule (dryrun 20260809c): overlay-requiring skills need the chosen
  # template to declare a live Sdwan::Network. The run's docker steps died at
  # runtime on 'no SDWAN peer with an assigned overlay address' when the
  # account had zero networks — every part of which was knowable here.
  module ProvisionPrerequisites
    module_function

    # Skills whose runtime requires the instance to hold an SDWAN overlay
    # address (DockerDaemonProvisioner binds the daemon to it by design).
    OVERLAY_REQUIRING_SKILLS = %w[docker_provision].freeze

    # Returns an array of human-readable issue strings; [] means the plan's
    # prerequisites are satisfied.
    #
    # `network_id` (IMP-94728a788498) carries the composer's OWN three-arm
    # resolution (template explicit → account default → networkless), so the
    # composer and this checker agree BY CONSTRUCTION — recomputing the
    # resolution here from the template alone would false-flag every
    # account-default plan ("declares no sdwan_network_id") and misread the
    # explicit "none" opt-out as a dead id. `nil` means the caller resolved
    # NOTHING for this plan. The `:unresolved` sentinel default preserves the
    # legacy template-only read for any caller that predates the kwarg.
    def check(account:, template_id:, skills:, network_id: :unresolved)
      overlay_skills = Array(skills).map(&:to_s) & OVERLAY_REQUIRING_SKILLS
      return [] if overlay_skills.empty?

      template = ::System::NodeTemplate.where(account_id: account.id).find_by(id: template_id)
      unless template
        return [ "#{overlay_skills.join(', ')} requires an SDWAN overlay, but the plan's " \
                 "template (#{template_id.inspect}) could not be resolved" ]
      end

      resolved = if network_id == :unresolved
        config = template.config.is_a?(Hash) ? template.config : {}
        config["sdwan_network_id"] || config[:sdwan_network_id]
      else
        network_id
      end

      if resolved.blank?
        return [ "#{overlay_skills.join(', ')} requires an SDWAN overlay, but no network resolves " \
                 "for this plan — set sdwan_network_id on template #{template.name.inspect} or " \
                 "default_sdwan_network_id in the account settings (an explicit \"none\" opt-out " \
                 "composes networkless deliberately, which these skills cannot run on)" ]
      end

      unless ::Sdwan::Network.where(account_id: account.id).exists?(id: resolved)
        return [ "the resolved SDWAN network #{resolved.inspect} (template " \
                 "#{template.name.inspect} or the account default) does not exist for this account" ]
      end

      []
    end
  end
end
