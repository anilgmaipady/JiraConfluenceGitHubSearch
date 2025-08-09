import json
import os
import urllib3

http = urllib3.PoolManager()
AOSS_ENDPOINT = os.environ.get("AOSS_COLLECTION_ENDPOINT", "")
INDEX_NAME = os.environ.get("AOSS_INDEX_NAME", "rag-unified")


def search_bm25(q: str, k: int = 50):
    url = f"{AOSS_ENDPOINT}/{INDEX_NAME}/_search"
    body = {
        "size": k,
        "query": {"multi_match": {"query": q, "fields": ["title^2", "text"]}},
        "_source": True
    }
    r = http.request("GET", url, body=json.dumps(body).encode(), headers={"Content-Type": "application/json"})
    hits = []
    if r.status == 200:
        data = json.loads(r.data.decode())
        hits = [h["_source"] for h in data.get("hits", {}).get("hits", [])]
    return hits


def handler(event, context):
    try:
        body = json.loads(event.get("body", "{}"))
    except Exception:
        body = {}
    query = body.get("q", "")

    bm25 = search_bm25(query, 25)
    # TODO: add vector kNN once index contains knn_vector field and AOSS index mapping is created
    # For now, just return BM25 results as citations
    citations = [
        {"title": d.get("title"), "url": d.get("url"), "source": d.get("source")}
        for d in bm25[:10]
    ]

    return {
        "statusCode": 200,
        "headers": {"Content-Type": "application/json"},
        "body": json.dumps({
            "query": query,
            "answer": "(stub) hybrid retrieval results attached as citations",
            "citations": citations
        })
    } 