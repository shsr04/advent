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
    row = [for char in split("", seat.row) : (char == "F" ? 0 : 1)]
    col = [for char in split("", seat.col) : (char == "L" ? 0 : 1)]
  }]
}

output "result" {
  value = local.binary_coords
}