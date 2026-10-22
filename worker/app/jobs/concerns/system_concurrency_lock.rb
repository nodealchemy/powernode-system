# frozen_string_literal: true

# The concurrency lock the system extension's periodic jobs take so two runs
# never overlap: SET NX EX on acquire, and on release a token-checked
# compare-and-delete, so a run only ever deletes a lock it still holds
# (IMP-a9fa85399526).
#
# Each job used to release with a bare DEL in an `ensure`. A run whose lock had
# expired mid-call deleted the lock a newer run had since taken, and a run that
# was REFUSED the lock returned from inside that same `ensure`, so being refused
# deleted the current holder's lock. Both re-admitted the overlap the lock
# exists to prevent. Holding a token per key makes either release a no-op.
#
# The release script is the shared DistributedLock concern's, so both locks use
# one compare-and-delete, sent in the call form the Sidekiq 8 client accepts
# (see DistributedLock#release_lock for why `conn.eval(..., keys:, argv:)` is
# not that form).
#
# Keys and TTLs are unchanged: a job passes nothing and gets its
# CONCURRENCY_LOCK / LOCK_TTL_SEC constants, or names a key (per-resource
# locks).
module SystemConcurrencyLock
  private

  # @return [Boolean] true when this run now holds the lock
  def acquire_lock(key = self.class::CONCURRENCY_LOCK, ttl: self.class::LOCK_TTL_SEC)
    token = SecureRandom.hex(16)
    acquired = Sidekiq.redis { |c| c.set(key, token, nx: true, ex: ttl) }
    concurrency_lock_tokens[key] = token if acquired
    acquired ? true : false
  end

  # Deletes the lock only if it still carries this run's token. A run that
  # never acquired it holds no token and touches nothing.
  def release_lock(key = self.class::CONCURRENCY_LOCK)
    token = concurrency_lock_tokens.delete(key)
    return false unless token

    Sidekiq.redis { |c| c.call("EVAL", DistributedLock::RELEASE_SCRIPT, 1, key, token) } == 1
  rescue StandardError => e
    # Logged, not raised: the lock still expires by TTL. A silent rescue is what
    # hid DistributedLock's broken release call form for its whole life.
    log_warn("[ConcurrencyLock] release failed", key: key, error: e.message)
    false
  end

  def concurrency_lock_tokens
    @concurrency_lock_tokens ||= {}
  end
end
