import json
import os
import logging
import base64
import boto3
import urllib3

logger = logging.getLogger()
logger.setLevel(logging.INFO)

AOSS_ENDPOINT = os.environ.get("AOSS_COLLECTION_ENDPOINT", "")
INDEX_NAME = os.environ.get("AOSS_INDEX_NAME", "rag-unified")
EMBED_MODEL_ID = os.environ.get("EMBED_MODEL_ID", "amazon.titan-embed-text-v2:0")
RAW_BUCKET = os.environ.get("RAW_BUCKET", "")

bedrock = boto3.client("bedrock-runtime")
s3 = boto3.client("s3")
http = urllib3.PoolManager()


def embed_text(text: str) -> list:
    body = {"inputText": text}
    resp = bedrock.invoke_model(modelId=EMBED_MODEL_ID, body=json.dumps(body))
    payload = json.loads(resp["body"].read())
    # Titan v2 returns {embedding: [..]}
    vec = payload.get("embedding") or payload.get("embeddings", [{}])[0].get("embedding")
    return vec


def upsert_document(doc: dict):
    url = f"{AOSS_ENDPOINT}/{INDEX_NAME}/_doc/{doc['id']}"
    headers = {"Content-Type": "application/json"}
    data = json.dumps(doc).encode()
    r = http.request("PUT", url, body=data, headers=headers)
    if r.status not in (200, 201):
        logger.error({"index_error": r.status, "body": r.data.decode(errors="ignore")})
    return r.status


def normalize_record(record: dict) -> list:
    """
    Convert an ingest message into one or more documents per unified schema.
    Expected message forms:
    - {source: "github", event_type: "push", payload: {...}}
    - {source: "jira", op: "delta", items: [...]}  # if expanded upstream
    - {source: "confluence", op: "delta", items: [...]}  # if expanded upstream
    For PoC, accept raw payloads and store minimal text.
    """
    source = record.get("source")
    docs = []

    if source == "github":
        payload = record.get("payload", {})
        repo = payload.get("repository", {}).get("full_name")
        commits = payload.get("commits", [])
        for c in commits:
            text = (c.get("message") or "") + "\n" + (c.get("added") and "\n".join(c["added"]) or "")
            vec = embed_text(text[:2000]) if text else []
            doc = {
                "source": "code",
                "id": f"gh:{c.get('id')}",
                "project": repo.split("/")[0] if repo else None,
                "repo": repo,
                "path_or_key": "",
                "title": c.get("message", "commit"),
                "tags": ["commit"],
                "url": payload.get("compare") or payload.get("repository", {}).get("html_url"),
                "created_at": c.get("timestamp"),
                "updated_at": c.get("timestamp"),
                "acl_allow_users": [],
                "acl_allow_groups": [],
                "acl_allow_projects": [],
                "text": text,
                "vector": vec,
            }
            docs.append(doc)

    elif source in ("jira", "confluence"):
        # Expect upstream to expand items; for now, store a stub delta marker
        text = json.dumps(record)
        vec = embed_text(text[:2000])
        doc = {
            "source": source,
            "id": f"{source}:delta:{base64.urlsafe_b64encode(text.encode())[:16].decode()}",
            "project": None,
            "repo": None,
            "path_or_key": None,
            "title": f"{source} delta",
            "tags": ["delta"],
            "url": None,
            "created_at": None,
            "updated_at": None,
            "acl_allow_users": [],
            "acl_allow_groups": [],
            "acl_allow_projects": [],
            "text": text,
            "vector": vec,
        }
        docs.append(doc)

    return docs


def handler(event, context):
    # SQS event
    records = event.get("Records", [])
    for r in records:
        try:
            body = json.loads(r["body"]) if isinstance(r.get("body"), str) else r.get("body")
            for doc in normalize_record(body):
                upsert_document(doc)
        except Exception as e:
            logger.exception({"error": str(e)})
    return {"statusCode": 200} 