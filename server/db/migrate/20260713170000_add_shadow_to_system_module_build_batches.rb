# frozen_string_literal: true

# Campaign 019f5885 inc10 — dual-run shadow mode. A `shadow` batch is a
# native module-build run dispatched ALONGSIDE the Gitea-authoritative build
# (mode == "dual") purely to exercise the native path and gate the eventual
# cutover (inc11) on structural parity. Shadow batches:
#   - build against `:native-<sha>` OCI tags (never the Gitea `:<sha>` tag
#     the fleet actually consumes — see System::ModuleBuildTriggerService)
#   - publish with promote: false (System::ModulePublicationProcessor) so
#     NodeModule#current_version_id never moves off the Gitea-built version
#
# Kept as a plain boolean column (not folded into `trigger`, which already
# carries push|manual|cve) so the orchestrator/parity service can branch on
# it with a single indexed predicate rather than parsing metadata.
class AddShadowToSystemModuleBuildBatches < ActiveRecord::Migration[8.1]
  def change
    add_column :system_module_build_batches, :shadow, :boolean, null: false, default: false
    add_index :system_module_build_batches, :shadow
  end
end
