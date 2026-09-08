# frozen_string_literal: true

module System
  class NodeTemplate < BaseRecord
    include System::Base

    # How many assigned modules fold into embedding_text, and how much of each
    # module's description. A template with 60 modules would otherwise produce a
    # vector dominated by whichever modules happen to sort first; capping keeps
    # the input bounded and the signal spread across the composition.
    EMBEDDING_MODULE_LIMIT = 40
    EMBEDDING_MODULE_DESCRIPTION_LIMIT = 200
    EMBEDDING_DESCRIPTION_LIMIT = 2000

    # Enables `.nearest_neighbors(:embedding, vec, distance: "cosine")` via the
    # `neighbor` gem. Populated by System::CatalogEmbeddingBackfillService and
    # consumed by System::CatalogDiscoveryService (the reuse-first gate).
    has_neighbors :embedding

    # Associations
    belongs_to :account
    belongs_to :node_platform, class_name: "System::NodePlatform"
    # Which plane this template composes for (Environment campaign, incr. 1).
    # Core owns the noun; every fleet row hangs off the template's value.
    # ALWAYS present: a creator that says nothing gets the account's default
    # environment, so there is no template the gate cannot place. The refusals
    # are for the two ways a value can be WRONG — cleared after creation, or
    # borrowed from another account.
    belongs_to :environment, class_name: "Ai::Environment"
    has_many :nodes, class_name: "System::Node", dependent: :restrict_with_error

    # Module associations (Release 3)
    has_many :template_modules, class_name: "System::TemplateModule", dependent: :destroy
    has_many :node_modules, through: :template_modules

    # Validations
    validates :name, presence: true, uniqueness: { scope: :account_id }
    validate  :environment_belongs_to_account

    before_validation :inherit_default_environment, on: :create

    scope :in_environment, ->(env) { where(environment_id: env.is_a?(::Ai::Environment) ? env.id : env) }

    # Config accessors
    store_accessor :config

    # === Embedding scopes ===
    scope :with_embedding,    -> { where.not(embedding: nil) }
    scope :without_embedding, -> { where(embedding: nil) }
    # See System::NodeModule.embedding_stale. One caveat specific to templates:
    # embedding_text folds in the ASSIGNED MODULES' text, and editing a module
    # does not bump the template's updated_at — so a module rename leaves its
    # templates' vectors quietly stale. `FORCE=true` on the backfill is the
    # sanctioned way to reconcile that; it is not detectable from this scope.
    scope :embedding_stale, -> {
      where("system_node_templates.embedding IS NULL " \
            "OR system_node_templates.embedding_generated_at IS NULL " \
            "OR system_node_templates.embedding_generated_at < system_node_templates.updated_at")
    }

    # Composed once, here, so a re-embed campaign feeds the embedder identical
    # input for an unchanged row (same contract as System::Package#embedding_text).
    #
    # Composition: name + description + the assigned modules' names and
    # descriptions. The modules are load-bearing, not decoration: a template's
    # `description` column is nullable and in practice frequently blank, while
    # what the template is FOR is almost entirely determined by what it
    # composes — "web-stack" means nothing to an embedder, "nginx-proxy /
    # reverse proxy + redis-cache / in-memory cache" means everything. Platform
    # is excluded for the same reason as on NodeModule: a compatibility
    # constraint, not a purpose.
    #
    # One query for the modules (pluck), never one per module.
    def embedding_text
      rows = node_modules.order(:name).limit(EMBEDDING_MODULE_LIMIT).pluck(:name, :description)
      module_lines = rows.map do |mod_name, mod_description|
        summary = mod_description.to_s.truncate(EMBEDDING_MODULE_DESCRIPTION_LIMIT)
        summary.empty? ? mod_name.to_s : "#{mod_name} — #{summary}"
      end

      <<~TEXT.strip
        #{name}

        #{description.to_s.truncate(EMBEDDING_DESCRIPTION_LIMIT)}

        Modules: #{rows.map(&:first).join(', ')}
        #{module_lines.join("\n")}
      TEXT
    end

    # Virtual attribute set by pgvector's nearest_neighbors scope.
    def neighbor_distance
      self[:neighbor_distance]
    end

    private

    def inherit_default_environment
      return if environment_id.present? || account.nil?

      self.environment = ::Ai::Environment.default_for(account)
    end

    def environment_belongs_to_account
      return if environment.nil? || account_id.nil? || environment.account_id == account_id

      errors.add(:environment, "must belong to the template's account")
    end
  end
end
