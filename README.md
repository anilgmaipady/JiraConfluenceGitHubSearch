# Jira/Confluence/Code RAG PoC (Terraform)

This PoC deploys AWS primitives for a hybrid RAG system that ingests GitHub webhooks, schedules Jira/Confluence delta scans, embeds and indexes into Amazon OpenSearch Serverless, and serves a simple query API plus a Slack command handler.

## What it creates
- Amazon OpenSearch Serverless collection (VECTORSEARCH) with public network policy and data access bound to a Lambda role
- S3 buckets for raw artifacts and logs
- DynamoDB tables for cursors and group mapping
- SQS queue + DLQ for ingest/index worker
- Five Lambda functions (placeholders) packaged from `lambdas/*`
- HTTP API (API Gateway v2) routes:
  - `POST /github/webhook`
  - `POST /query`
  - `POST /slack/command`
- EventBridge schedules for Jira and Confluence delta jobs

## Configure
- Create the required secrets in AWS Secrets Manager (names can be changed in `variables.tf`):
  - `github/webhook/secret`
  - `slack/bot/token`
  - `slack/signing/secret`
  - `jira/credentials` (JSON with `baseUrl`, `email`, `apiToken`)
  - `confluence/credentials` (JSON with `baseUrl`, `email`, `apiToken`)

## Deploy
```bash
terraform init
terraform apply -auto-approve
```

Outputs include the HTTP API endpoint. Point your GitHub webhook to `POST {api_endpoint}/github/webhook` and Slack slash command to `POST {api_endpoint}/slack/command`.

## Dependencies
- macOS: Homebrew Terraform
- Python dependencies are packaged into a Lambda layer at `layers/python_deps.zip`. Build it with:

```bash
mkdir -p layers/python/lib/python3.11/site-packages
pip3 install --upgrade pip
pip3 install -t layers/python/lib/python3.11/site-packages requests urllib3 boto3
(cd layers && zip -r9 python_deps.zip python)
```

Then apply Terraform.

## Routes
- GitHub webhook: `POST {api_endpoint}/github/webhook`
- Query API: `POST {api_endpoint}/query`
- Slack command: `POST {api_endpoint}/slack/command`

## Notes
- Bedrock models must be enabled in your account/region.
- OpenSearch index mapping is not auto-created. For production, create an index with mappings (BM25 fields and knn_vector) matching your schema, or add bootstrap code in `index_worker` to PUT mappings on cold start.
- Architecture aligns with AWS Slack+Bedrock reference: [Create a generative AI assistant with Slack and Amazon Bedrock](https://aws.amazon.com/blogs/machine-learning/create-a-generative-ai-assistant-with-slack-and-amazon-bedrock/). 