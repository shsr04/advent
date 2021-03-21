data "local_file" "input" {
  filename = "${path.module}/day3_input"
}

locals {
  grid = [for line in split("\n", data.local_file.input.content) : split("", line)]
  // part 1
  step_vector = [for y, line in local.grid : [(3 * y) % length(line), y, line[(3 * y) % length(line)] == "#" ? 1 : 0]]
  sum_trees   = sum([for triple in local.step_vector : triple[2]])
  // part 2
  slopes = [{
    dx = 1,
    dy = 1
    },
    {
      dx = 3,
      dy = 1
    },
    {
      dx = 5,
      dy = 1
    },
    {
      dx = 7,
      dy = 1
    },
    {
      dx = 0.5,
      dy = 2
    },
  ]
  sum_trees_for_slopes = [for i, _ in local.slopes : module.tree_finder[i].num_trees]
  // Left folding seems to be impossible in terraform... :(
  multiplied = parseint(module.multiplier.result, 10)
}

module "tree_finder" {
  for_each = zipmap([for i, _ in local.slopes : i], local.slopes)
  source   = "./tree_finder"
  grid     = local.grid
  delta_x  = each.value.dx
  delta_y  = each.value.dy
}

module "multiplier" {
  source     = "./evaluator"
  expression = join("*", local.sum_trees_for_slopes)
}

output "result_part1" {
  value = local.sum_trees
}

output "result_part2" {
  value = local.multiplied
}