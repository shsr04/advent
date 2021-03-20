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
    print = 9, // TODO: remove this (only used for zllx fun file)
    halt = 99,
};

using memory = vector<ssize_t>;
using mem_val = memory::value_type;
using mem_index = int;
using param_modes = string;

class memory_cell {
    memory &mem_;
    param_modes const &par_;

    int mode(int j) const {
        if (par_.size() <= j)
            return 0;
        else
            return par_[j] - '0';
    }

  public:
    memory_cell(memory &mem, param_modes const &par, mem_index base)
        : mem_(mem), par_(par), base_(base) {}

    mem_index const base_;

    mem_val &operator[](int j) {
        if (mode(j) == 1)
            return mem_[base_ + j];
        else
            return mem_[mem_[base_ + j]];
    }
};

class instruction {
  public:
    using func = function<mem_index(memory_cell)>;
    instruction(func p_action) : action(move(p_action)) {}
    auto operator()(memory_cell c) const { return action(move(c)); }

  private:
    func action;
};

int const INPUT_AIR_CONDITIONING = 1, INPUT_THERMAL_CONTROL = 5;

/// instruction map
const map<opcode, instruction> instr = {
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
         cin >> c[0];
         return 2;
     }}},
    {opcode::out, {[](auto c) {
         cout << "> " << c[0] << "\n";
         return 2;
     }}},
    {opcode::jnz, {[](auto c) {
         if (c[0] != 0) {
             auto r = static_cast<mem_index>(-c.base_ + c[1] + 1);
             return r;
         } else
             return static_cast<mem_index>(3);
     }}},
    {opcode::jz, {[](auto c) {
         if (c[0] == 0)
             return static_cast<mem_index>(-c.base_ + c[1] + 1);
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
    {opcode::print, {[](auto c) {
         // TODO: remove this on next intcode puzzle
         cout << static_cast<char>(c[0]);
         return 2;
     }}},
};

pair<opcode, param_modes> parse_mem(mem_val p) {
    auto str = to_string(p);
    string op = {str.back()};
    if (str.size() > 1)
        op = str[str.size() - 2] + op;
    param_modes par;
    for (int a : nums(0, max(0, int(str.size()) - 2)))
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
        // find(execution::par, instr.begin(), instr.end(), op);
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
