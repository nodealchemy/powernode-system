# frozen_string_literal: true

module System
  module Ai
    module Skills
      # Triage a CVE feed entry against the fleet — enumerate exposed instances
      # by SBOM/package match, score risk, and propose a remediation plan.
      #
      # v0 stub for SBOM matching: matches `affected_packages[].name` against
      # the module's name + each module artifact's sbom_uri presence. The real
      # SBOM-aware exposure calculator lands in M-D2-2 (CVE feed ingest +
      # exposure_calculator service); this executor's interface is stable so
      # the M-D2-2 calculator can be swapped in without changing callers.
      #
      # Reference: Golden Eclipse plan M6 — Skills catalog (cve_response row).
      class CveResponseExecutor < BaseSkillExecutor
        SEVERITY_WEIGHT = {
          "critical" => 100,
          "high"     => 60,
          "medium"   => 30,
          "low"      => 10
        }.freeze

        # Minimum risk score above which the executor recommends operator
        # confirmation before triggering rolling_module_upgrade. Tuned with
        # the medium=30 weight in mind: any single critical or any 2+ high-
        # severity exposures pushes us above this floor.
        AUTO_GATE_RISK_THRESHOLD = 50

        skill_descriptor(
          name: "cve_response",
          description: "Triage a CVE entry against the fleet — enumerates exposure, scores risk, proposes a remediation plan",
          category: "security",
          inputs: {
            cve_id: { type: "string", required: true,
                      description: "Canonical CVE id, e.g. CVE-2026-12345" },
            severity: { type: "string", required: true,
                        description: "critical|high|medium|low" },
            affected_packages: { type: "array", required: true,
                                 description: "[{name: 'openssl', version: '<3.1.4'}, ...]" },
            summary: { type: "string", required: false }
          },
          outputs: {
            cve_id: :string,
            severity: :string,
            risk_score: :integer,
            exposed_modules: [ :object ],
            exposed_instance_count: :integer,
            remediation_plan: :object,
            requires_approval: :boolean
          }
        )

        binds_to "CVE Responder"

        protected

        def perform(cve_id:, severity:, affected_packages:, summary: nil, persist: false)
          severity_norm = severity.to_s.downcase
          weight = SEVERITY_WEIGHT[severity_norm]
          return failure("severity must be one of: #{SEVERITY_WEIGHT.keys.join(', ')}") unless weight

          packages = Array(affected_packages).map { |p| p.is_a?(Hash) ? p.with_indifferent_access : { "name" => p.to_s } }
          return failure("affected_packages must contain at least one entry") if packages.empty?

          # Prefer persisted CveExposure rows if a Cve record exists for
          # this cve_id. Fall back to the keyword-overlap stub when there's
          # no DB record (e.g., transient/manual triage).
          exposed_modules, source = resolve_exposed_modules(cve_id, severity_norm, packages, summary, persist)
          exposed_instance_count = exposed_modules.sum { |m| m[:assignment_count].to_i }

          risk_score = compute_risk_score(weight, exposed_modules.size, exposed_instance_count)
          plan = build_plan(exposed_modules, severity_norm)

          success(
            cve_id: cve_id,
            severity: severity_norm,
            summary: summary,
            risk_score: risk_score,
            exposed_modules: exposed_modules,
            exposed_instance_count: exposed_instance_count,
            remediation_plan: plan,
            requires_approval: gate_for(severity_norm, risk_score),
            exposure_source: source,
            note: source == "persisted" ? "exposures from System::CveExposure rows" : "v0 keyword-overlap stub — persist via CveResponseExecutor#execute(..., persist: true)"
          )
        end

        private

        # Returns [exposed_modules, source_label]. Source = "persisted" when
        # System::CveExposure rows are read; "keyword_stub" otherwise.
        def resolve_exposed_modules(cve_id, severity, packages, summary, persist)
          cve_record = find_or_create_cve(cve_id, severity, packages, summary, persist)

          # Try to read persisted exposures.
          if cve_record
            calc = ::System::CveOps::ExposureCalculator.calculate!(cve: cve_record, account: @account)
            if calc.ok?
              exposures = ::System::CveExposure
                .where(cve: cve_record, state: %w[open remediating])
                .joins(node_module_version: :node_module)
                .where(system_node_modules: { account_id: @account.id })

              if exposures.any?
                rows = exposures.includes(node_module_version: :node_module).group_by { |e| e.node_module_version.node_module }
                return [
                  rows.map do |mod, exps|
                    {
                      module_id: mod.id,
                      name: mod.name,
                      matched_packages: exps.map(&:package_name).uniq,
                      assignment_count: mod.node_module_assignments.count,
                      current_version_id: mod.current_version_id,
                      exposure_ids: exps.map(&:id)
                    }
                  end,
                  "persisted"
                ]
              end
            end
          end

          # Fall through to the keyword stub.
          modules_resp = tool(::Ai::Tools::SystemFleetTool).execute(params: { action: "system_list_modules" })
          return [ [], "module_lookup_failed" ] unless modules_resp[:success]

          [ score_exposed_modules(modules_resp[:data][:modules], packages), "keyword_stub" ]
        end

        def find_or_create_cve(cve_id, severity, packages, summary, persist)
          return nil unless defined?(::System::Cve)

          existing = ::System::Cve.find_by(cve_id: cve_id)
          return existing if existing
          return nil unless persist

          ::System::Cve.create!(
            cve_id: cve_id,
            severity: severity,
            summary: summary,
            affected_packages: packages.map(&:to_h),
            feed_source: "manual"
          )
        rescue ActiveRecord::RecordInvalid => e
          Rails.logger.warn("[CveResponseExecutor] Cve persist failed: #{e.message}")
          nil
        end

        def score_exposed_modules(modules, packages)
          package_names = packages.map { |p| p["name"].to_s.downcase }.compact_blank
          Array(modules).filter_map do |m|
            haystack = "#{m[:name]} #{m[:gitea_repo_full_name]}".downcase
            matched = package_names.select { |pname| haystack.include?(pname) }
            next if matched.empty?

            mod_record = ::System::NodeModule.where(account: @account).find_by(id: m[:id])
            assignment_count = mod_record&.node_module_assignments&.count.to_i

            {
              module_id: m[:id],
              name: m[:name],
              matched_packages: matched,
              assignment_count: assignment_count,
              current_version_id: mod_record&.current_version_id
            }
          end
        end

        def compute_risk_score(weight, module_count, instance_count)
          return 0 if module_count.zero?

          # weight (10..100) * (1 + log10(instance_count + 1))
          # caps the contribution of fleet size while still differentiating
          # 1-instance from 100-instance exposures (≈3x multiplier).
          multiplier = 1 + Math.log10([ instance_count, 1 ].max + 1)
          (weight * multiplier).round
        end

        def build_plan(exposed_modules, severity)
          return { steps: [], reason: "no exposure detected" } if exposed_modules.empty?

          steps = []
          steps << {
            step: "rebuild_modules",
            module_ids: exposed_modules.map { |m| m[:module_id] },
            description: "Trigger module CI for each exposed module to produce a patched OCI artifact"
          }
          steps << {
            step: "rolling_upgrade",
            module_ids: exposed_modules.map { |m| m[:module_id] },
            batch_pct: severity == "critical" ? 25 : 10,
            description: "Once new versions are published+blessed, roll out across affected templates"
          }
          { steps: steps, ordering: "sequential" }
        end

        def gate_for(severity, risk_score)
          return true if severity == "critical"
          return true if severity == "high"
          risk_score >= AUTO_GATE_RISK_THRESHOLD
        end
      end
    end
  end
end
