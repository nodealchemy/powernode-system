import React, { useEffect, useState } from 'react';
import { Search, X, AlertTriangle } from 'lucide-react';
import { Badge } from '@/shared/components/ui/Badge';
import { Button } from '@/shared/components/ui/Button';
import { useNotifications } from '@/shared/hooks/useNotifications';
import { fleetApi, type AttributionResult, type AttributionCandidate } from '@system/features/system/services/api/fleetApi';
import { AttributionFeedbackButton } from './AttributionFeedbackButton';

interface Props {
  instanceId: string;
  isOpen: boolean;
  onClose: () => void;
}

// Attribution Result Modal (Golden Eclipse plan F + Block J).
// Calls AttributeFailureExecutor for the given instance, displays ranked
// candidates with their scores + reasons, and lets the operator
// confirm/reject each via the AttributionFeedbackButton — feeding the
// learning loop that boosts/downweights similar candidates next time.
export const AttributionResultModal: React.FC<Props> = ({ instanceId, isOpen, onClose }) => {
  const { addNotification } = useNotifications();
  const [result, setResult] = useState<AttributionResult | null>(null);
  const [loading, setLoading] = useState(false);
  const [lookbackHours, setLookbackHours] = useState(24);

  const fetchAttribution = async (): Promise<void> => {
    if (!instanceId) return;
    setLoading(true);
    try {
      const data = await fleetApi.attributeFailure(instanceId, lookbackHours);
      setResult(data);
    } catch {
      addNotification({ type: 'error', message: 'Attribution failed' });
    } finally {
      setLoading(false);
    }
  };

  useEffect(() => {
    if (isOpen) {
      void fetchAttribution();
    } else {
      setResult(null);
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [isOpen, instanceId, lookbackHours]);

  if (!isOpen) return null;

  return (
    <div className="fixed inset-0 bg-black/50 flex items-center justify-center z-50">
      <div className="bg-theme-surface border border-theme rounded-lg shadow-xl w-full max-w-3xl max-h-[80vh] overflow-y-auto p-6">
        <div className="flex items-center justify-between mb-4">
          <h2 className="text-lg font-semibold flex items-center gap-2">
            <Search size={16} />
            Attribute Failure
          </h2>
          <Button size="xs" variant="ghost" onClick={onClose}>
            <X size={16} />
          </Button>
        </div>

        <div className="mb-4 flex items-center gap-3">
          <label className="text-sm">Lookback (hours):</label>
          <input
            type="number"
            min="1"
            max="168"
            value={lookbackHours}
            onChange={(e) => setLookbackHours(Math.max(1, parseInt(e.target.value, 10) || 24))}
            className="w-20 px-2 py-1 text-sm rounded border border-theme bg-theme-background"
          />
          <Button size="sm" variant="secondary" onClick={fetchAttribution} disabled={loading}>
            Re-analyze
          </Button>
        </div>

        {loading ? (
          <p className="text-sm text-theme-muted">Computing attribution…</p>
        ) : !result ? (
          <p className="text-sm text-theme-muted">No data yet.</p>
        ) : (
          <div className="space-y-4">
            <div className="text-sm bg-theme-background border border-theme rounded p-3">
              <div className="font-medium mb-1">Reasoning</div>
              <p className="text-theme-muted">{result.reasoning}</p>
              {result.confidence > 0 && (
                <div className="mt-2 text-xs">
                  <span className="text-theme-muted">Confidence:</span>{' '}
                  <Badge variant={result.confidence >= 0.7 ? 'success' : result.confidence >= 0.4 ? 'warning' : 'default'}>
                    {(result.confidence * 100).toFixed(0)}%
                  </Badge>
                </div>
              )}
            </div>

            <div>
              <h3 className="text-sm font-semibold mb-2">
                Candidates ({result.candidates.length})
              </h3>
              {result.candidates.length === 0 ? (
                <p className="text-sm text-theme-muted">No suspect changes found in the lookback window.</p>
              ) : (
                <ul className="space-y-3">
                  {result.candidates.map((c, idx) => (
                    <CandidateRow key={`${c.kind}:${c.module_id}`} candidate={c} rank={idx + 1} instanceId={instanceId} />
                  ))}
                </ul>
              )}
            </div>
          </div>
        )}
      </div>
    </div>
  );
};

interface CandidateRowProps {
  candidate: AttributionCandidate & { feedback?: string };
  rank: number;
  instanceId: string;
}
const CandidateRow: React.FC<CandidateRowProps> = ({ candidate, rank, instanceId }) => {
  const isTop = rank === 1;
  return (
    <li className={`border ${isTop ? 'border-theme-warning' : 'border-theme'} rounded p-3 bg-theme-background`}>
      <div className="flex items-start justify-between gap-2">
        <div className="flex-1">
          <div className="flex items-center gap-2">
            <span className="font-mono text-xs text-theme-muted">#{rank}</span>
            {isTop && <AlertTriangle size={12} className="text-theme-warning" />}
            <span className="font-medium text-sm">{candidate.module_name || candidate.module_id}</span>
            <Badge variant="default">{candidate.kind}</Badge>
            <span className="text-xs text-theme-muted">score {candidate.score}</span>
            {(candidate as { feedback?: string }).feedback && (
              <Badge variant={(candidate as { feedback?: string }).feedback?.startsWith('boosted') ? 'success' : 'warning'}>
                {(candidate as { feedback?: string }).feedback?.split('_').slice(0, 2).join(' ')}
              </Badge>
            )}
          </div>
          {candidate.reasons.length > 0 && (
            <ul className="mt-2 text-xs text-theme-muted list-disc pl-4 space-y-0.5">
              {candidate.reasons.slice(0, 4).map((r, i) => (
                <li key={i}>{r}</li>
              ))}
            </ul>
          )}
        </div>
      </div>
      <div className="mt-3">
        <AttributionFeedbackButton
          instanceId={instanceId}
          candidateModuleId={candidate.module_id}
          candidateKind={candidate.kind}
        />
      </div>
    </li>
  );
};

export default AttributionResultModal;
