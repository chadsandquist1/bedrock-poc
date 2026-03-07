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
SEARCH_TYPE = "HYBRID"

client = boto3.client("bedrock-agent-runtime")


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

    citations = []
    for citation in response.get("citations", []):
        for ref in citation.get("retrievedReferences", []):
            location = ref.get("location", {})
            source_uri = location.get("s3Location", {}).get("uri", "")
            citations.append(
                {
                    "text": ref.get("content", {}).get("text", ""),
                    "source": source_uri,
                    "location_type": location.get("type", ""),
                }
            )

    result = {
        "query": query,
        "search_type": SEARCH_TYPE,
        "generated_response": generated_text,
        "citations": citations,
        "citation_count": len(citations),
        "latency_ms": elapsed_ms,
    }

    logger.info(f"Citation count: {len(citations)}")
    logger.info(f"Generated response length: {len(generated_text)} chars")

    return {
        "statusCode": 200,
        "body": json.dumps(result),
    }
