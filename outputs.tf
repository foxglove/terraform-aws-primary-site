output "application_url" {
  description = "The URL where the Foxglove Primary Site application is accessible."
  value       = "https://${aws_route53_record.app.fqdn}"
}

output "lake_bucket_name" {
  description = "The name of the S3 bucket created for the data lake."
  value       = module.s3_lake.bucket_name
}

output "inbox_bucket_name" {
  description = "The name of the S3 bucket created for the inbox."
  value       = module.s3_inbox.bucket_name
}

output "eks_cluster_name" {
  description = "The name of the created EKS cluster."
  value       = module.eks.cluster_name
}

output "eks_cluster_endpoint" {
  description = "The endpoint for the created EKS cluster's Kubernetes API server."
  value       = module.eks.cluster_endpoint
}

output "eks_cluster_certificate_authority_data" {
  description = "Base64 encoded certificate data required to communicate with the cluster."
  value       = module.eks.cluster_certificate_authority_data
}

output "eks_oidc_provider_arn" {
  description = "The ARN of the EKS cluster OpenID Connect provider."
  value       = module.eks.oidc_provider_arn
}

output "vpc_id" {
  description = "The ID of the VPC created for the deployment."
  value       = module.vpc.vpc_id
} 