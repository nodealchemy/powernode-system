import React, { useCallback, useEffect, useState } from 'react';
import {
  X,
  Network,
  MapPin,
  Calendar,
  Server,
  CheckCircle,
  XCircle,
  Plus,
  Edit2,
  Trash2
} from 'lucide-react';
import { Button } from '@/shared/components/ui/Button';
import { Badge } from '@/shared/components/ui/Badge';
import { LoadingSpinner } from '@/shared/components/ui/LoadingSpinner';
import { useNotifications } from '@/shared/hooks/useNotifications';
import { usePermissions } from '@/shared/hooks/usePermissions';
import { systemApi } from '@system/features/system/services/systemApi';
import { logger } from '@/shared/utils/logger';
import { SubnetFormModal } from './SubnetFormModal';
import type {
  SystemProviderNetwork,
  SystemProviderNetworkSubnet
} from '@system/features/system/types/system.types';

interface NetworkDetailModalProps {
  /** Network ID to display */
  networkId: string | null;
  /** Whether the modal is open */
  isOpen: boolean;
  /** Callback when modal is closed */
  onClose: () => void;
  /** Callback when network is updated */
  onNetworkUpdated?: () => void;
  /** Callback to edit the network */
  onEdit?: (network: SystemProviderNetwork) => void;
}

const statusVariants: Record<string, 'success' | 'warning' | 'danger' | 'secondary'> = {
  available: 'success',
  pending: 'warning',
  deleting: 'warning',
  deleted: 'secondary',
  error: 'danger'
};

/**
 * NetworkDetailModal - Modal showing network details
 */
