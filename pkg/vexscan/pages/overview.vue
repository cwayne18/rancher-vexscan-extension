<script>
import { WORKLOAD_TYPES } from '@shell/config/types';
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
        { name: 'findings', labelKey: 'vexscan.overview.table.cve', value: 'findings' },
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
        class="btn role-primary"
        :disabled="!cronJob || scanning"
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

    <template v-if="report">
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
        :search="false"
        :table-actions="false"
        :row-actions="false"
      />
    </template>
  </div>
</template>

<style lang="scss" scoped>
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
