# frozen_string_literal: true

module System
  # Stores and serves the FULL scrubbed log of a task (IMP-dbc22946e05c).
  #
  # The agent keeps only a scrubbed tail of a build's output on the task's events;
  # it now also uploads the whole scrubbed log, which lands here. NO SECRETS IN
  # LOGS is a hard requirement, so this reuses the platform's one redactor
  # (System::StoredOutputRedactor over ShellOutputSanitizer) and applies it twice:
  #
  #   * at WRITE, before anything is stored and before any cut, so a secret
  #     sitting past the cap is gone from the stored copy too;
  #   * at READ, over the whole stored text before it is paged, so a redactor
  #     that learned a pattern after the row was written still covers it, and a
  #     secret split across a page boundary is redacted whole, never in halves.
  #
  # BOUNDED on every axis: MAX_BYTES stored per task (the END is kept, since the
  # cause of a failure is at the end; the truncation is stated in the row and in
  # every page), a RETENTION window after which a row is neither served nor kept
  # (expired rows of the same instance are pruned on every upload), and a page
  # size cap on the read.
  #
  # Offsets are byte offsets into the redacted-at-read text, always moved to a
  # character boundary, so a page never splits a UTF-8 character and a client
  # that follows next_offset reassembles the log exactly.
  module TaskLogStore
    MAX_BYTES = 1_048_576
    # Largest original_bytes an uploader may claim (a statement, never trusted for sizing).
    MAX_CLAIMED_BYTES = 1 << 40
    # The controller refuses a body larger than this before parsing it into the store.
    MAX_UPLOAD_BYTES = 2 * MAX_BYTES
    DEFAULT_PAGE_BYTES = 65_536
    MAX_PAGE_BYTES = 262_144
    DEFAULT_RETENTION_DAYS = 14
    RETENTION_SETTING = "system.task_log.retention_days"

    module_function

    # Redact, bound (keeping the end) and store. Replaces any earlier upload for
    # the task. original_bytes and truncated are the AGENT's own statement of
    # what it cut before uploading; they are only ever widened here, never
    # narrowed.
    def write!(task:, text:, original_bytes: nil, truncated: false, instance: nil)
      raw = text.to_s.dup.force_encoding(::Encoding::UTF_8).scrub("")
      claimed = decimal(original_bytes).to_i.clamp(0, MAX_CLAIMED_BYTES)
      original = [ claimed, raw.bytesize ].max
      # BOUND THE INPUT BEFORE REDACTING: the redactor's private-key pattern is
      # superlinear on a body of many BEGIN headers with no END, and this runs in a
      # request thread. Keep the END (the cause of a failure is there); the cut is
      # stated, because it is folded into truncated below.
      input_cap = MAX_BYTES + MAX_BYTES / 4
      pre_cut = raw.bytesize > input_cap
      raw = raw.b.byteslice(-input_cap, input_cap).force_encoding(::Encoding::UTF_8).scrub("") if pre_cut

      redacted = ::System::StoredOutputRedactor.bounded(raw, MAX_BYTES, from: :tail, inclusive: true)
      cut = redacted.start_with?(::System::StoredOutputRedactor::TAIL_MARKER)
      content, clipped = clamp_bytes(redacted)

      instance_id = instance&.id || (task.operable_id if task.operable_type == "System::NodeInstance")
      attrs = {
        account_id: task.account_id, node_instance_id: instance_id, content: content,
        byte_size: content.bytesize, original_bytes: original,
        truncated: truncated ? true : (cut || clipped || pre_cut),
        expires_at: retention_days.days.from_now
      }
      upsert!(task, attrs)
      prune_expired(instance_id)
    end

    # One bounded page, or nil when the task has no live stored log.
    def read_page(task:, offset: 0, limit: nil)
      row = ::System::TaskLog.live.find_by(task_id: task.id)
      return nil unless row

      text = ::System::StoredOutputRedactor.bounded(row.content, MAX_BYTES, from: :tail, inclusive: true)
      bytes = text.b
      total = bytes.bytesize

      start = [ decimal(offset).to_i, 0 ].max
      start = [ start, total ].min
      start += 1 while start < total && continuation?(bytes.getbyte(start))

      size = decimal(limit)
      size = DEFAULT_PAGE_BYTES unless size&.positive?
      size = [ size, MAX_PAGE_BYTES ].min

      stop = [ start + size, total ].min
      stop -= 1 while stop > start && stop < total && continuation?(bytes.getbyte(stop))
      # A single character wider than the page: take it whole rather than stall.
      if stop == start && start < total
        stop = start + 1
        stop += 1 while stop < total && continuation?(bytes.getbyte(stop))
      end

      {
        content: bytes.byteslice(start, stop - start).force_encoding(::Encoding::UTF_8).scrub(""),
        offset: start,
        next_offset: stop,
        has_more: stop < total,
        total_bytes: total,
        truncated: row.truncated,
        original_bytes: row.original_bytes,
        expires_at: row.expires_at.utc.iso8601
      }
    end

    def retention_days
      value = ::SiteSetting.get(RETENTION_SETTING).to_i
      value.positive? ? value : DEFAULT_RETENTION_DAYS
    end

    def upsert!(task, attrs)
      row = ::System::TaskLog.find_or_initialize_by(task_id: task.id)
      row.update!(attrs)
    rescue ::ActiveRecord::RecordNotUnique, ::ActiveRecord::RecordInvalid
      ::System::TaskLog.find_by!(task_id: task.id).update!(attrs)
    end

    # Every expired row, platform-wide: a module build runs on an ephemeral leased
    # builder that rarely uploads twice, so an instance-scoped sweep would never
    # reach its rows (and an instance's deletion nullifies its tasks' operable).
    # Bounded per call so one upload never pays for a large backlog.
    PRUNE_BATCH = 500

    def prune_expired(_instance_id = nil)
      ids = ::System::TaskLog.where("expires_at <= ?", Time.current).limit(PRUNE_BATCH).pluck(:id)
      ::System::TaskLog.where(id: ids).delete_all if ids.any?
    end

    # [text, clipped]: the END of text within MAX_BYTES, on a character boundary.
    # The character bound the redactor applies is not a byte bound.
    def clamp_bytes(text)
      return [ text, false ] if text.bytesize <= MAX_BYTES

      tail = text.b.byteslice(-MAX_BYTES, MAX_BYTES).force_encoding(::Encoding::UTF_8).scrub("")
      [ tail, true ]
    end

    # A strict base-10 integer from an Integer or a numeric string, else nil:
    # radix strings ("0x10", "010") and structures read as no value at all.
    def decimal(value)
      return value if value.is_a?(::Integer)
      return nil unless value.is_a?(::String)

      Integer(value, 10, exception: false)
    end

    def continuation?(byte)
      !byte.nil? && (byte & 0xC0) == 0x80
    end

    private_class_method :upsert!, :prune_expired, :clamp_bytes, :continuation?, :decimal
  end
end
