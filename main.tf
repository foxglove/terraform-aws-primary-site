locals {
  # Consistently use lowercase prefix
  prefix = lower(var.prefix)

  # Merge user tags with mandatory tags
  tags = merge(var.tags, {
    TerraformManaged = "true"
    FoxgloveSite     = local.prefix
  })

  # Determine AZs based on user input count
  availability_zones = slice(data.aws_availability_zones.available.names, 0, var.vpc_availability_zones_count)

  # Use user-defined chart version or null (latest)
  primary_site_helm_chart_version = var.foxglove_helm_chart_version
}

# --- Provider Configuration (within module) ---
# These providers will be configured by the module user externally,
# but the Kubernetes and Helm providers need specific configuration
# based on the EKS cluster created within this module.

provider "aws" {
  # AWS provider configuration (region, credentials) is assumed to be
  # configured by the user calling this module.
  default_tags {
    tags = local.tags
  }
}

provider "kubernetes" {
  alias                  = "eks_cluster" # Alias to distinguish from potential external k8s provider
  host                   = module.eks.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)

  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    # This requires the aws CLI to be installed and configured in the environment running Terraform
    args = ["eks", "get-token", "--cluster-name", module.eks.cluster_name]
  }
}

provider "helm" {
  alias = "eks_cluster" # Alias to match the Kubernetes provider alias
  kubernetes {
    host                   = module.eks.cluster_endpoint
    cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)

    exec {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      # This requires the aws CLI to be installed and configured in the environment running Terraform
      args = ["eks", "get-token", "--cluster-name", module.eks.cluster_name]
    }
  }
}


# --- Base Infrastructure ---

## ----- Data Sources -----

data "aws_availability_zones" "available" {}

data "aws_region" "current" {}

## ----- VPC -----

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.0" # Use flexible versioning

  name = "${local.prefix}-vpc"
  cidr = var.vpc_cidr
  azs  = local.availability_zones

  # Define subnets dynamically based on AZ count
  private_subnets = [for i, az in local.availability_zones : cidrsubnet(var.vpc_cidr, 8, i + 1)]
  public_subnets  = [for i, az in local.availability_zones : cidrsubnet(var.vpc_cidr, 8, i + 101)]

  enable_dns_hostnames = true
  enable_dns_support   = true
  enable_nat_gateway   = true
  single_nat_gateway   = true
  enable_vpn_gateway   = false

  public_subnet_tags = {
    "kubernetes.io/cluster/${local.prefix}-cluster" = "shared"
    "kubernetes.io/role/elb"                        = "1" # Tag values should be strings
  }

  private_subnet_tags = {
    "kubernetes.io/cluster/${local.prefix}-cluster" = "shared"
    "kubernetes.io/role/internal-elb"               = "1" # Tag values should be strings
  }

  tags = local.tags
}

## ----- EKS cluster & instance security groups -----

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 19.0" # Use flexible versioning

  cluster_name    = "${local.prefix}-cluster"
  cluster_version = var.eks_cluster_version

  cluster_endpoint_private_access = true
  cluster_endpoint_public_access  = true # Required for Terraform Kubernetes/Helm providers initially

  cluster_addons = {
    kube-proxy = {}
    vpc-cni    = {}
    coredns    = {} # Add coredns explicitly
    aws-ebs-csi-driver = var.enable_monitoring ? {
      # We create the role separately for better control
      service_account_role_arn = module.ebs_csi_role[0].iam_role_arn
    } : {} # Ensure an empty object if monitoring disabled
  }

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  # Fargate profiles use the cluster primary security group, so these are not utilized
  # Let the module manage security groups for simplicity unless customized needs arise
  # create_cluster_security_group = false
  # create_node_security_group    = false

  eks_managed_node_group_defaults = {
    ami_type = "AL2_x86_64"
    # attach_cluster_primary_security_group = true # Let module handle defaults
    # create_security_group                 = false # Let module handle defaults
  }

  eks_managed_node_groups = {
    default = {
      # name uses cluster name prefix by default
      min_size     = var.eks_node_group_min_size
      max_size     = var.eks_node_group_max_size
      desired_size = var.eks_node_group_desired_size

      instance_types = var.eks_node_instance_types
      # subnet_ids uses cluster subnet_ids by default
      tags = merge(local.tags, { Name = "${local.prefix}-default-nodegroup" })
    }
  }

  # Fargate profile for core components (optional but good practice)
  fargate_profiles = {
    kube_system = {
      name = "kube-system"
      selectors = [
        { namespace = "kube-system" }
      ]
      subnet_ids = module.vpc.private_subnets # Run core components on private subnets
      tags       = merge(local.tags, { Name = "${local.prefix}-fargate-kube-system" })
    }
    foxglove = {
      # name = "foxglove" # uses key as name default
      selectors = [
        { namespace = kubernetes_namespace.foxglove.metadata[0].name }
      ]
      subnet_ids = module.vpc.private_subnets # Run Foxglove on private subnets
      tags       = merge(local.tags, { Name = "${local.prefix}-fargate-foxglove" })
    }
  }

  # Manage auth map to allow node group role access
  manage_aws_auth_configmap = true
  aws_auth_node_iam_role_arns_non_windows = [
    module.eks.managed_node_groups_roles["default"].arn
  ]

  tags = local.tags
}

