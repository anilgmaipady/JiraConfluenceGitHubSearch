import urllib.parse
import json
import os


def handler(event, context):
    # Slack sends application/x-www-form-urlencoded by default for slash commands
    body = event.get("body") or ""
    params = urllib.parse.parse_qs(body)
    text = (params.get("text", [""]) or [""])[0]

    # immediate ack (within 3s). For real use, respond to response_url asynchronously.
    return {
        "statusCode": 200,
        "headers": {"Content-Type": "application/json"},
        "body": json.dumps({"response_type": "ephemeral", "text": f"Processing: {text}"})
    } 