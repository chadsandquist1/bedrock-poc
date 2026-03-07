#!/usr/bin/env python3
"""
LLM as a Judge Evaluation Script

This script handles the full lifecycle of Bedrock LLM evaluation jobs:
1. Upload evaluation dataset (JSONL) to S3
2. Create an evaluation job
3. Monitor the job until completion
4. Download results to local directory

Environment Variables:
    EVALUATION_JOB_ARN: ARN of an existing evaluation job to monitor (optional)
    LLM_JUDGE_BUCKET: S3 bucket name for evaluations (optional, uses Terraform output if not set)
    EVALUATION_ROLE_ARN: IAM role ARN for evaluations (optional, uses Terraform output if not set)
    AWS_REGION: AWS region (default: us-east-1)

Usage:
    # Create new evaluation job with dataset
    python llm_judge_evaluation.py --dataset /path/to/eval.jsonl

    # Monitor existing job (uses EVALUATION_JOB_ARN env var)
    EVALUATION_JOB_ARN=arn:aws:bedrock:... python llm_judge_evaluation.py

    # Create job with custom settings
    python llm_judge_evaluation.py --dataset eval.jsonl --job-name my-eval --timeout 3600
"""

import argparse
import json
import os
import sys
import time
from datetime import datetime
from pathlib import Path
from typing import Optional, List, Dict




try:
    import boto3
    from botocore.exceptions import ClientError
except ImportError:
    print("Error: boto3 is required. Install it with:")
    print("  pip install -r requirements.txt")
    print("  # or")
    print("  pip install boto3")
    sys.exit(1)


