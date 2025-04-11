# Terraform AWS Foxglove Primary Site Module

This Terraform module deploys a complete Foxglove Primary Site environment on AWS.

It provisions the following core resources:

*   **VPC:** Creates a new VPC with public and private subnets across a configurable number of Availability Zones.
*   **EKS Cluster:** Deploys a managed EKS cluster with a default managed node group and Fargate profiles for `kube-system` and `foxglove` namespaces.
*   **S3 Buckets:** Creates dedicated S3 buckets for the Foxglove data lake and inbox.
*   **IAM Roles:** Configures necessary IAM roles for EKS service accounts (IRSA) to allow Foxglove services (inbox listener, stream service, garbage collector) access to S3.
*   **SNS/SQS:** Sets up an SNS topic and SQS dead-letter queue for S3 inbox notifications, subscribing the endpoint provided by Foxglove.
*   **ACM Certificate:** Provisions an ACM SSL certificate for your custom domain and validates it using DNS records in Route 53.
*   **Route 53 Record:** Creates a Route 53 Alias record pointing your chosen subdomain (based on the `prefix`) to the Application Load Balancer.
*   **AWS Load Balancer Controller:** Installs the AWS Load Balancer Controller using Helm, enabling the creation of an Application Load Balancer via Kubernetes Ingress.
*   **Foxglove Primary Site:** Deploys the Foxglove `primary-site` Helm chart into the `foxglove` namespace, configured to use the created S3 buckets, IAM roles, and ACM certificate.
*   **Wait Logic:** Includes robust wait logic using Kubernetes Jobs to ensure dependencies like the Load Balancer Controller and ALB are ready before dependent resources are created.
*   **(Optional) Monitoring:** Deploys Prometheus (using EBS storage via the EBS CSI Driver) and the Prometheus Adapter for metrics-based Horizontal Pod Autoscaling (HPA).
*   **(Optional) HPA:** Configures HPAs for Foxglove components based on CPU utilization if monitoring is enabled.

## Prerequisites

1.  **AWS Account & Credentials:** Configured AWS credentials with sufficient permissions to create the resources defined in this module.
2.  **Route 53 Public Hosted Zone:** An existing public hosted zone in Route 53 for the domain you intend to use. You will need its Zone ID and name.
3.  **Foxglove Account:** Access to your Foxglove organization settings to retrieve the `site_token` and `inbox_notification_endpoint`.
4.  **Terraform:** Terraform CLI (version >= 1.3.2) installed.
5.  **AWS CLI:** AWS CLI installed and configured (required for Kubernetes/Helm provider authentication).
6.  **kubectl:** Kubectl installed (useful for interacting with the cluster).
7.  **Helm:** Helm CLI installed (useful for interacting with releases).

## Usage

