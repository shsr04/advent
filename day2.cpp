#include "_main.hpp"

enum class opcode : int {
    add = 1,
    mul = 2,
    halt = 99,
};

class instruction {
    function<ssize_t(vector<ssize_t> &, ssize_t)> const action;

  public:
    instruction(decltype(action) p_action) : action(move(p_action)) {}
    auto operator()(vector<ssize_t> &a, ssize_t b) { return action(a, b); }
};

/// instruction map
map<opcode, instruction> instr = {
    {opcode::add, {[](auto &c, auto i) {
         c[c[i + 2]] = c[c[i]] + c[c[i + 1]];
         return 4;
     }}},
    {opcode::mul, {[](auto &c, auto i) {
         c[c[i + 2]] = c[c[i]] * c[c[i + 1]];
         return 4;
     }}},
};

vector<ssize_t> run_code(vector<ssize_t> mem) {
    for (ssize_t i_mem = 0; i_mem < mem.size();) {
        opcode op = static_cast<opcode>(mem[i_mem]);
        if (op == opcode::halt)
            break;
        if (auto a = instr.find(op); a != instr.end())
            i_mem += a->second(mem, i_mem + 1);
        else {
            cerr << "unknown opcode " << int(op) << "\n";
            break;
        }
    }
    return move(mem);
}

int main(int argc, char **argv) {
    if (argc < 2)
        return 99;
    ifstream in(argv[1]);
    int const solution = 19690720;
    vector<ssize_t> ops;
    for (ssize_t a = 0; in >> a;) {
        ops.push_back(a);
        in.ignore();
    }
    for (int noun : v::iota(0, 100)) {
        for (int verb : v::iota(0, 100)) {
            ops[1] = noun;
            ops[2] = verb;
            auto r = run_code(ops);
            if (r[0] == solution) {
                cout << (100 * r[1] + r[2]) << "\n";
                return 0;
            }
        }
    }
}
