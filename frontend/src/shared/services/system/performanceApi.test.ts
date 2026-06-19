/**
 * Behavioral tests for performanceApi.
 *
 * Covers every exported function: request shaping (exact URLs, payloads,
 * query params), error handling (API error extraction, network errors, generic
 * unknown errors), helper/pure-function logic (colors, formatting, validation),
 * and edge cases.
 *
 * Pattern: api.{get,post,put} resolves to an AxiosResponse whose body is the
 * full envelope { success, data?, message?, error? }. performanceApi returns
 * response.data directly, so the mock must be: { data: { success, data, ... } }.
 */

import { performanceApi } from './performanceApi';
import type {
  SystemMetrics,
  PerformanceSettings,
  PerformanceStats,
  PerformanceAlert,
  CacheStats,
  DatabaseStats,
  QueueStats,
  OptimizationAction,
} from './performanceApi';

// =============================================================================
// Mocks
// =============================================================================

const mockGet = jest.fn();
const mockPost = jest.fn();
const mockPut = jest.fn();

jest.mock('@/shared/services/api', () => ({
  api: {
    get: (...args: unknown[]) => mockGet(...args),
    post: (...args: unknown[]) => mockPost(...args),
    put: (...args: unknown[]) => mockPut(...args),
  },
}));

// =============================================================================
// Helpers & Fixtures
// =============================================================================

/**
 * Wrap a successful payload in the AxiosResponse shape that performanceApi
 * sees: response.data is the server envelope { success, data?, message? }.
 */
function envelope<T>(payload: T, extra: Record<string, unknown> = {}) {
  return { data: { success: true, data: payload, ...extra } };
}

function makeMetrics(overrides: Partial<SystemMetrics> = {}): SystemMetrics {
  return {
    id: 'metric-1',
    timestamp: '2026-06-05T00:00:00Z',
    cpu_usage: 45.2,
    memory_usage: 62.1,
    disk_usage: 30.5,
    network_io: { bytes_in: 1024, bytes_out: 512 },
    database_connections: 10,
    active_sessions: 5,
    queue_size: 3,
    response_time_avg: 120.5,
    error_rate: 0.01,
    ...overrides,
  };
}

function makeSettings(overrides: Partial<PerformanceSettings> = {}): PerformanceSettings {
  return {
    cache_enabled: true,
    cache_ttl: 3600,
    max_connections: 100,
    query_timeout: 30,
    rate_limiting_enabled: true,
    compression_enabled: true,
    cdn_enabled: false,
    database_pool_size: 25,
    worker_processes: 4,
    log_level: 'info',
    monitoring_enabled: true,
    alert_thresholds: {
      cpu_threshold: 85,
      memory_threshold: 90,
      disk_threshold: 95,
      error_rate_threshold: 0.05,
      response_time_threshold: 500,
    },
    ...overrides,
  };
}

function makeAlert(overrides: Partial<PerformanceAlert> = {}): PerformanceAlert {
  return {
    id: 'alert-1',
    type: 'cpu',
    severity: 'high',
    message: 'CPU usage exceeds threshold',
    value: 92.5,
    threshold: 85,
    triggered_at: '2026-06-05T00:00:00Z',
    status: 'active',
    ...overrides,
  };
}

function makeCacheStats(overrides: Partial<CacheStats> = {}): CacheStats {
  return {
    total_keys: 1500,
    hit_rate: 0.92,
    miss_rate: 0.08,
    memory_usage: 256 * 1024 * 1024,
    evictions: 12,
    expired_keys: 45,
    operations_per_second: 2500,
    ...overrides,
  };
}

function makeDatabaseStats(overrides: Partial<DatabaseStats> = {}): DatabaseStats {
  return {
    active_connections: 8,
    max_connections: 100,
    slow_queries: 2,
    avg_query_time: 15.3,
    deadlocks: 0,
    table_locks: 1,
    index_usage: 0.95,
    cache_hit_ratio: 0.98,
    ...overrides,
  };
}

function makeQueueStats(overrides: Partial<QueueStats> = {}): QueueStats {
  return {
    total_jobs: 500,
    pending_jobs: 25,
    processing_jobs: 5,
    failed_jobs: 2,
    completed_jobs: 468,
    avg_processing_time: 350,
    queue_latency: 120,
    workers_active: 4,
    ...overrides,
  };
}

function makeOptimizationAction(overrides: Partial<OptimizationAction> = {}): OptimizationAction {
  return {
    id: 'opt-1',
    type: 'cache_clear',
    name: 'Clear Application Cache',
    description: 'Clears all cached data to free memory',
    estimated_impact: 'medium',
    risk_level: 'safe',
    estimated_time: '30s',
    ...overrides,
  };
}

