# RAG Citations Lambdas

Two proof-of-concept Lambdas that return answers with **inline HTML citation links** (`<sup><a href="...">`) rather than a flat citation list.

---

## Option 1: RetrieveAndGenerate + Span Post-processing

**Lambda:** `bedrock-rag-dev-rag-citations-v1`
**Handler:** `lambda_rag_citations_v1_handler.py`

Calls `retrieve_and_generate` (SEMANTIC search — compatible with S3 Vectors). The response includes `citations[].generatedResponsePart.textResponsePart.span` with character offsets into the generated text. The handler inserts `<sup><a href="#ref-N">[N]</a></sup>` markers at those offsets, working end→start so earlier positions aren't shifted.

**Trade-offs:**
- Single API call; lower latency
- Citation positions are model-controlled via span offsets
- Search type locked to SEMANTIC (S3 Vectors does not support HYBRID)
- No control over the generation prompt

---

## Option 2: Retrieve + Converse Citations API

**Lambda:** `bedrock-rag-dev-rag-citations-v2`
**Handler:** `lambda_rag_citations_v2_handler.py`

Two-step approach:
1. `bedrock-agent-runtime.retrieve()` — fetches relevant KB chunks
2. `bedrock-runtime.converse()` — passes chunks as `DocumentBlock`s with `citationsConfig: {enabled: true}`, which asks the model to cite inline

**Trade-offs:**
- Two API calls; slightly higher latency
- Full control over the system prompt and message structure
- Uses Converse API — compatible with any Claude model that supports citations
- Citation parsing depends on the response block shape (logged in CloudWatch for inspection)

---

## Invocation

Both Lambdas accept `{"query": "..."}` and return `{"html_response": "...", "references": [...], "citation_count": N, "latency_ms": N}`.

```bash
# Option 1
aws lambda invoke --function-name bedrock-rag-dev-rag-citations-v1 --payload '{"query": "What is photosynthesis?"}' --cli-binary-format raw-in-base64-out /tmp/v1_out.json && cat /tmp/v1_out.json | jq '.body | fromjson | .html_response'

# Option 2
aws lambda invoke --function-name bedrock-rag-dev-rag-citations-v2 --payload '{"query": "What is photosynthesis?"}' --cli-binary-format raw-in-base64-out /tmp/v2_out.json && cat /tmp/v2_out.json | jq '.body | fromjson | .html_response'
```

---

## Sample Test Prompts

These map to documents in `scripts/documents/`:

| Document | Sample prompt |
|---|---|
| `photosynthesis-biology.txt` | `"What is photosynthesis and how does it work?"` |
| `states-of-matter.txt` | `"What are the differences between solids, liquids, and gases?"` |
| `france-geography.txt` | `"What are the major geographical regions of France?"` |
| `shakespeare-literature.txt` | `"What themes appear in Shakespeare's tragedies?"` |
| `rag-ai-explanation.txt` | `"How does retrieval-augmented generation improve LLM responses?"` |

---

## Reading the HTML Output

The `html_response` field contains the generated answer with inline footnote anchors:

```
Photosynthesis is the process by which plants convert sunlight into energy.<sup><a href="#ref-1">[1]</a></sup>
```

`references` is a list of objects mapping each `[N]` number to a source:

```json
[
  {"ref_n": 1, "source": "s3://bedrock-rag-dev-documents-123456789/photosynthesis-biology.txt", "text": "...chunk text..."}
]
```

To render as a full HTML page, append an `<ol>` built from the `references` list after the response body.
