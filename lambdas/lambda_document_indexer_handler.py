import json
import logging
import os
import re
import time

import boto3

logger = logging.getLogger()
logger.setLevel(logging.INFO)

DOCUMENTS_BUCKET = os.environ["DOCUMENTS_BUCKET"]
KNOWLEDGE_BASE_ID = os.environ["KNOWLEDGE_BASE_ID"]
DATA_SOURCE_ID = os.environ["DATA_SOURCE_ID"]
INDEX_KEY = "document-index.txt"

s3 = boto3.client("s3")
bedrock_agent = boto3.client("bedrock-agent")


def tokenize_filename(filename: str) -> list[str]:
    """
    Split a filename like 'france-geography.txt' into tokens ['france', 'geography'].
    Splits on hyphens, underscores, and dots; lowercases; drops the extension token.
    """
    base = filename.rsplit(".", 1)[0]
    tokens = re.split(r"[-_.]", base)
    return [t.lower() for t in tokens if t]


def list_source_documents() -> list[str]:
    """
    Return all .txt keys in the bucket, excluding the index file and metadata files.
    """
    paginator = s3.get_paginator("list_objects_v2")
    keys = []
    for page in paginator.paginate(Bucket=DOCUMENTS_BUCKET):
        for obj in page.get("Contents", []):
            key = obj["Key"]
            if key.endswith(".txt") and key != INDEX_KEY:
                keys.append(key)
    keys.sort()
    return keys


def build_index_content(keys: list[str]) -> str:
    """
    Build a plain-text document listing each filename in natural language so that
    vector search can match queries like 'find filenames with geography in the title'.

    Example line:
        The file france-geography.txt covers topics including: france, geography.
    """
    lines = [
        "Document Filename Index",
        "======================",
        "This index lists all available documents in the knowledge base "
        "along with their filename keywords for search purposes.",
        "",
    ]
    for key in keys:
        filename = key.split("/")[-1]
        tokens = tokenize_filename(filename)
        token_str = ", ".join(tokens)
        lines.append(f"The file {filename} covers topics including: {token_str}.")
    lines.append("")
    return "\n".join(lines)


def build_metadata(filename: str) -> dict:
    """
    Build a Bedrock-compatible metadata dict for the given filename.

    Bedrock reads '<key>.metadata.json' from the same S3 prefix as the source
    document and attaches these attributes to every chunk ingested from it.
    """
    tokens = tokenize_filename(filename)
    attributes = {
        "filename": {
            "value": {"stringValue": filename},
            "type": "STRING",
        },
        "filename_tokens": {
            "value": {"stringValue": " ".join(tokens)},
            "type": "STRING",
        },
    }
    for token in tokens:
        attributes[f"topic_{token}"] = {
            "value": {"stringValue": token},
            "type": "STRING",
        }
    return {"metadataAttributes": attributes}


def upload_text(key: str, body: str) -> None:
    s3.put_object(
        Bucket=DOCUMENTS_BUCKET,
        Key=key,
        Body=body.encode("utf-8"),
        ContentType="text/plain",
    )
    logger.info("Uploaded s3://%s/%s", DOCUMENTS_BUCKET, key)


def upload_json(key: str, obj: dict) -> None:
    s3.put_object(
        Bucket=DOCUMENTS_BUCKET,
        Key=key,
        Body=json.dumps(obj, indent=2).encode("utf-8"),
        ContentType="application/json",
    )
    logger.info("Uploaded s3://%s/%s", DOCUMENTS_BUCKET, key)


def lambda_handler(event, context):
    start = time.time()
    logger.info(
        "Starting document indexer | bucket=%s kb=%s ds=%s",
        DOCUMENTS_BUCKET,
        KNOWLEDGE_BASE_ID,
        DATA_SOURCE_ID,
    )

    # 1. Discover source documents
    keys = list_source_documents()
    logger.info("Found %d source document(s): %s", len(keys), keys)

    if not keys:
        return {
            "statusCode": 200,
            "body": json.dumps(
                {"message": "No source documents found.", "files_indexed": 0}
            ),
        }

    # 2. Generate and upload document-index.txt
    index_content = build_index_content(keys)
    upload_text(INDEX_KEY, index_content)

    # 3. Generate and upload .metadata.json for each source document
    metadata_keys = []
    for key in keys:
        filename = key.split("/")[-1]
        metadata = build_metadata(filename)
        metadata_key = f"{key}.metadata.json"
        upload_json(metadata_key, metadata)
        metadata_keys.append(metadata_key)

    # 4. Start Bedrock ingestion job
    ingest_response = bedrock_agent.start_ingestion_job(
        knowledgeBaseId=KNOWLEDGE_BASE_ID,
        dataSourceId=DATA_SOURCE_ID,
    )
    ingestion_job_id = ingest_response["ingestionJob"]["ingestionJobId"]
    logger.info("Ingestion job started: %s", ingestion_job_id)

    elapsed_ms = int((time.time() - start) * 1000)
    result = {
        "files_indexed": len(keys),
        "source_documents": keys,
        "metadata_files_created": metadata_keys,
        "index_file": INDEX_KEY,
        "ingestion_job_id": ingestion_job_id,
        "latency_ms": elapsed_ms,
    }
    logger.info("Completed in %dms", elapsed_ms)

    return {"statusCode": 200, "body": json.dumps(result)}
