package main

import (
	"github.com/stretchr/testify/assert"
	"testing"
)

var TEST_MATRIX = []struct {
	rangeLength uint
	indicators  []uint
	expected    uint
}{
	{16, []uint{0, 0, 0, 0}, 0},
	{16, []uint{0, 0, 0, 1}, 1},
	{16, []uint{0, 0, 1, 0}, 2},
	{16, []uint{0, 0, 1, 0, 1}, 999},
	{8, []uint{1, 0, 0}, 4},
	{8, []uint{1, 0, 1}, 5},
	{8, []uint{1, 1, 1}, 7},
	{128, []uint{0, 0, 0, 1, 1, 1, 0}, 14},
	{128, []uint{0, 1, 0, 1, 1, 0, 0}, 44},
	{128, []uint{1, 0, 0, 0, 1, 1, 0}, 70},
	{128, []uint{1, 1, 0, 0, 1, 1, 0}, 102},
}

func TestAll(t *testing.T) {
	for i, c := range TEST_MATRIX {
		actual, err := BinaryPartition(c.rangeLength, c.indicators)
		if c.expected == 999 {
			assert.Error(t, err)
		} else {
			assert.NoError(t, err, "Expected no error in test case #%v: %v", i, c)
			assert.Equal(t, c.expected, actual, "Expected equality in test case #%v: %v", i, c)
		}
	}
}