# --- Application Specific Resources ---

## ----- S3 buckets -----

module "s3_lake" {
  source = "./modules/s3" # Updated path

  bucket_name = "${local.prefix}-lake-bucket"
  abort_incomplete_multipart_upload_days = var.abort_incomplete_multipart_upload_days
  tags = local.tags
}

module "s3_inbox" {
  source = "./modules/s3" # Updated path

  bucket_name = "${local.prefix}-inbox-bucket"
  abort_incomplete_multipart_upload_days = var.abort_incomplete_multipart_upload_days
  tags = local.tags
}

## ----- Pubsub -----

module "inbox_sns_notification" {
  source = "./modules/sns" # Updated path

  bucket_arn = module.s3_inbox.bucket_arn
  bucket_id  = module.s3_inbox.bucket_id
  topic_name = "${local.prefix}-inbox-bucket-sns-topic"

  inbox_notification_endpoint = var.inbox_notification_endpoint
  tags = local.tags
}

## ----- IAM policy & roles -----

module "iam" {
  source = "./modules/iam" # Updated path

  providers = {
    aws = aws # Pass default AWS provider
  }

  prefix                 = local.prefix
  lake_bucket_arn        = module.s3_lake.bucket_arn
  inbox_bucket_arn       = module.s3_inbox.bucket_arn
  eks_oidc_provider_arn  = module.eks.oidc_provider_arn
  eks_foxglove_namespace = kubernetes_namespace.foxglove.metadata[0].name
  tags                   = local.tags
}

## ----- Kubernetes Resources -----
# Note: Use the aliased provider for resources within the EKS cluster

resource "kubernetes_namespace" "foxglove" {
  provider = kubernetes.eks_cluster # Use aliased provider

  metadata {
    name = "foxglove"
  }

  # Ensure the namespace is created after the EKS cluster is ready
  depends_on = [
    module.eks
  ]
}

resource "kubernetes_secret" "site_token" {
  provider = kubernetes.eks_cluster # Use aliased provider

  metadata {
    name      = "foxglove-site-token"
    namespace = kubernetes_namespace.foxglove.metadata[0].name
  }

  data = {
    FOXGLOVE_SITE_TOKEN = var.site_token
  }

  type = "Opaque" # Specify secret type

  depends_on = [
    kubernetes_namespace.foxglove
  ]
}

## ----- AWS Load Balancer Controller Setup -----

# IAM Role for Service Account (IRSA) for AWS Load Balancer Controller
module "lb_role" {
  source = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  # No version needed as it's part of the main IAM module source structure

  providers = {
    aws = aws # Pass default AWS provider
  }

  role_name                              = "${local.prefix}-eks-lb-controller"
  attach_load_balancer_controller_policy = true

  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["kube-system:aws-load-balancer-controller"]
    }
  }
  tags = local.tags
}

# Service Account for AWS Load Balancer Controller
resource "kubernetes_service_account" "aws_load_balancer_controller" {
  provider = kubernetes.eks_cluster # Use aliased provider

  metadata {
    name      = "aws-load-balancer-controller"
    namespace = "kube-system"
    annotations = {
      "eks.amazonaws.com/role-arn" = module.lb_role.iam_role_arn
    }
    labels = { # Add labels for potential selection
      "app.kubernetes.io/name" = "aws-load-balancer-controller"
    }
  }

  automount_service_account_token = true # Explicitly set

  depends_on = [
    module.eks,
    module.lb_role # Ensure role exists before annotating SA
  ]
}

