import json
import os
import boto3
import requests
from datetime import datetime, timedelta, timezone

sqs = boto3.client("sqs")
secrets = boto3.client("secretsmanager")
ddb = boto3.client("dynamodb")

QUEUE_URL = os.environ["SQS_INGEST_URL"]
CURSORS_TABLE = os.environ["CURSORS_TABLE"]
JIRA_SECRET_NAME = os.environ["JIRA_SECRET_NAME"]


def get_secret_json(name: str) -> dict:
    resp = secrets.get_secret_value(SecretId=name)
    s = resp.get("SecretString")
    return json.loads(s) if s else {}


def get_cursor(key: str) -> str | None:
    resp = ddb.get_item(TableName=CURSORS_TABLE, Key={"source": {"S": "jira"}, "cursor_key": {"S": key}})
    item = resp.get("Item")
    if not item:
        return None
    return item["cursor_value"]["S"]


def put_cursor(key: str, value: str):
    ddb.put_item(TableName=CURSORS_TABLE, Item={
        "source": {"S": "jira"},
        "cursor_key": {"S": key},
        "cursor_value": {"S": value}
    })


def fetch_issues(base_url: str, auth: tuple[str, str], jql: str):
    start_at = 0
    page_size = 50
    while True:
        url = f"{base_url}/rest/api/3/search"
        params = {"jql": jql, "startAt": start_at, "maxResults": page_size}
        r = requests.get(url, params=params, auth=auth, timeout=30)
        r.raise_for_status()
        data = r.json()
        issues = data.get("issues", [])
        if not issues:
            break
        yield from issues
        if start_at + page_size >= data.get("total", 0):
            break
        start_at += page_size


def handler(event, context):
    cfg = get_secret_json(JIRA_SECRET_NAME)
    base_url = cfg["baseUrl"].rstrip("/")
    auth = (cfg["email"], cfg["apiToken"])

    # use cursor or default to 24h ago
    since = get_cursor("updated") or (datetime.now(timezone.utc) - timedelta(days=1)).isoformat()
    jql = f"updated >= '{since}' order by updated"

    enqueued = 0
    latest = since
    for issue in fetch_issues(base_url, auth, jql):
        key = issue.get("key")
        fields = issue.get("fields", {})
        updated = fields.get("updated") or latest
        latest = max(latest, updated)

        base_chunk = {
            "source": "jira",
            "op": "upsert",
            "item_type": "issue",
            "key": key,
            "summary": fields.get("summary"),
            "description": (fields.get("description") or {}).get("content"),
            "url": f"{base_url}/browse/{key}",
            "updated": updated,
            "meta": {
                "status": (fields.get("status") or {}).get("name"),
                "assignee": (fields.get("assignee") or {}).get("emailAddress"),
                "labels": fields.get("labels") or [],
                "project": (fields.get("project") or {}).get("key"),
            },
        }
        sqs.send_message(QueueUrl=QUEUE_URL, MessageBody=json.dumps(base_chunk))
        enqueued += 1

        # comments
        comments_url = f"{base_url}/rest/api/3/issue/{key}/comment"
        cr = requests.get(comments_url, auth=auth, timeout=30)
        cr.raise_for_status()
        for c in cr.json().get("comments", []):
            chunk = {
                "source": "jira",
                "op": "upsert",
                "item_type": "comment",
                "key": key,
                "comment_id": c.get("id"),
                "text": (c.get("body") or {}).get("content"),
                "author": (c.get("author") or {}).get("emailAddress"),
                "updated": c.get("updated"),
                "url": f"{base_url}/browse/{key}",
            }
            sqs.send_message(QueueUrl=QUEUE_URL, MessageBody=json.dumps(chunk))
            enqueued += 1

    put_cursor("updated", latest)
    return {"statusCode": 200, "body": json.dumps({"enqueued": enqueued, "since": since, "latest": latest})} 