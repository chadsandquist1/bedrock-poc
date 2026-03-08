import json
import logging
import os
import re
import time

import boto3

logger = logging.getLogger()
logger.setLevel(logging.INFO)

KNOWLEDGE_BASE_ID = os.environ["KNOWLEDGE_BASE_ID"]
MODEL_ID = os.environ["MODEL_ID"]
NUMBER_OF_RESULTS = int(os.environ.get("NUMBER_OF_RESULTS", "5"))

agent_runtime_client = boto3.client("bedrock-agent-runtime")
bedrock_client = boto3.client("bedrock-runtime")

SYSTEM_PROMPT = (
    "You are a helpful assistant. Answer the user's question using only the provided "
    "documents. Cite your sources inline."
)


def _sanitize_doc_name(name):
    """Strip characters disallowed by the Converse API document name rules."""
    name = re.sub(r"[^a-zA-Z0-9\s\-\(\)\[\]]", " ", name)
    name = re.sub(r" {2,}", " ", name).strip()
    return name or "document"


def _clean_text(text):
    """Remove non-printable characters that cause Bedrock to misidentify the content type."""
    return re.sub(r"[^\x20-\x7E\n\r\t]", "", text)


def _retrieve_chunks(query):
    """
    Return KB chunks as dicts with uri, text, filename (from metadata), and
    doc_name (sanitized for the Converse API). Pre-building doc_name here lets
    us do an exact lookup later instead of heuristic URI matching.
    """
    response = agent_runtime_client.retrieve(
        knowledgeBaseId=KNOWLEDGE_BASE_ID,
        retrievalQuery={"text": query},
        retrievalConfiguration={
            "vectorSearchConfiguration": {"numberOfResults": NUMBER_OF_RESULTS}
        },
    )
    chunks = []
    for result in response.get("retrievalResults", []):
        uri = result.get("location", {}).get("s3Location", {}).get("uri", "")
        text = result.get("content", {}).get("text", "")
        # Prefer the filename stored in metadata; fall back to parsing the URI.
        filename = result.get("metadata", {}).get("filename") or uri.rsplit("/", 1)[-1]
        chunks.append(
            {
                "uri": uri,
                "text": text,
                "filename": filename,
                "doc_name": _sanitize_doc_name(filename),
            }
        )
    logger.info("Retrieved %d chunks from KB", len(chunks))
    return chunks


def _build_document_blocks(chunks):
    """Convert KB chunks to Converse API DocumentBlocks with citations enabled."""
    return [
        {
            "document": {
                "name": chunk["doc_name"],
                "format": "txt",
                "source": {"text": _clean_text(chunk["text"])},
                "citations": {"enabled": True},
            }
        }
        for chunk in chunks
    ]


def _parse_citations_response(content_blocks, chunk_by_name):
    """
    Parse Converse API response content blocks into inline HTML.

    chunk_by_name maps each sanitized doc_name to its chunk dict, enabling
    exact lookup when Converse returns a citation title.
    """
    logger.info(
        "Response content blocks (raw): %s", json.dumps(content_blocks, default=str)
    )

    html_parts = []
    references = []
    ref_n = 1

    def _make_sup(refs):
        return "".join(f'<sup><a href="#ref-{n}">[{n}]</a></sup>' for n in refs)

    def _record_citation(title, cited_text):
        nonlocal ref_n
        chunk = chunk_by_name.get(title, {})
        references.append(
            {
                "ref_n": ref_n,
                "source": chunk.get("filename") or chunk.get("uri") or title,
                "cited_text": cited_text,
            }
        )
        n = ref_n
        ref_n += 1
        return n

    for block in content_blocks:
        # Plain text block — no citation
        if "text" in block and len(block) == 1:
            html_parts.append(block["text"])

        # Text block with inline citations (Anthropic Citations API via Converse)
        elif "text" in block and "citations" in block:
            ref_nums = [
                _record_citation(
                    title=(
                        citation.get("reference", {}).get("documentBlock")
                        or citation.get("reference", {}).get("document")
                        or {}
                    ).get("name", ""),
                    cited_text=citation.get("citedText", ""),
                )
                for citation in block.get("citations", [])
            ]
            html_parts.append(block["text"] + _make_sup(ref_nums))

        # citationsContent shape
        elif "citationsContent" in block:
            cc = block["citationsContent"]
            cited_text = "".join(
                item["text"] for item in cc.get("content", []) if "text" in item
            )
            ref_nums = [
                _record_citation(
                    title=citation.get("title", ""),
                    cited_text="".join(
                        sc["text"]
                        for sc in citation.get("sourceContent", [])
                        if "text" in sc
                    ),
                )
                for citation in cc.get("citations", [])
            ]
            html_parts.append(cited_text + _make_sup(ref_nums))

        # Fallback
        elif "text" in block:
            html_parts.append(block["text"])

    return "".join(html_parts), references


def lambda_handler(event, context):
    query = event.get("query")
    if not query:
        return {
            "statusCode": 400,
            "body": json.dumps({"error": "Missing 'query' field in event payload"}),
        }

    logger.info(
        "Query: %s | KB: %s | Model: %s | Results: %d",
        query,
        KNOWLEDGE_BASE_ID,
        MODEL_ID,
        NUMBER_OF_RESULTS,
    )

    start_time = time.time()

    # Step 1: Retrieve chunks — filename comes from metadata, not URI parsing
    chunks = _retrieve_chunks(query)
    if not chunks:
        return {
            "statusCode": 200,
            "body": json.dumps(
                {
                    "query": query,
                    "html_response": "No relevant documents found.",
                    "references": [],
                    "citation_count": 0,
                    "latency_ms": int((time.time() - start_time) * 1000),
                }
            ),
        }

    # Step 2: Build exact lookup and Converse document blocks
    chunk_by_name = {c["doc_name"]: c for c in chunks}
    doc_blocks = _build_document_blocks(chunks)

    # Step 3: Invoke Converse API
    converse_response = bedrock_client.converse(
        modelId=MODEL_ID,
        system=[{"text": SYSTEM_PROMPT}],
        messages=[{"role": "user", "content": doc_blocks + [{"text": query}]}],
    )

    elapsed_ms = int((time.time() - start_time) * 1000)
    logger.info("Retrieve + Converse completed in %dms", elapsed_ms)

    content_blocks = converse_response["output"]["message"]["content"]
    html_response, references = _parse_citations_response(content_blocks, chunk_by_name)

    result = {
        "query": query,
        "html_response": html_response,
        "references": references,
        "citation_count": len(references),
        "latency_ms": elapsed_ms,
    }
    logger.info(
        "Citation count: %d | HTML length: %d chars",
        len(references),
        len(html_response),
    )

    return {"statusCode": 200, "body": json.dumps(result)}
