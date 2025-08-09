data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

locals {
  name_prefix = var.project_name
}

# -----------------------------
# S3 buckets (raw data, logs)
# -----------------------------
resource "aws_s3_bucket" "raw_bucket" {
  bucket = "${local.name_prefix}-raw-${data.aws_caller_identity.current.account_id}-${data.aws_region.current.name}"
}

resource "aws_s3_bucket" "logs_bucket" {
  bucket = "${local.name_prefix}-logs-${data.aws_caller_identity.current.account_id}-${data.aws_region.current.name}"
}

# -----------------------------
# DynamoDB tables
# -----------------------------
resource "aws_dynamodb_table" "cursors" {
  name         = "${local.name_prefix}-cursors"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "source"
  range_key    = "cursor_key"

  attribute {
    name = "source"
    type = "S"
  }

  attribute {
    name = "cursor_key"
    type = "S"
  }
}

resource "aws_dynamodb_table" "group_map" {
  name         = "${local.name_prefix}-group-map"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "user_id"

  attribute {
    name = "user_id"
    type = "S"
  }
}

# -----------------------------
# SQS (ingest / index worker)
# -----------------------------
resource "aws_sqs_queue" "dlq" {
  name = "${local.name_prefix}-dlq"
}

resource "aws_sqs_queue" "ingest_queue" {
  name                       = "${local.name_prefix}-ingest"
  visibility_timeout_seconds = 120
  redrive_policy             = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.dlq.arn,
    maxReceiveCount     = 5
  })
}

# -----------------------------
# OpenSearch Serverless (VECTOR)
# -----------------------------
resource "aws_opensearchserverless_collection" "vector" {
  name = var.opensearch_collection_name
  type = "VECTORSEARCH"
}

resource "aws_opensearchserverless_security_policy" "encryption" {
  name = "${local.name_prefix}-enc"
  type = "encryption"
  policy = jsonencode({
    Rules = [{
      ResourceType = "collection",
      Resource     = ["collection/${aws_opensearchserverless_collection.vector.name}"]
    }],
    AWSOwnedKey = true
  })
}

resource "aws_opensearchserverless_security_policy" "network" {
  name = "${local.name_prefix}-net"
  type = "network"
  policy = jsonencode({
    Rules = [{
      ResourceType = "collection",
      Resource     = ["collection/${aws_opensearchserverless_collection.vector.name}"]
    }],
    AllowFromPublic = true
  })
}

