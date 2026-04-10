# src/lib — Frontend Library

All frontend logic: API clients, Svelte stores, utilities, workers, marked extensions, and Svelte components.

## Directory Map

```
lib/
├── stores/index.ts         # ALL global state (70+ writable stores)
├── apis/                   # 27 domain API client modules
│   ├── index.ts            # getModels() multi-endpoint fan-out
│   ├── streaming/index.ts  # SSE stream parsing, TextStreamUpdate
│   └── {domain}/index.ts   # one per backend domain
├── components/             # All Svelte UI (505+ files)
├── utils/
│   ├── index.ts            # 1855-line utility barrel
│   └── marked/             # 7 custom marked extensions
├── workers/                # Pyodide WASM, Kokoro TTS
├── types/index.ts          # Banner, TTS_RESPONSE_SPLIT (most types are in stores)
├── constants/
│   └── permissions.ts      # DEFAULT_PERMISSIONS (as const)
└── i18n/                   # i18next setup
```

## Global State

All global state is in `stores/index.ts` as plain `writable()` stores. No derived stores at this layer — derivations happen in components with `$:` reactive declarations.

```typescript
// Reading (reactive in components)
import { models, settings, user } from '$lib/stores';
// In template: $models, $settings

// Updating — always spread, never mutate in place
settings.update(s => ({ ...s, theme: 'dark' }));

// After any API mutation, reload the store
models.set(await getModels(localStorage.token));
```

**Important type locations:** `Model`, `SessionUser`, `Config`, `Settings` are defined in `stores/index.ts`, not in `types/index.ts`. Only `Banner` and `TTS_RESPONSE_SPLIT` are in `types/`.

**Null vs undefined sentinels:** `config` and `user` initialize to `undefined` (loading state). `chats`, `tools`, `functions`, `skills` initialize to `null`. Check `!= null` (loose) to guard against both.

## API Client Pattern

Every function in `apis/*/index.ts` uses the deferred-throw pattern:

```typescript
export const getChats = async (token: string): Promise<Chat[]> => {
  let error = null;
  const res = await fetch(`${WEBUI_API_BASE_URL}/chats/`, {
    headers: {
      'Content-Type': 'application/json',
      ...(token && { authorization: `Bearer ${token}` })
    }
  })
    .then(async r => { if (!r.ok) throw await r.json(); return r.json(); })
    .catch(err => { error = err.detail; return null; });
  if (error) throw error;
  return res;
};
```

- Token is always first argument, always from `localStorage.token` at call site
- Never set `Content-Type` on `FormData` requests (browser sets multipart boundary)
- Query strings via `URLSearchParams`, never string interpolation
- **Analytics directory is misspelled:** `src/lib/apis/analyics/` (missing 't')

## SSE Streaming

```typescript
import { createOpenAITextStream } from '$lib/apis/streaming';

const stream = await createOpenAITextStream(response.body, splitLargeDeltas);
for await (const update of stream) {
  // update is a TextStreamUpdate object
  appendContent(update.value);
}
```

`splitLargeDeltas=true` artificially fragments tokens into 1-3 chars with 5ms delays for a typing effect — disable for programmatic consumers or performance-critical paths.

## Svelte Components — Key Patterns

**i18n is context, not an import:**
```typescript
const i18n = getContext('i18n');  // in script block
// in template:
{$i18n.t('Key string')}
{$i18n.t('Hello {{name}}', { name: $user?.name })}
// NEVER:
import i18n from '$lib/i18n';  // won't update on locale change
```

**Portal pattern for overlays** (Modal, Dropdown, Tooltip): append to `document.body` to escape `overflow:hidden` stacking contexts. Always clean up in `onDestroy`.

**DOM measurement:** Always `await tick()` before `getBoundingClientRect()` or `scrollHeight` — let Svelte flush pending updates first.

**Array reactivity:** Svelte doesn't detect in-place array mutation. After any array push/splice, reassign: `arr = arr`.

## Workers

Workers are imported with Vite's `?worker` suffix:
```typescript
import PyodideWorker from '$lib/workers/pyodide.worker?worker';
const worker = new PyodideWorker();
```

Both workers are stored in Svelte stores (`pyodideWorker`, `TTSWorker`) for cross-component sharing. After `worker.terminate()`, immediately null the store: `pyodideWorker.set(null)`. Pyodide worker preserves `IDBFS` state — don't terminate unless necessary.

## Custom marked.js Extensions

7 extensions registered in `Markdown.svelte` via `marked.use()`. Order matters — do not change registration order. To add a new syntax:
1. Create `src/lib/utils/marked/{feature}-extension.ts` following the factory function pattern
2. Add `marked.use(myExtension({}))` in `Markdown.svelte`
3. Add a case in `MarkdownTokens.svelte` or `MarkdownInlineTokens.svelte`

KaTeX regex patterns **must stay at module scope** — recompiling inside tokenizer functions caused ~87% render time regression.
