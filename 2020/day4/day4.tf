data "local_file" "input" {
  filename = "${path.module}/day4_input"
}

locals {
  passports     = [for segment in split("\n\n", data.local_file.input.content) : { for entry in split(" ", replace(segment, "\n", " ")) : split(":", entry)[0] => split(":", entry)[1] }]
  required_keys = ["byr", "iyr", "eyr", "hgt", "hcl", "ecl", "pid"]
  // part 1
  present_validations = [for fields in local.passports : flatten([fields, length(setintersection(keys(fields), local.required_keys)) == length(local.required_keys)])]
  num_present         = sum([for pair in local.present_validations : 1 if pair[1]])
  // part 2
  only_present_fields = [for pair in local.present_validations : pair[0] if pair[1]]
  is_hgt_valid        = [for fields in local.only_present_fields : try(regex("([[:digit:]]{3})cm", fields.hgt)[0] >= 150 && regex("([[:digit:]]{3})cm", fields.hgt)[0] <= 193, regex("([[:digit:]]{2})in", fields.hgt)[0] >= 59 && regex("([[:digit:]]{2})in", fields.hgt)[0] <= 76, false)]
  data_validations = [for index, fields in local.only_present_fields : flatten([fields,
    fields.byr >= 1920 && fields.byr <= 2002
    && fields.iyr >= 2010 && fields.iyr <= 2020
    && fields.eyr >= 2020 && fields.eyr <= 2030
    && local.is_hgt_valid[index]
    && length(regexall("^#[0-9a-f]{6}$", fields.hcl)) > 0
    && contains(["amb", "blu", "brn", "gry", "grn", "hzl", "oth"], fields.ecl)
    && length(regexall("^[[:digit:]]{9}$", fields.pid)) > 0
  ])]
  num_valid = sum([for pair in local.data_validations : (pair[1] ? 1 : 0)])
}

output "result_part1" {
  value = local.num_present
}

output "result_part2" {
  value = local.num_valid
}