```terraform
# Example main.tf in your root configuration

terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
  # Configure S3 backend for state management (recommended)
  backend "s3" {
    bucket = "your-terraform-state-bucket-name" # Replace with your bucket name
    key    = "foxglove/primary-site/terraform.tfstate"
    region = "us-west-2" # Replace with your bucket region
    # encrypt = true # Optional: enable server-side encryption
    # dynamodb_table = "your-terraform-lock-table" # Optional: for state locking
  }
}

provider "aws" {
  region = "us-west-2" # Specify your desired AWS region
}

module "foxglove_site" {
  source = "./foxglove-aws-site" # Or use git source: "git::https://github.com/your-org/foxglove-aws-site.git?ref=v1.0.0"

  prefix = "myfg-prod" # Choose a unique prefix

  # Foxglove Settings
  site_token                  = var.foxglove_site_token                 # Store sensitive values securely (e.g., tfvars, Vault)
  inbox_notification_endpoint = var.foxglove_inbox_notification_endpoint # Store sensitive values securely

  # Domain Settings
  route53_zone_id   = "Z0123456789ABCDEFGHIJ" # Your Route 53 Hosted Zone ID
  route53_zone_name = "example.com"           # Your domain name

  # EKS Configuration (Optional - using defaults here)
  # eks_cluster_version         = "1.29"
  # eks_node_group_min_size     = 1
  # eks_node_group_max_size     = 3
  # eks_node_group_desired_size = 1
  # eks_node_instance_types     = ["t3.large"]

  # VPC Configuration (Optional - using defaults here)
  # vpc_cidr = "10.10.0.0/16"
  # vpc_availability_zones_count = 2

  # Optional Features
  enable_monitoring = true # Example: Enable Prometheus and HPAs
  # foxglove_helm_chart_version = "0.5.0" # Pin specific chart version

  tags = {
    Environment = "production"
    Project     = "foxglove-primary"
  }
}

# --- Example Outputs (Optional) ---
output "application_url" {
  description = "URL of the deployed Foxglove application"
  value       = module.foxglove_site.application_url
}

output "eks_cluster_name" {
  description = "Name of the EKS cluster"
  value       = module.foxglove_site.eks_cluster_name
}

output "configure_kubectl_command" {
  description = "Command to configure kubectl for the created cluster"
  value       = "aws eks update-kubeconfig --name ${module.foxglove_site.eks_cluster_name} --region ${provider.aws.region}"
}
```

<!-- BEGIN_TF_DOCS -->
## Requirements