class LLMJudgeEvaluator:
    """Handles LLM as a Judge evaluation jobs."""

    def __init__(self, region: str = None):
        self.region = region or os.environ.get("AWS_REGION", "us-east-1")
        self.bedrock_client = boto3.client("bedrock", region_name=self.region)
        self.s3_client = boto3.client("s3", region_name=self.region)
        # Get configuration from environment or Terraform outputs
        self.bucket_name = os.environ.get("LLM_JUDGE_BUCKET") or self._get_terraform_output("llm_judge_bucket_name")
        self.role_arn = os.environ.get("EVALUATION_ROLE_ARN") or self._get_terraform_output("llm_judge_evaluation_role_arn")

        if not self.bucket_name or not self.role_arn:
            print("Error: Could not determine bucket name or role ARN.")
            print("Set LLM_JUDGE_BUCKET and EVALUATION_ROLE_ARN environment variables,")
            print("or run 'terraform output' in the project directory.")
            sys.exit(1)

    def _get_terraform_output(self, output_name: str) -> Optional[str]:
        """Get value from Terraform output."""
        try:
            import subprocess
            result = subprocess.run(
                ["terraform", "output", "-raw", output_name],
                capture_output=True,
                text=True,
                cwd=Path(__file__).parent.parent / "terraform"
            )
            if result.returncode == 0:
                return result.stdout.strip()
        except Exception:
            pass
        return None

    def upload_dataset(self, local_path: str, dataset_name: str = None) -> str:
        """
        Upload JSONL dataset to S3.

        Args:
            local_path: Path to local JSONL file
            dataset_name: Optional name for the dataset in S3

        Returns:
            S3 URI of uploaded dataset
        """
        local_file = Path(local_path)
        if not local_file.exists():
            raise FileNotFoundError(f"Dataset file not found: {local_path}")

        if not local_file.suffix == ".jsonl":
            print(f"Warning: File does not have .jsonl extension: {local_path}")

        # Validate JSONL format
        self._validate_jsonl(local_file)

        # Generate S3 key
        if dataset_name is None:
            dataset_name = local_file.stem
        timestamp = datetime.now().strftime("%Y%m%d-%H%M%S")
        s3_key = f"datasets/{dataset_name}-{timestamp}.jsonl"

        print(f"Uploading dataset to s3://{self.bucket_name}/{s3_key}...")
        self.s3_client.upload_file(str(local_file), self.bucket_name, s3_key)

        s3_uri = f"s3://{self.bucket_name}/{s3_key}"
        print(f"Dataset uploaded: {s3_uri}")
        return s3_uri

    def _validate_jsonl(self, file_path: Path) -> None:
        """Validate JSONL file format."""
        with open(file_path, "r") as f:
            for line_num, line in enumerate(f, 1):
                line = line.strip()
                if not line:
                    continue
                try:
                    data = json.loads(line)
                    if "prompt" not in data:
                        print(f"Warning: Line {line_num} missing 'prompt' field")
                except json.JSONDecodeError as e:
                    raise ValueError(f"Invalid JSON on line {line_num}: {e}")
        print(f"Dataset validation passed ({line_num} lines)")

    # Valid task types for Bedrock evaluation
    VALID_TASK_TYPES = ["Summarization", "Classification", "QuestionAndAnswer", "Generation", "Custom"]

    def _get_inference_params(self, model_id: str) -> str:
        """Get the correct inference parameters based on model family.

        Note: For Bedrock evaluation jobs, returning an empty string lets
        the service use its defaults. json.dumps({}) produces '{}' which
        is invalid - the API expects either no inferenceParams or an empty string.
        """
        # For evaluation jobs, empty string lets service use defaults
        return ""

    def create_evaluation_job(
        self,
        dataset_s3_uri: str,
        job_name: str = None,
        model_id: str = None,
        metrics: List[str] = None,
        task_type: str = "QuestionAndAnswer"
    ) -> str:
        """
        Create a Bedrock evaluation job.

        Args:
            dataset_s3_uri: S3 URI of the evaluation dataset
            job_name: Name for the evaluation job
            model_id: Model to evaluate
            metrics: List of metrics to evaluate
            task_type: Type of task (Summarization, Classification, QuestionAndAnswer, Generation, Custom)

        Returns:
            Job ARN
        """
        if job_name is None:
            timestamp = datetime.now().strftime("%Y%m%d-%H%M%S")
            job_name = f"llm-judge-eval-{timestamp}"

        if metrics is None:
            metrics = ["Builtin.Accuracy", "Builtin.Robustness"]

        if task_type not in self.VALID_TASK_TYPES:
            print(f"Warning: '{task_type}' may not be a valid task type.")
            print(f"Valid task types: {', '.join(self.VALID_TASK_TYPES)}")

        output_s3_uri = f"s3://{self.bucket_name}/results/{job_name}/"

        print(f"Creating evaluation job: {job_name}")
        print(f"  Task Type: {task_type}")
        print(f"  Model: {model_id}")
        print(f"  Dataset: {dataset_s3_uri}")
        print(f"  Metrics: {metrics}")
        print(f"  Output: {output_s3_uri}")

        try:
            # Build the model config - only include inferenceParams if non-empty
            inference_params = self._get_inference_params(model_id)
            bedrock_model_config = {"modelIdentifier": model_id}
            if inference_params:
                bedrock_model_config["inferenceParams"] = inference_params

            response = self.bedrock_client.create_evaluation_job(
                jobName=job_name,
                roleArn=self.role_arn,
                evaluationConfig={
                    "automated": {
                        "datasetMetricConfigs": [
                            {
                                "taskType": task_type,
                                "dataset": {
                                    "name": job_name,
                                    "datasetLocation": {
                                        "s3Uri": dataset_s3_uri
                                    }
                                },
                                "metricNames": metrics
                            }
                        ]
                    }
                },
                inferenceConfig={
                    "models": [
                        {
                            "bedrockModel": bedrock_model_config
                        }
                    ]
                },
                outputDataConfig={
                    "s3Uri": output_s3_uri
                }
            )

            job_arn = response["jobArn"]
            print(f"\nEvaluation job created successfully!")
            print(f"Job ARN: {job_arn}")
            print(f"\nTo monitor this job later, set the environment variable:")
            print(f"  export EVALUATION_JOB_ARN='{job_arn}'")

            return job_arn

        except ClientError as e:
            error_code = e.response["Error"]["Code"]
            error_message = e.response["Error"]["Message"]
            print(f"Error creating evaluation job: {error_code} - {error_message}")
            raise

    def get_job_status(self, job_arn: str) -> dict:
        """Get the current status of an evaluation job."""
        try:
            response = self.bedrock_client.get_evaluation_job(
                jobIdentifier=job_arn
            )
            return {
                "status": response.get("status"),
                "jobName": response.get("jobName"),
                "jobArn": response.get("jobArn"),
                "creationTime": response.get("creationTime"),
                "lastModifiedTime": response.get("lastModifiedTime"),
                "failureMessages": response.get("failureMessages", []),
                "outputDataConfig": response.get("outputDataConfig", {})
            }
        except ClientError as e:
            error_code = e.response["Error"]["Code"]
            error_message = e.response["Error"]["Message"]
            print(f"Error getting job status: {error_code} - {error_message}")
            raise

    def monitor_job(self, job_arn: str, timeout: int = 1800, poll_interval: int = 30) -> dict:
        """
        Monitor an evaluation job until completion.

        Args:
            job_arn: ARN of the evaluation job
            timeout: Maximum time to wait in seconds (default: 30 minutes)
            poll_interval: Time between status checks in seconds

        Returns:
            Final job status
        """
        print(f"\nMonitoring evaluation job...")
        print(f"Job ARN: {job_arn}")
        print(f"Timeout: {timeout} seconds")
        print("-" * 60)

        start_time = time.time()
        terminal_states = ["Completed", "Failed", "Stopped"]

        while True:
            elapsed = time.time() - start_time
            if elapsed > timeout:
                print(f"\nTimeout reached after {timeout} seconds")
                return self.get_job_status(job_arn)

            status = self.get_job_status(job_arn)
            current_status = status["status"]

            timestamp = datetime.now().strftime("%H:%M:%S")
            print(f"[{timestamp}] Status: {current_status} (elapsed: {int(elapsed)}s)")

            if current_status in terminal_states:
                print("-" * 60)
                if current_status == "Completed":
                    print("Evaluation job completed successfully!")
                elif current_status == "Failed":
                    print("Evaluation job failed!")
                    if status.get("failureMessages"):
                        print("Failure messages:")
                        for msg in status["failureMessages"]:
                            print(f"  - {msg}")
                elif current_status == "Stopped":
                    print("Evaluation job was stopped.")
                return status

            time.sleep(poll_interval)

    def download_results(self, job_status: dict, output_dir: str = None) -> Optional[str]:
        """
        Download evaluation results from S3.

        Args:
            job_status: Job status dictionary containing output location
            output_dir: Local directory to download results to

        Returns:
            Path to downloaded results directory, or None if download failed
        """
        if job_status.get("status") != "Completed":
            print("Cannot download results: job not completed")
            return None

        output_config = job_status.get("outputDataConfig", {})
        s3_uri = output_config.get("s3Uri")

        if not s3_uri:
            print("No output S3 URI found in job status")
            return None

        # Parse S3 URI
        s3_uri = s3_uri.replace("s3://", "")
        bucket, prefix = s3_uri.split("/", 1)

        # Set up output directory
        if output_dir is None:
            output_dir = f"./evaluation-results/{job_status.get('jobName', 'unknown')}"

        output_path = Path(output_dir)
        output_path.mkdir(parents=True, exist_ok=True)

        print(f"\nDownloading results to: {output_path}")

        try:
            # List and download all objects with the prefix
            paginator = self.s3_client.get_paginator("list_objects_v2")
            downloaded_count = 0

            for page in paginator.paginate(Bucket=bucket, Prefix=prefix):
                for obj in page.get("Contents", []):
                    key = obj["Key"]
                    relative_path = key[len(prefix):].lstrip("/")
                    if not relative_path:
                        continue

                    local_file = output_path / relative_path
                    local_file.parent.mkdir(parents=True, exist_ok=True)

                    print(f"  Downloading: {relative_path}")
                    self.s3_client.download_file(bucket, key, str(local_file))
                    downloaded_count += 1

            print(f"\nDownloaded {downloaded_count} file(s) to {output_path}")
            return str(output_path)

        except ClientError as e:
            print(f"Error downloading results: {e}")
            return None

    def run(
        self,
        dataset_path: str = None,
        job_name: str = None,
        model_id: str = None,
        metrics: List[str] = None,
        task_type: str = "QuestionAndAnswer",
        timeout: int = 1800,
        output_dir: str = None
    ) -> dict:
        """
        Run the full evaluation workflow.

        Args:
            dataset_path: Path to local JSONL dataset (required if no EVALUATION_JOB_ARN)
            job_name: Name for the evaluation job
            model_id: Model to evaluate
            metrics: List of metrics
            task_type: Type of task (Summarization, Classification, QuestionAndAnswer, Generation, Custom)
            timeout: Monitoring timeout in seconds
            output_dir: Directory to download results to

        Returns:
            Final job status and results path
        """
        # Check for existing job ARN in environment
        job_arn = os.environ.get("EVALUATION_JOB_ARN")

        if job_arn:
            print(f"Using existing evaluation job from EVALUATION_JOB_ARN")
        else:
            if not dataset_path:
                print("Error: Either provide --dataset or set EVALUATION_JOB_ARN environment variable")
                sys.exit(1)

            # Upload dataset and create job
            dataset_s3_uri = self.upload_dataset(dataset_path)
            job_arn = self.create_evaluation_job(
                dataset_s3_uri=dataset_s3_uri,
                job_name=job_name,
                model_id=model_id,
                metrics=metrics,
                task_type=task_type
            )

            # Set environment variable for future reference
            os.environ["EVALUATION_JOB_ARN"] = job_arn

        # Monitor job
        final_status = self.monitor_job(job_arn, timeout=timeout)

        # Download results if completed
        results_path = None
        if final_status.get("status") == "Completed":
            results_path = self.download_results(final_status, output_dir)

        return {
            "status": final_status,
            "results_path": results_path
        }

