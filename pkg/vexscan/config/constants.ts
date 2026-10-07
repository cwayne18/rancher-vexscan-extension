// Single source of truth for the product/resource names used across
// product.ts, routing, models and pages, so a rename only happens here.
export const PRODUCT_NAME = 'vexscan';
export const SCAN_REPORT = 'vexscan.cattle.io.vexscanreport';
export const OVERVIEW_PAGE = 'overview';

export const SEVERITIES = ['critical', 'high', 'medium', 'low', 'unknown'] as const;
export type Severity = typeof SEVERITIES[number];
