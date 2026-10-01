<script>
import SortableTable from '@shell/components/SortableTable';

export default {
  name: 'VexScanReportDetail',

  components: { SortableTable },

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

    componentResults() {
      return this.value?.status?.componentResults || [];
    },

    headers() {
      return [
        { name: 'component', labelKey: 'vexscan.overview.table.component', value: 'component' },
        { name: 'image', labelKey: 'tableHeaders.image', value: 'image' },
        { name: 'findings', labelKey: 'vexscan.overview.table.cve', value: 'findings' },
        {
          name:     'reportConfigMapRef',
          label:    'Full report',
          formatter: 'ConfigMapLink', // see README - optional formatter that links to the ConfigMap holding the full `vexscan --format json` output
          value:    'reportConfigMapRef',
        },
      ];
    },
  },
};
</script>

<template>
  <div>
    <div class="summary">
      <div
        v-for="(count, sev) in summary"
        :key="sev"
        class="summary-item"
      >
        <label>{{ sev }}</label>
        <span>{{ count }}</span>
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
