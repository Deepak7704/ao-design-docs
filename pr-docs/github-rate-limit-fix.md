# GitHub Rate Limit Fix

**Date:** March 22, 2026

---

## Problem

- 2,000-4,000 API calls/hour (40-80% of GitHub's 5,000/hour limit)
- Concurrent agents make duplicate calls for same PR
- `enrichSessionPR` triggers 6-7 API calls per PR
- `getCISummary()` internally calls `getCIChecks()` (duplicate)

---

## Solution

| Approach | Mechanism | Reduction |
|----------|-----------|-----------|
| **Deduplication** | Share concurrent identical requests | ~15-20% |
| **Batching** | Combine multiple gh calls into one | ~30-40% |
| **Total** | Both approaches | **~60%** |

**Why not caching?** No invalidation logic, no staleness concerns, simpler implementation.

---

## Implementation

### Step 1: Create Deduplication Module

**New file:** `packages/plugins/scm-github/src/dedupe.ts`

```typescript
export class RequestDeduplicator {
  private pendingRequests = new Map<string, Promise<unknown>>();

  async dedupe<T>(key: string, fn: () => Promise<T>): Promise<T> {
    const existing = this.pendingRequests.get(key);
    if (existing) return existing as Promise<T>;

    const promise = fn().finally(() => this.pendingRequests.delete(key));
    this.pendingRequests.set(key, promise);
    return promise;
  }
}

export const ghDeduplicator = new RequestDeduplicator();
```

### Step 2: Add Wrapper & Batching

**File:** `packages/plugins/scm-github/src/index.ts`

```typescript
import { ghDeduplicator } from "./dedupe";

async function dedupeGh(args: string[]): Promise<string> {
  const key = `gh:${args.join(":")}`;
  return ghDeduplicator.dedupe(key, async () => gh(args));
}

// Batch PR view - fetch all fields in one call
const prViewDataCache = new WeakMap<PRInfo, any>();

async function getBatchedPRData(pr: PRInfo) {
  const cached = prViewDataCache.get(pr);
  if (cached) return cached;

  const raw = await dedupeGh([
    "pr", "view", String(pr.number), "--repo", repoFlag(pr),
    "--json", "state,title,additions,deletions,reviewDecision,reviews,mergeable,mergeStateStatus,isDraft"
  ]);

  const data = JSON.parse(raw);
  prViewDataCache.set(pr, data);
  return data;
}
```

### Step 3: Refactor Methods

```typescript
async getPRSummary(pr: PRInfo) {
  const data = await getBatchedPRData(pr);  // No direct gh call
  return { state: parseState(data.state), title: data.title, ... };
}

async getReviewDecision(pr: PRInfo) {
  const data = await getBatchedPRData(pr);  // No direct gh call
  return parseReviewDecision(data.reviewDecision);
}

async getCIChecks(pr: PRInfo) {
  const raw = await dedupeGh([...]);  // Deduped
  return parseChecks(raw);
}

async getCISummary(pr: PRInfo, checks?: CICheck[]) {
  const ciChecks = checks ?? await this.getCIChecks(pr);  // Accept optional to avoid duplicate
  return parseCISummary(ciChecks);
}
```

### Step 4: Replace gh() with dedupeGh()

Replace all `gh([...])` with `dedupeGh([...])` in:
- `getCIChecks()`
- `getPendingComments()`
- `getAutomatedComments()`

---

## Files Changed

| File | Change |
|-------|---------|
| `packages/plugins/scm-github/src/dedupe.ts` | New (30 lines) |
| `packages/plugins/scm-github/src/index.ts` | Refactor (150 lines) |

---

## Expected Impact

| Metric | Before | After |
|--------|--------|-------|
| API calls per PR enrichment | 6-7 | ~3 |
| 5 concurrent agents, same PR | 20 calls | ~4 calls |
| Total calls/hour | 2,000-4,000 | ~800-1,600 |
| **Reduction** | - | **~60%** |

---

## Summary

- **Approach:** Deduplication + Batching (no caching)
- **Complexity:** Low (no state to manage, no invalidation)
- **Impact:** ~60% reduction, stays under GitHub rate limit
- **Timeline:** 1-2 days to implement and test
