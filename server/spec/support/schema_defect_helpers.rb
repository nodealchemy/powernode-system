# frozen_string_literal: true

# Builds the error a missing table actually produces: an
# ActiveRecord::StatementInvalid whose CAUSE is PG::UndefinedTable. Both
# halves matter — System::DeployDefect classifies by the cause chain, so a
# bare StatementInvalid (which also wraps deadlocks and lock waits) must NOT
# read as a schema defect, and a bare PG error never reaches a rescue arm
# unwrapped. `cause` is only set by raising inside a rescue, hence the shape.
module SchemaDefectHelpers
  def schema_defect_error(relation = "system_fleet_signal_states")
    raise PG::UndefinedTable, "ERROR:  relation \"#{relation}\" does not exist"
  rescue PG::UndefinedTable
    begin
      raise ActiveRecord::StatementInvalid, "PG::UndefinedTable: ERROR:  relation \"#{relation}\" does not exist"
    rescue ActiveRecord::StatementInvalid => wrapped
      wrapped
    end
  end

  # A transient failure of the same wrapper class: what the fallback arms
  # exist for, and what must keep being swallowed.
  def transient_statement_error
    ActiveRecord::Deadlocked.new("PG::TRDeadlockDetected: deadlock detected")
  end
end

RSpec.configure { |c| c.include SchemaDefectHelpers }
