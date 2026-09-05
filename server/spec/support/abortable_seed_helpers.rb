# frozen_string_literal: true

# Loads a seed that `abort`s on a failed assertion WITHOUT letting the abort
# take the rspec process with it.
#
# THE DEFECT THIS EXISTS FOR. The smoke seeds are straight-line scripts whose
# assertions end in Kernel#abort, i.e. SystemExit. rspec-support's
# AVOID_RESCUING (NoMemoryError, SignalException, Interrupt, SystemExit) means
# an example that lets SystemExit escape is not failed — it unwinds the
# runner, the process exits, and the reporter prints a clean summary of
# whatever had finished. CI run 1762's misc lane read "89 examples, 1 failure"
# with no load error and no "RSpec will now quit"; the suite collects 2172.
# One regressed seed hid every example scheduled after it, in every run, for
# as long as it was regressed. `--dry-run` cannot see this (collection is
# fine); only a real run does.
#
# `expect { load seed }.not_to raise_error` is NOT a guard: the matcher does
# not rescue SystemExit either. So every load of an abortable seed goes
# through here, and a SystemExit becomes a SeedAborted — an ordinary
# StandardError that fails its own example with the seed's own message and
# lets the rest of the run proceed. spec/lint/abortable_seed_load_guard_spec.rb
# is the ratchet that keeps a bare `load` from coming back.
module AbortableSeedHelpers
  # Carries what the SystemExit carried — the seed's own message and its exit
  # status — so a spec ABOUT a seed's failure path (example_honeypot_seed_spec)
  # can still assert on both without ever holding a SystemExit.
  class SeedAborted < StandardError
    attr_reader :status, :seed

    def initialize(message, status:, seed:)
      super(message)
      @status = status
      @seed = seed
    end
  end

  def load_abortable_seed!(path)
    load path
  rescue SystemExit => e
    raise SeedAborted.new(e.message, status: e.status, seed: File.basename(path.to_s))
  end
end

RSpec.configure { |c| c.include AbortableSeedHelpers }