function makePerformanceStats(): PerformanceStats {
  return {
    current_metrics: makeMetrics(),
    historical_data: [makeMetrics({ id: 'metric-hist-1', cpu_usage: 40 })],
    active_alerts: [makeAlert()],
    optimization_suggestions: ['Enable CDN', 'Increase cache TTL'],
    system_health_score: 88,
    uptime_percentage: 99.9,
    peak_usage_times: [{ hour: 14, cpu_avg: 78, memory_avg: 70 }],
  };
}

// =============================================================================
// Setup
// =============================================================================

beforeEach(() => {
  mockGet.mockReset();
  mockPost.mockReset();
  mockPut.mockReset();
});

// =============================================================================
// getSystemMetrics
// =============================================================================

describe('performanceApi.getSystemMetrics', () => {
  it('calls GET /admin/performance/metrics and returns the envelope data', async () => {
    const metrics = makeMetrics();
    mockGet.mockResolvedValueOnce(envelope(metrics));

    const result = await performanceApi.getSystemMetrics();

    expect(mockGet).toHaveBeenCalledTimes(1);
    expect(mockGet).toHaveBeenCalledWith('/admin/performance/metrics');
    expect(result.success).toBe(true);
    expect(result.data).toEqual(metrics);
  });

  it('returns error envelope when API rejects with a response error', async () => {
    const apiError = {
      response: { data: { error: 'Service unavailable' } },
    };
    mockGet.mockRejectedValueOnce(apiError);

    const result = await performanceApi.getSystemMetrics();

    expect(result.success).toBe(false);
    expect(result.error).toBe('Service unavailable');
    expect(result.data).toBeUndefined();
  });

  it('returns generic error message when API rejects without a response error field', async () => {
    const apiError = { response: { data: {} } };
    mockGet.mockRejectedValueOnce(apiError);

    const result = await performanceApi.getSystemMetrics();

    expect(result.success).toBe(false);
    expect(result.error).toBe('Failed to fetch system metrics');
  });

  it('returns generic error message when error has no response property', async () => {
    mockGet.mockRejectedValueOnce(new Error('Network Error'));

    const result = await performanceApi.getSystemMetrics();

    expect(result.success).toBe(false);
    expect(result.error).toBe('Failed to fetch system metrics');
  });
});

// =============================================================================
// getPerformanceStats
// =============================================================================

describe('performanceApi.getPerformanceStats', () => {
  it('calls GET /admin/performance/stats?time_range=24h by default', async () => {
    const stats = makePerformanceStats();
    mockGet.mockResolvedValueOnce(envelope(stats));

    const result = await performanceApi.getPerformanceStats();

    expect(mockGet).toHaveBeenCalledWith('/admin/performance/stats?time_range=24h');
    expect(result.success).toBe(true);
    expect(result.data?.system_health_score).toBe(88);
  });

  it('interpolates the provided time range into the query string', async () => {
    mockGet.mockResolvedValueOnce(envelope(makePerformanceStats()));

    await performanceApi.getPerformanceStats('7d');

    expect(mockGet).toHaveBeenCalledWith('/admin/performance/stats?time_range=7d');
  });

  it('passes through 1h and 30d time range variants', async () => {
    mockGet.mockResolvedValue(envelope(makePerformanceStats()));

    await performanceApi.getPerformanceStats('1h');
    expect(mockGet).toHaveBeenLastCalledWith('/admin/performance/stats?time_range=1h');

    await performanceApi.getPerformanceStats('30d');
    expect(mockGet).toHaveBeenLastCalledWith('/admin/performance/stats?time_range=30d');
  });

  it('returns error envelope on failure', async () => {
    mockGet.mockRejectedValueOnce({ response: { data: { error: 'Stats unavailable' } } });

    const result = await performanceApi.getPerformanceStats();

    expect(result.success).toBe(false);
    expect(result.error).toBe('Stats unavailable');
  });

  it('returns generic error message for non-response errors', async () => {
    mockGet.mockRejectedValueOnce(new TypeError('fetch failed'));

    const result = await performanceApi.getPerformanceStats();

    expect(result.success).toBe(false);
    expect(result.error).toBe('Failed to fetch performance stats');
  });
});

// =============================================================================
// getSettings
// =============================================================================

describe('performanceApi.getSettings', () => {
  it('calls GET /admin/performance/settings', async () => {
    const settings = makeSettings();
    mockGet.mockResolvedValueOnce(envelope(settings));

    const result = await performanceApi.getSettings();

    expect(mockGet).toHaveBeenCalledTimes(1);
    expect(mockGet).toHaveBeenCalledWith('/admin/performance/settings');
    expect(result.success).toBe(true);
    expect(result.data).toEqual(settings);
  });

  it('returns error envelope on failure', async () => {
    mockGet.mockRejectedValueOnce({ response: { data: { error: 'Settings not found' } } });

    const result = await performanceApi.getSettings();

    expect(result.success).toBe(false);
    expect(result.error).toBe('Settings not found');
  });

  it('returns generic error for non-response errors', async () => {
    mockGet.mockRejectedValueOnce(new Error('timeout'));

    const result = await performanceApi.getSettings();

    expect(result.success).toBe(false);
    expect(result.error).toBe('Failed to fetch performance settings');
  });
});

