# frozen_string_literal: true

module System
  # Registers and unregisters Ai::Skill rows for skills declared by node
  # modules in their manifest.yaml#skills: block. Powers Track F-4
  # "Module-as-Skill" — modules that ship AI capabilities (e.g.,
  # vector-db-mod ships a `semantic_search` skill against itself).
  #
  # Security tier handling: each registered skill carries the module's
  # signing tier (internal | verified-publisher | community) in its tags.
  # The platform's existing Ai::InterventionPolicy gates skill invocations
  # — community-tier skills default to require_approval per the security
  # architecture's "module-level security" section.
  #
  # Reference: Golden Eclipse plan F-4 Module-as-Skill.
  class ModuleSkillRegistrar
    Result = Struct.new(:ok?, :registered, :removed, :proposed, :error, keyword_init: true)

    SKILL_NAME_PREFIX = "module."

    def self.register_for_module!(node_module:)
      new.register_for_module!(node_module: node_module)
    end

    def self.unregister_for_module!(node_module:)
      new.unregister_for_module!(node_module: node_module)
    end

    def register_for_module!(node_module:)
      raise ArgumentError, "node_module required" unless node_module.is_a?(::System::NodeModule)

      manifest = parse_manifest(node_module)
      declared = Array(manifest["skills"])
      return Result.new(ok?: true, registered: 0, removed: 0, proposed: 0) if declared.empty?

      tier = signing_tier_for(node_module)
      registered = 0
      proposed = 0

      ActiveRecord::Base.transaction do
        declared.each do |entry|
          attrs = normalize_entry(entry, node_module, tier)

          # Trust-tier gate (Golden Eclipse plan F-4 security model):
          # community-tier skills go through Ai::SkillProposal so an
          # operator approves before they become callable. Internal +
          # verified-publisher tiers register directly.
          if tier == "community" && defined?(::Ai::SkillProposal)
            create_skill_proposal(attrs, node_module)
            proposed += 1
          else
            skill = ::Ai::Skill.find_or_initialize_by(slug: attrs[:slug])
            skill.assign_attributes(attrs.except(:slug))
            skill.account = node_module.account
            if skill.new_record? || skill.changed?
              skill.save!
              registered += 1
            end
          end
        end
      end

      Result.new(ok?: true, registered: registered, removed: 0, proposed: proposed)
    rescue ActiveRecord::RecordInvalid => e
      Result.new(ok?: false, error: e.record.errors.full_messages.join("; "),
                 registered: 0, removed: 0, proposed: 0)
    rescue StandardError => e
      Rails.logger.error("[ModuleSkillRegistrar] #{e.class}: #{e.message}")
      Result.new(ok?: false, error: e.message, registered: 0, removed: 0, proposed: 0)
    end

    def unregister_for_module!(node_module:)
      raise ArgumentError, "node_module required" unless node_module.is_a?(::System::NodeModule)

      slug_prefix = "#{SKILL_NAME_PREFIX}#{node_module.id}."
      # Use destroy_all (not delete_all) so dependent associations
      # (knowledge_graph_node has FK ai_skill_id with nullify rule, agent_skills
      # depend on destroy) cascade properly.
      removed = ::Ai::Skill.where(account: node_module.account).where("slug LIKE ?", "#{slug_prefix}%").destroy_all.size
      Result.new(ok?: true, registered: 0, removed: removed, proposed: 0)
    end

    private

    def create_skill_proposal(attrs, node_module)
      return unless defined?(::Ai::SkillProposal)
      proposal = ::Ai::SkillProposal.find_or_initialize_by(
        account: node_module.account,
        slug: attrs[:slug]
      )
      proposal.assign_attributes(
        name: attrs[:name],
        description: attrs[:description],
        category: attrs[:category],
        status: "proposed",
        commands: attrs[:commands],
        system_prompt: attrs[:system_prompt],
        tags: attrs[:tags],
        trust_tier_at_proposal: "community",
        metadata: {
          "module_id" => node_module.id,
          "rationale" => "Community-tier module skill registration. Module: #{node_module.name}. " \
                         "Approval grants the skill access to platform tools at the module's account scope."
        }
      )
      proposal.save! if proposal.new_record? || proposal.changed?
      proposal
    rescue ActiveRecord::RecordInvalid => e
      Rails.logger.warn("[ModuleSkillRegistrar] proposal create failed: #{e.message}")
      nil
    end

    # Parse manifest_yaml from the NodeModule (cached per M0 schema delta).
    # Returns {} on parse failure — silent so module attach doesn't break
    # because of authoring typos.
    def parse_manifest(node_module)
      raw = node_module.respond_to?(:manifest_yaml) ? node_module.manifest_yaml : nil
      return {} if raw.blank?
      YAML.safe_load(raw, permitted_classes: [ Symbol ]) || {}
    rescue Psych::SyntaxError => e
      Rails.logger.warn("[ModuleSkillRegistrar] manifest YAML parse failed for module #{node_module.id}: #{e.message}")
      {}
    end

    def signing_tier_for(node_module)
      # Cosign trust policy presence implies verified-publisher; otherwise
      # default to community. Internal tier is set by an explicit tag on
      # the module itself (M-MK-1 marketplace seeding).
      return "verified-publisher" if node_module.cosign_identity_regexp.present? && node_module.cosign_issuer_regexp.present?
      "community"
    end

    def normalize_entry(entry, node_module, tier)
      entry = entry.is_a?(Hash) ? entry.with_indifferent_access : { "name" => entry.to_s }

      name = entry["name"].to_s
      raise ArgumentError, "module skill name required" if name.blank?

      slug = "#{SKILL_NAME_PREFIX}#{node_module.id}.#{name.parameterize}"
      category = entry["category"].presence || "skill_management"

      {
        slug: slug,
        name: "#{node_module.name}::#{name}",
        description: entry["description"].presence || "Skill provided by node module #{node_module.name}",
        category: ::Ai::Skill::CATEGORIES.include?(category) ? category : "skill_management",
        status: "active",
        tags: [ "module-skill", "module:#{node_module.id}", "tier:#{tier}", *Array(entry["tags"]) ].uniq,
        commands: Array(entry["commands"]),
        system_prompt: entry["system_prompt"]
      }
    end
  end
end
