import { useEffect, useState, useCallback } from 'react';
import { bootReplayApi, type BootReplayResponse } from '../../../services/api/bootReplayApi';
import { logger } from '@/shared/utils/logger';

export interface UseBootReplayState {
  loading: boolean;
  data: BootReplayResponse | null;
  error: string | null;
  refresh: () => void;
}

export function useBootReplay(instanceId: string | null, correlationId?: string): UseBootReplayState {
  const [data, setData] = useState<BootReplayResponse | null>(null);
  const [loading, setLoading] = useState<boolean>(false);
  const [error, setError] = useState<string | null>(null);

  const fetchReplay = useCallback(async () => {
    if (!instanceId) return;
    setLoading(true);
    setError(null);
    try {
      const result = await bootReplayApi.fetch({ instance_id: instanceId, correlation_id: correlationId });
      setData(result);
    } catch (e) {
      const message = e instanceof Error ? e.message : 'Failed to load boot replay';
      logger.error('[useBootReplay] fetch failed', e);
      setError(message);
    } finally {
      setLoading(false);
    }
  }, [instanceId, correlationId]);

  useEffect(() => {
    fetchReplay();
  }, [fetchReplay]);

  return { loading, data, error, refresh: fetchReplay };
}
