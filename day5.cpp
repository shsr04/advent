#include "_main.hpp"

enum class opcode : int {
    add = 1,
    mul = 2,
    in = 3,
    out = 4,
    jnz = 5,
    jz = 6,
    lt = 7,
    eq = 8,
    halt = 99,
};

using memory = vector<ssize_t>;
using mem_val = memory::value_type;
using mem_index = int;
using param_mode = string;

class memory_cell {
    memory &mem_;
    param_mode const &par_;
    mem_index const base_;

    int mode(int i) const {
        if (par_.size() <= i)
            return 0;
        else
            return par_[i]-'0';
    }

  public:
    memory_cell(memory &mem, param_mode const &par, mem_index base)
        : mem_(mem), par_(par), base_(base) {}

    mem_index const i = base_;

    mem_val &operator[](int i) {
        if (mode(i)==1)
            return mem_[base_ + i];
        else
            return mem_[mem_[base_ + i]];
    }
};

class instruction {
  public:
    using func = function<mem_index(memory_cell)>;
    instruction(func p_action) : action(move(p_action)) {}
    auto operator()(memory_cell c) { return action(move(c)); }

  private:
    const func action;
};

int const INPUT_AIR_CONDITIONING = 1, INPUT_THERMAL_CONTROL = 5;

/// instruction map
map<opcode, instruction> instr = {
    {opcode::add, {[](auto c) {
         c[2] = c[0] + c[1];
         return 4;
     }}},
    {opcode::mul, {[](auto c) {
         c[2] = c[0] * c[1];
         return 4;
     }}},
    {opcode::in, {[](auto c) {
         cout << "Input a number: ";
         mem_val inp;
         cin >> inp;
         c[0] = inp;
         return 2;
     }}},
    {opcode::out, {[](auto c) {
         cout << "> " << c[0] << "\n";
         return 2;
     }}},
    {opcode::jnz, {[](auto c) {
         if (c[0] != 0) {
             auto r = static_cast<mem_index>(-c.i + c[1] + 1);
             return r;
         } else
             return static_cast<mem_index>(3);
     }}},
    {opcode::jz, {[](auto c) {
         if (c[0] == 0)
             return static_cast<mem_index>(-c.i + c[1] + 1);
         else
             return static_cast<mem_index>(3);
     }}},
    {opcode::lt, {[](auto c) {
         c[2] = c[0] < c[1];
         return 4;
     }}},
    {opcode::eq, {[](auto c) {
         c[2] = c[0] == c[1];
         return 4;
     }}},
};

pair<opcode, param_mode> parse_mem(mem_val p) {
    auto str = to_string(p);
    string op = {str.back()};
    if (str.size() > 1)
        op = str[str.size() - 2] + op;
    param_mode par;
    for (int a : v::iota(0, max(0, int(str.size()) - 2)))
        par.push_back(str[a]);
    r::reverse(par);
    return {static_cast<opcode>(stoi(op)), par};
}

memory run_code(memory mem) {
    for (mem_index i_mem = 0; i_mem < mem.size();) {
        auto [op, params] = parse_mem(mem[i_mem]);
        // cout << "instruction " << mem[i_mem] << " = " << int(op) << " with "
        //     << params << "\n";
        if (op == opcode::halt)
            break;
        if (auto a = instr.find(op); a != instr.end())
            i_mem += a->second(memory_cell(mem, params, i_mem + 1));
        else {
            cerr << i_mem << ": unknown opcode " << int(op) << "\n";
            break;
        }
    }
    return move(mem);
}

int main(int argc, char **argv) {
    if (argc < 2)
        return 99;
    ifstream in(argv[1]);
    memory ops;
    for (mem_val a = 0; in >> a;) {
        ops.push_back(a);
        in.ignore();
    }
    auto r = run_code(ops);
}
