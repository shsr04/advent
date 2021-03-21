variable "grid" {
  type        = list(list(string))
  description = "Grid of '.' and '#' strings ('.' = empty, '#' = tree)"
}

variable "delta_x" {
  type        = number
  description = "Horizontal steps to make for each traversed line (may be less than 1)"
}

variable "delta_y" {
  type        = number
  description = "Lines to traverse in one vertical step"
  validation {
    condition     = var.delta_y >= 1 && ceil(var.delta_y) == var.delta_y
    error_message = "Must be a whole number and greater than 0."
  }
}

locals {
  steps     = [for y, line in var.grid : [(var.delta_x * y) % length(line), y, line[(var.delta_x * y) % length(line)] == "#" ? 1 : 0] if y % var.delta_y == 0]
  num_trees = sum([for triple in local.steps : triple[2]])
}

output "steps" {
  value = local.steps
}

output "num_trees" {
  value = local.num_trees
}