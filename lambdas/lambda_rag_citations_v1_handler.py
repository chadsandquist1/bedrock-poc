import json
import logging
import os
import time

import boto3

logger = logging.getLogger()
logger.setLevel(logging.INFO)

KNOWLEDGE_BASE_ID = os.environ["KNOWLEDGE_BASE_ID"]
MODEL_ARN = os.environ["MODEL_ARN"]
NUMBER_OF_RESULTS = int(os.environ.get("NUMBER_OF_RESULTS", "5"))
SEARCH_TYPE = "SEMANTIC"

client = boto3.client("bedrock-agent-runtime")


def _build_html_response(generated_text, citations):
    """
    Insert inline footnote anchors into generated_text using span offsets.
    Insertions go end→start so earlier offsets stay valid.
    Returns (html_with_markers, references_list).
    """
    # Collect (span_end, ref_n, uri) tuples — one per (citation, reference) pair.
    # A single citation object can have multiple retrievedReferences.
    markers = []
    references = []
    ref_n = 1

    for citation in citations:
        span = (
            citation.get("generatedResponsePart", {})
            .get("textResponsePart", {})
            .get("span", {})
        )
        span_end = span.get("end")
        if span_end is None:
            continue

        uris_for_span = []
        for ref in citation.get("retrievedReferences", []):
            uri = ref.get("location", {}).get("s3Location", {}).get("uri", "")
            chunk_text = ref.get("content", {}).get("text", "")
            references.append({"ref_n": ref_n, "source": uri, "text": chunk_text})
            uris_for_span.append((ref_n, uri))
            ref_n += 1

        if uris_for_span:
            markers.append((span_end, uris_for_span))

    # Sort descending by span_end so we insert from the back.
    markers.sort(key=lambda x: x[0], reverse=True)

    text = generated_text
    for span_end, uri_pairs in markers:
        sup_tags = "".join(
            f'<sup><a href="#ref-{n}">[{n}]</a></sup>' for n, _ in uri_pairs
        )
        text = text[:span_end] + sup_tags + text[span_end:]

    return text, references


def lambda_handler(event, context):
    query = event.get("query")
    if not query:
        return {
            "statusCode": 400,
            "body": json.dumps({"error": "Missing 'query' field in event payload"}),
        }

    logger.info(f"Query: {query}")
    logger.info(f"Search type: {SEARCH_TYPE}")
    logger.info(f"Knowledge Base ID: {KNOWLEDGE_BASE_ID}")
    logger.info(f"Number of results: {NUMBER_OF_RESULTS}")

    start_time = time.time()

    response = client.retrieve_and_generate(
        input={"text": query},
        retrieveAndGenerateConfiguration={
            "type": "KNOWLEDGE_BASE",
            "knowledgeBaseConfiguration": {
                "knowledgeBaseId": KNOWLEDGE_BASE_ID,
                "modelArn": MODEL_ARN,
                "retrievalConfiguration": {
                    "vectorSearchConfiguration": {
                        "numberOfResults": NUMBER_OF_RESULTS,
                        "overrideSearchType": SEARCH_TYPE,
                    }
                },
            },
        },
    )

    elapsed_ms = int((time.time() - start_time) * 1000)
    logger.info(f"RetrieveAndGenerate completed in {elapsed_ms}ms")

    generated_text = response["output"]["text"]
    raw_citations = response.get("citations", [])

    logger.info(f"Raw citation objects: {len(raw_citations)}")

    html_response, references = _build_html_response(generated_text, raw_citations)

    result = {
        "query": query,
        "search_type": SEARCH_TYPE,
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
