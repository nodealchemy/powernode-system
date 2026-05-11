# frozen_string_literal: true

module System
  # Slice 7 — orchestrates pre-warmed instance pool operations.
  #
  # Three core operations:
  #   - acquire!  : atomically claim the oldest ready member (concurrency-safe)
  #   - replenish! : provision new instances to bring ready+warming up to target_size
  #   - drain!    : terminate ready members + halt replenishment
  #
  # All operations are idempotent and safe to retry. Atomic acquire uses
  # Postgres row-level locking (SELECT ... FOR UPDATE SKIP LOCKED) so
  # concurrent operators racing for the same pool member each get a
  # different instance (or NoReadyMembersError when the pool is empty).
  class InstancePoolService
    class PoolError < StandardError; end
    class NoReadyMembersError < PoolError; end
    class PoolNotActiveError < PoolError; end
    class PoolAtMaxCapacityError < PoolError; end
    class InvalidPoolStateError < PoolError; end

    # Maximum age (seconds) for a "warming" instance before the reaper
    # marks it errored. Provider boot + agent enrollment + module attach
    # should reach "running" + ready within ~10min for cloud, longer for
    # cold-boot physical. Bumping this on a per-pool basis is a future
    # extension via metadata["warming_timeout_seconds"].
    DEFAULT_WARMING_TIMEOUT_SECONDS = 1800 # 30 min

    # Maximum age (seconds) for a "ready" pool member before the reaper
    # recycles it. Prevents a stale member that's been ready for hours
    # from being acquired and immediately failing because some
    # underlying provider state expired (security group changed, IP
    # released, etc). Configurable per-pool via metadata.
    DEFAULT_READY_TTL_SECONDS = 4 * 3600 # 4 hours

    def self.acquire!(account:, pool_name: nil, pool_id: nil, lifecycle_class: nil)
      new(account: account).acquire!(
        pool_name: pool_name,
        pool_id: pool_id,
        lifecycle_class: lifecycle_class
      )
    end

    def self.replenish!(pool:)
      new(account: pool.account).replenish!(pool: pool)
    end

    def self.drain!(pool:)
      new(account: pool.account).drain!(pool: pool)
    end

    def self.recycle_stale_members!(pool:)
      new(account: pool.account).recycle_stale_members!(pool: pool)
    end

    def initialize(account:)
      @account = account
    end

    # Atomic acquire — claims the oldest ready pool member.
    # Concurrency-safe via SELECT ... FOR UPDATE SKIP LOCKED.
    #
    # Pool selection priority:
    #   1. Specific pool_id if provided
    #   2. Specific pool_name if provided
    #   3. Any active pool with matching lifecycle_class + ready members
    def acquire!(pool_name: nil, pool_id: nil, lifecycle_class: nil)
      pool = resolve_pool!(pool_name: pool_name, pool_id: pool_id, lifecycle_class: lifecycle_class)
      raise PoolNotActiveError, "pool '#{pool.name}' is #{pool.status}" unless pool.active? || pool.draining?

      ::ActiveRecord::Base.transaction do
        member = pool.node_instances
                     .where(pool_state: "ready")
                     .order(Arel.sql("pool_warming_started_at NULLS LAST"))
                     .lock("FOR UPDATE SKIP LOCKED")
                     .first

        raise NoReadyMembersError, "no ready members in pool '#{pool.name}' " \
                                   "(target=#{pool.target_size}, ready=#{pool.ready_count}, " \
                                   "warming=#{pool.warming_count}). Reaper will replenish." unless member

        member.update!(
          pool_state: "claimed",
          pool_acquired_at: Time.current
        )

        Rails.logger.info(
          "[InstancePoolService] acquired pool member " \
          "pool_id=#{pool.id} member_id=#{member.id} " \
          "ready_remaining=#{pool.ready_count} warming=#{pool.warming_count}"
        )

        member
      end
    end

    # Replenish — provision new NodeInstances to bring ready+warming
    # count up to target_size. Idempotent: if pool is already at
    # capacity, no-op.
    #
    # The actual provisioning is dispatched as worker jobs (one per
    # deficit slot) so this method returns quickly. Each job creates a
    # NodeInstance with pool_state="warming" + pool_warming_started_at
    # set; standard enrollment proceeds, and the after_save callback
    # transitions to "ready" once the instance is fully operational.
    def replenish!(pool:)
      raise PoolNotActiveError, "pool is paused" if pool.paused?

      deficit = pool.deficit
      return { provisioned: 0, deficit: 0 } if deficit.zero?

      ::ActiveRecord::Base.transaction do
        provisioned = []
        deficit.times do |i|
          instance = provision_warming_member!(pool: pool, slot_index: i)
          provisioned << instance
        end

        pool.update!(last_replenished_at: Time.current)

        Rails.logger.info(
          "[InstancePoolService] replenished pool '#{pool.name}' " \
          "deficit=#{deficit} provisioned=#{provisioned.size}"
        )

        { provisioned: provisioned.size, deficit: deficit, member_ids: provisioned.map(&:id) }
      end
    end

    # Drain — set pool to draining, terminate ready members. Claimed
    # members stay running until normal lifecycle terminate. Reaper
    # stops replenishing draining pools.
    def drain!(pool:)
      ::ActiveRecord::Base.transaction do
        pool.update!(status: "draining")

        terminated = []
        pool.ready_members.find_each do |member|
          member.update!(pool_state: "draining")
          terminated << member.id
        end

        Rails.logger.info(
          "[InstancePoolService] drained pool '#{pool.name}' " \
          "ready_terminated=#{terminated.size} claimed_remaining=#{pool.claimed_count}"
        )

        { drained: terminated.size, claimed_remaining: pool.claimed_count }
      end
    end

    # Recycle stale members — called by the reaper between replenishes.
    #   - warming members past warming_timeout → errored (provisioning got stuck)
    #   - ready members past ready_ttl → draining (stale, recycle for fresh state)
    #   - errored members → terminated (cleanup)
    def recycle_stale_members!(pool:)
      now = Time.current
      warming_timeout = pool.metadata["warming_timeout_seconds"]&.to_i ||
                        DEFAULT_WARMING_TIMEOUT_SECONDS
      ready_ttl = pool.metadata["ready_ttl_seconds"]&.to_i ||
                  DEFAULT_READY_TTL_SECONDS

      stale_warming = pool.warming_members
                          .where("pool_warming_started_at < ?", now - warming_timeout)
      stale_ready = pool.ready_members
                        .where("pool_warming_started_at < ?", now - ready_ttl)

      counts = { warming_to_errored: 0, ready_to_draining: 0 }

      ::ActiveRecord::Base.transaction do
        stale_warming.find_each do |m|
          m.mark_pool_errored!
          counts[:warming_to_errored] += 1
        end
        stale_ready.find_each do |m|
          m.update!(pool_state: "draining")
          counts[:ready_to_draining] += 1
        end
      end

      counts.values.sum.positive? &&
        Rails.logger.info("[InstancePoolService] recycled stale members in '#{pool.name}': #{counts}")

      counts
    end

    private

    attr_reader :account

    def resolve_pool!(pool_name:, pool_id:, lifecycle_class:)
      if pool_id
        pool = ::System::InstancePool.for_account(account).find_by(id: pool_id)
        raise PoolError, "pool_id=#{pool_id} not found in account #{account.id}" unless pool
        return pool
      end

      if pool_name
        pool = ::System::InstancePool.for_account(account).find_by(name: pool_name)
        raise PoolError, "pool '#{pool_name}' not found in account #{account.id}" unless pool
        return pool
      end

      # Fallback — pick any active pool with matching lifecycle_class
      # and ready members. Used when caller wants ANY ready instance
      # regardless of pool name.
      query = ::System::InstancePool.for_account(account).active
      query = query.where(lifecycle_class: lifecycle_class) if lifecycle_class
      query = query.joins(:node_instances).where(node_instances: { pool_state: "ready" })

      pool = query.first
      raise NoReadyMembersError, "no active pool with ready members " \
                                  "(lifecycle_class=#{lifecycle_class || 'any'})" unless pool
      pool
    end

    # Provisions a single warming member. The actual NodeInstance row
    # creation + cloud provider call happens in the worker via the
    # standard provisioning flow; this method just creates a stub
    # Node + NodeInstance with pool_state="warming" and dispatches the
    # provision job.
    def provision_warming_member!(pool:, slot_index:)
      # Step 1 — create the parent Node row. NodeInstance gets created
      # by ProvisioningService.provision_instance below; we don't
      # pre-create it because provision_instance always creates a
      # fresh row (calling it on an existing instance would either
      # double-up or no-op, neither of which is what we want).
      node = ::System::Node.create!(
        account: account,
        name: "#{pool.name}-pool-#{Time.current.to_i}-#{slot_index}",
        node_template: pool.node_template,
        lifecycle_class: pool.lifecycle_class,
        enabled: true,
        config: { "instance_pool_id" => pool.id }
      )

      # Step 2 — synchronously provision the cloud instance via the
      # canonical ProvisioningService path (the same path the MCP
      # `system_provision_instance` action uses; proven-working). This
      # returns when the libvirt/cloud VM is created + the
      # NodeInstance row is populated with cloud_instance_id + status.
      #
      # Why synchronous? The previous implementation dispatched to a
      # System::NodeInstanceProvisionJob worker job that:
      #   (a) had its method called wrong (.dispatch vs .enqueue)
      #   (b) expected node_id + operation_id args (an Operation
      #       record had to exist first); pool was sending
      #       node_instance_id + options hash
      #   (c) the queue 'system' wasn't even in the worker's listened
      #       queue list, so jobs accumulated forever in Redis
      # All three layers were broken; pool replenish has NEVER
      # actually provisioned cloud instances since pool support
      # landed. A synchronous direct call to ProvisioningService is
      # both correct and proven; the trade-off is replenish call
      # latency ≈ deficit × per-instance provisioning time
      # (~3-5s per cloud VM in our LocalQemu setup).
      result = ::System::ProvisioningService.provision_instance(
        node: node,
        provider_region_id: pool.provider_region_id,
        provider_instance_type_id: pool.provider_instance_type_id
      )

      unless result.success?
        Rails.logger.warn(
          "[InstancePoolService] cloud provision failed for pool '#{pool.name}' " \
          "slot=#{slot_index}: #{result.error}"
        )
        # Tear down the orphan Node so re-replenish doesn't accumulate
        # zombie nodes; the failure is propagated to the operator via
        # the result.error path.
        node.destroy
        raise PoolError, "cloud provision failed: #{result.error}"
      end

      # Step 3 — patch the freshly-created NodeInstance with the pool
      # tracking fields. ProvisioningService doesn't know about pools;
      # we apply pool_state/pool_warming_started_at/instance_pool_id
      # here so the pool's accounting (warming_count, ready_count,
      # deficit) is honest.
      instance = result.data[:instance]
      instance.update!(
        instance_pool_id: pool.id,
        pool_state: "warming",
        pool_warming_started_at: Time.current
      )

      instance
    end
  end
end
