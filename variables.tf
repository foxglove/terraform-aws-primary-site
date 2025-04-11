variable "prefix" {
  description = "A unique prefix used for naming AWS resources (e.g., 'myorg-prod')."
  type        = string
  validation {
    condition     = can(regex("^[a-z0-9-]+$", var.prefix))
    error_message = "Prefix must contain only lowercase letters, numbers, and hyphens."
  }
}

variable "site_token" {
  description = "The Site Token obtained from your Foxglove Site settings. Required for API authentication."
  type        = string
  sensitive   = true
}

variable "inbox_notification_endpoint" {
  description = "The HTTPS endpoint obtained from your Foxglove Site settings for inbox notifications."
  type        = string
  sensitive   = true
}

variable "abort_incomplete_multipart_upload_days" {
  description = "Number of days after which incomplete multipart uploads to S3 buckets will be aborted."
  type        = number
  default     = 5
}

variable "route53_zone_id" {
  description = "The ID of the public Route53 hosted zone where the application DNS record will be created."
  type        = string
}

variable "route53_zone_name" {
  description = "The name of the public Route53 hosted zone (e.g., 'example.com')."
  type        = string
}

# --- EKS Configuration ---

variable "eks_cluster_version" {
  description = "Desired Kubernetes version for the EKS cluster."
  type        = string
  default     = "1.29"
}

variable "eks_node_group_min_size" {
  description = "Minimum number of nodes in the default EKS managed node group."
  type        = number
  default     = 0
}

variable "eks_node_group_max_size" {
  description = "Maximum number of nodes in the default EKS managed node group."
  type        = number
  default     = 5
}

variable "eks_node_group_desired_size" {
  description = "Desired number of nodes in the default EKS managed node group."
  type        = number
  default     = 1
}

variable "eks_node_instance_types" {
  description = "List of EC2 instance types for the default EKS managed node group."
  type        = list(string)
  default     = ["t3.medium"]
}

# --- VPC Configuration ---

variable "vpc_cidr" {
  description = "The CIDR block for the VPC."
  type        = string
  default     = "10.0.0.0/16"
}

variable "vpc_availability_zones_count" {
  description = "Number of Availability Zones to use for the VPC and EKS subnets (max 3 recommended)."
  type        = number
  default     = 3
  validation {
    condition     = var.vpc_availability_zones_count > 0 && var.vpc_availability_zones_count <= 3
    error_message = "Availability zone count must be between 1 and 3."
  }
}

# --- Optional Features ---

variable "enable_monitoring" {
  description = "Set to true to deploy Prometheus and related monitoring components (requires EBS CSI driver)."
  type        = bool
  default     = false
}

variable "foxglove_helm_chart_version" {
  description = "Version of the Foxglove 'primary-site' Helm chart to deploy."
  type        = string
  default     = null # Defaults to latest if null
}

variable "tags" {
  description = "A map of additional tags to apply to created resources."
  type        = map(string)
  default     = {}
} 