---
name: handoff
description: Compact the current conversation into a handoff document for another agent to pick up.
argument-hint: "What will the next session be used for?"
disable-model-invocation: true
---

Write a handoff document summarising the current conversation so a fresh agent
can continue the work. Save it into the **Exchange directory** at
`$CLAUDE_EXCHANGE_DIR` (e.g. `$CLAUDE_EXCHANGE_DIR/handoff-<short-topic>.md`).

`$CLAUDE_EXCHANGE_DIR` is the per-project, host-visible channel that persists
across sessions — both the user and the next agent (in a new session of this
project) can read it. Do **not** save the handoff to `/tmp` (it lives in this
jail's private mount namespace and is invisible to the user and to later
sessions) and do **not** save it into the project working tree.

Include a "suggested skills" section in the document, which suggests skills
that the agent should invoke.

Do not duplicate content already captured in other artifacts (PRDs, plans,
ADRs, issues, commits, diffs). Reference them by path or URL instead.

Redact any sensitive information, such as API keys, passwords, or personally
identifiable information.

If the user passed arguments, treat them as a description of what the next
session will focus on and tailor the doc accordingly.

When done, print the absolute path of the file you wrote so the user can hand
it to the next session.
