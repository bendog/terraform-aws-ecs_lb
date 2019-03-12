
locals {
  deploy_name = "${var.project_name}-${var.environment}"
}

# Data

data "aws_s3_bucket" "log_bucket" {
  bucket = "${var.log_bucket}"
}

data "aws_security_groups" "loadbalancer_secuirty_groups" {
  filter {
    name   = "group-name"
    values = "${var.loadbalancer_security_groups}"
  }
  filter {
    name   = "vpc-id"
    values = ["${var.vpc_id}"]
  }
}

data "aws_subnet_ids" "public" {
  vpc_id = "${var.vpc_id}"
  tags {
    Tier = "Public"
  }
}

data "aws_acm_certificate" "domaincert" {
  domain   = "${var.certificate_domain}"
  statuses = ["ISSUED"]
  types = ["AMAZON_ISSUED"]
  most_recent = true
}

# Resources

resource "aws_lb_target_group" "target_group" {
  name     = "${local.deploy_name}-tg"
  port     = 80
  protocol = "HTTP"
  vpc_id   = "${var.vpc_id}"
  slow_start = 60
  deregistration_delay = 60
  target_type = "ip"

  health_check {
    path = "${var.healthCheckPath}"
    interval = 60
    timeout = 15
    matcher = "${var.healthCheckMatcher}"
  }

  tags {
    Environment = "${var.environment}"
    Project = "${var.project_name}"
  }
}

resource "aws_lb" "loadbalancer" {
  name               = "${local.deploy_name}-lb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = ["${data.aws_security_groups.loadbalancer_secuirty_groups.ids}"]
  subnets            = ["${data.aws_subnet_ids.public.ids}"]

  enable_deletion_protection = false

  # TODO: logs currently disabled as bucket doesn't like the LB
  //  access_logs {
  //    bucket  = "${data.aws_s3_bucket.log_bucket.bucket}"
  //    prefix  = "${local.deploy_name}-lb"
  //    enabled = true
  //  }

  tags {
    Environment = "${var.environment}"
    Project = "${var.project_name}"
  }
}

resource "aws_lb_listener" "lb_listener" {
  load_balancer_arn = "${aws_lb.loadbalancer.arn}"
  port              = "443"
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-2016-08"
  certificate_arn   = "${data.aws_acm_certificate.domaincert.arn}"

  default_action {
    type             = "forward"
    target_group_arn = "${aws_lb_target_group.target_group.arn}"
  }
}

resource "aws_lb_listener" "lb_listener_redirect" {
  load_balancer_arn = "${aws_lb.loadbalancer.arn}"
  port              = "80"
  protocol          = "HTTP"

//  default_action {
//    type             = "forward"
//    target_group_arn = "${aws_lb_target_group.target_group.arn}"
//  }

  default_action {
    type = "redirect"
    redirect {
      port = "443"
      protocol = "HTTPS"
      status_code = "HTTP_301"
    }
  }
}

resource "aws_route53_record" "dns_record" {
  name = "${var.subdomain}"
  type = "A"
  zone_id = "${var.r53zone}"

  alias {
    name                   = "${aws_lb.loadbalancer.dns_name}"
    zone_id                = "${aws_lb.loadbalancer.zone_id}"
    evaluate_target_health = true
  }

}

### AUTO SCALE ###

data aws_ecs_task_definition "task_def" {
  task_definition = "${local.deploy_name}"
}

data aws_iam_role "autoscale_role" {
  name = "${var.autoscale_role_name}"
}
data aws_iam_role "service_role" {
  name = "${var.service_role_name}"
}

data aws_ecs_cluster "cluster" {
  cluster_name = "${var.ecs_cluster_name}"
}

data "aws_security_groups" "ecs_secuirty_groups" {
  filter {
    name   = "group-name"
    values = ["default", "ausvet_staff", "EC2ContainerService-web-EcsSecurityGroup-12NGPX6VVYMQO"]
  }
  filter {
    name   = "vpc-id"
    values = ["${var.vpc_id}"]
  }
}