export const NetworkDetailModal: React.FC<NetworkDetailModalProps> = ({
  networkId,
  isOpen,
  onClose,
  onNetworkUpdated: _onNetworkUpdated,
  onEdit
}) => {
  const { addNotification } = useNotifications();
  const { hasPermission } = usePermissions();

  const canUpdate = hasPermission('system.networks.update');
  // ProviderNetworkSubnetsController gates each verb on its own
  // system.networks.* permission, the same family as the network itself.
  const canCreateSubnets = hasPermission('system.networks.create');
  const canDeleteSubnets = hasPermission('system.networks.delete');

  // State
  const [network, setNetwork] = useState<SystemProviderNetwork | null>(null);
  const [loading, setLoading] = useState(true);
  const [subnets, setSubnets] = useState<SystemProviderNetworkSubnet[]>([]);
  const [subnetsLoading, setSubnetsLoading] = useState(false);
  const [subnetsTotal, setSubnetsTotal] = useState(0);
  const [showSubnetModal, setShowSubnetModal] = useState(false);
  const [editSubnet, setEditSubnet] = useState<SystemProviderNetworkSubnet | null>(null);
  /**
   * True once we know the owning provider has a connection. Left false when the
   * lookup fails or the payload carries no provider_id — the label is a claim
   * about the provider, so an unknown answer must not assert one.
   */
  const [providerHasConnection, setProviderHasConnection] = useState(false);

  // Fetch network
  useEffect(() => {
    const fetchNetwork = async () => {
      if (!networkId) return;

      try {
        const data = await systemApi.getNetwork(networkId);
        setNetwork(data);
      } catch (error) {
        addNotification({
          type: 'error',
          message: 'Failed to load network details'
        });
      } finally {
        setLoading(false);
      }
    };

    if (isOpen && networkId) {
      setLoading(true);
      fetchNetwork();
    }
  }, [isOpen, networkId, addNotification]);

  const refreshSubnets = useCallback(async () => {
    if (!networkId) return;
    setSubnetsLoading(true);
    try {
      const page = await systemApi.getNetworkSubnetsPage(networkId);
      setSubnets(page.subnets);
      setSubnetsTotal(page.total);
    } catch (error) {
      logger.error('[NetworkDetailModal] subnet load failed', error);
      addNotification({ type: 'error', message: 'Failed to load subnets' });
    } finally {
      setSubnetsLoading(false);
    }
  }, [networkId, addNotification]);

  /**
   * Run after a subnet WRITE, not on the initial load. The header count comes
   * from the network payload's subnet_count, so reloading only the list leaves
   * the header contradicting the rows until the modal is reopened. The initial
   * load already has a fresh network and must not fetch it twice.
   */
  const refreshAfterSubnetWrite = useCallback(async () => {
    if (!networkId) return;
    await refreshSubnets();
    try {
      setNetwork(await systemApi.getNetwork(networkId));
    } catch (error) {
      // Pass the MESSAGE, not the error: logger.warn JSON.stringify()s its
      // context, which on an AxiosError serialises the request headers.
      logger.warn('[NetworkDetailModal] network refresh after subnet write failed', {
        error: error instanceof Error ? error.message : String(error)
      });
    }
  }, [networkId, refreshSubnets]);

  useEffect(() => {
    if (isOpen && networkId) void refreshSubnets();
  }, [isOpen, networkId, refreshSubnets]);

  // Whether writing a subnet by hand is an override of a synced catalog. The
  // network payload carries provider_id; a connection on that provider means
  // sync_catalog owns these rows. Any failure leaves the flag false rather than
  // labelling a manual provider's subnets as an override.
  useEffect(() => {
    let cancelled = false;
    if (!isOpen || !network?.provider_id) {
      setProviderHasConnection(false);
      return;
    }
    systemApi
      .getProviderConnections()
      .then((all) => {
        if (cancelled) return;
        setProviderHasConnection(all.some((c) => c.provider_id === network.provider_id));
      })
      .catch((error) => {
        logger.warn('[NetworkDetailModal] provider connection lookup failed', {
          error: error instanceof Error ? error.message : String(error)
        });
      });
    return () => {
      cancelled = true;
    };
  }, [isOpen, network?.provider_id]);

  const handleDeleteSubnet = useCallback(
    async (subnet: SystemProviderNetworkSubnet) => {
      if (!networkId) return;
      try {
        await systemApi.deleteNetworkSubnet(networkId, subnet.id);
        addNotification({
          type: 'success',
          message: `Subnet "${subnet.name}" deleted successfully`
        });
        await refreshAfterSubnetWrite();
      } catch (error) {
        const errorMessage = error instanceof Error ? error.message : 'An error occurred';
        addNotification({
          type: 'error',
          message: `Failed to delete subnet: ${errorMessage}`
        });
      }
    },
    [networkId, addNotification, refreshAfterSubnetWrite]
  );

  // Reset on close
  useEffect(() => {
    if (!isOpen) {
      setNetwork(null);
      setSubnets([]);
      setSubnetsTotal(0);
      setShowSubnetModal(false);
      setEditSubnet(null);
      setProviderHasConnection(false);
    }
  }, [isOpen]);

  // Format date
  const formatDate = (dateString: string) => {
    return new Date(dateString).toLocaleDateString('en-US', {
      year: 'numeric',
      month: 'short',
      day: 'numeric',
      hour: '2-digit',
      minute: '2-digit'
    });
  };

  if (!isOpen) return null;

  return (
    <div className="fixed inset-0 z-50 overflow-y-auto">
      <div className="fixed inset-0 bg-black/50 transition-opacity" onClick={onClose} />

      <div className="flex min-h-full items-center justify-center p-4">
        <div className="relative w-full max-w-2xl bg-theme-surface rounded-lg shadow-xl">
          {/* Header */}
          <div className="flex items-center justify-between p-4 border-b border-theme">
            <div className="flex items-center gap-3">
              <Network className="w-6 h-6 text-theme-info-fg" />
              <div>
                <h2 className="text-lg font-semibold text-theme-primary">
                  {loading ? 'Loading...' : network?.name || 'Network Details'}
                </h2>
                {network && (
                  <div className="flex items-center gap-2 mt-1">
                    <Badge
                      variant={statusVariants[network.status] || 'secondary'}
                      size="sm"
                      dot
                      pulse={network.status === 'pending'}
                    >
                      {network.status}
                    </Badge>
                    {network.is_default && (
                      <Badge variant="info" size="sm">Default</Badge>
                    )}
                  </div>
                )}
              </div>
            </div>
            <Button variant="ghost" size="sm" onClick={onClose}>
              <X className="w-5 h-5" />
            </Button>
          </div>

          {/* Content */}
          <div className="p-6">
            {loading ? (
              <div className="flex items-center justify-center py-12">
                <LoadingSpinner size="lg" />
              </div>
            ) : network ? (
              <div className="space-y-6">
                {/* Basic Info */}
                <div className="grid grid-cols-2 gap-6">
                  <div className="space-y-4">
                    <div>
                      <label className="block text-sm text-theme-secondary mb-1">CIDR Block</label>
                      <p className="text-theme-primary font-mono text-lg">{network.cidr_block}</p>
                    </div>
                    <div>
                      <label className="block text-sm text-theme-secondary mb-1">Region</label>
                      <div className="flex items-center gap-2 text-theme-primary">
                        <MapPin className="w-4 h-4 text-theme-tertiary" />
                        {network.region_name || network.provider_region_id || '—'}
                      </div>
                    </div>
                  </div>
                  <div className="space-y-4">
                    <div>
                      <label className="block text-sm text-theme-secondary mb-1">DNS Resolution</label>
                      <div className="flex items-center gap-2">
                        {network.dns_support ? (
                          <>
                            <CheckCircle className="w-4 h-4 text-theme-success-fg" />
                            <span className="text-theme-success-fg">Enabled</span>
                          </>
                        ) : (
                          <>
                            <XCircle className="w-4 h-4 text-theme-tertiary" />
                            <span className="text-theme-tertiary">Disabled</span>
                          </>
                        )}
                      </div>
                    </div>
                    <div>
                      <label className="block text-sm text-theme-secondary mb-1">DNS Hostnames</label>
                      <div className="flex items-center gap-2">
                        {network.dns_hostnames ? (
                          <>
                            <CheckCircle className="w-4 h-4 text-theme-success-fg" />
                            <span className="text-theme-success-fg">Enabled</span>
                          </>
                        ) : (
                          <>
                            <XCircle className="w-4 h-4 text-theme-tertiary" />
                            <span className="text-theme-tertiary">Disabled</span>
                          </>
                        )}
                      </div>
                    </div>
                  </div>
                </div>

                {/* Description */}
                {network.description && (
                  <div>
                    <label className="block text-sm text-theme-secondary mb-1">Description</label>
                    <p className="text-theme-primary bg-theme-background rounded-lg p-3 border border-theme">
                      {network.description}
                    </p>
                  </div>
                )}

                {/* Subnets */}
                <div className="pt-4 border-t border-theme">
                  <div className="flex items-center justify-between mb-2">
                    <div className="flex items-center gap-2">
                      <Server className="w-4 h-4 text-theme-tertiary" />
                      <span className="text-theme-secondary">Subnets:</span>
                      <span className="text-theme-primary font-medium">
                        {network.subnet_count ?? subnets.length}
                      </span>
                    </div>
                    {canCreateSubnets && (
                      <Button
                        variant="outline"
                        size="sm"
                        onClick={() => {
                          setEditSubnet(null);
                          setShowSubnetModal(true);
                        }}
                        title={
                          providerHasConnection
                            ? 'Add subnet (manual override)'
                            : 'Add subnet'
                        }
                      >
                        <Plus className="w-4 h-4 mr-1" />
                        Add Subnet
                      </Button>
                    )}
                  </div>

                  {providerHasConnection && (
                    <p className="text-xs text-theme-warning-fg bg-theme-background rounded-lg p-3 border border-theme mb-2">
                      This network&apos;s provider has a cloud connection, so its subnets
                      are normally populated by Sync catalog. Writes here are a manual
                      override.
                    </p>
                  )}

                  {subnetsLoading ? (
                    <LoadingSpinner size="sm" />
                  ) : subnets.length === 0 ? (
                    <p className="text-sm text-theme-tertiary">No subnets in this network</p>
                  ) : (
                    <ul className="space-y-1">
                      {subnetsTotal > subnets.length && (
                        <li className="text-xs text-theme-warning-fg">
                          Showing {subnets.length} of {subnetsTotal} subnets — use the
                          API for the rest.
                        </li>
                      )}
                      {subnets.map(subnet => (
                        <li
                          key={subnet.id}
                          className="flex items-center justify-between gap-2 text-sm"
                          data-testid={`network-subnet-${subnet.id}`}
                        >
                          <span className="text-theme-primary">
                            {subnet.name}{' '}
                            <span className="font-mono text-theme-secondary">
                              {subnet.cidr_block}
                            </span>
                          </span>
                          <span className="flex items-center gap-2">
                            <Badge variant={subnet.is_public ? 'info' : 'secondary'} size="xs">
                              {subnet.is_public ? 'public' : 'private'}
                            </Badge>
                            {canUpdate && (
                              <Button
                                variant="ghost"
                                size="sm"
                                onClick={() => {
                                  setEditSubnet(subnet);
                                  setShowSubnetModal(true);
                                }}
                                title="Edit subnet"
                              >
                                <Edit2 className="w-4 h-4" />
                              </Button>
                            )}
                            {canDeleteSubnets && (
                              <Button
                                variant="ghost"
                                size="sm"
                                onClick={() => handleDeleteSubnet(subnet)}
                                title="Delete subnet"
                                className="text-theme-error-fg hover:text-theme-error-fg"
                              >
                                <Trash2 className="w-4 h-4" />
                              </Button>
                            )}
                          </span>
                        </li>
                      ))}
                    </ul>
                  )}
                </div>

                {/* Timestamps */}
                <div className="flex items-center gap-6 text-sm text-theme-tertiary pt-4 border-t border-theme">
                  <div className="flex items-center gap-1">
                    <Calendar className="w-4 h-4" />
                    Created: {formatDate(network.created_at)}
                  </div>
                  <div className="flex items-center gap-1">
                    <Calendar className="w-4 h-4" />
                    Updated: {formatDate(network.updated_at)}
                  </div>
                </div>
              </div>
            ) : (
              <div className="text-center py-12">
                <Network className="w-12 h-12 text-theme-tertiary mx-auto mb-4" />
                <p className="text-theme-secondary">Network not found</p>
              </div>
            )}
          </div>

          {/* Footer */}
          <div className="flex justify-end gap-3 p-4 border-t border-theme">
            <Button variant="outline" onClick={onClose}>
              Close
            </Button>
            {canUpdate && onEdit && network && (
              <Button variant="primary" onClick={() => onEdit(network)}>
                Edit Network
              </Button>
            )}
          </div>
        </div>
      </div>

      {networkId && (
        <SubnetFormModal
          networkId={networkId}
          subnet={editSubnet}
          isOpen={showSubnetModal}
          onClose={() => {
            setShowSubnetModal(false);
            setEditSubnet(null);
          }}
          onSaved={refreshAfterSubnetWrite}
          manualOverride={providerHasConnection}
        />
      )}
    </div>
  );
};

export default NetworkDetailModal;