| Name | Version |
|------|---------|
| <a name="requirement_terraform"></a> [terraform](#requirement\_terraform) | >= 1.3.2 |
| <a name="requirement_aws"></a> [aws](#requirement\_aws) | ~> 5.0 |
| <a name="requirement_helm"></a> [helm](#requirement\_helm) | ~> 2.9 |
| <a name="requirement_kubernetes"></a> [kubernetes](#requirement\_kubernetes) | ~> 2.20 |
| <a name="requirement_null"></a> [null](#requirement\_null) | ~> 3.2 |
| <a name="requirement_random"></a> [random](#requirement\_random) | ~> 3.0 |
| <a name="requirement_time"></a> [time](#requirement\_time) | ~> 0.9 |

## Providers

| Name | Version |
|------|---------|
| <a name="provider_aws"></a> [aws](#provider\_aws) | ~> 5.0 |
| <a name="provider_helm.eks_cluster"></a> [helm.eks\_cluster](#provider\_helm.eks\_cluster) | ~> 2.9 |
| <a name="provider_kubernetes.eks_cluster"></a> [kubernetes.eks\_cluster](#provider\_kubernetes.eks\_cluster) | ~> 2.20 |
| <a name="provider_null"></a> [null](#provider\_null) | ~> 3.2 |

## Modules

| Name | Source | Version |
|------|--------|---------|
| <a name="module_ebs_csi_role"></a> [ebs\_csi\_role](#module\_ebs\_csi\_role) | terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks | n/a |
| <a name="module_eks"></a> [eks](#module\_eks) | terraform-aws-modules/eks/aws | ~> 19.0 |
| <a name="module_iam"></a> [iam](#module\_iam) | ./modules/iam | n/a |
| <a name="module_inbox_sns_notification"></a> [inbox\_sns\_notification](#module\_inbox\_sns\_notification) | ./modules/sns | n/a |
| <a name="module_lb_role"></a> [lb\_role](#module\_lb\_role) | terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks | n/a |
| <a name="module_s3_inbox"></a> [s3\_inbox](#module\_s3\_inbox) | ./modules/s3 | n/a |
| <a name="module_s3_lake"></a> [s3\_lake](#module\_s3\_lake) | ./modules/s3 | n/a |
| <a name="module_vpc"></a> [vpc](#module\_vpc) | terraform-aws-modules/vpc/aws | ~> 5.0 |

## Resources

| Name | Type |
|------|------|
| [aws_acm_certificate.main](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/acm_certificate) | resource |
| [aws_acm_certificate_validation.main](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/acm_certificate_validation) | resource |
| [aws_route53_record.acm_validation](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/route53_record) | resource |
| [aws_route53_record.app](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/route53_record) | resource |
| [helm_release.aws_load_balancer_controller](https://registry.terraform.io/providers/hashicorp/helm/latest/docs/resources/release) | resource |
| [helm_release.primary_site](https://registry.terraform.io/providers/hashicorp/helm/latest/docs/resources/release) | resource |
| [helm_release.prometheus](https://registry.terraform.io/providers/hashicorp/helm/latest/docs/resources/release) | resource |
| [helm_release.prometheus_adapter](https://registry.terraform.io/providers/hashicorp/helm/latest/docs/resources/release) | resource |
| [kubernetes_cluster_role.lb_controller_waiter_cluster](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/cluster_role) | resource |
| [kubernetes_cluster_role_binding.lb_controller_waiter_cluster_binding](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/cluster_role_binding) | resource |
| [kubernetes_horizontal_pod_autoscaler_v2.inbox_listener](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/horizontal_pod_autoscaler_v2) | resource |
| [kubernetes_horizontal_pod_autoscaler_v2.site_controller](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/horizontal_pod_autoscaler_v2) | resource |
| [kubernetes_horizontal_pod_autoscaler_v2.stream_service](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/horizontal_pod_autoscaler_v2) | resource |
| [kubernetes_job.wait_for_alb_hostname](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/job) | resource |
| [kubernetes_job.wait_for_lb_controller](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/job) | resource |
| [kubernetes_namespace.foxglove](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/namespace) | resource |
| [kubernetes_namespace.prometheus](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/namespace) | resource |
| [kubernetes_role.alb_waiter](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/role) | resource |
| [kubernetes_role.lb_controller_waiter](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/role) | resource |
| [kubernetes_role_binding.alb_waiter_binding](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/role_binding) | resource |
| [kubernetes_role_binding.lb_controller_waiter_binding](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/role_binding) | resource |
| [kubernetes_secret.site_token](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/secret) | resource |
| [kubernetes_service_account.aws_load_balancer_controller](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/service_account) | resource |
| [kubernetes_storage_class.ebs_sc](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/storage_class) | resource |
| [null_resource.cleanup_ebs_csi_role](https://registry.terraform.io/providers/hashicorp/null/latest/docs/resources/resource) | resource |
| [aws_availability_zones.available](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/availability_zones) | data source |
| [aws_lb.ingress](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/lb) | data source |
| [aws_region.current](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/region) | data source |

## Inputs

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|:--------:|
| <a name="input_abort_incomplete_multipart_upload_days"></a> [abort\_incomplete\_multipart\_upload\_days](#input\_abort\_incomplete\_multipart\_upload\_days) | Number of days after which incomplete multipart uploads to S3 buckets will be aborted. | `number` | `5` | no |
| <a name="input_eks_cluster_version"></a> [eks\_cluster\_version](#input\_eks\_cluster\_version) | Desired Kubernetes version for the EKS cluster. | `string` | `"1.29"` | no |
| <a name="input_eks_node_group_desired_size"></a> [eks\_node\_group\_desired\_size](#input\_eks\_node\_group\_desired\_size) | Desired number of nodes in the default EKS managed node group. | `number` | `1` | no |
| <a name="input_eks_node_group_max_size"></a> [eks\_node\_group\_max\_size](#input\_eks\_node\_group\_max\_size) | Maximum number of nodes in the default EKS managed node group. | `number` | `5` | no |
| <a name="input_eks_node_group_min_size"></a> [eks\_node\_group\_min\_size](#input\_eks\_node\_group\_min\_size) | Minimum number of nodes in the default EKS managed node group. | `number` | `0` | no |
| <a name="input_eks_node_instance_types"></a> [eks\_node\_instance\_types](#input\_eks\_node\_instance\_types) | List of EC2 instance types for the default EKS managed node group. | `list(string)` | <pre>[<br/>  "t3.medium"<br/>]</pre> | no |
| <a name="input_enable_monitoring"></a> [enable\_monitoring](#input\_enable\_monitoring) | Set to true to deploy Prometheus and related monitoring components (requires EBS CSI driver). | `bool` | `false` | no |
| <a name="input_foxglove_helm_chart_version"></a> [foxglove\_helm\_chart\_version](#input\_foxglove\_helm\_chart\_version) | Version of the Foxglove 'primary-site' Helm chart to deploy. | `string` | `null` | no |
| <a name="input_inbox_notification_endpoint"></a> [inbox\_notification\_endpoint](#input\_inbox\_notification\_endpoint) | The HTTPS endpoint obtained from your Foxglove Site settings for inbox notifications. | `string` | n/a | yes |
| <a name="input_prefix"></a> [prefix](#input\_prefix) | A unique prefix used for naming AWS resources (e.g., 'myorg-prod'). | `string` | n/a | yes |
| <a name="input_route53_zone_id"></a> [route53\_zone\_id](#input\_route53\_zone\_id) | The ID of the public Route53 hosted zone where the application DNS record will be created. | `string` | n/a | yes |
| <a name="input_route53_zone_name"></a> [route53\_zone\_name](#input\_route53\_zone\_name) | The name of the public Route53 hosted zone (e.g., 'example.com'). | `string` | n/a | yes |
| <a name="input_site_token"></a> [site\_token](#input\_site\_token) | The Site Token obtained from your Foxglove Site settings. Required for API authentication. | `string` | n/a | yes |
| <a name="input_tags"></a> [tags](#input\_tags) | A map of additional tags to apply to created resources. | `map(string)` | `{}` | no |
| <a name="input_vpc_availability_zones_count"></a> [vpc\_availability\_zones\_count](#input\_vpc\_availability\_zones\_count) | Number of Availability Zones to use for the VPC and EKS subnets (max 3 recommended). | `number` | `3` | no |
| <a name="input_vpc_cidr"></a> [vpc\_cidr](#input\_vpc\_cidr) | The CIDR block for the VPC. | `string` | `"10.0.0.0/16"` | no |

## Outputs

| Name | Description |
|------|-------------|
| <a name="output_application_url"></a> [application\_url](#output\_application\_url) | The URL where the Foxglove Primary Site application is accessible. |
| <a name="output_eks_cluster_certificate_authority_data"></a> [eks\_cluster\_certificate\_authority\_data](#output\_eks\_cluster\_certificate\_authority\_data) | Base64 encoded certificate data required to communicate with the cluster. |
| <a name="output_eks_cluster_endpoint"></a> [eks\_cluster\_endpoint](#output\_eks\_cluster\_endpoint) | The endpoint for the created EKS cluster's Kubernetes API server. |
| <a name="output_eks_cluster_name"></a> [eks\_cluster\_name](#output\_eks\_cluster\_name) | The name of the created EKS cluster. |
| <a name="output_eks_oidc_provider_arn"></a> [eks\_oidc\_provider\_arn](#output\_eks\_oidc\_provider\_arn) | The ARN of the EKS cluster OpenID Connect provider. |
| <a name="output_inbox_bucket_name"></a> [inbox\_bucket\_name](#output\_inbox\_bucket\_name) | The name of the S3 bucket created for the inbox. |
| <a name="output_lake_bucket_name"></a> [lake\_bucket\_name](#output\_lake\_bucket\_name) | The name of the S3 bucket created for the data lake. |
| <a name="output_vpc_id"></a> [vpc\_id](#output\_vpc\_id) | The ID of the VPC created for the deployment. |
<!-- END_TF_DOCS -->

## Development

To update the Inputs/Outputs tables in this README after making changes, run:

```bash
terraform-docs markdown table --output-file README.md --output-mode inject ./
```
(Requires [terraform-docs](https://terraform-docs.io/)) 