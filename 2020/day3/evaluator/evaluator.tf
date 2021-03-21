variable "expression" {
  type        = string
  description = "Terraform expression to evaluate"
}

locals {
  file_suffix = sha256(timestamp())
  result = trimspace(data.local_file.result.content)
}

resource "null_resource" "eval" {
  triggers = {
    x = var.expression
    y = local.file_suffix
  }
  provisioner "local-exec" {
    command = "echo \"${var.expression}\" | terraform console > ${path.module}/result.${local.file_suffix}.txt"
  }
}

data "local_file" "result" {
  depends_on = [null_resource.eval]
  filename   = "${path.module}/result.${local.file_suffix}.txt"
}

resource "null_resource" "cleanup" {
  depends_on = [data.local_file.result]
  triggers = {
    x = var.expression
    y = local.file_suffix
  }

  provisioner "local-exec" {
    command = "rm ${path.module}/result.${local.file_suffix}.txt"
  }
}

output "result" {
  value = local.result
}