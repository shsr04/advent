#include "_main.hpp"
#include <iterator>

enum class opcode : int {
    add = 1,
    mul = 2,
    in = 3,
    out = 4,
    jnz = 5,
    jz = 6,
    lt = 7,
    eq = 8,
    crel = 9,
    halt = 99,
};

using memory = vector<ssize_t>;
using mem_val = memory::value_type;
using mem_index = int;
using param_modes = string;
using io_buffer = deque<mem_val>;

class machine {
    pair<opcode, param_modes> parse_mem(mem_val p);

  public:
    memory mem;
    mem_index i_mem = 0;
    io_buffer input_, output_;
    int status_ = 0;
    bool halted_ = false;
    mem_index relative_offset_ = 0;

    machine(memory p_mem) : mem(p_mem) {}
    io_buffer run_code(io_buffer input);
};

class memory_cell {
    memory &mem_;
    param_modes const &par_;

    enum modes {
        position_mode = 0,
        immediate_mode = 1,
        relative_mode = 2,
    };

    modes mode(mem_index j) const {
        if (par_.size() <= j)
            return position_mode;
        else
            return static_cast<modes>(par_[j] - '0');
    }

  public:
    memory_cell(memory &mem, param_modes const &par, mem_index base,
                mem_index const &offset)
        : mem_(mem), par_(par), base_(base), offset_(offset) {}

    mem_index const base_;
    mem_index const offset_;

    mem_val &operator[](mem_index j) {
        if (base_ + j >= mem_index(mem_.size()))
            mem_.resize(base_ + j + 1, 0);
        auto &val = mem_.at(base_ + j);
        //cout << "mem at " << base_ << "+" << j << " = " << val << "\n";
        switch (mode(j)) {
        case position_mode:
            if (val >= mem_index(mem_.size())) {
                mem_.resize(val + 1); // invalidates references!
                val = mem_.at(base_ + j);
            }
            return mem_.at(val);
        case immediate_mode:
            return val;
        case relative_mode: {
            auto rel = offset_ + val;
            if (rel >= mem_index(mem_.size()))
                mem_.resize(rel + 1);
            return mem_.at(rel);
        }
        default:
            cerr << "unknown mode " << mode(j) << " in cell " << base_ << "\n";
            return mem_[-1];
        }
    }
};

class instruction {
  public:
    using func = function<mem_index(memory_cell, machine &)>;
    instruction(func p_action) : action(move(p_action)) {}
    auto operator()(memory_cell c, machine &m) const {
        return action(move(c), m);
    }

  private:
    func action;
};

/// instruction map
const map<opcode, instruction> instr = {
    {opcode::add, {[](auto c, auto &m) {
         c[2] = c[0] + c[1];
         return 4;
     }}},
    {opcode::mul, {[](auto c, auto &m) {
         c[2] = c[0] * c[1];
         return 4;
     }}},
    {opcode::in, {[](auto c, auto &m) {
         if (!m.input_.empty()) {
             cout << "reading input " << m.input_.front() << " into " << c[0]
                  << "\n";
             c[0] = m.input_.front();
             m.input_.pop_back();
         } else {
             cout << "Input a number: ";
             int inp;
             cin >> inp;
             c[0] = inp;
             // m.status_ = 2;
             // return 0;
         }
         return 2;
     }}},
    {opcode::out, {[](auto c, auto &m) {
         m.output_.push_back(c[0]);
         return 2;
     }}},
    {opcode::jnz, {[](auto c, auto &m) {
         if (c[0] != 0) {
             auto r = static_cast<mem_index>(-c.base_ + c[1] + 1);
             return r;
         } else
             return static_cast<mem_index>(3);
     }}},
    {opcode::jz, {[](auto c, auto &m) {
         if (c[0] == 0)
             return static_cast<mem_index>(-c.base_ + c[1] + 1);
         else
             return static_cast<mem_index>(3);
     }}},
    {opcode::lt, {[](auto c, auto &m) {
         c[2] = c[0] < c[1];
         return 4;
     }}},
    {opcode::eq, {[](auto c, auto &m) {
         c[2] = c[0] == c[1];
         return 4;
     }}},
    {opcode::crel, {[](auto c, auto &m) {
         m.relative_offset_ += c[0];
         return 2;
     }}},
};

pair<opcode, param_modes> machine::parse_mem(mem_val p) {
    auto str = to_string(p);
    string op = {str.back()};
    if (str.size() > 1)
        op = str[str.size() - 2] + op;
    param_modes par;
    for (auto a : nums(0, max(0, int(str.size()) - 2)))
        par.push_back(str[a]);
    r::reverse(par);
    return {static_cast<opcode>(stoi(op)), par};
}

io_buffer machine::run_code(io_buffer input) {
    input_ = move(input);
    output_ = {};
    while (i_mem < mem.size()) {
        auto [op, params] = parse_mem(mem[i_mem]);
        // cout << "instruction " << mem[i_mem] << " = " << int(op) << " with "
        //      << params << "\n ";
        if (op == opcode::halt) {
            halted_ = true;
            break;
        }
        if (auto a = instr.find(op); a != instr.end())
            i_mem += a->second(
                memory_cell(mem, params, i_mem + 1, relative_offset_), *this);
        else {
            cerr << i_mem << ": unknown opcode " << int(op) << "\n";
            break;
        }
        if (status_ != 0) {
            status_ = 0;
            break;
        }
    }
    return move(output_);
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
    auto r = machine(ops).run_code({});
    copy(r.begin(), r.end(), ostream_iterator<long>(cout, " ")), cout << "\n";
}