// =============================================================================
// updateSettings
// =============================================================================

describe('performanceApi.updateSettings', () => {
  it('calls PUT /admin/performance/settings with settings wrapped in body', async () => {
    const updated = makeSettings({ cache_ttl: 7200 });
    mockPut.mockResolvedValueOnce(envelope(updated, { message: 'Settings updated' }));

    const patch: Partial<PerformanceSettings> = { cache_ttl: 7200 };
    const result = await performanceApi.updateSettings(patch);

    expect(mockPut).toHaveBeenCalledTimes(1);
    expect(mockPut).toHaveBeenCalledWith('/admin/performance/settings', { settings: patch });
    expect(result.success).toBe(true);
    expect(result.data).toEqual(updated);
  });

  it('wraps the full settings object inside the settings key', async () => {
    const fullSettings = makeSettings();
    mockPut.mockResolvedValueOnce(envelope(fullSettings));

    await performanceApi.updateSettings(fullSettings);

    expect(mockPut).toHaveBeenCalledWith(
      '/admin/performance/settings',
      { settings: fullSettings }
    );
  });

  it('accepts a partial patch (only changed fields)', async () => {
    mockPut.mockResolvedValueOnce(envelope(makeSettings({ worker_processes: 8 })));

    await performanceApi.updateSettings({ worker_processes: 8 });

    expect(mockPut).toHaveBeenCalledWith(
      '/admin/performance/settings',
      { settings: { worker_processes: 8 } }
    );
  });

  it('returns the message from the response', async () => {
    mockPut.mockResolvedValueOnce(envelope(makeSettings(), { message: 'Updated successfully' }));

    const result = await performanceApi.updateSettings({ cache_enabled: false });

    // The full envelope body is returned, so message lives at result.message
    expect((result as { message?: string }).message).toBe('Updated successfully');
  });

  it('returns error envelope on failure', async () => {
    mockPut.mockRejectedValueOnce({ response: { data: { error: 'Validation failed' } } });

    const result = await performanceApi.updateSettings({ cache_ttl: 30 });

    expect(result.success).toBe(false);
    expect(result.error).toBe('Validation failed');
  });

  it('returns generic error for non-response errors', async () => {
    mockPut.mockRejectedValueOnce(new Error('network problem'));

    const result = await performanceApi.updateSettings({ log_level: 'debug' });

    expect(result.success).toBe(false);
    expect(result.error).toBe('Failed to update performance settings');
  });
});

// =============================================================================
// getCacheStats
// =============================================================================

describe('performanceApi.getCacheStats', () => {
  it('calls GET /admin/performance/cache', async () => {
    const cache = makeCacheStats();
    mockGet.mockResolvedValueOnce(envelope(cache));

    const result = await performanceApi.getCacheStats();

    expect(mockGet).toHaveBeenCalledTimes(1);
    expect(mockGet).toHaveBeenCalledWith('/admin/performance/cache');
    expect(result.success).toBe(true);
    expect(result.data).toEqual(cache);
  });

  it('returns error envelope on failure', async () => {
    mockGet.mockRejectedValueOnce({ response: { data: { error: 'Cache unavailable' } } });

    const result = await performanceApi.getCacheStats();

    expect(result.success).toBe(false);
    expect(result.error).toBe('Cache unavailable');
  });

  it('returns generic error for non-response errors', async () => {
    mockGet.mockRejectedValueOnce(new Error('timeout'));

    const result = await performanceApi.getCacheStats();

    expect(result.success).toBe(false);
    expect(result.error).toBe('Failed to fetch cache stats');
  });
});

// =============================================================================
// getDatabaseStats
// =============================================================================

describe('performanceApi.getDatabaseStats', () => {
  it('calls GET /admin/performance/database', async () => {
    const db = makeDatabaseStats();
    mockGet.mockResolvedValueOnce(envelope(db));

    const result = await performanceApi.getDatabaseStats();

    expect(mockGet).toHaveBeenCalledTimes(1);
    expect(mockGet).toHaveBeenCalledWith('/admin/performance/database');
    expect(result.success).toBe(true);
    expect(result.data).toEqual(db);
  });

  it('returns error envelope on failure', async () => {
    mockGet.mockRejectedValueOnce({ response: { data: { error: 'DB stats error' } } });

    const result = await performanceApi.getDatabaseStats();

    expect(result.success).toBe(false);
    expect(result.error).toBe('DB stats error');
  });

  it('returns generic error for non-response errors', async () => {
    mockGet.mockRejectedValueOnce('some string error');

    const result = await performanceApi.getDatabaseStats();

    expect(result.success).toBe(false);
    expect(result.error).toBe('Failed to fetch database stats');
  });
});

