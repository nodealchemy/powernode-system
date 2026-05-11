# frozen_string_literal: true

class AddAutoResolvedToSystemNodeModuleAssignments < ActiveRecord::Migration[8.0]
  def change
    # `true` when this assignment was added by closure expansion (dep of an
    # operator-explicit module). `false` when the operator picked the module
    # explicitly via a TemplateModule.
    add_column :system_node_module_assignments, :auto_resolved, :boolean,
      null: false, default: false
    add_index  :system_node_module_assignments, :auto_resolved

    # Records which TemplateModule's recommends_override governed this
    # assignment's inclusion in the closure. Used by:
    #   - the on-node UI to explain "why is this module here?"
    #   - SystemPackageModuleRefreshJob to re-derive on template changes
    # NULL for assignments created outside the template-apply path.
    add_reference :system_node_module_assignments, :source_template_module,
      type: :uuid, null: true,
      foreign_key: { to_table: :system_template_modules, on_delete: :nullify }
  end
end
