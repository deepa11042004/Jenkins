output "state_bucket_name" {
  description = "Put this in the TF_STATE_BUCKET GitHub secret"
  value       = aws_s3_bucket.tfstate.id
}

output "state_lock_table" {
  description = "Put this in the TF_STATE_DYNAMODB_TABLE GitHub secret"
  value       = aws_dynamodb_table.tflock.name
}