# RBAC for the wait job (namespaced)
resource "kubernetes_role" "lb_controller_waiter" {
  provider = kubernetes.eks_cluster # Use aliased provider

  metadata {
    name      = "lb-controller-waiter-role"
    namespace = "kube-system"
  }

  rule {
    api_groups = ["apps"]
    resources  = ["deployments"]
    verbs      = ["get", "list", "watch"]
  }
  rule {
    api_groups = [""]
    resources  = ["services", "endpoints"]
    verbs      = ["get"]
  }
}

resource "kubernetes_role_binding" "lb_controller_waiter_binding" {
  provider = kubernetes.eks_cluster # Use aliased provider

  metadata {
    name      = "lb-controller-waiter-binding"
    namespace = "kube-system"
  }
  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "Role"
    name      = kubernetes_role.lb_controller_waiter.metadata[0].name
  }
  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account.aws_load_balancer_controller.metadata[0].name
    namespace = "kube-system"
  }

  depends_on = [
    kubernetes_role.lb_controller_waiter,
    kubernetes_service_account.aws_load_balancer_controller
  ]
}

# RBAC for the wait job (cluster-scoped)
resource "kubernetes_cluster_role" "lb_controller_waiter_cluster" {
  provider = kubernetes.eks_cluster # Use aliased provider

  metadata {
    name = "lb-controller-waiter-clusterrole"
  }
  rule {
    api_groups = ["admissionregistration.k8s.io"]
    resources  = ["validatingwebhookconfigurations"]
    verbs      = ["get"]
  }
}

resource "kubernetes_cluster_role_binding" "lb_controller_waiter_cluster_binding" {
  provider = kubernetes.eks_cluster # Use aliased provider

  metadata {
    name = "lb-controller-waiter-clusterrolebinding"
  }
  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = kubernetes_cluster_role.lb_controller_waiter_cluster.metadata[0].name
  }
  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account.aws_load_balancer_controller.metadata[0].name
    namespace = "kube-system"
  }

  depends_on = [
    kubernetes_cluster_role.lb_controller_waiter_cluster,
    kubernetes_service_account.aws_load_balancer_controller
  ]
}

# Install AWS Load Balancer Controller via Helm
resource "helm_release" "aws_load_balancer_controller" {
  provider = helm.eks_cluster # Use aliased provider

  name       = "aws-load-balancer-controller"
  namespace  = "kube-system"
  repository = "https://aws.github.io/eks-charts"
  chart      = "aws-load-balancer-controller"
  version    = "1.6.1" # Pin chart version for stability

  set {
    name  = "clusterName"
    value = module.eks.cluster_name
  }
  set {
    name  = "serviceAccount.create"
    value = "false" # We created it above
  }
  set {
    name  = "serviceAccount.name"
    value = kubernetes_service_account.aws_load_balancer_controller.metadata[0].name
  }
  # Webhook settings already defaulted correctly in recent chart versions
  # set { name = "webhookTLS.enabled", value = "true" }

  # Tolerations for running on Fargate control plane nodes (if applicable)
  set {
    name  = "tolerations[0].key"
    value = "eks.amazonaws.com/compute-type"
  }
  set {
    name  = "tolerations[0].operator"
    value = "Equal"
  }
   set {
    name  = "tolerations[0].value"
    value = "fargate"
  }
   set {
    name  = "tolerations[0].effect"
    value = "NoSchedule"
  }

  depends_on = [
    module.eks,
    kubernetes_service_account.aws_load_balancer_controller # Ensure SA with Role ARN exists
  ]
}

