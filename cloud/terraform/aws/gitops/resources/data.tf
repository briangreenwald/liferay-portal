data "aws_caller_identity" "current" {
}
data "aws_eks_cluster" "cluster" {
	name=local.cluster_name
	region=var.region
}
data "aws_iam_role" "existing_opensearch_servicelinkedrole" {
  name = "AWSServiceRoleForAmazonOpenSearchService"
}
data "aws_subnets" "private" {
	filter {
		name="tag:kubernetes.io/role/internal-elb"
		values=["1"]
	}
	filter {
		name="vpc-id"
		values=[data.aws_vpc.current.id]
	}
}
data "aws_vpc" "current" {
	id=local.vpc_config.vpc_id
}