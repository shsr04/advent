data "local_file" "input" {
  filename = "${path.module}/day1_input"
}

locals {
  split = [for s in split("\n", data.local_file.input.content) : parseint(s, 10)]
  // part 1
  pair       = [for nums in setproduct(local.split, local.split) : nums if nums[0] + nums[1] == 2020][0]
  multiplied = local.pair[0] * local.pair[1]
  //  part 2 (~ 1.5 minutes)
  triple            = [for nums in setproduct(local.split, local.split, local.split) : nums if nums[0] + nums[1] + nums[2] == 2020][0]
  multiplied_triple = local.triple[0] * local.triple[1] * local.triple[2]
}

output "result_part1" {
  value = local.multiplied
}

output "result_part2" {
  value = local.multiplied_triple
}