// =============================================================================
// getQueueStats
// =============================================================================

describe('performanceApi.getQueueStats', () => {
  it('calls GET /admin/performance/queue', async () => {
    const queue = makeQueueStats();
    mockGet.mockResolvedValueOnce(envelope(queue));

    const result = await performanceApi.getQueueStats();

    expect(mockGet).toHaveBeenCalledTimes(1);
    expect(mockGet).toHaveBeenCalledWith('/admin/performance/queue');
    expect(result.success).toBe(true);
    expect(result.data?.pending_jobs).toBe(25);
  });

  it('returns error envelope on failure', async () => {
    mockGet.mockRejectedValueOnce({ response: { data: { error: 'Queue unreachable' } } });

    const result = await performanceApi.getQueueStats();

    expect(result.success).toBe(false);
    expect(result.error).toBe('Queue unreachable');
  });

  it('returns generic error for non-response errors', async () => {
    mockGet.mockRejectedValueOnce(new Error('network'));

    const result = await performanceApi.getQueueStats();

    expect(result.success).toBe(false);
    expect(result.error).toBe('Failed to fetch queue stats');
  });
});

// =============================================================================
// getActiveAlerts
// =============================================================================

describe('performanceApi.getActiveAlerts', () => {
  it('calls GET /admin/performance/alerts', async () => {
    const alerts = [makeAlert(), makeAlert({ id: 'alert-2', type: 'memory', severity: 'critical' })];
    mockGet.mockResolvedValueOnce(envelope(alerts));

    const result = await performanceApi.getActiveAlerts();

    expect(mockGet).toHaveBeenCalledTimes(1);
    expect(mockGet).toHaveBeenCalledWith('/admin/performance/alerts');
    expect(result.success).toBe(true);
    expect(result.data).toHaveLength(2);
    expect(result.data?.[1].type).toBe('memory');
  });

  it('returns an empty alerts array when no active alerts', async () => {
    mockGet.mockResolvedValueOnce(envelope([]));

    const result = await performanceApi.getActiveAlerts();

    expect(result.success).toBe(true);
    expect(result.data).toEqual([]);
  });

  it('returns error envelope on failure', async () => {
    mockGet.mockRejectedValueOnce({ response: { data: { error: 'Alerts fetch failed' } } });

    const result = await performanceApi.getActiveAlerts();

    expect(result.success).toBe(false);
    expect(result.error).toBe('Alerts fetch failed');
  });

  it('returns generic error for non-response errors', async () => {
    mockGet.mockRejectedValueOnce(new Error('timeout'));

    const result = await performanceApi.getActiveAlerts();

    expect(result.success).toBe(false);
    expect(result.error).toBe('Failed to fetch performance alerts');
  });
});

// =============================================================================
// dismissAlert
// =============================================================================

describe('performanceApi.dismissAlert', () => {
  it('calls POST /admin/performance/alerts/:alertId/dismiss', async () => {
    mockPost.mockResolvedValueOnce({ data: { success: true, message: 'Alert dismissed' } });

    const result = await performanceApi.dismissAlert('alert-1');

    expect(mockPost).toHaveBeenCalledTimes(1);
    expect(mockPost).toHaveBeenCalledWith('/admin/performance/alerts/alert-1/dismiss');
    expect(result.success).toBe(true);
  });

  it('interpolates arbitrary alert IDs into the URL', async () => {
    mockPost.mockResolvedValueOnce({ data: { success: true } });

    await performanceApi.dismissAlert('some-uuid-5678');

    expect(mockPost).toHaveBeenCalledWith(
      '/admin/performance/alerts/some-uuid-5678/dismiss'
    );
  });

  it('returns error envelope on failure', async () => {
    mockPost.mockRejectedValueOnce({ response: { data: { error: 'Alert not found' } } });

    const result = await performanceApi.dismissAlert('alert-999');

    expect(result.success).toBe(false);
    expect(result.error).toBe('Alert not found');
  });

  it('returns generic error for non-response errors', async () => {
    mockPost.mockRejectedValueOnce(new Error('network'));

    const result = await performanceApi.dismissAlert('alert-1');

    expect(result.success).toBe(false);
    expect(result.error).toBe('Failed to dismiss alert');
  });
});

// =============================================================================
// getOptimizationActions
// =============================================================================

