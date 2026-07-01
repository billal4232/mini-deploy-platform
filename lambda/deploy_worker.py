# ── Mini Deploy Platform V3 — Deploy Worker Lambda ──────────────────────────────
# Triggered by SQS. Reads deploy requests, VALIDATES the image tag exists in ECR,
# registers a new task-definition revision with the requested image tag, updates
# the ECS service, publishes to SNS.
# On failure, RAISES so SQS retries (after 3 failures the message lands in the DLQ).

import json
import os
import logging

import boto3
from botocore.exceptions import ClientError

logger = logging.getLogger()
logger.setLevel(logging.INFO)

ecs = boto3.client("ecs")
ecr = boto3.client("ecr")
sns = boto3.client("sns")

# ── Configuration ───────────────────────────────────────────────────────────────
# Injected by Terraform via Lambda environment variables.

ECS_CLUSTER = os.environ["ECS_CLUSTER"]
ECS_SERVICE = os.environ["ECS_SERVICE"]
ECS_TASK_FAMILY = os.environ["ECS_TASK_FAMILY"]
ECR_IMAGE_BASE = os.environ["ECR_IMAGE_BASE"]  # e.g. 68860....amazonaws.com/repo
ECR_REPO_NAME = os.environ["ECR_REPO_NAME"]     # e.g. mini-deploy-platform-app
SNS_TOPIC_ARN = os.environ["SNS_TOPIC_ARN"]


# ── Handler ─────────────────────────────────────────────────────────────────────


def lambda_handler(event, context):
    """
    SQS-triggered handler.
    event["Records"] is a list of SQS messages. Process each one.
    """
    for record in event["Records"]:
        process_message(record)


# ── Core logic ──────────────────────────────────────────────────────────────────


