output "vpc_east_id" { value = aws_vpc.east.id }
output "vpc_west_id" { value = aws_vpc.west.id }

output "east_host_public_ip"  { value = aws_instance.east.public_ip }
output "east_host_private_ip" { value = aws_instance.east.private_ip }
output "west_host_public_ip"  { value = aws_instance.west.public_ip }
output "west_host_private_ip" { value = aws_instance.west.private_ip }

output "core_network_arn" { value = aws_networkmanager_core_network.this.arn }
output "core_network_id"  { value = aws_networkmanager_core_network.this.id }

output "ssh_to_east" {
  value = "ssh -i ~/.ssh/aws_cloudwan_lab ec2-user@${aws_instance.east.public_ip}"
}
output "ssh_to_west" {
  value = "ssh -i ~/.ssh/aws_cloudwan_lab ec2-user@${aws_instance.west.public_ip}"
}

output "test_ping_east_to_west" {
  value = "from east host: ping -c 3 ${aws_instance.west.private_ip}"
}
output "test_ping_west_to_east" {
  value = "from west host: ping -c 3 ${aws_instance.east.private_ip}"
}
