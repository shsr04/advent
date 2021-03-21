variable "expression" {
  type        = string
  description = "Terraform expression to evaluate"
}

resource "null_resource" "eval" {
  triggers = {
    x = var.expression
  }
  provisioner "local-exec" {
    command = "echo \"${var.expression}\" | terraform console > ${path.module}/result.txt"
  }
}

data "local_file" "result" {
  depends_on = [null_resource.eval]
  filename   = "${path.module}/result.txt"
}

output "result" {
  value = trimspace(data.local_file.result.content)
}