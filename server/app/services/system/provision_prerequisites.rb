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
    def check(account:, template_id:, skills:)
      overlay_skills = Array(skills).map(&:to_s) & OVERLAY_REQUIRING_SKILLS
      return [] if overlay_skills.empty?

      template = ::System::NodeTemplate.where(account_id: account.id).find_by(id: template_id)
      unless template
        return [ "#{overlay_skills.join(', ')} requires an SDWAN overlay, but the plan's " \
                 "template (#{template_id.inspect}) could not be resolved" ]
      end

      config = template.config.is_a?(Hash) ? template.config : {}
      network_id = config["sdwan_network_id"] || config[:sdwan_network_id]
      if network_id.blank?
        return [ "#{overlay_skills.join(', ')} requires an SDWAN overlay; template " \
                 "#{template.name.inspect} declares no sdwan_network_id — instances would " \
                 "provision without an overlay address and the runtime step would fail" ]
      end

      unless ::Sdwan::Network.where(account_id: account.id).exists?(id: network_id)
        return [ "template #{template.name.inspect} declares sdwan_network_id " \
                 "#{network_id.inspect}, but that network does not exist for this account" ]
      end

      []
    end
  end
end