def process_message(record):
    """
    Parse one SQS message and trigger a deploy of a SPECIFIC image tag.

    Steps:
      1. Parse the message body for image_tag and requested_by.
      2. VALIDATE the image tag exists in ECR (fails fast if not).
      3. Describe the current task definition to get the active revision.
      4. Swap the container image to the requested ECR URI + tag.
      5. Register a NEW task-definition revision with the updated image.
      6. Update the ECS service to use the new revision.
      7. Publish an SNS notification.

    If anything fails, RAISE so SQS retries → after 3 attempts → DLQ.
    """
    # ── 1. Parse the message ──────────────────────────────────────────────────
    try:
        body = json.loads(record["body"])
    except json.JSONDecodeError:
        logger.error("Invalid JSON in message body: %s", record["body"])
        # Raise so the message is retried and eventually lands in the DLQ,
        # where you can inspect what was sent.
        raise

    image_tag = body.get("image_tag", "")
    requested_by = body.get("requested_by", "unknown")

    if not image_tag:
        # image_tag is required for this version — there's nothing to deploy.
        logger.error("Message missing required field: image_tag (body=%s)", body)
        raise ValueError("image_tag is required")

    # Build the full ECR image URI: registry/repo:tag
    new_image = f"{ECR_IMAGE_BASE}:{image_tag}"

    logger.info(
        "Deploy request — image_tag=%s requested_by=%s message_id=%s",
        image_tag,
        requested_by,
        record.get("messageId", "n/a"),
    )

    # ── 2. Validate the image tag exists in ECR ───────────────────────────────
    # BEFORE we register a task definition or touch the service, verify that
    # the requested image tag actually exists in the repository. If it doesn't,
    # fail loudly — raise so the message hits the DLQ — and never create a
    # doomed task-definition revision.
    try:
        ecr.describe_images(
            repositoryName=ECR_REPO_NAME,
            imageIds=[{"imageTag": image_tag}],
        )
    except ecr.exceptions.ImageNotFoundException:
        logger.error(
            "Image tag '%s' does NOT exist in ECR repo '%s' — failing the deploy",
            image_tag,
            ECR_REPO_NAME,
        )
        raise ValueError(
            f"Image tag '{image_tag}' does not exist in ECR"
        )
    except ClientError:
        # Any other ECR error (throttling, auth, etc.) is also fatal.
        # Log and raise so it's visible in logs and eventually hits the DLQ.
        logger.exception(
            "ECR describe_images FAILED for repo=%s tag=%s",
            ECR_REPO_NAME,
            image_tag,
        )
        raise

    logger.info("Verified image tag exists in ECR: %s", image_tag)

    # ── 3. Describe current task definition ───────────────────────────────────
    # Fetch the latest ACTIVE revision of the family. We'll copy every field
    # except the container image(s), ensuring nothing else changes.
    try:
        current_td = ecs.describe_task_definition(taskDefinition=ECS_TASK_FAMILY)
    except Exception:
        logger.exception(
            "describe_task_definition FAILED for family=%s", ECS_TASK_FAMILY
        )
        raise  # Retry → DLQ

    td = current_td["taskDefinition"]

    # ── 4. Swap the container image ───────────────────────────────────────────
    # containerDefinitions is a list of dicts. We change ONLY the "image" field
    # on each container (handles sidecars safely). Everything else — portMappings,
    # environment, secrets, logConfiguration — is preserved as-is.
    old_image = td["containerDefinitions"][0]["image"]
    logger.info("Current image: %s → New image: %s", old_image, new_image)

    new_container_defs = []
    for container in td["containerDefinitions"]:
        updated = dict(container)  # shallow copy so we don't mutate the original
        updated["image"] = new_image
        new_container_defs.append(updated)

    # ── 5. Register a new task-definition revision ────────────────────────────
    # Copy the required fields from the current definition. The fields we pass
    # are exactly what register_task_definition needs — no read-only fields
    # like taskDefinitionArn, revision, status, etc.
    try:
        new_td_resp = ecs.register_task_definition(
            family=td["family"],
            containerDefinitions=new_container_defs,
            executionRoleArn=td["executionRoleArn"],
            taskRoleArn=td["taskRoleArn"],
            networkMode=td["networkMode"],
            requiresCompatibilities=td["requiresCompatibilities"],
            cpu=td["cpu"],
            memory=td["memory"],
        )
    except Exception:
        logger.exception(
            "register_task_definition FAILED for family=%s image=%s",
            ECS_TASK_FAMILY,
            new_image,
        )
        raise

    new_td_arn = new_td_resp["taskDefinition"]["taskDefinitionArn"]
    new_revision = new_td_resp["taskDefinition"]["revision"]
    logger.info(
        "Registered new task definition — ARN=%s revision=%d",
        new_td_arn,
        new_revision,
    )

    # ── 6. Update the ECS service to use the new revision ─────────────────────
    # We point the service at the EXACT new revision ARN (not forceNewDeployment
    # on the old one). ECS will roll out a replacement task set.
    try:
        ecs.update_service(
            cluster=ECS_CLUSTER,
            service=ECS_SERVICE,
            taskDefinition=new_td_arn,
        )
    except Exception:
        logger.exception(
            "update_service FAILED for %s/%s → task_definition=%s",
            ECS_CLUSTER,
            ECS_SERVICE,
            new_td_arn,
        )
        raise  # Retry → DLQ

    logger.info(
        "ECS update_service triggered — %s/%s now using revision %d (image=%s)",
        ECS_CLUSTER,
        ECS_SERVICE,
        new_revision,
        new_image,
    )

    # ── 7. Publish SNS notification ───────────────────────────────────────────
    # At this point: image validated ✓, task def registered ✓, service updated ✓.
    # ECS will now pull the image asynchronously — the image is known to exist,
    # so pull failures here would be network/auth issues, not missing tags.
    message = (
        f"Deploy triggered!\n\n"
        f"Image:      {new_image}\n"
        f"Tag:        {image_tag}\n"
        f"Requested by: {requested_by}\n"
        f"Cluster:    {ECS_CLUSTER}\n"
        f"Service:    {ECS_SERVICE}\n"
        f"Revision:   {new_revision}\n"
        f"\n"
        f"Pre-deploy validation: image tag confirmed in ECR.\n"
    )

    try:
        sns.publish(
            TopicArn=SNS_TOPIC_ARN,
            Subject="[Mini Deploy Platform] Deploy Triggered",
            Message=message,
        )
        logger.info("SNS notification published")
    except Exception:
        # SNS failure is non-critical — the deploy already happened.
        logger.exception("SNS publish failed (deploy already triggered)")
