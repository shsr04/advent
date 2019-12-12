#include "_main.hpp"

struct cartesian_vector {
    double x, y, z;
    void operator+=(cartesian_vector const &p) {
        x += p.x;
        y += p.y;
        z += p.z;
    }
    double &operator[](int i) {
        if (i == 0)
            return x;
        else if (i == 1)
            return y;
        else if (i == 2)
            return z;
        else
            cerr << "invalid vector index\n";
        return x;
    }
    bool operator==(cartesian_vector const &p) const {
        return x == p.x && y == p.y && z == p.z;
    }
};
ostream &operator<<(ostream &o, cartesian_vector const &p) {
    o << "(" << p.x << "," << p.y << "," << p.z << ")";
    return o;
}

struct moving_body {
    cartesian_vector pos = {0, 0, 0}, vel = {0, 0, 0};
    bool operator==(moving_body const &p) const {
        return pos == p.pos && vel == p.vel;
    }
    double potential_energy() const {
        return abs(pos.x) + abs(pos.y) + abs(pos.z);
    }
    double kinetic_energy() const {
        return abs(vel.x) + abs(vel.y) + abs(vel.z);
    }
};
ostream &operator<<(ostream &o, moving_body const &p) {
    o << "[ pos: " << p.pos << ", vel: " << p.vel << " ]";
    return o;
}

void pull_gravity(moving_body &a, moving_body &b) {
    if (a.pos.x > b.pos.x) {
        a.vel.x -= 1;
        b.vel.x += 1;
    } else if (a.pos.x < b.pos.x) {
        a.vel.x += 1;
        b.vel.x -= 1;
    }
    if (a.pos.y > b.pos.y) {
        a.vel.y -= 1;
        b.vel.y += 1;
    } else if (a.pos.y < b.pos.y) {
        a.vel.y += 1;
        b.vel.y -= 1;
    }
    if (a.pos.z > b.pos.z) {
        a.vel.z -= 1;
        b.vel.z += 1;
    } else if (a.pos.z < b.pos.z) {
        a.vel.z += 1;
        b.vel.z -= 1;
    }
}

auto make_power_set(int to) {
    vector<pair<int, int>> r;
    for (auto p : v::iota(0, pow(2, to))) {
        vector<int> res;
        for (auto a : v::iota(0, p)) {
            if (p & (1 << a))
                res.push_back(a);
        }
        if (res.size() == 2 && res[0] != res[1])
            r.push_back({res[0], res[1]});
    }
    return r;
}

template <class T> size_t cycle_length(function<T(T)> f, T x0) {
    auto slow = f(x0), fast = f(f(x0));
    while (slow != fast)
        slow = f(slow), fast = f(f(fast));
    cout << "cycle found ";
    // find position of first recurring x
    auto pos = 0_s;
    slow = x0;
    while (slow != fast)
        slow = f(slow), fast = f(fast), pos++;
    cout << "at " << pos << " ";
    // find cycle length starting from pos
    auto len = 1_s;
    fast = f(slow);
    while (slow != fast)
        fast = f(fast), len++;
    cout << "of length " << len << "\n";
    return len;
}

int main(int argc, char **argv) {
    if (argc < 2)
        return 99;
    vector<moving_body> bodies;
    ifstream in(argv[1]);
    string tmp;
    while (getline(in, tmp)) {
        istringstream line(tmp);
        moving_body b;
        getline(line, tmp, '=');
        line >> b.pos.x;
        getline(line, tmp, '=');
        line >> b.pos.y;
        getline(line, tmp, '=');
        line >> b.pos.z;
        cout << b << "\n";
        bodies.push_back(b);
    }
    auto state0 = bodies;

    vector<pair<int, int>> power_set = make_power_set(bodies.size());
    for (auto step : v::iota(0, 1000)) {
        // cout << "STEP " << (step + 1) << "\n";
        for (auto &[i_a, i_b] : power_set) {
            auto &a = bodies[i_a], &b = bodies[i_b];
            // cout << i_a << "<->" << (i_b % bodies.size()) << " ";
            pull_gravity(a, b);
        }
        for (auto &a : bodies) {
            a.pos += a.vel;
            // cout << i_a << ": " << a << "\n";
        }
    }
    auto energy =
        accumulate(begin(bodies), end(bodies), 0, [](auto &x, auto &y) {
            return x + y.potential_energy() * y.kinetic_energy();
        });
    cout << "Final energy: " << energy << "\n";

    int i_vec = 0;
    function<vector<moving_body>(vector<moving_body>)> modify_component =
        [&power_set, &i_vec](auto x) {
            for (auto &[i_a, i_b] : power_set) {
                auto &a = x[i_a], &b = x[i_b];
                if (a.pos[i_vec] > b.pos[i_vec]) {
                    a.vel[i_vec] -= 1;
                    b.vel[i_vec] += 1;
                } else if (a.pos[i_vec] < b.pos[i_vec]) {
                    a.vel[i_vec] += 1;
                    b.vel[i_vec] -= 1;
                }
            }
            for (auto &a : x) {
                a.pos += a.vel;
            }
            return x;
        };
    auto cycle_x = cycle_length(modify_component, state0);
    i_vec = 1;
    auto cycle_y = cycle_length(modify_component, state0);
    i_vec = 2;
    auto cycle_z = cycle_length(modify_component, state0);
    cout << "Period: " << lcm(lcm(cycle_x, cycle_y), cycle_z) << "\n";
}
