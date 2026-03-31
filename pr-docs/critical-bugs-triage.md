# Critical Bugs Triage — Agent Orchestrator

**Date:** March 31, 2026
**Author:** Deepak Veluvolu

---

## Overview

After auditing 100+ open issues on [ComposioHQ/agent-orchestrator](https://github.com/ComposioHQ/agent-orchestrator), the following bugs are the highest-priority fixes. These cause **silent failures, crash loops, orphaned processes, and broken worker sessions** — directly impacting reliability and user trust.

Ranked by severity × blast radius.

---

## 1. Silent Prompt Delivery Failure (#718)

**Severity:** 🔴 Critical — sessions spawn but do nothing, no one is notified

### Problem

When AO spawns a Claude Code session, the initial prompt is delivered post-launch via `sendMessage()` after a 5-second delay. If delivery fails, the error is **silently swallowed** in a bare `catch {}`:

```typescript
if (plugins.agent.promptDelivery === "post-launch" && agentLaunchConfig.prompt) {
  try {
    await new Promise((resolve) => setTimeout(resolve, 5_000));
    await plugins.runtime.sendMessage(handle, agentLaunchConfig.prompt);
  } catch {
    // Non-fatal: agent is running but didn't receive the initial prompt.
    // User can retry with `ao send`.
  }
}
```

The spawn call returns success. The agent sits idle at an empty prompt. Nobody knows.

### Impact

- Wasted compute time (agent idle, no work done)
- User trust erosion — AO reports success but nothing happens
- Manual intervention required to detect and fix

### Fix

**A. Retry with backoff** (primary fix):

```typescript
async function deliverPromptWithRetry(
  runtime: RuntimePlugin,
  handle: RuntimeHandle,
  prompt: string,
  maxRetries = 3
): Promise<boolean> {
  for (let attempt = 0; attempt < maxRetries; attempt++) {
    try {
      const delay = 5_000 + attempt * 3_000; // 5s, 8s, 11s
      await sleep(delay);
      await runtime.sendMessage(handle, prompt);
      return true;
    } catch (err) {
      log.warn(`Prompt delivery attempt ${attempt + 1} failed`, { err });
    }
  }
  return false;
}
```

**B. Surface failure to caller:**

```typescript
const delivered = await deliverPromptWithRetry(plugins.runtime, handle, prompt);
if (!delivered) {
  log.error("Prompt delivery failed after retries", { sessionId });
  session.metadata.promptDeliveryFailed = true;
  // Notify via configured notifier
  await plugins.notifier?.notify({
    type: "spawn-warning",
    message: `Session ${sessionId} spawned but prompt delivery failed. Use \`ao send\` to retry.`,
  });
}
```

**C. Lifecycle anomaly detection:**

A freshly spawned session transitioning to `needs_input` within 30 seconds is almost certainly a failed prompt. The lifecycle manager should flag this:

```typescript
if (session.status === "needs_input" && session.age < 30_000 && !session.metadata.promptDelivered) {
  await this.fireReaction(session, "prompt-delivery-failed");
}
```

### Files Changed

| File | Change |
|------|--------|
| `packages/core/src/session-manager.ts` | Replace bare catch with retry + notification |
| `packages/core/src/lifecycle-manager.ts` | Add anomaly detection for early `needs_input` |

---

## 2. tmux Server Dies Silently → Crash Loop (#695)

**Severity:** 🔴 Critical — orchestrator becomes unreachable, dashboard orphaned

### Problem

The tmux server dies silently after ~5 minutes. The orchestrator session disappears. The Next.js dashboard stays alive as an orphan on its port. Subsequent `ao start` picks a new port, compounding the mess.

After 5 start/stop cycles, you can have 5+ orphaned processes fighting for ports.

### Root Cause

No health monitoring of the tmux server. When it dies:
1. Lifecycle manager can't poll sessions (tmux commands fail)
2. No restart mechanism exists
3. Dashboard isn't notified
4. `ao stop` can't find the orphaned dashboard (wrong port)

### Fix

**A. tmux health watchdog** in lifecycle manager:

```typescript
class TmuxWatchdog {
  private checkInterval = 15_000; // 15s

  async check(): Promise<boolean> {
    try {
      await exec("tmux", ["list-sessions"]);
      return true;
    } catch {
      return false;
    }
  }

