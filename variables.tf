variable "aws_region" {
  description = "AWS region to deploy into"
  type        = string
  default     = "us-east-1"
}

variable "project_name" {
  description = "Project/prefix name for resources"
  type        = string
  default     = "jira-conf-code-rag"
}

variable "github_webhook_secret_name" {
  description = "Secrets Manager name for GitHub webhook secret"
  type        = string
  default     = "github/webhook/secret"
}

variable "slack_bot_token_secret_name" {
  description = "Secrets Manager name for Slack bot token"
  type        = string
  default     = "slack/bot/token"
}

variable "slack_signing_secret_name" {
  description = "Secrets Manager name for Slack signing secret"
  type        = string
  default     = "slack/signing/secret"
}

variable "jira_secret_name" {
  description = "Secrets Manager name for Jira credentials (JSON with baseUrl, email, apiToken)"
  type        = string
  default     = "jira/credentials"
}

variable "confluence_secret_name" {
  description = "Secrets Manager name for Confluence credentials (JSON with baseUrl, email, apiToken)"
  type        = string
  default     = "confluence/credentials"
}

variable "jira_schedule_expression" {
  description = "EventBridge schedule expression for Jira delta"
  type        = string
  default     = "rate(24 hours)"
}

variable "confluence_schedule_expression" {
  description = "EventBridge schedule expression for Confluence delta"
  type        = string
  default     = "rate(24 hours)"
}

variable "opensearch_collection_name" {
  description = "OpenSearch Serverless collection name"
  type        = string
  default     = "rag-collection"
}

variable "embed_model_id" {
  description = "Bedrock embedding model id"
  type        = string
  default     = "amazon.titan-embed-text-v2:0"
}

variable "llm_model_id" {
  description = "Bedrock LLM model id for generation"
  type        = string
  default     = "anthropic.claude-3-5-sonnet-20240620-v1:0"
}

variable "opensearch_index_name" {
  description = "OpenSearch index name to store hybrid docs"
  type        = string
  default     = "rag-unified"
}

variable "github_pat_secret_name" {
  description = "Secrets Manager name for GitHub Personal Access Token"
  type        = string
  default     = "github/pat"
} 