BoringAgent 0.3.0 adds Codex and a shared Message / Reply composer for Claude and Codex, inside the same independently installed extension.

- Codex discovers loaded sessions through an existing local app-server, reads available account limits, and routes prompts, active-turn steering, and exact-ID question replies to that owner.
- Claude can answer future questions through an opt-in hook and receive ordinary prompts in explicitly connected interactive CLI Channels.
- Per-session drafts, explicit sends, stale-turn/request checks, bounded private queues, delivery receipts, and no automatic resend protect session targeting.
- The shared native editor acquires keyboard focus on explicit Message/Reply actions. The dashboard uses native segmented controls and grouped actions; the session picker uses native search, reusable table rows, filtering, and arrow-key navigation within compact and regular bounds.
- The Claude account-usage fix from 0.2.1 is included.
- Codex subscription usage has its own account connection. An Azure/API-key session provider no longer determines which subscription account is queried; missing authentication shows an explicit sign-in action. Slow account startup has a separate bounded queue so it cannot delay session commands.
- Verified Claude channel heartbeats keep long-idle sessions available for messages. Delivery status is scoped to the current prompt or question.

Update the relay using each provider's setup command. Claude question replies require the Settings toggle; ordinary Claude prompts require a new channel-enabled interactive CLI session. Desktop-only processes without a control endpoint and unsupported requests use the original-app handoff. Codex subscription usage requires a ChatGPT login through the official CLI. Its separate usage login preserves existing API credentials and session settings; Azure/API billing is not a subscription allowance. Tool permissions remain in the original agent.

**Self-signed development preview. Requires the compatible Debug host with development extensions enabled; not Apple-notarized.** [Setup and limitations](https://github.com/TheBoredTeam/boring-notch-extensions/blob/main/packages/boring-agent/SESSION_CONTROL.md).
