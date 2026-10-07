<script>
import { WORKLOAD_TYPES } from '@shell/config/types';
import { isRancherPrime } from '@shell/config/version';
import Loading from '@shell/components/Loading';
import { Banner } from '@components/Banner';
import SortableTable from '@shell/components/SortableTable';
import { SCAN_REPORT } from '../config/constants';

// Chart release name is fixed by charts/vexscan-scanner/Chart.yaml -
// "vexscan-scanner" - and the chart always installs its CronJob/CR into the
// cattle-vexscan-system namespace, so both are safe to hardcode here rather
// than discovered at runtime.
const NAMESPACE = 'cattle-vexscan-system';
const CRONJOB_NAME = 'vexscan-scanner';
const REPORT_NAME = 'cluster-scan';

const SEVERITY_COLOR = {
  critical: '--sev-critical-bg',
  high:     '--sev-high-bg',
  medium:   '--sev-medium-bg',
  low:      '--sev-low-bg',
  unknown:  '--sev-unknown-bg',
};

// Bucket keys/labels/colors/notes mirror contrib/vexscan-dashboard.py's own
// BUCKET_*/SECTIONS/CARD_NOTES constants exactly, so the extension's UI
// uses the same triage vocabulary vexscan users already know from the CLI
// dashboard, rather than inventing new terms.
const BUCKETS = [
  {
    key: 'affected', labelKey: 'vexscan.overview.bucket.affected', noteKey: 'vexscan.overview.bucketNote.affected', color: '--sev-critical-bg',
  },
  {
    key: 'vexed', labelKey: 'vexscan.overview.bucket.vexed', noteKey: 'vexscan.overview.bucketNote.vexed', color: '--ok-border',
  },
  {
    key: 'undetermined', labelKey: 'vexscan.overview.bucket.undetermined', noteKey: 'vexscan.overview.bucketNote.undetermined', color: '--sev-medium-border',
  },
  {
    key: 'ruledOut', labelKey: 'vexscan.overview.bucket.ruledOut', noteKey: 'vexscan.overview.bucketNote.ruledOut', color: '--link',
  },
];

