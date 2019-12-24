#include "_main.hpp"
#include "fn.hpp"
#include <algorithm>

auto const GRID_SIZE = 5;
using GRID = map<int, array<array<bool, GRID_SIZE>, GRID_SIZE>>;

int neighbours(GRID const &grid, int l, int y, int x) {
    int r = 0;

    /// OUTER RING
    if (x == 0 && y > 0 && y < 4) {
        r = grid.at(l)[y][x + 1] + grid.at(l - 1)[2][1] + grid.at(l)[y - 1][x] +
            grid.at(l)[y + 1][x];
    } else if (x == 4 && y > 0 && y < 4) {
        r = grid.at(l)[y][x - 1] + grid.at(l - 1)[2][3] + grid.at(l)[y - 1][x] +
            grid.at(l)[y + 1][x];
    } else if (y == 0 && x > 0 && x < 4) {
        r = grid.at(l)[y + 1][x] + grid.at(l - 1)[1][2] + grid.at(l)[y][x - 1] +
            grid.at(l)[y][x + 1];
    } else if (y == 4 && x > 0 && x < 4) {
        r = grid.at(l)[y - 1][x] + grid.at(l - 1)[3][2] + grid.at(l)[y][x - 1] +
            grid.at(l)[y][x + 1];
    }

    else if (x == 0 && y == 0) {
        r = grid.at(l)[y][x + 1] + grid.at(l - 1)[2][1] + grid.at(l - 1)[1][2] +
            grid.at(l)[y + 1][x];
    } else if (x == 4 && y == 0) {
        r = grid.at(l)[y][x - 1] + grid.at(l - 1)[2][3] + grid.at(l - 1)[1][2] +
            grid.at(l)[y + 1][x];
    } else if (y == 4 && x == 0) {
        r = grid.at(l)[y - 1][x] + grid.at(l - 1)[3][2] + grid.at(l - 1)[2][1] +
            grid.at(l)[y][x + 1];
    } else if (y == 4 && x == 4) {
        r = grid.at(l)[y - 1][x] + grid.at(l - 1)[3][2] + grid.at(l)[y][x - 1] +
            grid.at(l - 1)[2][3];
    }

    /// INNER RING
    else if (x == 1 && y > 0 && y < 4) {
        r = grid.at(l)[y - 1][x] + grid.at(l)[y + 1][x] + grid.at(l)[y][x - 1];
        if (y != 2)
            r += grid.at(l)[y][x + 1];
        else
            for (auto a : nums(0, GRID_SIZE))
                r += grid.at(l + 1)[a][0];
    } else if (x == 3 && y > 0 && y < 4) {
        r = grid.at(l)[y - 1][x] + grid.at(l)[y + 1][x] + grid.at(l)[y][x + 1];
        if (y != 2)
            r += grid.at(l)[y][x - 1];
        else
            for (auto a : nums(0, GRID_SIZE))
                r += grid.at(l + 1)[a][4];
    } else if (y == 1 && x == 2) {
        r = grid.at(l)[y][x - 1] + grid.at(l)[y][x + 1] + grid.at(l)[y - 1][x];
        for (auto a : nums(0, GRID_SIZE))
            r += grid.at(l + 1)[0][a];
    } else if (y == 3 && x == 2) {
        r = grid.at(l)[y][x - 1] + grid.at(l)[y][x + 1] + grid.at(l)[y + 1][x];
        for (auto a : nums(0, GRID_SIZE))
            r += grid.at(l + 1)[4][a];
    } else if (x == 2 && y == 2) {
        r = 0;
    } else {
        cerr << "unhandled coordinate " << y << "," << x << "\n";
        throw 0;
    }
    // cout << "n(" << l << "," << y << "," << x << ")=" << r << "\n";
    return r;
}

int count_alive(GRID::mapped_type const &layer) {
    auto r = 0;
    for (auto y : nums(0, GRID_SIZE))
        for (auto x : nums(0, GRID_SIZE))
            r += layer[y][x];
    return r;
}

GRID simulate(GRID grid) {
    auto r = grid;
    set<int> new_layers;
    auto min_layer =
             r::min_element(grid % f::where([](auto x) {
                                return count_alive(x.second) > 0;
                            }),
                            [](auto x, auto y) { return x.first < y.first; })
                 ->first,
         max_layer =
             r::max_element(grid % f::where([](auto x) {
                                return count_alive(x.second) > 0;
                            }),
                            [](auto x, auto y) { return x.first < y.first; })
                 ->first;
    cout << "layers: " << min_layer << ".." << max_layer << "\n";
    if (!grid.count(min_layer - 2)) {
        cout << "creating layer " << min_layer - 2 << "\n";
        new_layers.insert(min_layer - 2);
    }
    if (!grid.count(max_layer + 2)) {
        cout << "creating layer " << max_layer + 2 << "\n";
        new_layers.insert(max_layer + 2);
    }
    for (auto l : new_layers) {
        grid[l] = r[l] = {};
        if (count_alive(grid[l]) != 0)
            cerr << "layer " << l << " has set bits!";
    }

    for (auto l : nums(min_layer - 1, max_layer + 2)) {
        for (auto y : nums(0, GRID_SIZE)) {
            for (auto x : nums(0, GRID_SIZE)) {
                if (neighbours(grid, l, y, x) != 1 && grid[l][y][x])
                    r[l][y][x] = false;
                else if ((neighbours(grid, l, y, x) == 1 ||
                          neighbours(grid, l, y, x) == 2) &&
                         !grid[l][y][x])
                    r[l][y][x] = true;
            }
        }
    }

    return move(r);
}

size_t compute_rating(GRID const &grid) {
    auto points = 1;
    auto r = 0;
    for (auto y : nums(0, GRID_SIZE)) {
        for (auto x : nums(0, GRID_SIZE)) {
            if (grid.at(0)[y][x])
                r += points;
            points *= 2;
        }
    }
    return r;
}

void print_grid(GRID const &grid) {
    for (auto &[l, g] : grid) {
        cout << "Level " << l << ":\n";
        for (auto y : nums(0, GRID_SIZE)) {
            for (auto x : nums(0, GRID_SIZE))
                if (x == 2 && y == 2)
                    cout << 'X';
                else
                    cout << (grid.at(l)[y][x] ? '#' : '.');
            cout << "\n";
        }
    }
    cout << "\n";
}

int main(int argc, char **argv) {
    if (argc < 2)
        return 99;
    ifstream in(argv[1]);
    string line;
    auto i_row = 0;
    array<array<bool, GRID_SIZE>, GRID_SIZE> base_grid;
    while (in >> line) {
        auto i_col = 0;
        for (auto c : line)
            base_grid[i_row][i_col++] = c == '#';
        i_row++;
    }
    GRID grid = {{-1, {}}, {0, move(base_grid)}, {1, {}}};

    /*
    map<size_t, int> ratings;
    while (true) {
         grid = simulate(move(grid));
         ratings[compute_rating(grid)] += 1;
         cout << compute_rating(grid) << "\n";
         print_grid(grid);
         if (ratings[compute_rating(grid)] > 1)
             break;
     }
    */

    for (auto steps : nums(0, 200)) {
        print_grid(grid);
        grid = simulate(move(grid));
    }
    auto alive = 0;
    for (auto &[l, g] : grid) {
        alive += count_alive(g);
    }
    cout << "Alive: " << alive << "\n";
    // 1848 < x < 2309
}