describe('performanceApi.getOptimizationActions', () => {
  it('calls GET /admin/performance/optimizations', async () => {
    const actions = [
      makeOptimizationAction(),
      makeOptimizationAction({ id: 'opt-2', type: 'restart_workers', name: 'Restart Workers' }),
    ];
    mockGet.mockResolvedValueOnce(envelope(actions));

    const result = await performanceApi.getOptimizationActions();

    expect(mockGet).toHaveBeenCalledTimes(1);
    expect(mockGet).toHaveBeenCalledWith('/admin/performance/optimizations');
    expect(result.success).toBe(true);
    expect(result.data).toHaveLength(2);
  });

  it('returns error envelope on failure', async () => {
    mockGet.mockRejectedValueOnce({ response: { data: { error: 'Optimizations unavailable' } } });

    const result = await performanceApi.getOptimizationActions();

    expect(result.success).toBe(false);
    expect(result.error).toBe('Optimizations unavailable');
  });

  it('returns generic error for non-response errors', async () => {
    mockGet.mockRejectedValueOnce(new Error('broken'));

    const result = await performanceApi.getOptimizationActions();

    expect(result.success).toBe(false);
    expect(result.error).toBe('Failed to fetch optimization actions');
  });
});

// =============================================================================
// executeOptimization
// =============================================================================

describe('performanceApi.executeOptimization', () => {
  it('calls POST /admin/performance/optimizations/:actionId/execute', async () => {
    mockPost.mockResolvedValueOnce({ data: { success: true, message: 'Cache cleared' } });

    const result = await performanceApi.executeOptimization('opt-1');

    expect(mockPost).toHaveBeenCalledTimes(1);
    expect(mockPost).toHaveBeenCalledWith('/admin/performance/optimizations/opt-1/execute');
    expect(result.success).toBe(true);
  });

  it('interpolates arbitrary action IDs into the URL', async () => {
    mockPost.mockResolvedValueOnce({ data: { success: true } });

    await performanceApi.executeOptimization('opt-rebuild-indexes');

    expect(mockPost).toHaveBeenCalledWith(
      '/admin/performance/optimizations/opt-rebuild-indexes/execute'
    );
  });

  it('returns error envelope on failure', async () => {
    mockPost.mockRejectedValueOnce({ response: { data: { error: 'Execution failed' } } });

    const result = await performanceApi.executeOptimization('opt-1');

    expect(result.success).toBe(false);
    expect(result.error).toBe('Execution failed');
  });

  it('returns generic error for non-response errors', async () => {
    mockPost.mockRejectedValueOnce(new Error('unexpected'));

    const result = await performanceApi.executeOptimization('opt-1');

    expect(result.success).toBe(false);
    expect(result.error).toBe('Failed to execute optimization');
  });
});

// =============================================================================
// clearCache
// =============================================================================

describe('performanceApi.clearCache', () => {
  it('calls POST /admin/performance/cache/clear with no cache_type when omitted', async () => {
    mockPost.mockResolvedValueOnce({ data: { success: true, message: 'Cache cleared' } });

    const result = await performanceApi.clearCache();

    expect(mockPost).toHaveBeenCalledTimes(1);
    expect(mockPost).toHaveBeenCalledWith(
      '/admin/performance/cache/clear',
      { cache_type: undefined }
    );
    expect(result.success).toBe(true);
  });

  it('passes cache_type when provided', async () => {
    mockPost.mockResolvedValueOnce({ data: { success: true, message: 'Fragment cache cleared' } });

    await performanceApi.clearCache('fragment');

    expect(mockPost).toHaveBeenCalledWith(
      '/admin/performance/cache/clear',
      { cache_type: 'fragment' }
    );
  });

  it('passes cache_type=all explicitly', async () => {
    mockPost.mockResolvedValueOnce({ data: { success: true } });

    await performanceApi.clearCache('all');

    expect(mockPost).toHaveBeenCalledWith(
      '/admin/performance/cache/clear',
      { cache_type: 'all' }
    );
  });

  it('returns error envelope on failure', async () => {
    mockPost.mockRejectedValueOnce({ response: { data: { error: 'Cache clear failed' } } });

    const result = await performanceApi.clearCache();

    expect(result.success).toBe(false);
    expect(result.error).toBe('Cache clear failed');
  });

  it('returns generic error for non-response errors', async () => {
    mockPost.mockRejectedValueOnce(new Error('boom'));

    const result = await performanceApi.clearCache('redis');

    expect(result.success).toBe(false);
    expect(result.error).toBe('Failed to clear cache');
  });
});

// =============================================================================
// restartWorkers
// =============================================================================

describe('performanceApi.restartWorkers', () => {
  it('calls POST /admin/performance/workers/restart', async () => {
    mockPost.mockResolvedValueOnce({ data: { success: true, message: 'Workers restarted' } });

    const result = await performanceApi.restartWorkers();

    expect(mockPost).toHaveBeenCalledTimes(1);
    expect(mockPost).toHaveBeenCalledWith('/admin/performance/workers/restart');
    expect(result.success).toBe(true);
  });

  it('returns error envelope on failure', async () => {
    mockPost.mockRejectedValueOnce({ response: { data: { error: 'Workers busy' } } });

    const result = await performanceApi.restartWorkers();

    expect(result.success).toBe(false);
    expect(result.error).toBe('Workers busy');
  });

  it('returns generic error for non-response errors', async () => {
    mockPost.mockRejectedValueOnce(new Error('connection refused'));

    const result = await performanceApi.restartWorkers();

    expect(result.success).toBe(false);
    expect(result.error).toBe('Failed to restart workers');
  });
});

