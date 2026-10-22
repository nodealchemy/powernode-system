# frozen_string_literal: true

module System
  # System::SudoersGrant — a narrow, per-command sudoers entry owned by
  # a NodeModule that lets a specific ServiceUser invoke specific
  # absolute-path commands as root (or another ServiceUser). No broad
  # ALL=(ALL) ALL grants are ever permitted — the validation rejects
  # the literal token "ALL" anywhere in commands and requires every
  # entry to start with `/`.
  #
  # Rendered by the on-node agent into
  # /etc/sudoers.d/powernode-<module>-<grant_id> at mode 0440 root:root.
  # The agent runs `visudo -cf` on every file before atomic-rename so a
  # broken grant can't take sudo offline.
  #
  # Unlike ServiceUser/ServiceGroup, SudoersGrant has NO drain state.
  # Sudo is a runtime check with no persistent state; removing a grant
  # MUST be effective on the next reconcile tick. States are
  # active/removed only.
  class SudoersGrant < ApplicationRecord
    self.table_name = "system_sudoers_grants"

    STATES      = %w[active removed].freeze
    GRANT_ID_RX = /\A[a-z0-9_-]+\z/  # sudoers.d filename safe (no dots, no tildes)

    # What the on-node agent (etcsudoers.Grant.CheckFilename) accepts for EACH of
    # the module name and grant id in powernode-<module>-<id>, plus its cap on the
    # whole basename and the break-glass drop-in it will never let a grant replace.
    # GRANT_ID_RX above is the lowercase subset; the module name has no such
    # model-level rule, so the manifest import applies this one to it.
    FILENAME_COMPONENT_RX = /\A[a-zA-Z0-9_-]+\z/
    MAX_FILENAME_LENGTH   = 200
    BREAK_GLASS_FILENAME  = "powernode-operator-break-glass"

    belongs_to :node_module,  class_name: "System::NodeModule"
    belongs_to :service_user, class_name: "System::ServiceUser"

    validates :grant_id, presence: true,
                         format: { with: GRANT_ID_RX },
                         length: { maximum: 64 },
                         uniqueness: { scope: :node_module_id }
    validates :runas_user, presence: true, length: { maximum: 32 }
    validates :state, inclusion: { in: STATES }
    validate :commands_are_absolute_paths
    validate :commands_reject_all_keyword
    validate :fields_stay_in_their_slot

    scope :active,  -> { where(state: "active") }
    scope :removed, -> { where(state: "removed") }

    def mark_removed!
      update!(state: "removed")
    end

    def self.filename_for(module_name, grant_id)
      "powernode-#{module_name}-#{grant_id}"
    end

    def sudoers_filename(module_name)
      self.class.filename_for(module_name, grant_id)
    end

    private

    # IMP-01a0f109: runas, flags and every command are concatenated into one
    # sudoers rule; a newline or separator would add a second rule.
    def fields_stay_in_their_slot
      grammar = ::System::Identity::FieldGrammar
      [ [ :runas_user, runas_user ], [ :runas_group, runas_group ] ].each do |attr, v|
        next if v.nil?
        next if v.is_a?(String) && v.match?(::System::ServiceUser::USERNAME_RX)

        errors.add(attr, "must be a user/group name matching #{::System::ServiceUser::USERNAME_RX.inspect}")
      end
      unless flags.is_a?(Array)
        errors.add(:flags, "must be an array")
        return
      end
      flags.each_with_index do |f, i|
        err = grammar.sudo_flag_error(f)
        errors.add(:flags, "[#{i}] #{err}") if err
      end
      Array(commands).each_with_index do |c, i|
        err = grammar.sudo_command_error(c)
        errors.add(:commands, "[#{i}] #{err}") if err
      end
    end

    def commands_are_absolute_paths
      return if commands.is_a?(Array) && commands.all? do |c|
        c.is_a?(String) && c.start_with?("/")
      end
      errors.add(:commands, "must be an array of absolute paths starting with /")
    end

    # Sudo's `ALL` keyword in the command list grants permission to run
    # ANY command — exactly the broad grant this model exists to prevent.
    # Allow it only as part of a longer path (e.g. /opt/ALLEN-tool) but
    # never as a standalone token. Splitting on whitespace + checking
    # each shell-token catches `ALL`, `ALL,FOO`, and `command ALL` cases.
    def commands_reject_all_keyword
      Array(commands).each_with_index do |entry, i|
        next unless entry.is_a?(String)
        tokens = entry.split(/[\s,]+/)
        next unless tokens.include?("ALL")
        errors.add(:commands, "[#{i}] contains the literal token ALL (broad grants are forbidden)")
      end
    end
  end
end
