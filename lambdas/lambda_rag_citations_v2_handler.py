import json
import logging
import os
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


def _retrieve_chunks(query):
    """Return a list of (uri, text) tuples from the KB."""
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
        chunks.append({"uri": uri, "text": text})
    logger.info(f"Retrieved {len(chunks)} chunks from KB")
    return chunks


def _build_document_blocks(chunks):
    """Convert KB chunks to Converse API DocumentBlocks with citations enabled."""
    blocks = []
    for i, chunk in enumerate(chunks):
        filename = chunk["uri"].rsplit("/", 1)[-1] if chunk["uri"] else f"doc-{i}"
        blocks.append(
            {
                "document": {
                    "name": filename,
                    "format": "txt",
                    "source": {"bytes": chunk["text"].encode("utf-8")},
                    "citations": {"enabled": True},
                }
            }
        )
    return blocks


def _parse_citations_response(content_blocks, chunks):
    """
    Parse Converse API response content blocks and build inline HTML.

    AWS Bedrock returns citation information in content blocks. When the Citations
    API is active, the response may contain citationsContentBlock entries or
    standard text blocks with citation metadata embedded.

    We log the full structure on first parse to aid debugging in case the response
    shape differs across SDK/model versions.
    """
    logger.info(
        f"Response content blocks (raw): {json.dumps(content_blocks, default=str)}"
    )

    html_parts = []
    references = []
    ref_n = 1

    for block in content_blocks:
        # Standard text block — no citation
        if "text" in block and len(block) == 1:
            html_parts.append(block["text"])
            continue

        # Text block that also carries inline citations (Anthropic Citations API shape
        # as surfaced through AWS Converse API)
        if "text" in block and "citations" in block:
            text_segment = block["text"]
            block_refs = []
            for citation in block.get("citations", []):
                cited_text = citation.get("citedText", "")
                # The reference may point to a documentBlock or similar structure
                ref_info = citation.get("reference", {})
                doc_info = ref_info.get("documentBlock", {}) or ref_info.get(
                    "document", {}
                )
                title = doc_info.get("title", "") or doc_info.get("name", "")
                uri = _resolve_uri_by_title(title, chunks)
                references.append(
                    {"ref_n": ref_n, "source": uri, "cited_text": cited_text}
                )
                block_refs.append(ref_n)
                ref_n += 1

            sup_tags = "".join(
                f'<sup><a href="#ref-{n}">[{n}]</a></sup>' for n in block_refs
            )
            html_parts.append(text_segment + sup_tags)
            continue

        # citationsContentBlock shape (alternative Bedrock wrapper)
        if "citationsContentBlock" in block:
            for sub in block["citationsContentBlock"].get("content", []):
                if "textBlock" in sub:
                    html_parts.append(sub["textBlock"]["text"])
                elif "citationsBlock" in sub:
                    for citation in sub["citationsBlock"].get("citations", []):
                        cited_text = citation.get("citedText", "")
                        ref_info = citation.get("reference", {})
                        doc_info = ref_info.get("documentBlock", {}) or ref_info.get(
                            "document", {}
                        )
                        title = doc_info.get("title", "") or doc_info.get("name", "")
                        uri = _resolve_uri_by_title(title, chunks)
                        sup = f'<sup><a href="#ref-{ref_n}">[{ref_n}]</a></sup>'
                        references.append(
                            {"ref_n": ref_n, "source": uri, "cited_text": cited_text}
                        )
                        html_parts.append(cited_text + sup)
                        ref_n += 1
            continue

        # Fallback: treat any remaining block with text as plain text
        if "text" in block:
            html_parts.append(block["text"])

    return "".join(html_parts), references


def _resolve_uri_by_title(title, chunks):
    """Map a document name/title back to an S3 URI using the retrieved chunks list."""
    for chunk in chunks:
        filename = chunk["uri"].rsplit("/", 1)[-1] if chunk["uri"] else ""
        if title and (title == filename or title in chunk["uri"]):
            return chunk["uri"]
    return title  # Fall back to the title itself if no match found


def lambda_handler(event, context):
    query = event.get("query")
    if not query:
        return {
            "statusCode": 400,
            "body": json.dumps({"error": "Missing 'query' field in event payload"}),
        }

    logger.info(f"Query: {query}")
    logger.info(f"Knowledge Base ID: {KNOWLEDGE_BASE_ID}")
    logger.info(f"Model ID: {MODEL_ID}")
    logger.info(f"Number of results: {NUMBER_OF_RESULTS}")

    start_time = time.time()

    # Step 1: Retrieve relevant chunks from KB
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

    # Step 2: Build Converse API message with DocumentBlocks
    doc_blocks = _build_document_blocks(chunks)
    messages = [
        {
            "role": "user",
            "content": doc_blocks + [{"text": query}],
        }
    ]

    # Step 3: Invoke Converse API
    converse_response = bedrock_client.converse(
        modelId=MODEL_ID,
        system=[{"text": SYSTEM_PROMPT}],
        messages=messages,
    )

    elapsed_ms = int((time.time() - start_time) * 1000)
    logger.info(f"Retrieve + Converse completed in {elapsed_ms}ms")

    content_blocks = converse_response["output"]["message"]["content"]
    html_response, references = _parse_citations_response(content_blocks, chunks)

    result = {
        "query": query,
        "html_response": html_response,
        "references": references,
        "citation_count": len(references),
        "latency_ms": elapsed_ms,
    }

    logger.info(f"Citation count: {len(references)}")
    logger.info(f"HTML response length: {len(html_response)} chars")

    return {
        "statusCode": 200,
        "body": json.dumps(result),
    }
