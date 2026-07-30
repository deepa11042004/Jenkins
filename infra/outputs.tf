output "instance_id" {
  description = "EC2 instance ID (use with SSM Session Manager)"
  value       = aws_instance.jenkins.id
}

output "jenkins_public_ip" {
  description = "Static public IP of the Jenkins server"
  value       = aws_eip.jenkins.public_ip
}

output "jenkins_url" {
  description = "Jenkins web UI URL"
  value       = "http://${aws_eip.jenkins.public_ip}:8080"
}

output "ssm_connect_command" {
  description = "Run this locally (with AWS CLI configured) to get a shell on the instance"
  value       = "aws ssm start-session --target ${aws_instance.jenkins.id} --region ${var.aws_region}"
}