# Wait for the AWS Load Balancer Controller to be ready
resource "kubernetes_job" "wait_for_lb_controller" {
  provider = kubernetes.eks_cluster # Use aliased provider

  metadata {
    generate_name = "wait-for-lb-controller-"
    namespace     = "kube-system"
  }

  spec {
    template {
      metadata {
        labels = { # Add labels for easier cleanup/identification
          "app.kubernetes.io/name" = "wait-for-lb-controller"
        }
      }
      spec {
        container {
          name    = "wait"
          image   = "bitnami/kubectl:1.29" # Pin kubectl version
          command = ["/bin/sh", "-c"]
          args = [<<-EOT
            echo "Waiting for AWS Load Balancer Controller deployment..."
            if ! kubectl wait --for=condition=available --timeout=180s deployment/aws-load-balancer-controller -n kube-system; then
              echo "Deployment not ready after 180s. Dumping logs and exiting."
              kubectl logs -n kube-system deploy/aws-load-balancer-controller --tail 50 || true # Get recent logs
              exit 1
            fi
            echo "Deployment ready."

            WEBHOOK_CONFIG_NAME="aws-load-balancer-webhook"
            WEBHOOK_SERVICE_NAME="aws-load-balancer-webhook-service"
            export WEBHOOK_CONFIG_NAME WEBHOOK_SERVICE_NAME # Export for subshell

            echo "Waiting for webhook configuration ($WEBHOOK_CONFIG_NAME)..."
            timeout 60s bash -c \
            'until kubectl get validatingwebhookconfigurations "$WEBHOOK_CONFIG_NAME" &> /dev/null; do echo -n .; sleep 5; done'
            if [ $? -ne 0 ]; then echo "Webhook configuration check timed out for $WEBHOOK_CONFIG_NAME"; exit 1; fi
            echo "Webhook configuration found."

            echo "Waiting for webhook service ($WEBHOOK_SERVICE_NAME)..."
            timeout 60s bash -c \
            'until kubectl get service -n kube-system "$WEBHOOK_SERVICE_NAME" &> /dev/null; do echo -n .; sleep 5; done'
            if [ $? -ne 0 ]; then echo "Webhook service check timed out for $WEBHOOK_SERVICE_NAME"; exit 1; fi
            echo "Webhook service found."

            echo "Waiting for webhook service endpoints ($WEBHOOK_SERVICE_NAME)..."
            timeout 60s bash -c \
            'until kubectl get endpoints -n kube-system "$WEBHOOK_SERVICE_NAME" -o json | jq -e ".subsets[].addresses | length > 0" &> /dev/null; do echo -n .; sleep 5; done'
            if [ $? -ne 0 ]; then echo "Webhook endpoints check timed out for $WEBHOOK_SERVICE_NAME"; exit 1; fi
            echo "Webhook endpoints ready."

            echo "AWS Load Balancer Controller appears ready."
          EOT
          ]
        }
        restart_policy       = "Never"
        service_account_name = kubernetes_service_account.aws_load_balancer_controller.metadata[0].name
        # Add tolerations if controller runs on Fargate
        tolerations {
          key      = "eks.amazonaws.com/compute-type"
          operator = "Equal"
          value    = "fargate"
          effect   = "NoSchedule"
        }
      }
    }
    backoff_limit = 3
    # Set a TTL for successful job history cleanup
    ttl_seconds_after_finished = 3600 # 1 hour
  }

  wait_for_completion = true

  depends_on = [
    helm_release.aws_load_balancer_controller,
    kubernetes_role_binding.lb_controller_waiter_binding,
    kubernetes_cluster_role_binding.lb_controller_waiter_cluster_binding
  ]
}

## ----- Install Foxglove Primary Site Helm Chart -----

