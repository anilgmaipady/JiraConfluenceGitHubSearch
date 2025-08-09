## Architecture and Design

This document describes the Terraform-based RAG system that ingests GitHub code, Jira issues, and Confluence pages, indexes them into Amazon OpenSearch Serverless, and serves answers via API and Slack.

### System Diagram

```mermaid
graph TD
  subgraph "External Sources"
    GH["GitHub"]
    JR["Atlassian Jira"]
    CF["Atlassian Confluence"]
    SL["Slack"]
  end

  subgraph "API Layer"
    APIGW["API Gateway (HTTP API)<br/>Routes:<br/>/github/webhook<br/>/query<br/>/slack/command"]
  end

  subgraph "Ingestion Lambdas"
    L_GH["Lambda: github_webhook"]
    L_JR["Lambda: jira_delta"]
    L_CF["Lambda: confluence_delta"]
  end

  subgraph "Async Pipeline"
    SQS["SQS: ingest queue"]
    L_IDX["Lambda: index_worker"]
  end

  subgraph "Serving"
    L_QRY["Lambda: query_api"]
    L_SLK["Lambda: slack_handler"]
  end

  subgraph "Storage & Indexes"
    AOSS["Amazon OpenSearch Serverless<br/>Collection: VECTORSEARCH<br/>Index: rag-unified"]
    S3RAW["S3: raw artifacts"]
    DDB["DynamoDB: cursors + group_map"]
  end

  subgraph "AI Services"
    BED_EMB["Amazon Bedrock<br/>Embeddings: amazon.titan-embed-text-v2:0"]
    BED_LLM["Amazon Bedrock<br/>LLM: Claude Sonnet/Haiku"]
  end

  subgraph "Security & Secrets"
    SM["AWS Secrets Manager"]
  end

  %% Webhooks & API
  GH -->|"Webhook (push)"| APIGW
  SL -->|"Slash Command"| APIGW

  %% API Gateway to Lambdas
  APIGW -->|"POST /github/webhook"| L_GH
  APIGW -->|"POST /query"| L_QRY
  APIGW -->|"POST /slack/command"| L_SLK

  %% Scheduled delta scans
  EB["EventBridge Schedules"] -->|"rate(24h)"| L_JR
  EB -->|"rate(24h)"| L_CF

  %% Ingest to queue
  L_GH --> SQS
  L_JR --> SQS
  L_CF --> SQS

  %% Worker embeds + index
  SQS --> L_IDX
  L_IDX -->|"Embed"| BED_EMB
  L_IDX -->|"Upsert"| AOSS
  L_IDX -->|"Write"| S3RAW

  %% Query path
  L_QRY -->|"BM25 / kNN"| AOSS
  L_SLK -->|"BM25 / kNN"| AOSS
  L_QRY -->|"Generate"| BED_LLM
  L_SLK -->|"Generate"| BED_LLM
  L_SLK -->|"Respond"| SL

  %% State & secrets
  SM -.-> L_GH
  SM -.-> L_JR
  SM -.-> L_CF
  SM -.-> L_SLK
  DDB <--> L_JR
  DDB <--> L_CF
```

### Components
- **API Gateway (HTTP API)**: public endpoints for GitHub webhook, Query API, and Slack slash commands.
- **Ingestion Lambdas**:
  - `github_webhook`: validates signature, fetches changed files via GitHub API, enqueues for indexing.
  - `jira_delta`: scheduled delta by `updated`, emits issue + comment chunks.
  - `confluence_delta`: scheduled delta by `lastmodified`, emits page chunks.
- **SQS ingest queue**: buffers events for indexing.
- **index_worker**: embeds via Bedrock, upserts unified documents into OpenSearch, writes raw artifacts to S3.
- **query_api**: hybrid retrieval (BM25, kNN future) and returns citations; calls Bedrock LLM for generation (future).
- **slack_handler**: receives slash commands, retrieves, generates, and replies in-channel.
- **DynamoDB**: cursors for Jira/Confluence deltas; group map for ACLs (future).
- **Secrets Manager**: GitHub webhook secret, GitHub PAT, Jira/Confluence creds, Slack tokens.
- **OpenSearch Serverless**: `VECTORSEARCH` collection; index `rag-unified` for BM25 text + vector fields.

### Flow (concise)
- Ingest: GitHub webhooks and EventBridge schedules → Lambdas → SQS → index_worker → Bedrock embeddings → OpenSearch upserts.
- Query: API/Slack → OpenSearch retrieval → Bedrock LLM (optional) → Answer + citations.

### Reference
- Slack + Bedrock reference pattern adapted: [Create a generative AI assistant with Slack and Amazon Bedrock](https://aws.amazon.com/blogs/machine-learning/create-a-generative-ai-assistant-with-slack-and-amazon-bedrock/). 