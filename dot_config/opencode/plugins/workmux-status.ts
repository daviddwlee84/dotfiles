// ~/.config/opencode/plugins/workmux-status.ts
// Source: dot_config/opencode/plugins/workmux-status.ts (managed by chezmoi)
//
// Mirrors the upstream plugin from raine/workmux:
//   https://raw.githubusercontent.com/raine/workmux/main/resources/opencode/plugins/workmux-status.ts
//
// Why managed here: workmux's `wm setup` writes this file on first run, but
// only on machines where you remembered to run setup. Tracking it in chezmoi
// makes the integration auto-deploy on every fresh box.
//
// Refresh strategy: `wm` itself is install-only via ansible (see
// dot_ansible/roles/devtools/tasks/main.yml) — we don't auto-bump it. When
// you `just upgrade-tools` and workmux ships a new plugin schema, copy the
// upstream file over this one:
//   curl -fsSL https://raw.githubusercontent.com/raine/workmux/main/resources/opencode/plugins/workmux-status.ts \
//     > $(chezmoi source-path ~/.config/opencode/plugins/workmux-status.ts)
//
// Companion package.json lives next to this file (also chezmoi-managed) so
// OpenCode resolves @opencode-ai/plugin without us shipping node_modules.
//
// Status semantics (from `workmux set-window-status --help`):
//   working — agent processing                (sticky; never auto-clears)
//   waiting — agent needs user input          (auto-clears on window focus)
//   done    — agent finished                  (auto-clears on window focus)
// See docs/tools/workmux.md for the lifecycle / leak story.

import type { Plugin } from '@opencode-ai/plugin';

export const WorkmuxStatusPlugin: Plugin = async ({ $ }) => {
  // OpenCode can emit repeated `session.status busy` events for a single turn,
  // and can even emit a stale trailing `busy` after `idle` at the end. Track
  // per-session status so workmux only sees real transitions.
  const lastStatusBySession = new Map<string, string>();
  const acceptBusyBySession = new Map<string, boolean>();

  async function setStatus(
    sessionID: string | undefined,
    status: string,
  ) {
    if (!sessionID) {
      return;
    }

    const previous = lastStatusBySession.get(sessionID);
    // Ignore the final stale `busy` OpenCode sometimes emits after a session is
    // already done. The next user message re-arms `working` for the new turn.
    if (status === 'working' && acceptBusyBySession.get(sessionID) === false) {
      return;
    }
    if (previous === status) {
      return;
    }

    lastStatusBySession.set(sessionID, status);
    if (status === 'done') {
      acceptBusyBySession.set(sessionID, false);
    } else {
      acceptBusyBySession.set(sessionID, true);
    }

    await $`workmux set-window-status ${status}`.quiet();
  }

  return {
    event: async ({ event }) => {
      if (event.type === 'message.updated' && event.properties.info.role === 'user') {
        acceptBusyBySession.set(event.properties.sessionID, true);
      }

      switch (event.type) {
        case 'session.status':
          if (event.properties.status.type === 'busy') {
            await setStatus(event.properties.sessionID, 'working');
          }
          if (event.properties.status.type === 'idle') {
            await setStatus(event.properties.sessionID, 'done');
          }
          break;
        case 'permission.asked':
        case 'question.asked':
          await setStatus(event.properties.sessionID, 'waiting');
          break;
        case 'permission.replied':
        case 'question.replied':
          await setStatus(event.properties.sessionID, 'working');
          break;
        case 'session.idle':
          await setStatus(event.properties.sessionID, 'done');
          break;
      }
    },
  };
};