// =============================================================================
// generateReport
// =============================================================================

describe('performanceApi.generateReport', () => {
  it('calls POST /admin/performance/reports/generate with default 7d/pdf', async () => {
    mockPost.mockResolvedValueOnce({ data: { success: true, message: 'Report queued' } });

    const result = await performanceApi.generateReport();

    expect(mockPost).toHaveBeenCalledTimes(1);
    expect(mockPost).toHaveBeenCalledWith(
      '/admin/performance/reports/generate',
      { time_range: '7d', format: 'pdf' }
    );
    expect(result.success).toBe(true);
  });

  it('passes custom time range and format', async () => {
    mockPost.mockResolvedValueOnce({ data: { success: true, message: 'Report queued' } });

    await performanceApi.generateReport('30d', 'csv');

    expect(mockPost).toHaveBeenCalledWith(
      '/admin/performance/reports/generate',
      { time_range: '30d', format: 'csv' }
    );
  });

  it('passes custom time range with default pdf format', async () => {
    mockPost.mockResolvedValueOnce({ data: { success: true } });

    await performanceApi.generateReport('1h');

    expect(mockPost).toHaveBeenCalledWith(
      '/admin/performance/reports/generate',
      { time_range: '1h', format: 'pdf' }
    );
  });

  it('returns error envelope on failure', async () => {
    mockPost.mockRejectedValueOnce({ response: { data: { error: 'Report generation failed' } } });

    const result = await performanceApi.generateReport();

    expect(result.success).toBe(false);
    expect(result.error).toBe('Report generation failed');
  });

  it('returns generic error for non-response errors', async () => {
    mockPost.mockRejectedValueOnce(new Error('disk full'));

    const result = await performanceApi.generateReport('7d', 'pdf');

    expect(result.success).toBe(false);
    expect(result.error).toBe('Failed to generate performance report');
  });
});

// =============================================================================
// getMetricColor (pure helper)
// =============================================================================

describe('performanceApi.getMetricColor', () => {
  const thresholds = { warn: 70, critical: 90 };

  it('returns text-theme-success-fg when value is below warn threshold', () => {
    expect(performanceApi.getMetricColor(50, thresholds)).toBe('text-theme-success-fg');
    expect(performanceApi.getMetricColor(0, thresholds)).toBe('text-theme-success-fg');
    expect(performanceApi.getMetricColor(69.9, thresholds)).toBe('text-theme-success-fg');
  });

  it('returns text-theme-warning-fg when value is at or above warn but below critical', () => {
    expect(performanceApi.getMetricColor(70, thresholds)).toBe('text-theme-warning-fg');
    expect(performanceApi.getMetricColor(89.9, thresholds)).toBe('text-theme-warning-fg');
  });

  it('returns text-theme-error-fg when value is at or above critical threshold', () => {
    expect(performanceApi.getMetricColor(90, thresholds)).toBe('text-theme-error-fg');
    expect(performanceApi.getMetricColor(100, thresholds)).toBe('text-theme-error-fg');
  });
});

// =============================================================================
// getMetricBackgroundColor (pure helper)
// =============================================================================

describe('performanceApi.getMetricBackgroundColor', () => {
  const thresholds = { warn: 70, critical: 90 };

  it('returns bg-theme-success-background when value is below warn threshold', () => {
    expect(performanceApi.getMetricBackgroundColor(40, thresholds)).toBe('bg-theme-success-background');
  });

  it('returns bg-theme-warning-background when value is in the warn zone', () => {
    expect(performanceApi.getMetricBackgroundColor(75, thresholds)).toBe('bg-theme-warning-background');
  });

  it('returns bg-theme-error-bg when value is at or above critical threshold', () => {
    expect(performanceApi.getMetricBackgroundColor(95, thresholds)).toBe('bg-theme-error-bg');
    expect(performanceApi.getMetricBackgroundColor(90, thresholds)).toBe('bg-theme-error-bg');
  });
});

// =============================================================================
// getAlertSeverityColor (pure helper)
// =============================================================================

describe('performanceApi.getAlertSeverityColor', () => {
  it('returns critical color class for critical severity', () => {
    const cls = performanceApi.getAlertSeverityColor('critical');
    expect(cls).toContain('bg-theme-error-bg');
    expect(cls).toContain('text-theme-error-fg');
  });

  it('returns high color class for high severity', () => {
    const cls = performanceApi.getAlertSeverityColor('high');
    expect(cls).toContain('bg-theme-error-bg');
    expect(cls).toContain('text-theme-error-fg');
  });

  it('returns medium color class for medium severity', () => {
    const cls = performanceApi.getAlertSeverityColor('medium');
    expect(cls).toContain('bg-theme-warning-bg');
    expect(cls).toContain('text-theme-warning-fg');
  });

  it('returns low color class for low severity', () => {
    const cls = performanceApi.getAlertSeverityColor('low');
    expect(cls).toContain('bg-theme-info-bg');
    expect(cls).toContain('text-theme-info-fg');
  });

  it('returns default class for unknown severity', () => {
    const cls = performanceApi.getAlertSeverityColor('unknown');
    expect(cls).toContain('bg-theme-surface');
    expect(cls).toContain('text-theme-secondary');
  });
});

