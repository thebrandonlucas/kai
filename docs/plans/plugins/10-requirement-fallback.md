# Plan 10: Run optional requirement fallback actions

**Commit:** `feat: support backend requirement fallback`  
**Budget:** 200–350 changed code/test lines  
**Depends on:** plan 09b

## Goal

Let a backend describe a visible, optional recovery action when its driver or
required programs cannot be verified.

## Changes

1. Finalize backend fallback metadata as pure data:
   - optional custom prompt text, with a generic confirmation prompt otherwise;
   - an ordered list of existing executor actions;
   - no implicit package-manager switch.
   Every non-empty fallback action list requires explicit confirmation.
2. On preflight failure:
   - return the normal diagnostic when no fallback exists;
   - show the exact planned actions;
   - always ask for confirmation before fallback actions;
   - fail safely on declined or unavailable/non-interactive input;
   - execute fallback actions through the common executor;
   - rerun the complete preflight exactly once.
3. Continue to implementation actions only after the recheck succeeds.
4. Preserve the original requirement diagnostic and append fallback failure
   context if an action or recheck fails.
5. Add a safe fake-backend fixture. Do not add a real Nix/Guix installer to the
   standard plugin in this commit.
6. Test no fallback, accepted, declined, fallback action failure, successful
   recheck, and failed recheck. Assert no retry loop and no premature writes.

## Files

- Modify `xkai-bin/Plugin.roc`.
- Modify `xkai-bin/BackendRuntime.roc`.
- Modify `xkai-bin/Executor.roc`.
- Modify the modular custom backend fixture.
- Modify `scripts/test-xkai-projects.sh`.

## Acceptance criteria

- Fallback behavior is backend-defined but executor-controlled and visible.
- Fallback actions never run without explicit confirmation.
- Revalidation happens once after fallback and is mandatory.
- A fallback cannot silently select Nix when Guix was requested, or vice versa.
- Implementation effects do not run after a declined or unsuccessful fallback.
- `zig build ci` passes.

## Not included

- Shipping a production Determinate Nix installer command.
- Repeated retries or unattended confirmation flags.

## Risks

Installer-like actions are security-sensitive. Keep standard backends without
fallback until an installer policy is reviewed separately. Closed stdin must
produce a concise refusal, not hang CI.