resource "helm_release" "primary_site" {
  provider = helm.eks_cluster # Use aliased provider

  name      = "foxglove-primary-site"
  namespace = kubernetes_namespace.foxglove.metadata[0].name

  repository = "https://helm-charts.foxglove.dev"
  chart      = "primary-site"
  version    = local.primary_site_helm_chart_version # Use variable or latest

  create_namespace = false

  values = [
    yamlencode({
      globals = {
        # Configure storage based on module outputs
        lake = {
          storageProvider = "aws"
          bucketName      = module.s3_lake.bucket_id
        }
        inbox = {
          storageProvider = "aws"
          bucketName      = module.s3_inbox.bucket_id
        }
        aws = {
          region = data.aws_region.current.name
        }
      }
      # Configure service accounts to use IAM roles
      inboxListener = {
        deployment = {
          serviceAccount = {
            create      = true # Let chart create SA
            annotations = { "eks.amazonaws.com/role-arn" = module.iam.iam_inbox_listener_role_arn }
          }
          podAnnotations = var.enable_monitoring ? { "prometheus.io/scrape" = "true" } : {}
        }
      }
      streamService = {
        deployment = {
          serviceAccount = {
            create      = true
            annotations = { "eks.amazonaws.com/role-arn" = module.iam.iam_stream_service_role_arn }
          }
          podAnnotations = var.enable_monitoring ? { "prometheus.io/scrape" = "true" } : {}
        }
      }
      siteController = { # Typically doesn't need direct S3 access
        deployment = {
          podAnnotations = var.enable_monitoring ? { "prometheus.io/scrape" = "true" } : {}
        }
      }
      garbageCollector = {
        deployment = {
          serviceAccount = {
            create      = true
            annotations = { "eks.amazonaws.com/role-arn" = module.iam.iam_garbage_collector_role_arn }
          }
        }
      }
      # Configure Ingress using the dynamically created ACM certificate
      ingress = {
        enabled = true # Ensure ingress is enabled in the chart
        # Chart likely creates ingress named 'site' by default
        annotations = {
          "kubernetes.io/ingress.class"                = "alb"
          "alb.ingress.kubernetes.io/scheme"           = "internet-facing"
          "alb.ingress.kubernetes.io/target-type"      = "ip"
          "alb.ingress.kubernetes.io/backend-protocol" = "HTTP" # Assuming internal traffic is HTTP
          "alb.ingress.kubernetes.io/listen-ports"     = jsonencode([{ "HTTPS" = 443 }])
          "alb.ingress.kubernetes.io/certificate-arn"  = aws_acm_certificate_validation.main.certificate_arn # Use validated cert ARN
          # Add any other required annotations like WAF, etc.
        }
        # Hostname will be automatically configured by the ALB based on the Route53 record
        # Do not set hostname in the chart values if using external DNS like this module does
      }
    })
  ]

  # Wait for LB controller job and dependent K8s resources/IAM roles
  depends_on = [
    kubernetes_job.wait_for_lb_controller,
    kubernetes_namespace.foxglove,
    kubernetes_secret.site_token,
    module.iam,
    aws_acm_certificate_validation.main # Ensure cert is validated before Ingress uses it
  ]
}

## ----- Wait for ALB Hostname in Ingress Status -----

# RBAC for the ALB wait job (in foxglove namespace)
resource "kubernetes_role" "alb_waiter" {
  provider = kubernetes.eks_cluster # Use aliased provider

  metadata {
    name      = "alb-waiter-role"
    namespace = kubernetes_namespace.foxglove.metadata[0].name
  }
  rule {
    api_groups = ["networking.k8s.io"]
    resources  = ["ingresses"]
    verbs      = ["get"]
  }
}

resource "kubernetes_role_binding" "alb_waiter_binding" {
  provider = kubernetes.eks_cluster # Use aliased provider

  metadata {
    name      = "alb-waiter-binding"
    namespace = kubernetes_namespace.foxglove.metadata[0].name
  }
  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "Role"
    name      = kubernetes_role.alb_waiter.metadata[0].name
  }
  subject {
    kind      = "ServiceAccount"
    name      = "default" # Use default SA in foxglove namespace for simplicity
    namespace = kubernetes_namespace.foxglove.metadata[0].name
  }
  depends_on = [kubernetes_role.alb_waiter]
}

