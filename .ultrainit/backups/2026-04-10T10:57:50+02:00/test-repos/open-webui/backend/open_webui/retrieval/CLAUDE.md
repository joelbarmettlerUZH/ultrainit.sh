# open_webui Retrieval (RAG)

Full RAG pipeline: document ingestion, vector storage, hybrid search, reranking, and web search. The vector backend is swappable via `VECTOR_DB` env var.

## The Golden Rule

**Never instantiate a vector DB client directly.** Always use:
```python
from open_webui.retrieval.vector.factory import VECTOR_DB_CLIENT
result = VECTOR_DB_CLIENT.search(collection_name, queries, query_embeddings, k=5)
```

`VECTOR_DB_CLIENT` is a singleton created at module import time. If the DB is unavailable at startup, the app fails to start — there is no lazy initialization.

## Collection Naming Convention

This is implicit — violating it breaks retrieval silently:

| Resource | Collection Name |
|----------|----------------|
| Knowledge base | `{kb_id}` (the UUID directly) |
| Uploaded file | `file-{file_id}` |
| User memory | `user-memory-{user_id}` |
| Web search | `web-search-{hash}` |

Multitenancy variants (Qdrant/Milvus) remap these to shared physical collections via pattern matching. If you change the naming convention, update the multitenancy adapter's `_get_collection_and_tenant_id()` too.

## Distance Scores Are Normalized

All 14 adapters normalize distances to `[0,1]` (1 = most similar) before returning `SearchResult`. Do not compare raw scores across backends or assume the formula — always treat the returned score as already normalized.

## Search() Returns None, Not Empty

Adapters return `None` (not empty `SearchResult`) when there are no results or the collection doesn't exist:
```python
result = VECTOR_DB_CLIENT.search(...)
if result is None:
    return []  # collection doesn't exist or no results
for doc in result.documents:
    ...
```

## Hybrid Search with Fallback

`query_collection_with_hybrid_search()` in `utils.py` combines BM25 + vector via RRF. It **silently falls back to vector-only** on any exception, logged at DEBUG. Watch for `Hybrid search failed, falling back to vector search` in DEBUG logs if hybrid quality seems off.

BM25 text enrichment adds filename (doubled for weight), title, section headings, and source URL before indexing. Deduplication uses SHA-256 of ORIGINAL (not enriched) text via `_chunk_hash`.

## Embedding Models

All embeddings are async. `get_embedding_function()` always returns an async function. Sync local models are wrapped in `asyncio.to_thread`.

**Changing embedding models mid-deployment** corrupts the vector store — pgvector pads/truncates vectors to the old dimension silently. When changing models: delete all collections and re-ingest.

## Document Loaders

All loaders go through `Loader(engine, **kwargs).load(filename, content_type, path)` in `loaders/main.py`. `ftfy.fix_text()` is applied to all page content here — do not apply it in individual loaders (double-processing).

Cloud loaders (DatalabMarker, MinerU) use synchronous `time.sleep()` in their polling loops — **this blocks the event loop**. Run them in background tasks, not in synchronous request handlers.

Loaders raise `HTTPException` directly (not generic exceptions) even though they're a data layer. When calling loaders outside a FastAPI request context, catch `fastapi.HTTPException`.

## Web Search

26 search engine adapters in `web/`. Each exports exactly one function: `search_{engine}(api_key, query, count, filter_list) -> list[SearchResult]`. 18 of 26 adapters swallow all exceptions and return `[]`. Filter semantics vary: most adapters pass `filter_list` to `get_filtered_results()` as domain exclusion, but `exa.py` passes it as `includeDomains` (opposite sense).

## Rerankers

Three rerankers implement `BaseReranker.predict(sentences: List[Tuple[str, str]])`: `ColBERT` (local), `ExternalReranker` (HTTP API, Cohere-style), and `sentence_transformers.CrossEncoder` (not in `models/` directory, wired in router). Selection in `routers/retrieval.py:get_rf()`. All rerankers run in `asyncio.to_thread()` since `predict()` is synchronous.

`ColBERT.predict()` returns `np.ndarray[float32]`. `ExternalReranker.predict()` returns `List[float]`. Normalize: `scores.tolist() if hasattr(scores, 'tolist') else scores`.
