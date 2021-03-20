data "local_file" "input" {
  filename = "${path.module}/day2_input"
}

locals {
  elements = [for line in split("\n", data.local_file.input.content) : {
    constraint = {
      min    = parseint(split("-", split(" ", split(": ", line)[0])[0])[0], 10)
      max    = parseint(split("-", split(" ", split(": ", line)[0])[0])[1], 10)
      letter = split(" ", split(": ", line)[0])[1]
    },
    password = split(": ", line)[1]
  }]
  // part 1
  occurrences = [for elem in local.elements : [
    elem,
    length([for part in split("", elem.password) : part if part == elem.constraint.letter])
  ]]
  validations = [for pair in local.occurrences :
    // Find the elements with the desired number of occurrences
    flatten([pair, pair[1] >= pair[0].constraint.min && pair[1] <= pair[0].constraint.max])
  ]
  num_valid = length([for triple in local.validations : triple if triple[2]])
  // part 2
  index_occurrences = [for elem in local.elements : [
    elem,
    // {0,1,2}
    sum(coalescelist(
      [
        for index, part in split("", elem.password) :
        // Insert 1 element if the letter is at either the min or the max index (1-based)
      1 if(index == elem.constraint.min - 1 || index == elem.constraint.max - 1) && part == elem.constraint.letter]
    , [0]))
  ]]
  // Find the elements with exactly 1 match
  index_validations  = [for pair in local.index_occurrences : flatten([pair, pair[1] == 1])]
  num_valid_at_index = length([for triple in local.index_validations : triple if triple[2]])
}

output "result_part1" {
  value = local.num_valid
}

output "result_part2" {
  value = local.num_valid_at_index
}