// =============================================================================
// getHealthScoreColor (pure helper)
// =============================================================================

describe('performanceApi.getHealthScoreColor', () => {
  it('returns text-theme-success-fg for scores >= 90', () => {
    expect(performanceApi.getHealthScoreColor(90)).toBe('text-theme-success-fg');
    expect(performanceApi.getHealthScoreColor(100)).toBe('text-theme-success-fg');
    expect(performanceApi.getHealthScoreColor(95)).toBe('text-theme-success-fg');
  });

  it('returns text-theme-warning-fg for scores >= 70 but < 90', () => {
    expect(performanceApi.getHealthScoreColor(70)).toBe('text-theme-warning-fg');
    expect(performanceApi.getHealthScoreColor(89)).toBe('text-theme-warning-fg');
    expect(performanceApi.getHealthScoreColor(75)).toBe('text-theme-warning-fg');
  });

  it('returns text-theme-error-fg for scores below 70', () => {
    expect(performanceApi.getHealthScoreColor(69)).toBe('text-theme-error-fg');
    expect(performanceApi.getHealthScoreColor(0)).toBe('text-theme-error-fg');
    expect(performanceApi.getHealthScoreColor(50)).toBe('text-theme-error-fg');
  });
});

// =============================================================================
// formatBytes (pure helper)
// =============================================================================

describe('performanceApi.formatBytes', () => {
  it('returns "0 Bytes" for zero', () => {
    expect(performanceApi.formatBytes(0)).toBe('0 Bytes');
  });

  it('formats bytes correctly (< 1 KB)', () => {
    expect(performanceApi.formatBytes(1)).toBe('1 Bytes');
    expect(performanceApi.formatBytes(512)).toBe('512 Bytes');
    expect(performanceApi.formatBytes(1023)).toBe('1023 Bytes');
  });

  it('formats kilobytes correctly (1 KB boundary)', () => {
    expect(performanceApi.formatBytes(1024)).toBe('1 KB');
    expect(performanceApi.formatBytes(1536)).toBe('1.5 KB');
  });

  it('formats megabytes correctly', () => {
    expect(performanceApi.formatBytes(1024 * 1024)).toBe('1 MB');
    expect(performanceApi.formatBytes(1.5 * 1024 * 1024)).toBe('1.5 MB');
  });

  it('formats gigabytes correctly', () => {
    expect(performanceApi.formatBytes(1024 * 1024 * 1024)).toBe('1 GB');
  });

  it('formats terabytes correctly for large values', () => {
    expect(performanceApi.formatBytes(1024 * 1024 * 1024 * 1024)).toBe('1 TB');
  });
});

// =============================================================================
// formatUptime (pure helper)
// =============================================================================

describe('performanceApi.formatUptime', () => {
  it('formats minutes-only uptime', () => {
    expect(performanceApi.formatUptime(60)).toBe('1m');
    expect(performanceApi.formatUptime(300)).toBe('5m');
    expect(performanceApi.formatUptime(59)).toBe('0m');
  });

  it('formats hours and minutes when hours >= 1 but days = 0', () => {
    expect(performanceApi.formatUptime(3600)).toBe('1h 0m');
    expect(performanceApi.formatUptime(3661)).toBe('1h 1m');
    expect(performanceApi.formatUptime(7320)).toBe('2h 2m');
  });

  it('formats days, hours and minutes when days >= 1', () => {
    expect(performanceApi.formatUptime(86400)).toBe('1d 0h 0m');
    expect(performanceApi.formatUptime(86400 + 3661)).toBe('1d 1h 1m');
    expect(performanceApi.formatUptime(2 * 86400 + 2 * 3600 + 30 * 60)).toBe('2d 2h 30m');
  });
});

// =============================================================================
// formatPercentage (pure helper)
// =============================================================================

describe('performanceApi.formatPercentage', () => {
  it('formats value with one decimal place', () => {
    expect(performanceApi.formatPercentage(45.678)).toBe('45.7%');
    expect(performanceApi.formatPercentage(100)).toBe('100.0%');
    expect(performanceApi.formatPercentage(0)).toBe('0.0%');
    expect(performanceApi.formatPercentage(99.9)).toBe('99.9%');
  });
});

// =============================================================================
// validateSettings (pure helper)
// =============================================================================

