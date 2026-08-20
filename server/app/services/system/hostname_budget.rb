# frozen_string_literal: true

module System
  # Fits a generated name inside one DNS label (IMP-fd3397eef4b1).
  #
  # Names here are built as <variable middle><fixed tail>, where the tail
  # carries the uniqueness — a timestamp and a random suffix — and the middle
  # carries the meaning. When the two together outgrow a label, the middle is
  # what gives: truncating the tail would make two instances provisioned in the
  # same second for the same node collide on a column that is unique per node,
  # which is the exact failure the random suffix exists to prevent.
  #
  # WHY 63 AND NOT 64. The kernel's HOST_NAME_MAX is 64 and sethostname(2)
  # accepts that, but a hostname published as a single DNS label is bounded at
  # 63 (RFC 1035 §2.3.4). The agent already caps at 64 on apply
  # (etcidentity.ApplyHostname, "degrades to truncated-but-valid rather than a
  # failed apply"), so budgeting at 64 here would still hand DNS an illegal
  # label AND leave the platform's record disagreeing with the guest's by
  # nothing visible. 63 is the limit that makes both true at once.
  #
  # NOT a sanitiser: callers already build from parameterized parts, so this
  # only makes the length decision, in one place, rather than letting cloud-init
  # and the kernel each make a different one further downstream.
  module HostnameBudget
    # One DNS label, RFC 1035 §2.3.4.
    MAX_LABEL = 63

    # @param variable [String] the meaningful middle; truncated when needed.
    # @param fixed_tail [String] the uniqueness-bearing suffix; never touched.
    # @raise [ArgumentError] when the tail alone cannot fit. That is a caller
    #   bug rather than a runtime condition — every real tail here is ~19
    #   characters — and minting a name that is nothing but timestamp would
    #   hide it behind a plausible-looking string.
    def self.fit(variable:, fixed_tail:, max: MAX_LABEL)
      variable = variable.to_s
      fixed_tail = fixed_tail.to_s

      room = max - fixed_tail.length
      if room <= 0
        raise ArgumentError,
              "fixed tail #{fixed_tail.inspect} is #{fixed_tail.length} of #{max} characters — " \
              "nothing is left for the name itself"
      end

      head = variable.length <= room ? variable : variable[0, room]
      # A label may not end with a hyphen, and a blind cut lands on one whenever
      # the boundary falls there. Also covers a variable that already ended in
      # one, so the join never produces "--".
      "#{head.sub(/-+\z/, '')}#{fixed_tail}"
    end
  end
end