# Job to wait for the ALB hostname to appear in the Ingress status
resource "kubernetes_job" "wait_for_alb_hostname" {
  provider = kubernetes.eks_cluster # Use aliased provider

  metadata {
    generate_name = "wait-for-alb-hostname-"
    namespace     = kubernetes_namespace.foxglove.metadata[0].name
  }

  spec {
    template {
      metadata {
        labels = { # Add labels for easier cleanup/identification
          "app.kubernetes.io/name" = "wait-for-alb-hostname"
        }
      }
      spec {
        container {
          name    = "wait"
          image   = "bitnami/kubectl:1.29" # Pin kubectl version
          command = ["/bin/sh", "-c"]
          # Use the correct Ingress name 'site'
          args = [<<-EOT
            INGRESS_NAME="site" # Ingress name created by the helm chart
            NAMESPACE="${kubernetes_namespace.foxglove.metadata[0].name}"
            export INGRESS_NAME NAMESPACE # Export variables to subshell

            echo "Waiting up to 300s for Ingress $NAMESPACE/$INGRESS_NAME to have hostname..."
            timeout 300s bash -c \
            'until kubectl get ingress -n "$NAMESPACE" "$INGRESS_NAME" -o jsonpath="{.status.loadBalancer.ingress[0].hostname}" | grep . &> /dev/null; do echo -n .; sleep 10; done'

            # Check exit status of timeout command
            STATUS=$?
            if [ $STATUS -ne 0 ]; then
              echo "" # Newline after dots
              echo "ERROR: Ingress hostname check timed out or failed (status $STATUS) after 300s for $NAMESPACE/$INGRESS_NAME"
              echo "--- Ingress Description ---"
              kubectl describe ingress -n "$NAMESPACE" "$INGRESS_NAME" || echo "Failed to describe ingress."
              echo "--- ALB Controller Logs ---"
              kubectl logs -n kube-system deploy/aws-load-balancer-controller --tail 50 || echo "Failed to get ALB controller logs."
              exit 1
            fi
            echo "" # Newline after dots
            echo "Ingress hostname found."
          EOT
          ]
        }
        restart_policy       = "Never"
        service_account_name = "default" # Uses the SA bound by alb_waiter_binding
        # Add tolerations if foxglove service might run on Fargate
        tolerations {
          key      = "eks.amazonaws.com/compute-type"
          operator = "Equal"
          value    = "fargate"
          effect   = "NoSchedule"
        }
      }
    }
    backoff_limit = 3
    # Set a TTL for successful job history cleanup
    ttl_seconds_after_finished = 3600 # 1 hour
  }

  wait_for_completion = true

  depends_on = [
    helm_release.primary_site, # Ensure Helm release is done
    kubernetes_role_binding.alb_waiter_binding # Ensure permissions exist
  ]
}


## ----- Route 53 and ACM -----

# ACM Certificate for the application domain
resource "aws_acm_certificate" "main" {
  domain_name       = var.route53_zone_name # Primary domain name
  subject_alternative_names = ["*.${var.route53_zone_name}"] # Wildcard SAN
  validation_method = "DNS"

  lifecycle {
    create_before_destroy = true
  }

  tags = merge(local.tags, { Name = "${local.prefix}-certificate" })
}

# DNS Validation Records for ACM Certificate
resource "aws_route53_record" "acm_validation" {
  # Use DNS validation options from the ACM certificate resource
  for_each = {
    for dvo in aws_acm_certificate.main.domain_validation_options : dvo.domain_name => {
      name   = dvo.resource_record_name
      record = dvo.resource_record_value
      type   = dvo.resource_record_type
    }
  }

  allow_overwrite = true
  name            = each.value.name
  records         = [each.value.record]
  ttl             = 60
  type            = each.value.type
  zone_id         = var.route53_zone_id # Use the provided public hosted zone ID
}

# Resource to wait for ACM certificate validation to complete
resource "aws_acm_certificate_validation" "main" {
  certificate_arn         = aws_acm_certificate.main.arn
  validation_record_fqdns = [for record in aws_route53_record.acm_validation : record.fqdn]

  # Add timeouts if validation takes time
  timeouts {
    create = "45m"
  }
}

# Data source to fetch the ALB details (only after it's ready)
data "aws_lb" "ingress" {
  tags = {
    "elbv2.k8s.aws/cluster" = module.eks.cluster_name # Use cluster name from EKS module output
    "ingress.k8s.aws/stack" = "${kubernetes_namespace.foxglove.metadata[0].name}/site" # Correct stack tag
  }

  depends_on = [
    kubernetes_job.wait_for_alb_hostname # Ensure ALB is ready and reported by K8s job
  ]
}

# Route 53 Alias Record pointing the application subdomain to the ALB
resource "aws_route53_record" "app" {
  zone_id = var.route53_zone_id
  name    = local.prefix # Create record for prefix.zone_name (e.g., myprefix.example.com)
  type    = "A"

  alias {
    name                   = data.aws_lb.ingress.dns_name
    zone_id                = data.aws_lb.ingress.zone_id
    evaluate_target_health = true
  }

  # Depends on the data source successfully finding the ALB
  depends_on = [
    data.aws_lb.ingress
  ]
}


## ----- Monitoring Setup (Optional) -----

# IAM Role for EBS CSI Driver (only if monitoring is enabled)
module "ebs_csi_role" {
  count = var.enable_monitoring ? 1 : 0

  source = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"

  providers = {
    aws = aws # Pass default AWS provider
  }

