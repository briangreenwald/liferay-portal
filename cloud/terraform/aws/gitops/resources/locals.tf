locals {
	account_id=data.aws_caller_identity.current.account_id
	argocd_ecr_credentials_secret_name="argocd-ecr-credentials"
	argocd_git_credentials_secret_name="argocd-git-credentials"
	cluster_name="${var.deployment_name}-eks"
	common_labels={
		"app.kubernetes.io/component"="gitops-infrastructure"
		"app.kubernetes.io/managed-by"=local.terraform_manager_name
		"app.kubernetes.io/part-of"="liferay-gitops"
		"environment"="internal"
		"liferay.com/project"="liferay-cloud-native"
	}
	ecr_credentials_sync_image="alpine/k8s:1.29.1"
	ecr_credentials_sync_schedule="0 */8 * * *"
	ecr_credentials_sync_script=<<-EOT
		set -euo pipefail

		TOKEN=$(aws ecr get-login-password --region ${local.liferay_helm_chart_config.region})

		if [ -z "$TOKEN" ]; then
			echo "Failed to fetch ECR token"
			exit 1
		fi

		kubectl create secret generic argocd-ecr-credentials \
			--dry-run=client -o yaml \
			--from-literal=enableOCI=true \
			--from-literal=name=liferay-helm-chart \
			--from-literal=password="$TOKEN" \
			--from-literal=project=${local.liferay_appproject_name} \
			--from-literal=type=helm \
			--from-literal=url=${local.liferay_helm_chart_config.source_repourl_value} \
			--from-literal=username=AWS \
			--namespace ${var.argocd_namespace} | kubectl apply -f -

		kubectl label secret argocd-ecr-credentials argocd.argoproj.io/secret-type=repository \
			--namespace ${var.argocd_namespace} \
			--overwrite
	EOT
	ecr_credentials_sync_serviceaccount_name="ecr-credentials-sync-sa"
	infrastructure_appproject_name="liferay-infrastructure"
	liferay_appproject_name="liferay-application"
	liferay_helm_chart_config=merge(
		{
			version=var.liferay_helm_chart_version
		},
		var.liferay_helm_chart_name == "liferay-default" ? {
			ecr_credentials_sync_required=false
			name="liferay-default"
			region=var.region
			source_chart_value="liferay-default"
			source_repourl_value="oci://us-central1-docker.pkg.dev/liferay-artifact-registry/liferay-helm-chart/liferay-default"
			values_scope_prefix=""
		} : {},
		var.liferay_helm_chart_name == "liferay-aws" ? {
			ecr_credentials_sync_required=false
			name="liferay-aws"
			region=var.region
			source_chart_value="liferay-aws"
			source_repourl_value="oci://us-central1-docker.pkg.dev/liferay-artifact-registry/liferay-helm-chart/liferay-aws"
			values_scope_prefix="liferay-default."
		} : {},
		var.liferay_helm_chart_name == "liferay-aws-marketplace" ? {
			ecr_credentials_sync_required=true
			name="liferay-aws-marketplace"
			region="us-east-1"
			source_chart_value="liferay/liferay-aws-marketplace"
			source_repourl_value="709825985650.dkr.ecr.us-east-1.amazonaws.com"
			values_scope_prefix="liferay-aws.liferay-default."
		} : {},
	)
	liferay_infrastructure_helm_chart_config={
		source_chart_value="liferay-aws-environment-infrastructure"
		source_repourl_value="oci://us-central1-docker.pkg.dev/liferay-artifact-registry/liferay-helm-chart/liferay-aws-environment-infrastructure"
		version=var.liferay_infrastructure_helm_chart_version
	}
	liferay_infrastructure_provider_helm_chart_config={
		source_chart_value="liferay-aws-infrastructure-provider"
		source_repourl_value="oci://us-central1-docker.pkg.dev/liferay-artifact-registry/liferay-helm-chart/liferay-aws-infrastructure-provider"
		version=var.liferay_infrastructure_helm_chart_version
	}
	liferay_service_account_role_name="${var.deployment_name}-irsa"
	oidc_provider=replace(data.aws_eks_cluster.cluster.identity[0].oidc[0].issuer, "https://", "")
	opensearch_servicelinkedrole_exists = data.aws_iam_role.existing_opensearch_servicelinkedrole.arn != null ? true : false
	secret_store_name="argocd-git-credentials-vault"
	secret_store_provider=local.secret_store_provider_default_enabled ? {
		aws={
			auth={
				jwt={
					serviceAccountRef={
						name="argocd-git-repo-auth-sa"
						namespace=var.argocd_namespace
					}
				}
			}
			region=var.region
			service="SecretsManager"
		}
	} : var.git_repo_auth_config.secret_store_provider_hcl
	secret_store_provider_default_enabled=var.git_repo_auth_config.secret_store_provider_hcl == null
	terraform_manager_name="liferay-cloud-native-terraform"
	vpc_config=data.aws_eks_cluster.cluster.vpc_config[0]
}
