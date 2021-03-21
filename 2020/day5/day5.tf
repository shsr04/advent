data "local_file" "input" {
  filename = "${path.module}/day5_input"
}

locals {
  seats = [for line in split("\n", data.local_file.input.content) : {
    row = substr(line, 0, 7)
    col = substr(line, 7, 3)
  }]
  // part 1
  binary_coords = [for seat in local.seats : {
    // array orientation: front/left = 0, back/right = 1
    row     = [for char in split("", seat.row) : (char == "F" ? 0 : 1)]
    row_lim = [for exp in reverse(range(length(split("", seat.row)))) : pow(2, exp + 1) - 1]
    col     = [for char in split("", seat.col) : (char == "L" ? 0 : 1)]
  }]
  one_step = [for seat in local.binary_coords : {
    //    row = [for row_coord in seat.row : [row_coord == 0 ? 0 : floor(128 / 2), row_coord == 0 ? floor(128 / 2) - 1 : 128]]
    //    row = [for i, r in seat.row : "[for x in [0, ${seat.row_lim[i]}]: [${seat.row[i] == 0 ? 0 : floor(seat.row_lim[i] / 2) + 1}, ${seat.row[i] == 0 ? floor(seat.row_lim[i] / 2) : seat.row_lim[i]}] ]"]
    row = [for i, r in seat.row : {
      front = "slice("
      back  = ", ${r == 0 ? 0 : floor(seat.row_lim[i] / 2) + 1}, ${r == 0 ? floor(seat.row_lim[i] / 2) : seat.row_lim[i]})"
    }]
  }]
  interpolated = [for i, seat in local.one_step : {
    row = flatten([seat.row[*].front, ["range(${local.binary_coords[i].row_lim[0] + 1})"], seat.row[*].back])
  }]
}

module "row_evaluator" {
  //  for_each   = { for i, seat in local.interpolated : i => seat.row }
  for_each   = { 0 = local.interpolated[0].row }
  source     = "../day3/evaluator"
  expression = join("", each.value)
}

output "result" {
  value = module.row_evaluator[0].result
}