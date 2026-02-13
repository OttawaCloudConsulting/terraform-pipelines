# -----------------------------------------------------------------------------
# CodeStar Connection (conditional)
# Created when codestar_connection_arn is not provided.
# New connections require one-time manual OAuth authorization in AWS Console.
# -----------------------------------------------------------------------------

resource "aws_codestarconnections_connection" "github" {
  count         = var.codestar_connection_arn == "" ? 1 : 0
  name          = "${var.project_name}-github"
  provider_type = "GitHub"
  tags          = local.all_tags
}
