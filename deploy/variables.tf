variable "aws_region" {
  type    = string
  default = "eu-west-1"
}
variable "VAULT_HOST" {
  type    = string
  default = "https://vault.ixsa.net"
}
variable "K8S_CONFIG" {
  type    = string
  default = "~/.kube/k8s-deployer.yaml"
}
variable "image_tag" {
  type = string
}
