# Variables

variable "vpc_id" {
  description = "the VPC id for the load balancer"
}

variable "loadbalancer_security_groups" {
    type = "list"
    default = ["default"]
    description = "Names of security groups for the load balancer"
}


variable "project_name" {
  description = "name for the new load balancer"
}

variable "environment" {
  description = "production / testing / dev"
}

variable "subdomain" {
  description = "subdomain name for the load balancer"
}

variable "certificate_domain" {
  description = "domain name for the certificate"
}

variable "r53zone" {
  description = "id for R53 zone"
}

variable "log_bucket" {
  description = "Bucket for logging to"
}

variable healthCheckPath {
  type = "string"
  default = "/"
}

variable healthCheckMatcher {
  type = "string"
  default = "200,202"
}


variable sns_alert_name {
  type = "string"
}

### AUTO SCALE ###

variable "ecs_cluster_name" {
  type = "string"
  description = "Name of the ECS cluster to deploy to"
}

variable "ecs_min_capacity" {
  type = "string"
  description = "minimum number of tasks"
  default = "1"
}
variable "ecs_max_capacity" {
  type = "string"
  description = "maximum number of tasks"
  default = "8"
}
variable "ecs_container_port" {
  type = "string"
  description = "port the service runs on"
  default = "80"
}


variable "service_role_name" {
  default = "AWSServiceRoleForECS"
}


variable "autoscale_role_name" {
  default = "ecsAutoscaleRole"
}