  role_name             = "${local.prefix}-eks-ebs-csi"
  attach_ebs_csi_policy = true

  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      # Assumes default SA name used by the aws-ebs-csi-driver addon
      namespace_service_accounts = ["kube-system:ebs-csi-controller-sa"]
    }
  }
  tags = local.tags
}

# Cleanup potentially orphaned EBS CSI role (only if monitoring enabled)
resource "null_resource" "cleanup_ebs_csi_role" {
  count = var.enable_monitoring ? 1 : 0

  # This provisioner runs on destroy or if the role_name trigger changes
  provisioner "local-exec" {
    when    = destroy # Attempt cleanup only on destroy
    command = "aws iam detach-role-policy --role-name ${local.prefix}-eks-ebs-csi --policy-arn arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy --ignore-not-found || true && aws iam delete-role --role-name ${local.prefix}-eks-ebs-csi --ignore-not-found || true"
    interpreter = ["/bin/sh", "-c"]
  }

  # Use a trigger to ensure it's managed correctly
  triggers = {
    role_name = module.ebs_csi_role[0].iam_role_name
  }
}


# Kubernetes Namespace for Prometheus (only if monitoring enabled)
resource "kubernetes_namespace" "prometheus" {
  count = var.enable_monitoring ? 1 : 0

  provider = kubernetes.eks_cluster # Use aliased provider

  metadata {
    name = "prometheus"
  }
  depends_on = [module.eks]
}

# EBS Storage Class for Prometheus (only if monitoring enabled)
resource "kubernetes_storage_class" "ebs_sc" {
  count = var.enable_monitoring ? 1 : 0

  provider = kubernetes.eks_cluster # Use aliased provider

  metadata {
    name = "ebs-sc" # Standard name
    annotations = {
      # Mark as default storage class if desired
      # "storageclass.kubernetes.io/is-default-class" = "true"
    }
  }

  storage_provisioner = "ebs.csi.aws.com" # EBS CSI provisioner
  volume_binding_mode = "WaitForFirstConsumer"
  reclaim_policy      = "Delete"

  parameters = {
    type   = "gp3" # Use gp3 by default
    fsType = "ext4"
  }

  # Ensure EKS cluster and EBS CSI driver addon/role are ready
  depends_on = [
    module.eks,
    module.ebs_csi_role # Depends on the role being created
  ]
}

# Install Prometheus Helm chart (only if monitoring enabled)
resource "helm_release" "prometheus" {
  count = var.enable_monitoring ? 1 : 0

  provider = helm.eks_cluster # Use aliased provider

  name       = "${local.prefix}-prometheus"
  namespace  = kubernetes_namespace.prometheus[0].metadata[0].name
  repository = "https://prometheus-community.github.io/helm-charts"
  chart      = "prometheus"
  version    = "25.4.0" # Pin chart version

  values = [
    yamlencode({
      # Configure Prometheus server persistence using EBS
      server = {
        persistentVolume = {
          enabled      = true
          storageClass = kubernetes_storage_class.ebs_sc[0].metadata[0].name
          size         = "50Gi"
        }
        resources = {
          requests = { cpu = "500m", memory = "512Mi" }
          limits   = { cpu = "1000m", memory = "1Gi" }
        }
        # Tolerations for Fargate control plane nodes
        tolerations = [{
            key      = "eks.amazonaws.com/compute-type"
            operator = "Equal"
            value    = "fargate"
            effect   = "NoSchedule"
        }]
      }
      # Configure other components (alertmanager, node-exporter, etc.)
      alertmanager = {
        enabled = false # Disable by default for simplicity
      }
      kubeStateMetrics = { # Required for some metrics
        enabled = true
        tolerations = [{ # Add toleration
            key      = "eks.amazonaws.com/compute-type"
            operator = "Equal"
            value    = "fargate"
            effect   = "NoSchedule"
        }]
      }
      prometheus-node-exporter = { # Usually runs on worker nodes, disable if only Fargate
          enabled = false # Disable if only using Fargate profiles for workloads
          # tolerations = [] # Adjust if needed for mixed nodegroups/fargate
      }
      prometheus-pushgateway = {
          enabled = false # Disable by default
      }
    })
  ]

  depends_on = [
    kubernetes_namespace.prometheus,
    kubernetes_storage_class.ebs_sc,
    # Ensure LB controller is ready as Prometheus might scrape it
    kubernetes_job.wait_for_lb_controller
  ]
}

