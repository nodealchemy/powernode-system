# frozen_string_literal: true

require "rails_helper"

# IMP-24a25a083497 — the hub's Rails cache must be shared across processes.
#
# hub-backend's unit pinned CACHE_STORE=memory_store. MemoryStore lives inside
# one Ruby process, so every puma worker, every restart and every out-of-band
# `rails runner` started from an empty, private cache:
#
#   - RateLimiting counters were per process: the effective limit was the
#     configured limit times the number of processes, and a restart reset it.
#   - Powernode::CacheRedis found no Redis behind Rails.cache, so the admin
#     rate-limit stats were empty. (solid_cache does not change that: see the
#     note on the last example.)
#
# Operator decision (2026-10-19): solid_cache, the Postgres-backed store, behind
# the existing CACHE_STORE variable so a rollback is one line. That keeps cache
# writes out of the Redis AOF the queues depend on.
#
# HOW THE TWO PROCESSES ARE MODELLED. Two store instances built from the store
# name the hub deploys with are two puma workers: a MemoryStore keeps its
# entries in the instance, while two SolidCache stores read one table. Each
# "request" runs with Rails.cache pointed at one of them, so a store that is not
# shared shows up as a counter or a revocation that the other worker cannot see.
RSpec.describe "hub-backend Rails cache is shared across processes (IMP-24a25a083497)" do
  let(:module_dir) { Rails.root.join("../extensions/system/modules/powernode-hub-backend") }
  let(:manifest_text) { File.read(module_dir.join("manifest.yaml")) }
  let(:rails_start) { File.read(module_dir.join("rootfs/usr/local/bin/rails-start.sh")) }
  let(:rails_exec) { File.read(module_dir.join("rootfs/usr/local/bin/powernode-rails-exec")) }

  # The store puma runs with: the unit's own Environment= line.
  let(:hub_cache_store) do
    manifest_text[/^\s*Environment=CACHE_STORE=(\S+)$/, 1] || raise("hub-backend unit sets no CACHE_STORE")
  end

  let(:worker_a) { ActiveSupport::Cache.lookup_store(hub_cache_store.to_sym) }
  let(:worker_b) { ActiveSupport::Cache.lookup_store(hub_cache_store.to_sym) }

  # The test schema does not carry solid_cache_entries (it lives in the cache
  # database's own migrations). Create it with the migration production runs,
  # inside the example's transaction, so it rolls back with the example.
  before do
    if hub_cache_store == "solid_cache_store"
      require Rails.root.join("db/cache_migrate/20260904175500_create_solid_cache_entries.rb").to_s
      ActiveRecord::Migration.suppress_messages { CreateSolidCacheEntries.new.migrate(:up) }
    end
  end

  def as_worker(store)
    allow(Rails).to receive(:cache).and_return(store)
    yield
  end

  describe "the configured store" do
    it "is pinned explicitly to a store every process shares" do
      expect(hub_cache_store).to eq("solid_cache_store"),
        "hub-backend runs CACHE_STORE=#{hub_cache_store}; the operator chose solid_cache (shared, Postgres-backed)"
    end

    it "is the same for out-of-band rails (powernode-rails-exec mirrors the unit by hand)" do
      expect(rails_exec[/^export CACHE_STORE=(\S+)$/, 1]).to eq(hub_cache_store)
    end

    it "is not overridden by the persisted secrets file, which start scripts source after Environment=" do
      heredoc = rails_start[/cat > "\$SECRETS_FILE" <<EOF\n(.*?)\nEOF/m, 1] || raise("secrets heredoc not found")
      expect(heredoc).not_to match(/^CACHE_STORE=/)
    end

    it "has its backing table delivered by the db:migrate the start wrapper runs" do
      # The hub renders config/database.yml from the TRACKED example file
      # (rails-setup.sh), not from this checkout's local database.yml.
      example = YAML.safe_load(ERB.new(File.read(Rails.root.join("config/database.yml.example"))).result,
                               aliases: true)
      expect(example.dig("production", "cache", "migrations_paths")).to eq("db/cache_migrate")
      expect(Dir[Rails.root.join("db/cache_migrate/*_create_solid_cache_entries.rb")]).not_to be_empty
    end
  end

  describe "rate limits" do
    let(:controller_class) do
      Class.new(ActionController::API) do
        include RateLimiting

        attr_reader :limited

        def render_error(*, **)
          @limited = true
        end

        private

        def should_rate_limit? = true
        def rate_limit_key = "rate_limit:hub_cache_spec:203.0.113.7"
      end
    end

    # One request: the before_action check, then the post-request increment the
    # including controller performs. Returns true when the request was limited.
    def request_on(store)
      as_worker(store) do
        controller = controller_class.new
        controller.send(:check_and_increment_rate_limit)
        controller.send(:increment_rate_limit_count) unless controller.limited
        controller.limited == true
      end
    end

    it "counts attempts across workers, so the limit is not multiplied by the worker count" do
      max = controller_class.new.send(:rate_limit_max_attempts)
      allowed = Array.new(max) { |i| request_on(i.even? ? worker_a : worker_b) }
      expect(allowed).to all(be(false))

      expect(request_on(worker_a)).to be(true),
        "attempt #{max + 1} reached worker A unthrottled: under #{hub_cache_store} each worker " \
        "counted only its own share of the #{max} attempts"
      expect(request_on(worker_b)).to be(true)
    end
  end

  describe "the JWT blacklist" do
    # Pinned so the store switch cannot regress it, not because memory_store
    # broke it: Security::JwtBlacklistService uses Redis only when Rails.cache IS
    # a RedisCacheStore, and otherwise falls back to the jwt_blacklists table,
    # which every process shares. memory_store and solid_cache_store both take
    # that SQL path, so this is green under either; what memory_store cost here
    # was a SQL lookup per authenticated request, which solid_cache keeps.
    let(:user) { create(:user) }

    it "a token revoked in one worker is rejected by another" do
      jti = SecureRandom.uuid
      as_worker(worker_a) { Security::JwtBlacklistService.blacklist(jti, 15.minutes.from_now, user_id: user.id) }

      as_worker(worker_b) do
        expect(Security::JwtBlacklistService.blacklisted?(jti)).to be(true)
      end
    end

    it "a user-wide revocation in one worker rejects that user's older tokens in another" do
      issued_at = 1.minute.ago.to_i
      as_worker(worker_a) { expect(Security::JwtBlacklistService.blacklist_user_tokens(user.id)).to be(true) }

      as_worker(worker_b) do
        expect(Security::JwtBlacklistService.blacklisted?(SecureRandom.uuid, user_id: user.id, issued_at: issued_at))
          .to be(true)
      end
    end
  end
end
