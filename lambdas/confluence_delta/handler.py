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
CONF_SECRET_NAME = os.environ["CONFLUENCE_SECRET_NAME"]


def get_secret_json(name: str) -> dict:
    resp = secrets.get_secret_value(SecretId=name)
    s = resp.get("SecretString")
    return json.loads(s) if s else {}


def get_cursor(key: str) -> str | None:
    resp = ddb.get_item(TableName=CURSORS_TABLE, Key={"source": {"S": "confluence"}, "cursor_key": {"S": key}})
    item = resp.get("Item")
    if not item:
        return None
    return item["cursor_value"]["S"]


def put_cursor(key: str, value: str):
    ddb.put_item(TableName=CURSORS_TABLE, Item={
        "source": {"S": "confluence"},
        "cursor_key": {"S": key},
        "cursor_value": {"S": value}
    })


def list_recent_pages(base_url: str, auth: tuple[str, str], since_time: str):
    # Confluence Cloud: CQL search by lastmodified
    start = 0
    limit = 50
    while True:
        url = f"{base_url}/wiki/rest/api/search"
        cql = f"type=page and lastmodified >= '{since_time}' order by lastmodified"
        params = {"cql": cql, "start": start, "limit": limit}
        r = requests.get(url, params=params, auth=auth, timeout=30)
        r.raise_for_status()
        data = r.json()
        results = data.get("results", [])
        if not results:
            break
        for res in results:
            content = res.get("content", {})
            if content.get("type") == "page":
                yield content.get("id")
        if start + limit >= data.get("totalSize", 0):
            break
        start += limit


def fetch_page(base_url: str, auth: tuple[str, str], page_id: str) -> dict:
    url = f"{base_url}/wiki/rest/api/content/{page_id}"
    params = {"expand": "body.storage,version,ancestors,space"}
    r = requests.get(url, params=params, auth=auth, timeout=30)
    r.raise_for_status()
    return r.json()


def handler(event, context):
    cfg = get_secret_json(CONF_SECRET_NAME)
    base_url = cfg["baseUrl"].rstrip("/")
    auth = (cfg["email"], cfg["apiToken"])

    since = get_cursor("lastmodified") or (datetime.now(timezone.utc) - timedelta(days=1)).isoformat()

    enq = 0
    latest = since
    for page_id in list_recent_pages(base_url, auth, since):
        page = fetch_page(base_url, auth, page_id)
        version = (page.get("version") or {}).get("when") or since
        latest = max(latest, version)

        chunk = {
            "source": "confluence",
            "op": "upsert",
            "item_type": "page",
            "id": page.get("id"),
            "title": page.get("title"),
            "url": base_url + page.get("_links", {}).get("webui", ""),
            "space": (page.get("space") or {}).get("key"),
            "ancestors": [a.get("title") for a in page.get("ancestors", [])],
            "updated": version,
            "body_storage": (page.get("body") or {}).get("storage", {}).get("value", ""),
        }
        sqs.send_message(QueueUrl=QUEUE_URL, MessageBody=json.dumps(chunk))
        enq += 1

    put_cursor("lastmodified", latest)
    return {"statusCode": 200, "body": json.dumps({"enqueued": enq, "since": since, "latest": latest})} 