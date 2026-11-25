# Read by the pipeline (and scripts/render-config.sh) to configure the deploy.
output "region" { value = var.region }
output "cluster_name" { value = aws_eks_cluster.main.name }
output "table_name" { value = aws_dynamodb_table.meetings.name }
output "bucket_name" { value = aws_s3_bucket.audio.bucket }
output "queue_url" { value = aws_sqs_queue.jobs.url }
output "dlq_url" { value = aws_sqs_queue.dlq.url }
output "registry" { value = "${local.account_id}.dkr.ecr.${var.region}.amazonaws.com" }
output "ecr" { value = { for k, r in aws_ecr_repository.svc : k => r.repository_url } }
output "app_url" { value = "https://${local.fqdn}" }
