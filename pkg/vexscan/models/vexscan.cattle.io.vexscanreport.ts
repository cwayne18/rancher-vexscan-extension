import SteveModel from '@shell/plugins/steve/steve-class';

interface ScanSummary {
  // Counts by vexscan --severity.
  critical?: number;
  high?: number;
  medium?: number;
  low?: number;
  unknown?: number;
  // Counts by vexscan's own finding bucket (see contrib/vexscan-dashboard.py
  // bucket_of()): affected = reachable/linked with no exculpatory VEX;
  // vexed = reachable/linked but a not_affected/fixed VEX statement applies;
  // undetermined = no mapping could be resolved; ruledOut = not_present or
  // not_in_execute_path.
  affected?: number;
  vexed?: number;
  undetermined?: number;
  ruledOut?: number;
}

interface ScanHistoryEntry extends ScanSummary {
  time: string;
  rke2Version?: string;
}

interface ComponentResult {
  component: string;
  image: string;
  // Total finding count (== affected+vexed+undetermined+ruledOut). Kept for
  // back-compat; prefer the bucket counts below, which are what the
  // Overview/detail bucket breakdown actually renders.
  findings: number;
  affected?: number;
  vexed?: number;
  undetermined?: number;
  ruledOut?: number;
  reportConfigMapRef?: string;
}

// Mirrors the status shape written by scanner/entrypoint.sh in the
// vexscan-scanner chart. Kept intentionally small (summary counts + a
// pointer per component) - the full `vexscan --format json` output lives in
// a ConfigMap referenced by reportConfigMapRef, not inline in the CR, so a
// cluster scanning hundreds of images doesn't blow past etcd's per-object
// size limit.
//
// SteveModel itself is plain JS with no .d.ts, so `spec`/`status` (set by
// the Steve store from the raw API resource) aren't visible to the
// TypeScript compiler without being declared here.
export default class VexScanReport extends SteveModel {
  spec!: { rke2Version?: string; sourceNode?: string };
  status!: {
    phase?: string;
    lastScanTime?: string;
    summary?: ScanSummary;
    componentResults?: ComponentResult[];
    message?: string;
    // Rolling trend of past scans' summary counts (oldest first), capped to
    // a fixed length by scanner/entrypoint.sh itself - not a CR-per-scan, so
    // this stays bounded with no retention job to maintain.
    history?: ScanHistoryEntry[];
  };

  get rke2Version(): string {
    return this.spec?.rke2Version || 'unknown';
  }

  get summary(): ScanSummary {
    return this.status?.summary || {};
  }

  get componentResults(): ComponentResult[] {
    return this.status?.componentResults || [];
  }

  get history(): ScanHistoryEntry[] {
    return this.status?.history || [];
  }

  get lastScanTime(): string | undefined {
    return this.status?.lastScanTime;
  }

  get phase(): string {
    return this.status?.phase || 'Unknown';
  }
}
