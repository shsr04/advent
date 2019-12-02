#include "_main.hpp"

enum class opcode {
    add = 1,
    mul = 2,
    halt = 99,
};

/// instruction size (opcode + operands)
map<opcode, int> instr_size = {{opcode::add, 4}, {opcode::mul, 4}};

/// instruction execution
map<opcode, function<void(vector<int> &, int)>> instr = {
    {opcode::add, [](auto &c, auto i) { c[c[i + 2]] = c[c[i]] + c[c[i + 1]]; }},
    {opcode::mul, [](auto &c, auto i) { c[c[i + 2]] = c[c[i]] * c[c[i + 1]]; }},
};

vector<int> run_code(vector<int> code) {
    for (int a = 0; a < code.size();) {
        if (code[a] == int(opcode::halt))
            break;
        opcode op = static_cast<opcode>(code[a]);
        instr[op](code, a + 1);
        a += instr_size[op];
    }
    return move(code);
}

int main(int argc, char **argv) {
    if (argc < 2)
        return 99;
    ifstream in(argv[1]);
    vector<int> ops;
    for (int a = 0; in >> a;) {
        ops.push_back(a);
        in.ignore();
    }
    for (int noun : v::iota(0, 100)) {
        for (int verb : v::iota(0, 100)) {
            ops[1] = noun;
            ops[2] = verb;
            auto r = run_code(ops);
            if (r[0] == 19690720) {
                cout << (100 * r[1] + r[2]) << "\n";
                return 0;
            }
        }
    }
}
