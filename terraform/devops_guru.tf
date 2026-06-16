resource "aws_devops_guru_resource_collection" "techstream" {
  resource_collection_filter {
    cloud_formation = {
      stack_names = ["TechStream-Prod"]
    }
  }
}