resource "aws_ecs_service" "service" {
  depends_on = ["aws_lb_target_group.target_group", "aws_lb.loadbalancer"]

  name          = "${local.deploy_name}"
  cluster       = "${data.aws_ecs_cluster.cluster.id}"
  desired_count = 1
  launch_type = "FARGATE"
  //  iam_role = "${data.aws_iam_role.service_role.arn}"  # TODO: this doesn't seem to be working.

  # Track the latest ACTIVE revision
  task_definition = "${local.deploy_name}:${data.aws_ecs_task_definition.task_def.revision}"

  network_configuration {
    security_groups   = ["${data.aws_security_groups.ecs_secuirty_groups.ids}"]
    subnets           = ["${data.aws_subnet_ids.public.ids}"]
    assign_public_ip  = true  # todo: this is required to pull from ECR repo and save to S3 logs
  }

  load_balancer {
    container_name = "${local.deploy_name}"
    container_port = "${var.ecs_container_port}"
    target_group_arn = "${aws_lb_target_group.target_group.arn}"
  }

  lifecycle {
    ignore_changes = ["desired_count"]
  }
}

resource "aws_appautoscaling_target" "target" {
  depends_on = ["aws_ecs_service.service"]
  lifecycle {
    ignore_changes = "role_arn"  # ignore this change as it's an alias
  }

  service_namespace  = "ecs"
  resource_id        = "service/${var.ecs_cluster_name}/${local.deploy_name}"
  scalable_dimension = "ecs:service:DesiredCount"
  role_arn           = "${data.aws_iam_role.autoscale_role.arn}"
  min_capacity       = "${var.ecs_min_capacity}"
  max_capacity       = "${var.ecs_max_capacity}"
}

resource "aws_appautoscaling_policy" "out" {
  depends_on = ["aws_appautoscaling_target.target"]

  name                    = "${local.deploy_name}_scale_out"
  service_namespace       = "ecs"
  resource_id             = "service/${var.ecs_cluster_name}/${local.deploy_name}"
  scalable_dimension      = "ecs:service:DesiredCount"

  step_scaling_policy_configuration {
    adjustment_type         = "ChangeInCapacity"
    cooldown                = 60
    metric_aggregation_type = "Maximum"

    step_adjustment {
      metric_interval_lower_bound = 0
      scaling_adjustment = 1
    }
  }
}

resource "aws_appautoscaling_policy" "in" {
  depends_on = ["aws_appautoscaling_target.target"]

  name                    = "${local.deploy_name}_scale_in"
  service_namespace       = "ecs"
  resource_id             = "service/${var.ecs_cluster_name}/${local.deploy_name}"
  scalable_dimension      = "ecs:service:DesiredCount"

  step_scaling_policy_configuration {
    adjustment_type         = "ChangeInCapacity"
    cooldown                = 60
    metric_aggregation_type = "Maximum"

    step_adjustment {
      metric_interval_upper_bound = 0
      scaling_adjustment = -1
    }
  }
}

/* metric used for auto scale */
resource "aws_cloudwatch_metric_alarm" "service_cpu_high" {
  alarm_name          = "${local.deploy_name}_cpu_utilization_high"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = "2"
  metric_name         = "CPUUtilization"
  namespace           = "AWS/ECS"
  period              = "60"  # seconds
  statistic           = "Maximum"
  threshold           = "85"

  dimensions {
    ClusterName = "${var.ecs_cluster_name}"
    ServiceName = "${local.deploy_name}"
  }

  alarm_actions = ["${aws_appautoscaling_policy.out.arn}"]
  ok_actions = ["${aws_appautoscaling_policy.in.arn}"]
}



### ALARM ###

data "aws_sns_topic" "alert" {
  name = "${var.sns_alert_name}"
}

resource "aws_cloudwatch_metric_alarm" "low_hosts" {
  alarm_name              = "${local.deploy_name}_low_hosts"
  comparison_operator     = "LessThanThreshold"
  evaluation_periods      = "1"
  metric_name             = "HealthyHostCount"
  namespace               = "AWS/ApplicationELB"
  period                  = "60"
  statistic               = "Minimum"
  threshold               = "${var.ecs_min_capacity}"
  alarm_description       = "Alert when running below minimum"
  treat_missing_data      = "breaching"

  dimensions {
    LoadBalancer = "${aws_lb.loadbalancer.arn_suffix}"
    TargetGroup = "${aws_lb_target_group.target_group.arn_suffix}"
  }

  alarm_actions = ["${data.aws_sns_topic.alert.arn}"]
}
