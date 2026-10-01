# frozen_string_literal: true

# System extension destroy guard for the core FileManagement::Storage model.
# Loaded by the PowernodeSystem engine via config.to_prepare decorator loading.
#
# system_storage_assignments.file_storage_id has no foreign key, and
# System::StorageAssignment#file_storage is a hand-written lookup rather than
# a belongs_to — so without this, destroying a storage neither cascades to nor
# is blocked by the assignments that mount it. They are left pointing at a
# missing row (#file_storage => nil) while their SMB users / NFS grants stay
# provisioned on the backend.
#
# Refuse, don't cascade: tearing an assignment down is an agent-side unmount
# plus a credential revoke, which a callback cannot do. The operator removes
# the assignments through their own pipeline first.
#
# A callback rather than `has_many ..., dependent: :restrict_with_error` so the
# error can name the count. It lives on the model, not in a controller, so it
# covers every destroy path — the storage delete endpoint and Account's
# `has_many :file_storages, dependent: :destroy` alike.
#
# EVERY assignment counts, whatever its status/enabled flag and whichever
# account it sits in: a disabled or failed row still owns storage_credentials
# and mount_encryption_keys, and would still be orphaned.
FileManagement::Storage.class_eval do
  before_destroy :refuse_destroy_with_storage_assignments

  private

  def refuse_destroy_with_storage_assignments
    count = ::System::StorageAssignment.where(file_storage_id: id).count
    return if count.zero?

    errors.add(
      :base,
      "Cannot delete storage with #{count} storage #{'assignment'.pluralize(count)}. " \
      "Remove the assignments first."
    )
    throw :abort
  end
end