  async ensureAlive(): Promise<void> {
    const alive = await this.check();
    if (!alive) {
      log.error("tmux server died — attempting restart");
      await exec("tmux", ["new-session", "-d", "-s", "ao-watchdog"]);
      // Re-create orchestrator session
      await this.restoreOrchestratorSession();
    }
  }
}
```

**B. Process group cleanup on stop:**

```typescript
async function stopAll(): Promise<void> {
  // Kill by process group, not just port
  const pids = await findProcessesByName(["next-server", "terminal-websocket", "direct-terminal-ws"]);
  for (const pid of pids) {
    process.kill(pid, "SIGTERM");
  }
  // Also kill tmux sessions
  await exec("tmux", ["kill-server"]).catch(() => {});
}
```

**C. PID file with port tracking:**

Write the actual assigned port to `running.json` so `ao stop` always knows where the dashboard lives, even after port reassignment.

### Files Changed

| File | Change |
|------|--------|
| `packages/core/src/lifecycle-manager.ts` | Add tmux watchdog to poll cycle |
| `packages/cli/src/commands/start.ts` | Write actual port to `running.json` after startup |
| `packages/cli/src/commands/stop.ts` | Kill by process tree, not just port |

---

## 3. Killed Sessions with Open PRs Go Dark (#700)

**Severity:** 🔴 Critical — merged/failed PRs get no reaction after agent exits

### Problem

When a worker agent exits (`status: killed`), the lifecycle manager stops polling that session entirely. If the PR is still open, CI failures, merge conflicts, and approvals are never detected.

### Root Cause

Two issues in `lifecycle-manager.ts`:

1. **`sessionsToCheck` filter**: Killed sessions are excluded after the initial transition cycle
2. **`determineStatus` early return**: Dead runtime is detected → returns `"killed"` immediately, skipping PR state checks

### Fix

**A. Keep polling sessions with open PRs:**

```typescript
const sessionsToCheck = sessions.filter(s =>
  isActiveStatus(s.status) ||
  (s.status === "killed" && s.pr?.state === "open")
);
```

**B. Skip runtime checks for already-killed sessions:**

```typescript
async determineStatus(session: Session): Promise<Status> {
  // For killed sessions with open PRs, skip runtime liveness check
  // and proceed directly to PR state evaluation
  if (session.status === "killed" && session.pr?.state === "open") {
    return this.evaluatePRState(session);
  }

  // Normal flow: check runtime first
  const alive = await this.checkRuntime(session);
  if (!alive) return "killed";

  return this.evaluatePRState(session);
}
```

**C. Define reactions for orphaned PRs:**

| PR State | Reaction | Action |
|----------|----------|--------|
| CI failed | `ci-failed` | Respawn agent to fix |
| Merge conflicts | `merge-conflicts` | Respawn agent to rebase |
| Approved + green | `approved-and-green` | Auto-merge |
| Changes requested | `changes-requested` | Respawn agent to address |

### Files Changed

| File | Change |
|------|--------|
| `packages/core/src/lifecycle-manager.ts` | Fix filter + early return |

---

## 4. Claude Code Bypass Permissions Prompt Blocks Workers (#817)

**Severity:** 🔴 Critical — all permissionless worker sessions broken

### Problem

Claude Code v2.1.x added an interactive confirmation prompt for `--dangerously-skip-permissions`:

```
WARNING: Claude Code running in Bypass Permissions mode
❯ 1. No, exit
  2. Yes, I accept
```

tmux sessions are non-interactive — no one presses the keys. Workers spawn, hit the prompt, and exit immediately.

### Fix

**A. Auto-accept via tmux keystroke injection:**

```typescript
function getLaunchCommand(config: AgentConfig): string {
  const baseCmd = `claude --dangerously-skip-permissions`;

  if (config.permissions === "permissionless") {
    // Background subshell auto-accepts the bypass prompt
    return `(sleep 3 && tmux send-keys -t "$AO_TMUX_NAME" Down Enter 2>/dev/null) & ${baseCmd}`;
  }

  return baseCmd;
}
```

**B. Check for `--yes` flag first:**

Claude Code may support `--yes` or `--accept` in future versions. Check release notes and prefer a non-interactive flag if available:

```typescript
const supportsYesFlag = await detectClaudeCodeVersion() >= "2.1.5";
if (supportsYesFlag) {
  return `claude --dangerously-skip-permissions --yes`;
}
// Fallback to tmux keystroke injection
```

### Files Changed

| File | Change |
|------|--------|
| `packages/plugins/agent-claude-code/src/index.ts` | Add auto-accept wrapper |

---

## 5. Bot Review Comments Leak Through Filter (#702)

**Severity:** 🟡 High — agents receive duplicate work from same bot comment

### Problem

GitHub's GraphQL API returns bot logins **without** the `[bot]` suffix, while REST API includes it. The `BOT_AUTHORS` filter only has `[bot]` variants:

| API | Login returned | BOT_AUTHORS match? |
|-----|---------------|-------------------|
| GraphQL | `cursor` | ❌ No |
| REST | `cursor[bot]` | ✅ Yes |

Bot comments pass through `getPendingComments()` (GraphQL) as "human" comments, triggering a `changes-requested` reaction. The same comments are caught by `getAutomatedComments()` (REST), triggering `bugbot-comments`. The agent gets both — duplicate work.

### Fix

Add `__typename` check to the GraphQL filter:

```typescript
// In getPendingComments() thread filter
const isBot =
  comment.author?.__typename === "Bot" ||
  BOT_AUTHORS.has(comment.author?.login ?? "") ||
  BOT_AUTHORS.has(`${comment.author?.login}[bot]`);

