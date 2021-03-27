package main

import (
	"fmt"
	"gopkg.in/alecthomas/kingpin.v2"
	"os"
)

var (
	app         = kingpin.New("binary_partition", "Finds a number in a range by binary partition")
	rangeLength = app.Arg("range_length", "End of the range to partition").Uint()
	indicators  = app.Arg("sequence", "Sequence of 0/1 partition indicators").Uints()
)

func main() {
	kingpin.MustParse(app.Parse(os.Args[1:]))
	fmt.Println(*indicators)
	result, err := BinaryPartition(*rangeLength, *indicators)
	if err != nil {
		fmt.Println(err.Error())
		os.Exit(1)
	}

	fmt.Println(result)
	os.Exit(0)
}

func BinaryPartition(rangeLength uint, indicators []uint) (uint, error) {
	var a uint = 0
	var b = rangeLength - 1
	for _, elem := range indicators {
		if elem == 0 {
			b = b - (b-a)/2 - 1
		} else if elem == 1 {
			a = a + (b-a)/2 + 1
		}
	}

	if a != b {
		return a, fmt.Errorf("range does not converge: %v <-> %v", a, b)
	}

	return a, nil
}
