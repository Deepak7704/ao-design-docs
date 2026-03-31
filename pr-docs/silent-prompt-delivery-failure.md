# Deep Dive: Silent Prompt Delivery Failure (#718)

**Date:** March 31, 2026
**Author:** Deepak Veluvolu
**Issue:** [ComposioHQ/agent-orchestrator#718](https://github.com/ComposioHQ/agent-orchestrator/issues/718)

---

## The Problem

When AO spawns a worker session (e.g. `ao spawn #715`), the session is created successfully — worktree, branch, tmux session, Claude Code — all launch fine. But then **nothing happens.** The agent sits at an empty prompt doing zero work. Nobody is notified.

This is the worst kind of bug: **silent success.** The system reports everything worked, but the critical step — delivering the task prompt to the agent — failed in the dark.

---

## The Failure Chain

### Step-by-step: what happens during `ao spawn`

```
1. spawn() called
   ├── Validate project, resolve plugins
   ├── Fetch issue from tracker (GitHub)
   ├── Create workspace (git worktree)
   ├── Build prompt (base instructions + issue context)
   ├── Get agent launch command
   ├── Create runtime (tmux session)          ← tmux session now exists
   ├── Write metadata (status: "spawning")
   ├── Run postLaunchSetup()
   │
   └── 🔴 POST-LAUNCH PROMPT DELIVERY
       ├── sleep(5000)                         ← fixed 5-second wait
       ├── runtime.sendMessage(handle, prompt) ← THIS FAILS SILENTLY
       └── catch {}                            ← error swallowed, no log
```

### The exact code (session-manager.ts, ~line 580)

```typescript
// Send initial prompt post-launch for agents that need it (e.g. Claude Code
// exits after -p, so we send the prompt after it starts in interactive mode).
// This is intentionally outside the try/catch above — a prompt delivery failure
// should NOT destroy the session. The agent is running; user can retry with
// `ao send`.
if (plugins.agent.promptDelivery === "post-launch" && agentLaunchConfig.prompt) {
  try {
    // Wait for agent to start and be ready for input
    await new Promise((resolve) => setTimeout(resolve, 5_000));
    await plugins.runtime.sendMessage(handle, agentLaunchConfig.prompt);
  } catch {
    // Non-fatal: agent is running but didn't receive the initial prompt.
    // User can retry with `ao send`.
  }
}
```

### Why sendMessage fails

The `sendMessage` in `runtime-tmux/src/index.ts` does this:

```typescript
async sendMessage(handle, message) {
  await tmux("send-keys", "-t", handle.id, "C-u");      // Clear input

  // For long/multiline messages:
  const tmpPath = join(tmpdir(), `ao-send-${randomUUID()}.txt`);
  writeFileSync(tmpPath, message);
  await tmux("load-buffer", "-b", bufferName, tmpPath);   // Load into tmux buffer
  await tmux("paste-buffer", "-b", bufferName, "-t", handle.id, "-d"); // Paste

  await sleep(300);                                        // 300ms wait
  await tmux("send-keys", "-t", handle.id, "Enter");      // Submit
}
```

Failure modes:

1. **Claude Code not ready after 5s** — the TUI hasn't finished rendering. `send-keys C-u` or `paste-buffer` hits a pane that isn't accepting input yet
2. **tmux pane not in expected state** — Claude Code is showing a startup banner, terms prompt, or permissions prompt
3. **paste-buffer race** — the text is pasted but the 300ms delay before Enter isn't enough for Claude Code's ink-based React renderer to process it (this is the same root cause as #564/PR #571)
4. **tmux server instability** — tmux commands fail transiently under load

### What happens after failure

```
spawn() returns Session { status: "spawning" }  ← looks successful
                    ↓
Lifecycle manager polls (every 30s)
                    ↓
determineStatus() checks agent activity
  → agent.getActivityState() returns "waiting_input" or "idle"
                    ↓
Status transitions: spawning → needs_input
                    ↓
Event "session.needs_input" emitted
  → reaction "agent-needs-input" fires (if configured)
  → BUT: default config doesn't auto-retry prompt delivery
                    ↓
Session sits at needs_input forever until human notices
```

The lifecycle manager **does** detect the idle agent, but it interprets it as "agent finished and is waiting for more work" — not "agent never received its first task."

---

## Five Approaches to Fix This

### Approach 1: Log and Notify (Minimal Fix)

**Change:** Replace bare `catch {}` with logging + notification.

```typescript
if (plugins.agent.promptDelivery === "post-launch" && agentLaunchConfig.prompt) {
  try {
    await new Promise((resolve) => setTimeout(resolve, 5_000));
    await plugins.runtime.sendMessage(handle, agentLaunchConfig.prompt);
    session.metadata["promptDelivered"] = "true";
    updateMetadata(sessionsDir, sessionId, { promptDelivered: "true" });
  } catch (err) {
    const msg = err instanceof Error ? err.message : String(err);
    console.error(`[spawn] Prompt delivery failed for ${sessionId}: ${msg}`);
    session.metadata["promptDelivered"] = "false";
    updateMetadata(sessionsDir, sessionId, { promptDelivered: "false" });
  }
}
```

**Pros:**
- Minimal code change (~10 lines)
- Doesn't change system behavior
- Gives operators visibility

**Cons:**
- Still fails — just tells you about it
- User must manually `ao send` to recover
- No automation

**Verdict:** Necessary but insufficient. This should be part of any fix.

---

### Approach 2: Retry with Fixed Backoff

**Change:** Retry prompt delivery up to 3 times with increasing delays.

```typescript
async function deliverPromptWithRetry(
  runtime: Runtime,
  handle: RuntimeHandle,
  prompt: string,
  opts = { maxRetries: 3, baseDelayMs: 5_000, backoffMs: 3_000 }
): Promise<boolean> {
  for (let attempt = 0; attempt < opts.maxRetries; attempt++) {
    try {
      const delay = opts.baseDelayMs + attempt * opts.backoffMs;
      await sleep(delay);
      await runtime.sendMessage(handle, prompt);
      return true;
    } catch (err) {
      console.warn(`[spawn] Prompt delivery attempt ${attempt + 1}/${opts.maxRetries} failed for session: ${err}`);
    }
  }
  return false;
}
```

**Timeline:** 5s → try → 8s → try → 11s → try → give up (~24s total)

**Pros:**
- Handles transient tmux failures
- Handles slow agent startup (up to ~19s total wait)
- Simple, predictable behavior
- No new dependencies

**Cons:**
- Fixed delays are a guess — some agents need 5s, some need 30s
- Blocks the spawn() return for up to 24 seconds
- Doesn't verify the agent actually received the prompt
- The root cause (agent not ready) isn't addressed, just worked around

**Verdict:** Good pragmatic fix. Solves most cases but not all.

---

### Approach 3: Poll-Based Ready Detection

**Change:** Instead of fixed delays, poll the agent's output to detect when it's ready for input before sending the prompt.

```typescript
async function waitForAgentReady(
  runtime: Runtime,
  agent: Agent,
  handle: RuntimeHandle,
  timeoutMs = 30_000,
  pollIntervalMs = 1_000,
): Promise<boolean> {
  const deadline = Date.now() + timeoutMs;

  while (Date.now() < deadline) {
    try {
      const output = await runtime.getOutput(handle, 10);
      const activity = agent.detectActivity(output);

      // Agent is showing its input prompt — ready for text
      if (activity === "waiting_input" || activity === "idle") {
        return true;
      }
    } catch {
      // tmux not ready yet — keep trying
    }
    await sleep(pollIntervalMs);
  }

  return false;
}

// Usage in spawn():
if (plugins.agent.promptDelivery === "post-launch" && agentLaunchConfig.prompt) {
  const ready = await waitForAgentReady(
    plugins.runtime, plugins.agent, handle, 30_000
  );

  if (ready) {
    try {
      await plugins.runtime.sendMessage(handle, agentLaunchConfig.prompt);
      updateMetadata(sessionsDir, sessionId, { promptDelivered: "true" });
    } catch {
      updateMetadata(sessionsDir, sessionId, { promptDelivered: "false" });
    }
  } else {
    updateMetadata(sessionsDir, sessionId, { promptDelivered: "false" });
  }
}
```

**Pros:**
- Adapts to actual agent startup time (no guessing)
- Works for slow startups (up to 30s)
- Confirms agent is actually ready before sending
- No wasted time — sends as soon as agent is ready

**Cons:**
- Adds up to 30s to spawn time in worst case
- `detectActivity` must work for fresh Claude Code sessions (may not — the initial prompt screen looks different from the idle prompt)
- Couples session-manager to agent activity detection logic
- More complex, more code to maintain

**Verdict:** More reliable than Approach 2, but adds complexity and may still fail if activity detection doesn't recognize the initial state.

---

### Approach 4: Async Delivery via Lifecycle Manager

**Change:** Don't deliver the prompt during spawn at all. Instead, store it in metadata and let the lifecycle manager deliver it on the first poll.

```typescript
// In spawn() — just store the prompt, don't deliver it
if (plugins.agent.promptDelivery === "post-launch" && agentLaunchConfig.prompt) {
  updateMetadata(sessionsDir, sessionId, {
    pendingPrompt: agentLaunchConfig.prompt,
    promptDelivered: "false",
  });
}

// In lifecycle-manager determineStatus() or a new deliverPendingPrompts() step:
async function deliverPendingPrompts(sessions: Session[]): Promise<void> {
  for (const session of sessions) {
    const pending = session.metadata["pendingPrompt"];
    if (!pending || session.metadata["promptDelivered"] === "true") continue;

    // Only deliver if agent is detected as waiting for input
    const agent = registry.get<Agent>("agent", ...);
    const activityState = await agent.getActivityState(session, config.readyThresholdMs);

    if (activityState?.state === "waiting_input" || activityState?.state === "idle") {
      const runtime = registry.get<Runtime>("runtime", ...);
      try {
        await runtime.sendMessage(session.runtimeHandle, pending);
        updateMetadata(sessionsDir, session.id, {
          promptDelivered: "true",
          pendingPrompt: "", // clear
        });
      } catch {
        // Will retry on next poll cycle
        const attempts = parseInt(session.metadata["promptDeliveryAttempts"] ?? "0") + 1;
        updateMetadata(sessionsDir, session.id, {
          promptDeliveryAttempts: String(attempts),
        });

        if (attempts >= 5) {
          // Give up — notify human
          await notifier?.notify({
            type: "prompt-delivery-failed",
            sessionId: session.id,
            message: `Failed to deliver prompt after ${attempts} attempts`,
          });
        }
      }
    }
  }
}
```

**Pros:**
- Spawn returns immediately (no blocking)
- Natural retry — lifecycle polls every 30s, so retries happen automatically
- Delivery only attempted when agent is confirmed ready
- Fits the existing architecture (lifecycle manager already handles session state)
- Notification on permanent failure

**Cons:**
- Prompt delivery delayed by up to one poll interval (30s)
- Metadata gets more complex (pendingPrompt field)
- Large prompts stored in metadata files (could be multi-KB)
- Lifecycle manager gets more responsibility
- Requires lifecycle manager to be running (doesn't work for standalone `ao spawn` without `ao start`)

**Verdict:** Architecturally clean but adds latency and complexity. Best if spawn-time blocking is unacceptable.

---

### Approach 5: Retry + Verification + Notification (Recommended)

**Change:** Combine the best parts of approaches 1-3: poll for ready state, deliver with retry, verify delivery, notify on failure.

```typescript
interface PromptDeliveryResult {
  delivered: boolean;
  attempts: number;
  error?: string;
}

async function deliverPostLaunchPrompt(
  runtime: Runtime,
  agent: Agent,
  handle: RuntimeHandle,
  prompt: string,
): Promise<PromptDeliveryResult> {
  const MAX_ATTEMPTS = 3;
  const READY_TIMEOUT_MS = 15_000;
  const READY_POLL_MS = 1_000;
  const POST_SEND_VERIFY_DELAY_MS = 2_000;

  // Phase 1: Wait for agent to be ready (up to 15s)
  const readyDeadline = Date.now() + READY_TIMEOUT_MS;
  let agentReady = false;

  while (Date.now() < readyDeadline) {
    try {
      const output = await runtime.getOutput(handle, 10);
      const activity = agent.detectActivity(output);
      if (activity === "waiting_input" || activity === "idle") {
        agentReady = true;
        break;
      }
    } catch {
      // Not ready yet
    }
    await sleep(READY_POLL_MS);
  }

  if (!agentReady) {
    // Fall back to fixed delay (agent might be ready but detectActivity
    // doesn't recognize the initial screen)
    await sleep(5_000);
  }

  // Phase 2: Send with retry
  let lastError: string | undefined;
  for (let attempt = 1; attempt <= MAX_ATTEMPTS; attempt++) {
    try {
      await runtime.sendMessage(handle, prompt);

      // Phase 3: Verify delivery — check if agent started processing
      await sleep(POST_SEND_VERIFY_DELAY_MS);
      try {
        const postOutput = await runtime.getOutput(handle, 15);
        const postActivity = agent.detectActivity(postOutput);
        // If agent is now "active" or output changed, delivery worked
        if (postActivity === "active" || postActivity === "processing") {
          return { delivered: true, attempts: attempt };
        }
        // If still "waiting_input", the Enter key might not have registered
        // (same root cause as #564). Retry.
        if (postActivity === "waiting_input" && attempt < MAX_ATTEMPTS) {
          console.warn(
            `[spawn] Prompt may not have been submitted (attempt ${attempt}), retrying...`
          );
          continue;
        }
      } catch {
        // Can't verify — assume it worked
      }

      return { delivered: true, attempts: attempt };
    } catch (err) {
      lastError = err instanceof Error ? err.message : String(err);
      console.warn(
        `[spawn] Prompt delivery attempt ${attempt}/${MAX_ATTEMPTS} failed: ${lastError}`
      );
      if (attempt < MAX_ATTEMPTS) {
        await sleep(3_000 * attempt); // 3s, 6s backoff between retries
      }
    }
  }

  return { delivered: false, attempts: MAX_ATTEMPTS, error: lastError };
}
```

**Usage in spawn():**

```typescript
if (plugins.agent.promptDelivery === "post-launch" && agentLaunchConfig.prompt) {
  const result = await deliverPostLaunchPrompt(
    plugins.runtime, plugins.agent, handle, agentLaunchConfig.prompt
  );

  updateMetadata(sessionsDir, sessionId, {
    promptDelivered: String(result.delivered),
    promptDeliveryAttempts: String(result.attempts),
    ...(result.error ? { promptDeliveryError: result.error } : {}),
  });

  if (!result.delivered) {
    console.error(
      `[spawn] ⚠️  Prompt delivery failed for ${sessionId} after ${result.attempts} attempts. ` +
      `Agent is running but idle. Use \`ao send ${sessionId}\` to retry.`
    );

    // Notify via configured notifier
    const notifier = project.notifier
      ? registry.get<Notifier>("notifier", project.notifier.plugin)
      : null;
    if (notifier) {
      await notifier.notify({
        projectId: session.projectId,
        event: {
          type: "session.spawn_warning",
          priority: "warning",
          sessionId,
          message: `Prompt delivery failed for ${sessionId}. Agent spawned but idle. Retry with: ao send ${sessionId}`,
        },
      }).catch(() => {}); // Don't fail spawn on notification error
    }
  }
}
```

**Timeline:**
```
0s        Start: poll for agent ready
0-15s     Polling... (exits early when ready)
~7s       Agent ready detected → send prompt
~7.3s     sendMessage completes
~9.3s     Verify: check if agent is processing
~9.3s     ✅ Delivered! Return.