# -----------------------------
# IAM for Lambda
# -----------------------------
resource "aws_iam_role" "lambda_role" {
  name = "${local.name_prefix}-lambda-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [{
      Effect = "Allow",
      Principal = { Service = "lambda.amazonaws.com" },
      Action   = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_policy" "lambda_policy" {
  name   = "${local.name_prefix}-lambda-policy"
  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Effect = "Allow",
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ],
        Resource = "*"
      },
      {
        Effect = "Allow",
        Action = ["sqs:ReceiveMessage", "sqs:DeleteMessage", "sqs:GetQueueAttributes"],
        Resource = [aws_sqs_queue.ingest_queue.arn]
      },
      {
        Effect = "Allow",
        Action = ["sqs:SendMessage"],
        Resource = [aws_sqs_queue.ingest_queue.arn]
      },
      {
        Effect = "Allow",
        Action = ["secretsmanager:GetSecretValue"],
        Resource = "*"
      },
      {
        Effect = "Allow",
        Action = ["dynamodb:GetItem", "dynamodb:PutItem", "dynamodb:UpdateItem", "dynamodb:Query"],
        Resource = [aws_dynamodb_table.cursors.arn, aws_dynamodb_table.group_map.arn]
      },
      {
        Effect = "Allow",
        Action = ["s3:PutObject", "s3:GetObject", "s3:ListBucket"],
        Resource = [
          aws_s3_bucket.raw_bucket.arn,
          "${aws_s3_bucket.raw_bucket.arn}/*"
        ]
      },
      {
        Effect = "Allow",
        Action = ["bedrock:InvokeModel", "bedrock:InvokeModelWithResponseStream"],
        Resource = "*"
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "lambda_attach" {
  role       = aws_iam_role.lambda_role.name
  policy_arn = aws_iam_policy.lambda_policy.arn
}

# OpenSearch Serverless access policy granting the Lambda role data-plane access
resource "aws_opensearchserverless_access_policy" "data" {
  name = "${local.name_prefix}-aoss-access"
  type = "data"
  policy = jsonencode([
    {
      Rules = [
        {
          ResourceType = "index",
          Resource     = ["index/${aws_opensearchserverless_collection.vector.name}/*"],
          Permission   = ["aoss:ReadDocument", "aoss:WriteDocument", "aoss:CreateIndex", "aoss:UpdateIndex", "aoss:DescribeIndex"]
        },
        {
          ResourceType = "collection",
          Resource     = ["collection/${aws_opensearchserverless_collection.vector.name}"],
          Permission   = ["aoss:DescribeCollectionItems"]
        }
      ],
      Principal = [aws_iam_role.lambda_role.arn]
    }
  ])
}

# -----------------------------
# Lambda packages (archive_file)
# -----------------------------
data "archive_file" "github_webhook_zip" {
  type        = "zip"
  source_dir  = "${path.module}/lambdas/github_webhook"
  output_path = "${path.module}/lambdas/github_webhook.zip"
}

data "archive_file" "jira_delta_zip" {
  type        = "zip"
  source_dir  = "${path.module}/lambdas/jira_delta"
  output_path = "${path.module}/lambdas/jira_delta.zip"
}

data "archive_file" "conf_delta_zip" {
  type        = "zip"
  source_dir  = "${path.module}/lambdas/confluence_delta"
  output_path = "${path.module}/lambdas/confluence_delta.zip"
}

data "archive_file" "index_worker_zip" {
  type        = "zip"
  source_dir  = "${path.module}/lambdas/index_worker"
  output_path = "${path.module}/lambdas/index_worker.zip"
}

data "archive_file" "query_api_zip" {
  type        = "zip"
  source_dir  = "${path.module}/lambdas/query_api"
  output_path = "${path.module}/lambdas/query_api.zip"
}

data "archive_file" "slack_handler_zip" {
  type        = "zip"
  source_dir  = "${path.module}/lambdas/slack_handler"
  output_path = "${path.module}/lambdas/slack_handler.zip"
}

# -----------------------------
# Lambda functions
# -----------------------------
resource "aws_lambda_layer_version" "python_deps" {
  filename            = "${path.module}/layers/python_deps.zip"
  layer_name          = "${local.name_prefix}-python-deps"
  compatible_runtimes = ["python3.11"]
}

# Attach layer to functions
resource "aws_lambda_function" "github_webhook" {
  function_name = "${local.name_prefix}-github-webhook"
  role          = aws_iam_role.lambda_role.arn
  handler       = "handler.handler"
  runtime       = "python3.11"
  timeout       = 30
  filename      = data.archive_file.github_webhook_zip.output_path
  layers        = [aws_lambda_layer_version.python_deps.arn]
  environment {
    variables = {
      AOSS_COLLECTION_ENDPOINT = aws_opensearchserverless_collection.vector.collection_endpoint
      AOSS_INDEX_NAME          = var.opensearch_index_name
      SQS_INGEST_URL           = aws_sqs_queue.ingest_queue.url
      GITHUB_SECRET_NAME       = var.github_webhook_secret_name
      GITHUB_PAT_SECRET_NAME   = var.github_pat_secret_name
      RAW_BUCKET               = aws_s3_bucket.raw_bucket.bucket
    }
  }
}

resource "aws_lambda_function" "jira_delta" {
  function_name = "${local.name_prefix}-jira-delta"
  role          = aws_iam_role.lambda_role.arn
  handler       = "handler.handler"
  runtime       = "python3.11"
  timeout       = 60
  filename      = data.archive_file.jira_delta_zip.output_path
  layers        = [aws_lambda_layer_version.python_deps.arn]
  environment {
    variables = {
      JIRA_SECRET_NAME  = var.jira_secret_name
      CURSORS_TABLE     = aws_dynamodb_table.cursors.name
      SQS_INGEST_URL    = aws_sqs_queue.ingest_queue.url
      RAW_BUCKET        = aws_s3_bucket.raw_bucket.bucket
      AOSS_INDEX_NAME   = var.opensearch_index_name
    }
  }
}

resource "aws_lambda_function" "confluence_delta" {
  function_name = "${local.name_prefix}-confluence-delta"
  role          = aws_iam_role.lambda_role.arn
  handler       = "handler.handler"
  runtime       = "python3.11"
  timeout       = 60
  filename      = data.archive_file.conf_delta_zip.output_path
  layers        = [aws_lambda_layer_version.python_deps.arn]
  environment {
    variables = {
      CONFLUENCE_SECRET_NAME = var.confluence_secret_name
      CURSORS_TABLE          = aws_dynamodb_table.cursors.name
      SQS_INGEST_URL         = aws_sqs_queue.ingest_queue.url
      RAW_BUCKET             = aws_s3_bucket.raw_bucket.bucket
      AOSS_INDEX_NAME        = var.opensearch_index_name
    }
  }
}

resource "aws_lambda_function" "index_worker" {
  function_name = "${local.name_prefix}-index-worker"
  role          = aws_iam_role.lambda_role.arn
  handler       = "handler.handler"
  runtime       = "python3.11"
  timeout       = 120
  filename      = data.archive_file.index_worker_zip.output_path
  layers        = [aws_lambda_layer_version.python_deps.arn]
  environment {
    variables = {
      AOSS_COLLECTION_ENDPOINT = aws_opensearchserverless_collection.vector.collection_endpoint
      AOSS_INDEX_NAME          = var.opensearch_index_name
      EMBED_MODEL_ID           = var.embed_model_id
      RAW_BUCKET               = aws_s3_bucket.raw_bucket.bucket
    }
  }
}

resource "aws_lambda_event_source_mapping" "index_worker_sqs" {
  event_source_arn = aws_sqs_queue.ingest_queue.arn
  function_name    = aws_lambda_function.index_worker.arn
  batch_size       = 5
}

resource "aws_lambda_function" "query_api" {
  function_name = "${local.name_prefix}-query-api"
  role          = aws_iam_role.lambda_role.arn
  handler       = "handler.handler"
  runtime       = "python3.11"
  timeout       = 30
  filename      = data.archive_file.query_api_zip.output_path
  layers        = [aws_lambda_layer_version.python_deps.arn]
  environment {
    variables = {
      AOSS_COLLECTION_ENDPOINT = aws_opensearchserverless_collection.vector.collection_endpoint
      AOSS_INDEX_NAME          = var.opensearch_index_name
      LLM_MODEL_ID             = var.llm_model_id
    }
  }
}

resource "aws_lambda_function" "slack_handler" {
  function_name = "${local.name_prefix}-slack-handler"
  role          = aws_iam_role.lambda_role.arn
  handler       = "handler.handler"
  runtime       = "python3.11"
  timeout       = 15
  filename      = data.archive_file.slack_handler_zip.output_path
  layers        = [aws_lambda_layer_version.python_deps.arn]
  environment {
    variables = {
      SLACK_BOT_TOKEN_SECRET   = var.slack_bot_token_secret_name
      SLACK_SIGNING_SECRET     = var.slack_signing_secret_name
      AOSS_COLLECTION_ENDPOINT = aws_opensearchserverless_collection.vector.collection_endpoint
      AOSS_INDEX_NAME          = var.opensearch_index_name
      LLM_MODEL_ID             = var.llm_model_id
    }
  }
}

# Bootstrap index template via a one-off Lambda invoke
resource "aws_lambda_function" "index_bootstrap" {
  function_name = "${local.name_prefix}-index-bootstrap"
  role          = aws_iam_role.lambda_role.arn
  handler       = "handler.handler"
  runtime       = "python3.11"
  timeout       = 60
  filename      = data.archive_file.index_worker_zip.output_path
  layers        = [aws_lambda_layer_version.python_deps.arn]
  environment {
    variables = {
      AOSS_COLLECTION_ENDPOINT = aws_opensearchserverless_collection.vector.collection_endpoint
      AOSS_INDEX_NAME          = var.opensearch_index_name
    }
  }
}

resource "null_resource" "create_index" {
  triggers = {
    index_name   = var.opensearch_index_name
    collection   = aws_opensearchserverless_collection.vector.name
    code_hash    = data.archive_file.index_worker_zip.output_base64sha256
  }

  provisioner "local-exec" {
    command = "echo 'Bootstrap index with mapping via Lambda invoke is a TODO; run manually or extend handler.'"
  }
}

# -----------------------------
# API Gateway HTTP API
# -----------------------------
resource "aws_apigatewayv2_api" "rag_http_api" {
  name          = "${local.name_prefix}-api"
  protocol_type = "HTTP"
}

resource "aws_apigatewayv2_integration" "github_webhook" {
  api_id                 = aws_apigatewayv2_api.rag_http_api.id
  integration_type       = "AWS_PROXY"
  integration_uri        = aws_lambda_function.github_webhook.invoke_arn
  integration_method     = "POST"
  payload_format_version = "2.0"
}

resource "aws_apigatewayv2_route" "github_webhook" {
  api_id    = aws_apigatewayv2_api.rag_http_api.id
  route_key = "POST /github/webhook"
  target    = "integrations/${aws_apigatewayv2_integration.github_webhook.id}"
}

resource "aws_lambda_permission" "apigw_github" {
  statement_id  = "AllowAPIGwInvokeGithub"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.github_webhook.arn
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.rag_http_api.execution_arn}/*/*"
}

resource "aws_apigatewayv2_integration" "query_api" {
  api_id                 = aws_apigatewayv2_api.rag_http_api.id
  integration_type       = "AWS_PROXY"
  integration_uri        = aws_lambda_function.query_api.invoke_arn
  integration_method     = "POST"
  payload_format_version = "2.0"
}

resource "aws_apigatewayv2_route" "query_api" {
  api_id    = aws_apigatewayv2_api.rag_http_api.id
  route_key = "POST /query"
  target    = "integrations/${aws_apigatewayv2_integration.query_api.id}"
}

resource "aws_lambda_permission" "apigw_query" {
  statement_id  = "AllowAPIGwInvokeQuery"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.query_api.arn
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.rag_http_api.execution_arn}/*/*"
}

