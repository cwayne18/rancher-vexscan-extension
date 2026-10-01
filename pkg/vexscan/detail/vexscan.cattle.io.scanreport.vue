<script>
import SortableTable from '@shell/components/SortableTable';
import { Banner } from '@components/Banner';

// Same bucket vocabulary/colors as pages/overview.vue and
// contrib/vexscan-dashboard.py's BUCKET_*/CARD_NOTES - kept in sync by hand
// since this is a separate Vue component (the generic resource detail page
// mounts whichever <type>.vue lives in detail/, independent of overview.vue).
const BUCKETS = [
  {
    key: 'affected', label: 'Affected', note: 'present and loadable', color: '#B13333',
  },
  {
    key: 'vexed', label: 'Already Vexed', note: 'somebody has answered', color: '#1A7A41',
  },
  {
    key: 'undetermined', label: 'Undetermined', note: 'needs a human', color: '#E5A200',
  },
  {
    key: 'ruledOut', label: 'Ruled Out', note: 'not present or unreachable', color: '#1F67DB',
  },
];

const SEVERITIES = ['critical', 'high', 'medium', 'low', 'unknown'];

export default {
  name: 'VexScanReportDetail',

  components: { SortableTable, Banner },

  props: {
    value: {
      type:     Object,
      required: true,
    },
  },

  computed: {
    summary() {
      return this.value?.status?.summary || {};
    },

    // status.message doubles as a human-readable note on *any* non-nominal
    // condition the scanner recorded - today that's only the ConfigMap
    // size-degradation note (see scanner/entrypoint.sh), but phase=Failed
    // errors are written through the same field.
    message() {
      return this.value?.status?.message || '';
    },

    componentResults() {
      return this.value?.status?.componentResults || [];
    },

    bucketCards() {
      return BUCKETS.map((b) => ({ ...b, value: this.summary[b.key] || 0 }));
    },

    severityCards() {
      return SEVERITIES.map((sev) => ({ key: sev, label: sev, value: this.summary[sev] || 0 }));
    },

    headers() {
      return [
        { name: 'component', labelKey: 'vexscan.overview.table.component', value: 'component' },
        { name: 'image', labelKey: 'tableHeaders.image', value: 'image' },
        { name: 'affected', labelKey: 'vexscan.overview.bucket.affected', value: 'affected' },
        { name: 'vexed', labelKey: 'vexscan.overview.bucket.vexed', value: 'vexed' },
        { name: 'undetermined', labelKey: 'vexscan.overview.bucket.undetermined', value: 'undetermined' },
        { name: 'ruledOut', labelKey: 'vexscan.overview.bucket.ruledOut', value: 'ruledOut' },
        {
          name:     'reportConfigMapRef',
          label:    'Full report',
          // Registered by formatters/ConfigMapLink.vue - links to the core
          // Explorer ConfigMap detail view for the gzipped vexscan JSON
          // report (key: report.json.gz; large reports may have had
          // evidence chains stripped or been capped per status bucket to
          // fit the 1MiB ConfigMap limit, see status.message - no bucket is
          // ever fully dropped).
          formatter: 'ConfigMapLink',
          value:    'reportConfigMapRef',
        },
      ];
    },
  },
};
</script>

<template>
  <div>
    <Banner
      v-if="message"
      color="warning"
      :label="message"
    />

    <h3 class="section-heading">
      Triage verdict
    </h3>
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
      By severity
    </h3>
    <div class="summary">
      <div
        v-for="card in severityCards"
        :key="card.key"
        class="summary-item"
      >
        <label>{{ card.label }}</label>
        <span>{{ card.value }}</span>
      </div>
    </div>

    <h3>Per-component findings</h3>
    <SortableTable
      :rows="componentResults"
      :headers="headers"
      key-field="component"
      :search="false"
      :table-actions="false"
      :row-actions="false"
    />
  </div>
</template>

<style lang="scss" scoped>
.section-heading {
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

.summary {
  display: flex;
  gap: 24px;
  margin-bottom: 20px;

  .summary-item {
    display: flex;
    flex-direction: column;

    label {
      font-size: 12px;
      text-transform: uppercase;
      color: var(--muted);
    }

    span {
      font-size: 20px;
      font-weight: 600;
    }
  }
}
</style>
