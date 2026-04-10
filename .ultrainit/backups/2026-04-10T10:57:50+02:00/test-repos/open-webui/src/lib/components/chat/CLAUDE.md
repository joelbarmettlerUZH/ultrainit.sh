# Chat Components

Core chat interface: ~110 Svelte files, ~36,000 lines. `Chat.svelte` is the 3000-line orchestrator; everything else is subordinate.

## Message History Is a DAG

Conversations support branching (editing a past message creates a new branch):

```typescript
// The structure — NOT a flat array
type History = {
  messages: Record<string, Message>;  // id → message
  currentId: string | null;           // head of current branch
};

// Each message has:
type Message = {
  parentId: string | null;
  childrenIds: string[];
  content: string;
  // ...
};

// CORRECT: get ordered display list
const messages = buildMessages(history, history.currentId);

// WRONG: never iterate directly
for (const msg of Object.values(history.messages)) { /* wrong order, all branches */ }
```

## Reactivity Pattern for History Mutations

Svelte only detects top-level reference changes:
```typescript
// CORRECT: mutate then reassign top-level
history.messages[msgId] = updatedMsg;
history = history;  // triggers reactivity

// WRONG: deep mutation without reassignment
history.messages[msgId].content = 'new';  // Svelte doesn't detect this
```

Children use `bind:history` and mutate the parent's object directly.

## Streaming Performance

Markdown re-parses and message list rebuilds are throttled with `requestAnimationFrame`:

```typescript
// Pattern used in Messages.svelte and Markdown.svelte
let pendingRebuild: number | null = null;

function scheduleRebuild() {
  if (pendingRebuild) cancelAnimationFrame(pendingRebuild);
  pendingRebuild = requestAnimationFrame(() => {
    pendingRebuild = null;
    buildMessages();  // or parseMarkdown()
  });
}
```

Structural changes (new `currentId`, navigation) bypass throttle and rebuild immediately. Always cancel in `onDestroy`.

## Two-Tier Reactivity Guard in Message Components

`ResponseMessage.svelte` avoids redundant `structuredClone()` on every streaming tick:

```typescript
$: if (history.messages) {
  const src = history.messages[messageId];
  // Fast path: only hot fields
  if (message.content !== src.content || message.done !== src.done) {
    message = structuredClone(src);
  // Slow path: full deep compare
  } else if (JSON.stringify(message) !== JSON.stringify(src)) {
    message = structuredClone(src);
  }
}
```

Always use `structuredClone()` for message copies — never spread (`{...msg}`) — to avoid shared reference issues.

## Callback Props (Not Svelte Events)

Cross-component communication uses **callback props**, not `createEventDispatcher()`:

```svelte
<!-- Parent passes callbacks down -->
<Message
  {message}
  editMessage={handleEdit}
  deleteMessage={handleDelete}
  rateMessage={handleRate}
/>

<!-- Child calls them -->
export let editMessage: Function = () => {};
```

Adding a new action requires threading it through: `Chat.svelte` → `Messages.svelte` → `Message.svelte` → leaf component. Forgetting any intermediate level silently drops the callback (no TypeScript error since `Function` is loose).

## Dual-Path Streaming

AI responses can arrive via two independent paths that both update the same message:

1. **SSE via ReadableStream** — `generateOpenAIChatCompletion()` → `createOpenAITextStream()`
2. **Socket.IO events** — `chat:message:delta`, `chat:message` events in `chatEventHandler()`

When debugging duplicate content or missing chunks, check both paths. A single request uses exactly one path.

## Draft Persistence

Chat input auto-saves to `sessionStorage['chat-input-{chatId}']` with 500ms debounce. Content over 5000 chars is not saved. Stored in `sessionStorage` (not `localStorage`) — lost on tab close. In tests, clear `sessionStorage` before navigating to a chat page.

## Queued Prompts

When a user sends messages while generating, messages queue in `chatRequestQueues`. On dequeue, all queued prompts are joined with `'\n\n'` into a single message. Rapid sends merge into one turn — intentional behavior.

## DOM Safety

All `{@html}` uses go through `DOMPurify.sanitize()` first. Never use `{@html rawString}` — always `{@html DOMPurify.sanitize(rawString) || ''}`.

## Module-Level State for Tab Persistence

`ChatControls.svelte` uses `<script context="module">` for `savedTab` — persists across component destroy/recreate cycles when navigating between chats. Use this pattern (not a global store) for UI state that should survive remounts but isn't global.