export default {
  name: 'VexScanOverview',

  components: {
    Loading, Banner, SortableTable,
  },

  async fetch() {
    const hash = {};

    if (this.$store.getters['cluster/canList'](SCAN_REPORT)) {
      hash.reports = this.$store.dispatch('cluster/findAll', { type: SCAN_REPORT });
    }

    if (this.$store.getters['cluster/canList'](WORKLOAD_TYPES.CRON_JOB)) {
      hash.cronJobs = this.$store.dispatch('cluster/findAll', { type: WORKLOAD_TYPES.CRON_JOB });
    }

    const res = await this.$allHash ? this.$allHash(hash) : Promise.all(Object.values(hash)).then((vals) => {
      const out = {};

      Object.keys(hash).forEach((k, i) => {
        out[k] = vals[i];
      });

      return out;
    });

    this.report = (res.reports || []).find((r) => r.metadata?.name === REPORT_NAME);
    this.cronJob = (res.cronJobs || []).find(
      (c) => c.metadata?.name === CRONJOB_NAME && c.metadata?.namespace === NAMESPACE
    );
  },

  data() {
    return {
      report:    null,
      cronJob:   null,
      scanning:  false,
      scanError: null,
    };
  },

  computed: {
    // vexscan is distributed Prime-only (see README "Rancher Prime gating");
    // isRancherPrime() reads the RancherPrime flag the server already sends
    // back from /rancherversion (@shell/config/version, populated at app
    // boot before any page mounts), so this is accurate without the
    // extension having to call anything itself. This is a UI-level
    // courtesy/soft gate only - it can't stop someone who obtained the
    // chart/image directly from applying it against a Community server;
    // real enforcement has to happen at distribution (private,
    // entitlement-gated registry), not in shipped extension code.
    isPrime() {
      // LOCAL TEST OVERRIDE - DO NOT COMMIT: forced true to test against a
      // Community (non-Prime) server. Revert to `return isRancherPrime();`
      // before committing/distributing.
      return true;
    },

    summary() {
      return this.report?.status?.summary || {};
    },

    componentResults() {
      return this.report?.status?.componentResults || [];
    },

    rke2Version() {
      return this.report?.spec?.rke2Version;
    },

    lastScanTime() {
      return this.report?.status?.lastScanTime;
    },

    phase() {
      return this.report?.status?.phase;
    },

    // entrypoint.sh writes the same status.message field for both a
    // successful-but-truncated report (see cronjob's degrade-in-stages
    // comment) and a failed scan's error tail - split here so each gets its
    // own banner with accurate wording/color instead of one generic one.
    failureMessage() {
      return this.phase === 'Failed' ? (this.report?.status?.message || '') : '';
    },

    truncationMessage() {
      return this.phase === 'Failed' ? '' : (this.report?.status?.message || '');
    },

    // "Scan Now" calls cronJob.runNow(), which creates a batch.job and
    // patches the batch.cronjob - both require the "VEX Scan - Operator"
    // RoleTemplate (see charts/vexscan-scanner/templates/roletemplates.yaml).
    // A "VEX Scan - View"-only user can still see this whole page (the CR
    // status/ConfigMap reads are a separate, lesser permission), they just
    // shouldn't get a button that 403s when clicked.
    //
    // There's no "cluster/canCreate"/"cluster/canUpdate" store getter (only
    // "cluster/canList" exists at the store level) - can{Create,Update} are
    // instance getters on resource-class.js model objects instead, derived
    // from the schema's collectionMethods (create) or the object's own
    // "update" link (update). No Job exists yet to check an instance
    // against, so check its schema directly; a CronJob instance already
    // exists (this.cronJob), so use its own canUpdate getter for that half.
    canScanNow() {
      const jobSchema = this.$store.getters['cluster/schemaFor'](WORKLOAD_TYPES.JOB);
      const canCreateJob = !!jobSchema?.collectionMethods?.some((m) => m.toLowerCase() === 'post');

      return canCreateJob && !!this.cronJob?.canUpdate;
    },

    // The triage verdict - what vexscan actually determined about each CVE
    // match, not just its severity. This is the headline of the page:
    // most of a real scan's raw CVE matches end up ruledOut (not present or
    // unreachable), and surfacing that - not just hiding it - is the whole
    // point of vexscan's triage over a plain "N CVEs found" scanner.
    bucketCards() {
      return BUCKETS.map((b) => ({
        key:   b.key,
        label: this.t(b.labelKey),
        note:  this.t(b.noteKey),
        value: this.summary[b.key] || 0,
        color: `var(${ b.color })`,
      }));
    },

    severityCards() {
      return Object.keys(SEVERITY_COLOR).map((sev) => ({
        key:   sev,
        label: this.t(`vexscan.overview.severity.${ sev }`),
        value: this.summary[sev] || 0,
        color: `var(${ SEVERITY_COLOR[sev] })`,
      }));
    },

    componentHeaders() {
      return [
        { name: 'component', labelKey: 'vexscan.overview.table.component', value: 'component' },
        { name: 'image', labelKey: 'tableHeaders.image', value: 'image' },
        { name: 'affected', labelKey: 'vexscan.overview.bucket.affected', value: 'affected' },
        { name: 'vexed', labelKey: 'vexscan.overview.bucket.vexed', value: 'vexed' },
        { name: 'undetermined', labelKey: 'vexscan.overview.bucket.undetermined', value: 'undetermined' },
        { name: 'ruledOut', labelKey: 'vexscan.overview.bucket.ruledOut', value: 'ruledOut' },
        {
          name: 'reportConfigMapRef', label: 'Full report', formatter: 'ConfigMapLink', value: 'reportConfigMapRef',
        },
      ];
    },

    // Lightweight trend: just the summary counts from each past scan (no
    // findings/evidence), already capped to a fixed length by
    // scanner/entrypoint.sh - shown newest-first so the latest scan (which
    // duplicates the cards above) is still a useful sanity-check anchor.
    historyRows() {
      return [...(this.report?.status?.history || [])].reverse();
    },

    historyHeaders() {
      return [
        {
          name: 'time', labelKey: 'vexscan.overview.table.scanTime', value: 'time', formatter: 'LiveDate', sort: 'time',
        },
        { name: 'rke2Version', labelKey: 'vexscan.overview.rke2Version', value: 'rke2Version' },
        { name: 'affected', labelKey: 'vexscan.overview.bucket.affected', value: 'affected' },
        { name: 'vexed', labelKey: 'vexscan.overview.bucket.vexed', value: 'vexed' },
        { name: 'undetermined', labelKey: 'vexscan.overview.bucket.undetermined', value: 'undetermined' },
        { name: 'ruledOut', labelKey: 'vexscan.overview.bucket.ruledOut', value: 'ruledOut' },
      ];
    },
  },

  methods: {
    async scanNow() {
      if (!this.cronJob) {
        return;
      }

      this.scanning = true;
      this.scanError = null;

      try {
        // Reuses Rancher's built-in CronJob#runNow(), the same action
        // available from Workloads > CronJobs > (kebab) > Run Now. It
        // clones spec.jobTemplate into a new Job owned by this CronJob, so
        // no extra RBAC or custom Steve action is required.
        await this.cronJob.runNow();
      } catch (e) {
        this.scanError = e?.message || e;
      } finally {
        this.scanning = false;
      }
    },
  },
};
</script>

