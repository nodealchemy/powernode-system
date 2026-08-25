# frozen_string_literal: true

module System
  # Removal of an operable must TRANSITION its tasks, never delete them.
  #
  # WHAT THIS REPLACES. Six models declared
  # `has_many :tasks, as: :operable, dependent: :destroy` — Node, NodeInstance,
  # Provider, ProviderNetwork, ProviderVolume, ProviderVolumeSnapshot. So
  # destroying any of them silently destroyed its task history, including tasks
  # still RUNNING: the row vanished mid-flight, with no terminal transition and
  # no record it had ever existed. Offer 01a03064-cc38 is exactly that — a task
  # observed running on 2026-08-15 with no surviving row in any status.
  #
  # A deleted task is worse than a failed one. `failed` says the platform tried
  # and something went wrong; absence says nothing happened at all, and no audit
  # can tell that apart from a period of genuine quiet. Task rows are the only
  # durable record of what the control plane did to a node.
  #
  # THE PROPERTY, stated so it does not depend on which model is removed:
  #
  #   No System::Task row may vanish, and none may be left non-terminal because
  #   its operable went away. Removal transitions its tasks and preserves which
  #   operable they belonged to.
  #
  # WHY A CONCERN. Fixing one model would leave five other ways to lose the same
  # history, and the next model to grow a tasks association would default back to
  # `dependent: :destroy` by copy-paste. One include carries the association, the
  # hook and the reasoning together.
  #
  # ORDERING IS LOAD-BEARING. `dependent: :nullify` is itself a before_destroy
  # callback registered when the association is declared, so the hook is
  # registered with `prepend: true` to guarantee it runs FIRST — otherwise the
  # operable pointer is already nil by the time we try to stamp it, and the
  # surviving rows would be anonymous.
  module PreservesTaskHistory
    extend ActiveSupport::Concern

    included do
      has_many :tasks, class_name: "System::Task", as: :operable, dependent: :nullify

      before_destroy :preserve_task_history!, prepend: true
    end

    private

    def preserve_task_history!
      reason = "operable removed: #{self.class.name} #{id}"

      tasks.find_each do |task|
        stamp_removed_operable!(task)
        terminate_task!(task, reason)
      rescue StandardError => e
        # One un-transitionable task must not block the removal — an operator
        # deleting an instance should not be held hostage by a row in an odd
        # state. The row still SURVIVES (nullify runs regardless), and if it was
        # left non-terminal, StuckTaskBacklogSensor raises it to an operator
        # within its window. Logged at error because a transition that cannot be
        # made is a real anomaly, not routine.
        Rails.logger.error(
          "[PreservesTaskHistory] could not terminate task #{task.id} while " \
          "destroying #{self.class.name} #{id}: #{e.class}: #{e.message}"
        )
      end
    end

    # Recorded BEFORE the pointer is nulled. Without it the surviving row says
    # something was cancelled but not what it belonged to, which is most of the
    # audit value.
    def stamp_removed_operable!(task)
      stamp = { "type" => self.class.name, "id" => id }
      stamp["name"] = name if respond_to?(:name) && name.present?

      task.update_columns(options: (task.options || {}).merge("removed_operable" => stamp))
    end

    # Terminal state chosen from the task's own state, matching the janitor's
    # rule: a task that never started is CANCELLED, because recording it as
    # failed would assert an execution that never happened.
    def terminate_task!(task, reason)
      case task.status
      when "running"                then task.fail!(reason)
      when "pending", "scheduled"   then task.cancel!(reason)
      end
    end
  end
end
