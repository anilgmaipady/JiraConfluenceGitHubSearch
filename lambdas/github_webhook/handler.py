import json
import os
import boto3
import base64
import hmac
import hashlib
import requests

sqs = boto3.client("sqs")
secrets = boto3.client("secretsmanager")

QUEUE_URL = os.environ.get("SQS_INGEST_URL")
GITHUB_SECRET_NAME = os.environ.get("GITHUB_SECRET_NAME")
GITHUB_PAT_SECRET_NAME = os.environ.get("GITHUB_PAT_SECRET_NAME")


def verify_signature(secret: bytes, body: bytes, signature_header: str) -> bool:
    try:
        sha_name, signature = signature_header.split("=", 1)
    except Exception:
        return False
    mac = hmac.new(secret, msg=body, digestmod=hashlib.sha256)
    expected = mac.hexdigest()
    return hmac.compare_digest(expected, signature)


def get_secret_value(name: str) -> str:
    resp = secrets.get_secret_value(SecretId=name)
    if "SecretString" in resp:
        return resp["SecretString"]
    return base64.b64decode(resp["SecretBinary"]).decode()


def handler(event, context):
    body = event.get("body", "")
    if isinstance(body, str):
        raw_body = body.encode()
    else:
        raw_body = json.dumps(body).encode()

    signature = event.get("headers", {}).get("x-hub-signature-256", "")
    secret_str = get_secret_value(GITHUB_SECRET_NAME)
    secret = secret_str.encode()

    if not verify_signature(secret, raw_body, signature):
        return {"statusCode": 401, "body": "invalid signature"}

    try:
        payload = json.loads(body)
    except Exception:
        payload = {"raw": body}

    event_type = event.get("headers", {}).get("x-github-event")

    # For push events, fetch changed files content for each commit
    if event_type == "push":
        pat = get_secret_value(GITHUB_PAT_SECRET_NAME)
        headers = {"Authorization": f"Bearer {pat}", "Accept": "application/vnd.github+json"}
        repo_full = payload.get("repository", {}).get("full_name")
        base_api = f"https://api.github.com/repos/{repo_full}"
        for commit in payload.get("commits", []):
            sha = commit.get("id")
            r = requests.get(f"{base_api}/commits/{sha}", headers=headers, timeout=30)
            if r.status_code != 200:
                continue
            data = r.json()
            files = data.get("files", [])
            for f in files:
                if f.get("status") in {"added", "modified"}:
                    path = f.get("filename")
                    raw_url = f.get("raw_url")
                    try:
                        fr = requests.get(raw_url, headers=headers, timeout=30)
                        content = fr.text if fr.status_code == 200 else ""
                    except Exception:
                        content = ""
                    msg = {
                        "source": "github",
                        "event_type": "file",
                        "repo": repo_full,
                        "path": path,
                        "sha": sha,
                        "lang": None,
                        "content": content[:200000],  # cap
                    }
                    sqs.send_message(QueueUrl=QUEUE_URL, MessageBody=json.dumps(msg))
        return {"statusCode": 202, "body": json.dumps({"ok": True, "type": "push"})}

    # fallback: enqueue raw payload
    sqs.send_message(QueueUrl=QUEUE_URL, MessageBody=json.dumps({
        "source": "github",
        "event_type": event_type,
        "payload": payload,
    }))
    return {"statusCode": 202, "body": json.dumps({"ok": True})} 