if (isBot) continue;
```

Update the GraphQL query to include `__typename`:

```graphql
author {
  login
  __typename
}
```

### Files Changed

| File | Change |
|------|--------|
| `packages/plugins/scm-github/src/index.ts` | Add `__typename` to query + filter |

---

## 6. ${VAR} References Not Expanded in Config (#701)

**Severity:** 🟡 High — users forced to hardcode secrets in config file

### Problem

`agent-orchestrator.yaml` doesn't expand `${ENV_VAR}` placeholders. Webhook URLs, API tokens, etc. must be hardcoded.

### Fix

Add substitution pass before YAML parsing in `config.ts`:

```typescript
function expandEnvVars(raw: string): string {
  return raw.replace(/\$\{([^}]+)\}/g, (match, varName) => {
    const value = process.env[varName.trim()];
    if (value === undefined) {
      log.warn(`Config references undefined env var: ${varName}`);
      return match; // Leave placeholder unchanged
    }
    return value;
  });
}

export function loadConfig(configPath: string): Config {
  const raw = readFileSync(configPath, "utf-8");
  const expanded = expandEnvVars(raw);
  return parseYaml(expanded) as Config;
}
```

### Files Changed

| File | Change |
|------|--------|
| `packages/core/src/config.ts` | Add `expandEnvVars()` before parse |

---

## 7. /tmp .so File Leak with OpenCode Agent (#835)

**Severity:** 🟡 High — disk exhaustion over hours

### Problem

The OpenCode agent plugin runs `/usr/local/lib/.../opencode install --no-cache` repeatedly during lifecycle, each invocation creating a new `.so` file in `/tmp`. After a few hours: 4,000+ files, disk full, service dies.

### Fix

**A. Cache the detection result:**

```typescript
let openCodeDetected: boolean | null = null;

function detect(): boolean {
  if (openCodeDetected !== null) return openCodeDetected;
  openCodeDetected = /* actual detection */;
  return openCodeDetected;
}
```

**B. Skip `install --no-cache` if already installed:**

```typescript
async function ensureInstalled(): Promise<void> {
  if (await isInstalled()) return; // Check binary exists
  await exec("opencode", ["install"]); // Only run once
}
```

**C. Cleanup stale .so files on stop:**

```typescript
// In ao stop
await exec("find", ["/tmp", "-name", "*-00000000.so", "-delete"]);
```

### Files Changed

| File | Change |
|------|--------|
| `packages/plugins/agent-opencode/src/index.ts` | Cache detection, skip redundant installs |
| `packages/cli/src/commands/stop.ts` | Clean up /tmp .so files |

---

## Priority Matrix

| # | Issue | Severity | Effort | Fix First? |
|---|-------|----------|--------|------------|
| 1 | #718 Silent prompt failure | 🔴 Critical | Medium | ✅ Yes |
| 2 | #695 tmux crash loop | 🔴 Critical | High | ✅ Yes |
| 3 | #700 Killed sessions go dark | 🔴 Critical | Low | ✅ Yes |
| 4 | #817 Bypass prompt blocks workers | 🔴 Critical | Low | ✅ Yes |
| 5 | #702 Bot comment leak | 🟡 High | Low | ✅ Yes |
| 6 | #701 Config env var expansion | 🟡 High | Low | Next |
| 7 | #835 /tmp .so leak | 🟡 High | Low | Next |

**Recommended order:** #700 → #817 → #718 → #702 → #701 → #835 → #695

Start with #700 and #817 — lowest effort, highest impact. Then #718 (the silent failure everyone hits). Save #695 (tmux watchdog) for last since it's the most complex.

---

## Summary

Seven bugs. Four are critical — silent failures that break core workflows with no user-visible error. Three are high-severity — cause wasted resources or force unsafe workarounds.

Combined, these fixes would eliminate the most common failure modes reported in the last two weeks of issues.