# Install Prometheus Adapter for HPA custom metrics (only if monitoring enabled)
resource "helm_release" "prometheus_adapter" {
  count = var.enable_monitoring ? 1 : 0

  provider = helm.eks_cluster # Use aliased provider

  name       = "${local.prefix}-prometheus-adapter"
  namespace  = kubernetes_namespace.prometheus[0].metadata[0].name
  repository = "https://prometheus-community.github.io/helm-charts"
  chart      = "prometheus-adapter"
  version    = "4.6.0" # Pin chart version

  values = [
    yamlencode({
      prometheus = {
        url  = "http://${helm_release.prometheus[0].name}-server.${kubernetes_namespace.prometheus[0].metadata[0].name}.svc"
        port = 80
      }
      # Tolerations for Fargate control plane nodes
      tolerations = [{
          key      = "eks.amazonaws.com/compute-type"
          operator = "Equal"
          value    = "fargate"
          effect   = "NoSchedule"
      }]
      # Add rules for custom metrics if needed for HPA
      # rules:
      #   default: false
      #   custom: [...]
    })
  ]

  depends_on = [
    kubernetes_namespace.prometheus,
    helm_release.prometheus
  ]
}


## ----- Horizontal Pod Autoscalers (Optional) -----

# HPA depends on Prometheus adapter being installed if enable_monitoring = true

resource "kubernetes_horizontal_pod_autoscaler_v2" "site_controller" {
  count = var.enable_monitoring ? 1 : 0 # Only create if monitoring is enabled

  provider = kubernetes.eks_cluster # Use aliased provider

  metadata {
    name      = "site-controller-hpa"
    namespace = kubernetes_namespace.foxglove.metadata[0].name
  }

  spec {
    scale_target_ref {
      api_version = "apps/v1"
      kind        = "Deployment"
      # Assumes deployment name follows <helm-release-name>-<chart-component> convention
      name = "${helm_release.primary_site.name}-site-controller"
    }

    min_replicas = 1
    max_replicas = 5

    metric {
      type = "Resource"
      resource {
        name = "cpu"
        target {
          type                = "Utilization"
          average_utilization = 80
        }
      }
    }
    # Add custom metrics if needed, e.g.:
    # metric {
    #   type = "Pods"
    #   pods {
    #     metric { name = "some_custom_metric" }
    #     target { type = "AverageValue", averageValue = "100" }
    #   }
    # }
  }

  depends_on = [
    helm_release.primary_site,
    helm_release.prometheus_adapter # HPA depends on metrics server
  ]
}

resource "kubernetes_horizontal_pod_autoscaler_v2" "stream_service" {
  count = var.enable_monitoring ? 1 : 0

  provider = kubernetes.eks_cluster # Use aliased provider

  metadata {
    name      = "stream-service-hpa"
    namespace = kubernetes_namespace.foxglove.metadata[0].name
  }

  spec {
    scale_target_ref {
      api_version = "apps/v1"
      kind        = "Deployment"
      name        = "${helm_release.primary_site.name}-stream-service"
    }

    min_replicas = 1
    max_replicas = 5

    metric {
      type = "Resource"
      resource {
        name = "cpu"
        target {
          type                = "Utilization"
          average_utilization = 80
        }
      }
    }
  }

  depends_on = [
    helm_release.primary_site,
    helm_release.prometheus_adapter
  ]
}

resource "kubernetes_horizontal_pod_autoscaler_v2" "inbox_listener" {
  count = var.enable_monitoring ? 1 : 0

  provider = kubernetes.eks_cluster # Use aliased provider

  metadata {
    name      = "inbox-listener-hpa"
    namespace = kubernetes_namespace.foxglove.metadata[0].name
  }

  spec {
    scale_target_ref {
      api_version = "apps/v1"
      kind        = "Deployment"
      name        = "${helm_release.primary_site.name}-inbox-listener"
    }

    min_replicas = 1
    max_replicas = 5

    metric {
      type = "Resource"
      resource {
        name = "cpu"
        target {
          type                = "Utilization"
          average_utilization = 80
        }
      }
    }
  }

  depends_on = [
    helm_release.primary_site,
    helm_release.prometheus_adapter
  ]
}
