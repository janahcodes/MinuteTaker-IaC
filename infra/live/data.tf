# Managed data services, same design as Project 2, now part of the environment
# that is torn down and rebuilt (nothing here blocks a destroy).

resource "aws_dynamodb_table" "meetings" {
  name                        = "${local.name}-meetings"
  billing_mode                = "PAY_PER_REQUEST" # no capacity planning, ~$0 at class scale
  hash_key                    = "id"
  deletion_protection_enabled = false # the environment must be destroyable

  attribute {
    name = "id"
    type = "S"
  }

  point_in_time_recovery { enabled = true }
  server_side_encryption { enabled = true }
}

resource "aws_s3_bucket" "audio" {
  bucket        = "${local.name}-audio-${local.account_id}" # S3 names are global
  force_destroy = true                                      # teardown empties it first
}

resource "aws_s3_bucket_public_access_block" "audio" {
  bucket                  = aws_s3_bucket.audio.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "audio" {
  bucket = aws_s3_bucket.audio.id
  rule {
    apply_server_side_encryption_by_default { sse_algorithm = "AES256" }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "audio" {
  bucket = aws_s3_bucket.audio.id
  rule {
    id     = "expire-recordings"
    status = "Enabled"
    filter { prefix = "uploads/" }
    expiration { days = 30 }
    abort_incomplete_multipart_upload { days_after_initiation = 1 }
  }
}

resource "aws_sqs_queue" "dlq" {
  name                      = "${local.name}-jobs-dlq"
  message_retention_seconds = 1209600 # 14 days to inspect poison messages
  sqs_managed_sse_enabled   = true
}

resource "aws_sqs_queue" "jobs" {
  name                       = "${local.name}-jobs"
  visibility_timeout_seconds = 120 # worker heartbeat extends this while busy
  receive_wait_time_seconds  = 20  # long polling
  sqs_managed_sse_enabled    = true
  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.dlq.arn
    maxReceiveCount     = 5
  })
}

# ---------------------------------------------------------------- registry
resource "aws_ecr_repository" "svc" {
  for_each             = toset(["api", "worker", "web"])
  name                 = "${local.name}-${each.key}"
  image_tag_mutability = "IMMUTABLE" # a tag (= git commit) always means the same image
  force_delete         = true
  image_scanning_configuration { scan_on_push = true }
}

resource "aws_ecr_lifecycle_policy" "svc" {
  for_each   = aws_ecr_repository.svc
  repository = each.value.name
  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "keep last 10 images"
      selection    = { tagStatus = "any", countType = "imageCountMoreThan", countNumber = 10 }
      action       = { type = "expire" }
    }]
  })
}
