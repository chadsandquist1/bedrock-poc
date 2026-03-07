import base64
import gzip
import json
import logging

logger = logging.getLogger()
logger.setLevel(logging.INFO)


def lambda_handler(event, context):
    """
    Lambda handler triggered by CloudWatch Logs subscription filter
    when Bedrock Knowledge Base ingestion job events are logged.

    CloudWatch Logs events are base64 encoded and gzipped.
    """
    logger.info("=== Bedrock Knowledge Base Ingestion Event Received ===")

    try:
        # Decode CloudWatch Logs event
        compressed_payload = base64.b64decode(event["awslogs"]["data"])
        uncompressed_payload = gzip.decompress(compressed_payload)
        log_data = json.loads(uncompressed_payload)

        logger.info(f"Log Group: {log_data.get('logGroup')}")
        logger.info(f"Log Stream: {log_data.get('logStream')}")

        # Process each log event
        for log_event in log_data.get("logEvents", []):
            message = log_event.get("message", "")
            timestamp = log_event.get("timestamp", 0)

            logger.info(f"Timestamp: {timestamp}")
            logger.info(f"Message: {message}")

            # Try to parse the message as JSON
            try:
                parsed_message = json.loads(message)

                # Extract event details from the nested structure
                event_type = parsed_message.get("event_type", "UNKNOWN")
                event_data = parsed_message.get("event", {})

                status = event_data.get("ingestion_job_status", "UNKNOWN")
                kb_arn = event_data.get("knowledge_base_arn", "UNKNOWN")
                ds_id = event_data.get("data_source_id", "UNKNOWN")
                job_id = event_data.get("ingestion_job_id", "UNKNOWN")

                # Extract resource statistics
                stats = event_data.get("resource_statistics", {})

                logger.info(f"Parsed Event Details:")
                logger.info(f"  Event Type: {event_type}")
                logger.info(f"  Knowledge Base ARN: {kb_arn}")
                logger.info(f"  Data Source ID: {ds_id}")
                logger.info(f"  Ingestion Job ID: {job_id}")
                logger.info(f"  Status: {status}")

                if stats:
                    logger.info(f"  Resource Statistics:")
                    logger.info(f"    Ingested: {stats.get('number_of_resources_ingested', 0)}")
                    logger.info(f"    Updated: {stats.get('number_of_resources_updated', 0)}")
                    logger.info(f"    Deleted: {stats.get('number_of_resources_deleted', 0)}")
                    logger.info(f"    Metadata Updated: {stats.get('number_of_resources_with_metadata_updated', 0)}")
                    logger.info(f"    Failed: {stats.get('number_of_resources_failed', 0)}")

                # Handle different statuses
                if status == "COMPLETE":
                    logger.info("Ingestion job completed successfully!")
                    # Add your post-ingestion logic here
                elif status == "FAILED":
                    logger.error("Ingestion job failed!")
                    # Add your failure handling logic here
                elif status == "IN_PROGRESS":
                    logger.info("Ingestion job is in progress...")
                elif status == "STARTING":
                    logger.info("Ingestion job is starting...")

            except json.JSONDecodeError:
                # Message is not JSON, log as plain text
                logger.info(f"Plain text log message: {message}")

        return {
            "statusCode": 200,
            "body": json.dumps({
                "message": "Log events processed successfully",
                "eventCount": len(log_data.get("logEvents", []))
            })
        }

    except KeyError as e:
        # Not a CloudWatch Logs event, might be a test event
        logger.warning(f"Not a CloudWatch Logs event format: {e}")
        logger.info(f"Raw event: {json.dumps(event, indent=2)}")

        return {
            "statusCode": 200,
            "body": json.dumps({
                "message": "Event received but not in CloudWatch Logs format",
                "event": event
            })
        }

    except Exception as e:
        logger.error(f"Error processing event: {str(e)}")
        raise