resource "aws_apigatewayv2_integration" "slack_handler" {
  api_id                 = aws_apigatewayv2_api.rag_http_api.id
  integration_type       = "AWS_PROXY"
  integration_uri        = aws_lambda_function.slack_handler.invoke_arn
  integration_method     = "POST"
  payload_format_version = "2.0"
}

resource "aws_apigatewayv2_route" "slack_handler" {
  api_id    = aws_apigatewayv2_api.rag_http_api.id
  route_key = "POST /slack/command"
  target    = "integrations/${aws_apigatewayv2_integration.slack_handler.id}"
}

resource "aws_lambda_permission" "apigw_slack" {
  statement_id  = "AllowAPIGwInvokeSlack"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.slack_handler.arn
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.rag_http_api.execution_arn}/*/*"
}

# -----------------------------
# EventBridge Schedules
# -----------------------------
resource "aws_cloudwatch_event_rule" "jira_schedule" {
  name                = "${local.name_prefix}-jira-schedule"
  schedule_expression = var.jira_schedule_expression
}

resource "aws_cloudwatch_event_target" "jira_schedule_target" {
  rule      = aws_cloudwatch_event_rule.jira_schedule.name
  target_id = "jira-delta"
  arn       = aws_lambda_function.jira_delta.arn
}

resource "aws_lambda_permission" "events_jira" {
  statement_id  = "AllowEventInvokeJira"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.jira_delta.arn
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.jira_schedule.arn
}

resource "aws_cloudwatch_event_rule" "conf_schedule" {
  name                = "${local.name_prefix}-conf-schedule"
  schedule_expression = var.confluence_schedule_expression
}

resource "aws_cloudwatch_event_target" "conf_schedule_target" {
  rule      = aws_cloudwatch_event_rule.conf_schedule.name
  target_id = "conf-delta"
  arn       = aws_lambda_function.confluence_delta.arn
}

resource "aws_lambda_permission" "events_conf" {
  statement_id  = "AllowEventInvokeConf"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.confluence_delta.arn
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.conf_schedule.arn
} 