<template>
  <Loading v-if="$fetchState.pending" />
  <div
    v-else
    class="vexscan-overview"
  >
    <header class="vexscan-header">
      <div>
        <h1>{{ t('vexscan.overview.title') }}</h1>
        <p class="subtitle">
          {{ t('vexscan.overview.subtitle') }}
        </p>
      </div>
      <button
        v-tooltip="!isPrime ? t('vexscan.overview.primeRequired') : (canScanNow ? undefined : t('vexscan.overview.scanNowNoPermission'))"
        class="btn role-primary"
        :disabled="!cronJob || scanning || !canScanNow || !isPrime"
        @click="scanNow"
      >
        <i
          class="icon"
          :class="scanning ? 'icon-spinner icon-spin' : 'icon-refresh'"
        />
        {{ t('vexscan.overview.scanNow') }}
      </button>
    </header>

    <Banner
      v-if="!isPrime"
      color="error"
      :label="t('vexscan.overview.primeRequired')"
    />
    <Banner
      v-if="scanError"
      color="error"
      :label="scanError"
    />
    <Banner
      v-if="!cronJob"
      color="warning"
      label="vexscan-scanner CronJob not found in cattle-vexscan-system - install the vexscan-scanner chart first."
    />
    <Banner
      v-else-if="!report"
      color="info"
      :label="t('vexscan.overview.noReport')"
    />
    <Banner
      v-if="cronJob && !canScanNow"
      color="info"
      :label="t('vexscan.overview.scanNowNoPermission')"
    />
    <Banner
      v-if="phase === 'Failed'"
      color="error"
      :label="t('vexscan.overview.scanFailed', { message: failureMessage })"
    />
    <Banner
      v-if="truncationMessage"
      color="warning"
      :label="truncationMessage"
    />

    <template v-if="report && isPrime">
      <div class="meta-row">
        <div class="meta-item">
          <label>{{ t('vexscan.overview.rke2Version') }}</label>
          <code>{{ rke2Version }}</code>
        </div>
        <div class="meta-item">
          <label>{{ t('vexscan.overview.lastScan') }}</label>
          <span>{{ lastScanTime }}</span>
        </div>
      </div>

      <h3 class="section-heading">
        {{ t('vexscan.overview.bucketHeading') }}
      </h3>
      <p class="section-subtitle">
        {{ t('vexscan.overview.bucketSubtitle') }}
      </p>
      <div class="bucket-row">
        <div
          v-for="card in bucketCards"
          :key="card.key"
          class="bucket-card"
          :style="{ borderLeftColor: card.color }"
        >
          <div class="bucket-label">
            {{ card.label }}
          </div>
          <div class="bucket-value">
            {{ card.value }}
          </div>
          <div class="bucket-note">
            {{ card.note }}
          </div>
        </div>
      </div>

      <h3 class="section-heading">
        {{ t('vexscan.overview.severityHeading') }}
      </h3>
      <p class="section-subtitle">
        {{ t('vexscan.overview.severitySubtitle', { affected: summary.affected || 0 }) }}
      </p>
      <div class="severity-row">
        <div
          v-for="card in severityCards"
          :key="card.key"
          class="severity-card"
          :style="{ borderTopColor: card.color }"
        >
          <div
            class="severity-value"
            :style="{ color: card.color }"
          >
            {{ card.value }}
          </div>
          <div class="severity-label">
            {{ card.label }}
          </div>
        </div>
      </div>

      <h3>{{ t('vexscan.overview.table.component') }}</h3>
      <SortableTable
        :rows="componentResults"
        :headers="componentHeaders"
        key-field="component"
        :paging="true"
        :rows-per-page="10"
        :table-actions="false"
        :row-actions="false"
      />

      <h3 v-if="historyRows.length">
        {{ t('vexscan.overview.table.history') }}
      </h3>
      <SortableTable
        v-if="historyRows.length"
        :rows="historyRows"
        :headers="historyHeaders"
        key-field="time"
        :paging="true"
        :rows-per-page="10"
        :table-actions="false"
        :row-actions="false"
      />
    </template>
  </div>
