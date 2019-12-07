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

    machine(memory p_mem) : mem(p_mem) {}
    io_buffer run_code(io_buffer input);
};

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
             // cout << "reading input " << *INPUT << "\n";
             c[0] = m.input_.front();
             m.input_.pop_back();
         } else {
             // cerr << "No input\n";
             m.status_ = 2;
             return 0;
         }
         return 2;
     }}},
    {opcode::out, {[](auto c, auto &m) {
         // cout << "> " << c[0] << "\n";
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
};

pair<opcode, param_modes> machine::parse_mem(mem_val p) {
    auto str = to_string(p);
    string op = {str.back()};
    if (str.size() > 1)
        op = str[str.size() - 2] + op;
    param_modes par;
    for (int a : v::iota(0, max(0, int(str.size()) - 2)))
        par.push_back(str[a]);
    r::reverse(par);
    return {static_cast<opcode>(stoi(op)), par};
}

io_buffer machine::run_code(io_buffer input) {
    input_ = move(input);
    output_ = {};
    while (i_mem < mem.size()) {
        auto [op, params] = parse_mem(mem[i_mem]);
        // cout << "instruction " << mem[i_mem] << " = " << int(op)
        //     << " with " << params << "\n ";
        if (op == opcode::halt) {
            halted_ = true;
            break;
        }
        if (auto a = instr.find(op); a != instr.end())
            i_mem += a->second(memory_cell(mem, params, i_mem + 1), *this);
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
    vector<mem_val> phase = {5, 6, 7, 8, 9};
    mem_val max = 0;
    do {
        vector<machine> amps(5, ops);
        for (int a : v::iota(0_s, amps.size()))
            amps[a].run_code({phase[a]});
        io_buffer buf;
        buf.push_back(0);
        int amp = 0;
        bitset<5> halts = 0;
        while (halts.count() != 5) {
            if (!buf.empty())
                cout << char('A' + amp) << " input: " << buf.front() << "\n";
            if (amps[amp].halted_) {
                cerr << "Machine " << char('A' + amp) << "is already halted!\n";
                return 1;
            }
            buf = amps[amp].run_code(buf);
            if (amps[amp].halted_) {
                cout << char('A' + amp) << " HALTED\n";
                halts[amp] = true;
            }
            amp = (amp + 1) % amps.size();
        }
        cout << "=> " << buf.front() << "\n";
        if (buf.front() > max) {
            max = buf.front();
        }
    } while (r::next_permutation(phase));
    cout << max << "\n";
}
