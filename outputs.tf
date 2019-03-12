output "load_balancer_arn" {
  value = "${aws_lb.loadbalancer.arn}"
}

output "target_group_arn" {
  value = "${aws_lb_target_group.target_group.arn}"
}