</template>

<style lang="scss" scoped>
// These aren't Rancher Dashboard theme tokens (it has no notion of CVE
// severity/VEX-triage colors) - scoped locally here using the same hex
// values as contrib/vexscan-dashboard.py's own :root vars, so this page and
// the CLI's HTML dashboard read as the same tool rather than inventing a
// separate palette.
.vexscan-overview {
  --sev-critical-bg: #B13333;
  --sev-high-bg: #E45C1E;
  --sev-medium-bg: #FFE47A;
  --sev-medium-border: #E5A200;
  --sev-low-bg: #DFE6F2;
  --sev-unknown-bg: #6C6C76;
  --ok-border: #1A7A41;
}

.section-heading {
  margin-bottom: 2px;
}

.section-subtitle {
  color: var(--muted);
  font-size: 13px;
  margin-top: 0;
  margin-bottom: 10px;
}

.bucket-row {
  display: flex;
  gap: 12px;
  margin-bottom: 24px;
}

.bucket-card {
  flex: 1;
  border: 1px solid var(--border);
  border-left: 4px solid;
  border-radius: var(--border-radius);
  padding: 12px;
  background: var(--box-bg);

  .bucket-label {
    font-size: 12px;
    font-weight: 600;
    text-transform: uppercase;
    color: var(--muted);
  }

  .bucket-value {
    font-size: 28px;
    font-weight: 600;
  }

  .bucket-note {
    font-size: 12px;
    color: var(--muted);
  }
}

.vexscan-header {
  display: flex;
  justify-content: space-between;
  align-items: flex-start;
  margin-bottom: 20px;

  .subtitle {
    color: var(--muted);
    max-width: 60ch;
  }
}

.meta-row {
  display: flex;
  gap: 40px;
  margin-bottom: 20px;

  .meta-item {
    display: flex;
    flex-direction: column;

    label {
      font-size: 12px;
      color: var(--muted);
      text-transform: uppercase;
    }
  }
}

.severity-row {
  display: flex;
  gap: 12px;
  margin-bottom: 30px;
}

.severity-card {
  flex: 1;
  border: 1px solid var(--border);
  border-top: 3px solid;
  border-radius: var(--border-radius);
  padding: 12px;
  text-align: center;
  background: var(--box-bg);

  .severity-value {
    font-size: 28px;
    font-weight: 600;
  }

  .severity-label {
    font-size: 12px;
    color: var(--muted);
    text-transform: uppercase;
  }
}
</style>
