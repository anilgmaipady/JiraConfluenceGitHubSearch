output "opensearch_collection_endpoint" {
  description = "OpenSearch Serverless collection endpoint"
  value       = aws_opensearchserverless_collection.vector.collection_endpoint
}

output "api_endpoint" {
  description = "HTTP API endpoint"
  value       = aws_apigatewayv2_api.rag_http_api.api_endpoint
}

output "sqs_ingest_queue_url" {
  description = "URL of the ingest SQS queue"
  value       = aws_sqs_queue.ingest_queue.url
}

output "raw_bucket_name" {
  value = aws_s3_bucket.raw_bucket.id
}

output "dynamodb_cursors_table" {
  value = aws_dynamodb_table.cursors.name
} 