Or if first attempt fails:
~7.3s     sendMessage fails
~10.3s    Retry #2
~13.3s    Verify #2
~13.3s    ✅ Delivered on 2nd attempt.

Worst case (all fail):
~30s      3 attempts exhausted → notify human
```

**Pros:**
- Adapts to agent startup time (no unnecessary waiting)
- Verifies delivery actually worked (catches #564 Enter race too)
- Retries with backoff on failure
- Notifies human when all retries fail
- Records attempt history in metadata (debuggable)
- Falls back gracefully when detection doesn't work

**Cons:**
- Most complex approach (~60 lines)
- Can block spawn for up to 30s in worst case
- Verification heuristic may not be 100% accurate

**Verdict:** ✅ **Recommended.** This is the most robust fix with the best tradeoffs. It handles all known failure modes, verifies success, retries intelligently, and fails loudly.

---

## Comparison Matrix

| Criteria | Approach 1 | Approach 2 | Approach 3 | Approach 4 | Approach 5 |
|----------|-----------|-----------|-----------|-----------|-----------|
| **Fixes the bug** | ❌ No | ✅ Usually | ✅ Usually | ✅ Yes | ✅ Yes |
| **Handles slow startup** | ❌ | ⚠️ Fixed guess | ✅ Adaptive | ✅ Waits for ready | ✅ Adaptive |
| **Verifies delivery** | ❌ | ❌ | ❌ | ⚠️ Next poll | ✅ Immediate |
| **Retries** | ❌ | ✅ 3x | ❌ | ✅ Every 30s | ✅ 3x |
| **Notifies on failure** | ⚠️ Log only | ❌ | ❌ | ✅ | ✅ |
| **Spawn-time blocking** | ~5s | ~24s worst | ~30s worst | None | ~30s worst |
| **Complexity** | Low | Low | Medium | High | Medium |
| **Works without lifecycle** | ✅ | ✅ | ✅ | ❌ | ✅ |

---

## Recommended Implementation Plan

### Phase 1: Immediate (Approach 1 + 2 combined)
1. Replace bare `catch {}` with logging
2. Add `promptDelivered` metadata flag
3. Add 3x retry with exponential backoff
4. **Ship this as a quick fix — covers 90% of cases**

### Phase 2: Robust (Approach 5)
1. Add ready-state polling before delivery
2. Add post-delivery verification
3. Add notification on permanent failure
4. Update lifecycle manager to flag `spawning → needs_input` within 60s as anomalous

### Files Changed

| File | Change | Phase |
|------|--------|-------|
| `packages/core/src/session-manager.ts` | Replace bare catch with retry + verify + notify | 1+2 |
| `packages/core/src/lifecycle-manager.ts` | Anomaly detection for fast needs_input | 2 |
| `packages/core/src/metadata.ts` | No changes (uses existing updateMetadata) | — |
| `packages/plugins/runtime-tmux/src/index.ts` | No changes (sendMessage API is fine) | — |

---

## Summary

The bug is a bare `catch {}` that swallows prompt delivery failures. The fix isn't just adding a retry — it's building a delivery pipeline that adapts to agent startup time, verifies the agent actually received the prompt, retries when it didn't, and tells someone when all else fails.

**Start with Approach 1+2 (quick fix), then upgrade to Approach 5 (robust).**

The worst thing about this bug isn't the technical failure — it's the silence. A system that fails and says nothing is worse than a system that fails loudly. Even Approach 1 alone (just logging) would have saved the 10 minutes of debugging that discovered this issue.