describe('performanceApi.validateSettings', () => {
  it('returns empty array for valid settings', () => {
    const errors = performanceApi.validateSettings({
      cache_ttl: 3600,
      max_connections: 100,
      query_timeout: 30,
      database_pool_size: 25,
      worker_processes: 4,
    });
    expect(errors).toEqual([]);
  });

  it('returns error when cache_ttl is below minimum (60)', () => {
    const errors = performanceApi.validateSettings({ cache_ttl: 59 });
    expect(errors).toContain('Cache TTL must be between 60 seconds and 24 hours');
  });

  it('returns error when cache_ttl is above maximum (86400)', () => {
    const errors = performanceApi.validateSettings({ cache_ttl: 86401 });
    expect(errors).toContain('Cache TTL must be between 60 seconds and 24 hours');
  });

  it('accepts cache_ttl at the exact boundaries (60 and 86400)', () => {
    expect(performanceApi.validateSettings({ cache_ttl: 60 })).toEqual([]);
    expect(performanceApi.validateSettings({ cache_ttl: 86400 })).toEqual([]);
  });

  it('returns error when max_connections is below minimum (10)', () => {
    const errors = performanceApi.validateSettings({ max_connections: 9 });
    expect(errors).toContain('Max connections must be between 10 and 1000');
  });

  it('returns error when max_connections is above maximum (1000)', () => {
    const errors = performanceApi.validateSettings({ max_connections: 1001 });
    expect(errors).toContain('Max connections must be between 10 and 1000');
  });

  it('accepts max_connections at the exact boundaries (10 and 1000)', () => {
    expect(performanceApi.validateSettings({ max_connections: 10 })).toEqual([]);
    expect(performanceApi.validateSettings({ max_connections: 1000 })).toEqual([]);
  });

  it('returns error when query_timeout is below minimum (1)', () => {
    const errors = performanceApi.validateSettings({ query_timeout: 0 });
    expect(errors).toContain('Query timeout must be between 1 and 300 seconds');
  });

  it('returns error when query_timeout is above maximum (300)', () => {
    const errors = performanceApi.validateSettings({ query_timeout: 301 });
    expect(errors).toContain('Query timeout must be between 1 and 300 seconds');
  });

  it('accepts query_timeout at the exact boundaries (1 and 300)', () => {
    expect(performanceApi.validateSettings({ query_timeout: 1 })).toEqual([]);
    expect(performanceApi.validateSettings({ query_timeout: 300 })).toEqual([]);
  });

  it('returns error when database_pool_size is below minimum (5)', () => {
    const errors = performanceApi.validateSettings({ database_pool_size: 4 });
    expect(errors).toContain('Database pool size must be between 5 and 100');
  });

  it('returns error when database_pool_size is above maximum (100)', () => {
    const errors = performanceApi.validateSettings({ database_pool_size: 101 });
    expect(errors).toContain('Database pool size must be between 5 and 100');
  });

  it('accepts database_pool_size at the exact boundaries (5 and 100)', () => {
    expect(performanceApi.validateSettings({ database_pool_size: 5 })).toEqual([]);
    expect(performanceApi.validateSettings({ database_pool_size: 100 })).toEqual([]);
  });

  it('returns error when worker_processes is below minimum (1)', () => {
    const errors = performanceApi.validateSettings({ worker_processes: 0 });
    expect(errors).toContain('Worker processes must be between 1 and 20');
  });

  it('returns error when worker_processes is above maximum (20)', () => {
    const errors = performanceApi.validateSettings({ worker_processes: 21 });
    expect(errors).toContain('Worker processes must be between 1 and 20');
  });

  it('accepts worker_processes at the exact boundaries (1 and 20)', () => {
    expect(performanceApi.validateSettings({ worker_processes: 1 })).toEqual([]);
    expect(performanceApi.validateSettings({ worker_processes: 20 })).toEqual([]);
  });

  it('accumulates multiple errors simultaneously', () => {
    const errors = performanceApi.validateSettings({
      cache_ttl: 10,
      max_connections: 5000,
      query_timeout: 500,
      database_pool_size: 200,
      worker_processes: 50,
    });
    expect(errors).toHaveLength(5);
    expect(errors).toContain('Cache TTL must be between 60 seconds and 24 hours');
    expect(errors).toContain('Max connections must be between 10 and 1000');
    expect(errors).toContain('Query timeout must be between 1 and 300 seconds');
    expect(errors).toContain('Database pool size must be between 5 and 100');
    expect(errors).toContain('Worker processes must be between 1 and 20');
  });

  it('returns empty array for empty settings object (no fields to validate)', () => {
    const errors = performanceApi.validateSettings({});
    expect(errors).toEqual([]);
  });

  it('skips validation for fields not present in the partial settings', () => {
    // Only log_level is provided — none of the range-validated fields are present
    const errors = performanceApi.validateSettings({ log_level: 'debug' });
    expect(errors).toEqual([]);
  });
});