DEFAULT_MODEL_ID = ""

def main():
    parser = argparse.ArgumentParser(
        description="LLM as a Judge Evaluation Script",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  # Create and monitor a new evaluation job
  python llm_judge_evaluation.py --dataset ./eval-dataset.jsonl

  # Monitor an existing job
  export EVALUATION_JOB_ARN='arn:aws:bedrock:us-east-1:123456789:evaluation-job/abc123'
  python llm_judge_evaluation.py

  # Create job with custom settings
  python llm_judge_evaluation.py --dataset eval.jsonl --job-name my-eval --model us.amazon.nova-lite-v1:0
        """
    )

    parser.add_argument(
        "--dataset", "-d",
        help="Path to local JSONL evaluation dataset"
    )
    parser.add_argument(
        "--job-name", "-n",
        help="Name for the evaluation job (auto-generated if not provided)"
    )
    parser.add_argument(
        "--model", "-m",
        default=DEFAULT_MODEL_ID,
        help="Model ID to evaluate"
    )
    parser.add_argument(
        "--metrics",
        nargs="+",
        default=["Builtin.Accuracy", "Builtin.Robustness"],
        help="Metrics to evaluate (default: Builtin.Accuracy Builtin.Robustness)"
    )
    parser.add_argument(
        "--task-type",
        choices=["Summarization", "Classification", "QuestionAndAnswer", "Generation", "Custom"],
        default="QuestionAndAnswer",
        help="Task type for evaluation (default: QuestionAndAnswer)"
    )
    parser.add_argument(
        "--timeout", "-t",
        type=int,
        default=1800,
        help="Timeout in seconds for monitoring (default: 1800)"
    )
    parser.add_argument(
        "--output-dir", "-o",
        help="Directory to download results to (default: ./evaluation-results/<job-name>)"
    )
    parser.add_argument(
        "--region",
        default="us-east-1",
        help="AWS region (default: us-east-1)"
    )

    args = parser.parse_args()

    # Check if we have a job ARN or dataset
    job_arn = os.environ.get("EVALUATION_JOB_ARN")
    if not job_arn and not args.dataset:
        print("Error: Either provide --dataset or set EVALUATION_JOB_ARN environment variable")
        print("\nTo create a new evaluation job:")
        print("  python llm_judge_evaluation.py --dataset /path/to/eval.jsonl")
        print("\nTo monitor an existing job:")
        print("  export EVALUATION_JOB_ARN='arn:aws:bedrock:...'")
        print("  python llm_judge_evaluation.py")
        sys.exit(1)

    # Run evaluation
    evaluator = LLMJudgeEvaluator(region=args.region)
    result = evaluator.run(
        dataset_path=args.dataset,
        job_name=args.job_name,
        model_id=args.model,
        metrics=args.metrics,
        task_type=args.task_type,
        timeout=args.timeout,
        output_dir=args.output_dir
    )

    # Print summary
    print("\n" + "=" * 60)
    print("EVALUATION SUMMARY")
    print("=" * 60)
    print(f"Status: {result['status'].get('status')}")
    print(f"Job Name: {result['status'].get('jobName')}")
    print(f"Job ARN: {result['status'].get('jobArn')}")
    if result["results_path"]:
        print(f"Results downloaded to: {result['results_path']}")
    print("=" * 60)


if __name__ == "__main__":
    main()
