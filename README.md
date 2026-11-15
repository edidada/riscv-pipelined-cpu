# 五级流水线 RISC-V CPU（教学版）

一个用 Verilog 写的、能真正跑起来的 **五级流水线 RV32I 子集 CPU**。目标不是"实现得多完整"，而是让你**亲手把冒险、停顿、旁路看出来**：

- 同一份 RTL 可以编译成 4 种配置：`full` / `stall_only` / `no_forward` / `no_hazard`；
- 7 个汇编程序专门制造不同类型的冒险；
- 每条退休指令都与一个独立的单周期参考解释器逐条比对（值、PC、指令字、寄存器堆、数据内存全比）；
- CI 在 **Ubuntu / macOS / Windows** 三个平台上跑完整的 7 × 4 = 28 组仿真，并打印每种配置的 CPI。

> 原 README 只是几篇"推荐去看别人的仓库"的笔记。那些仓库仍然值得读（Patterson & Hennessy 流水线章节 + `ahan321/mips-pipelined-cpu`、`samiyaalizaidi/Pipelined-RISC-V-Processor`），但**读完不算理解**。这个仓库是照着笔记里第三步做的：自己写、自己把逻辑改错、自己看波形里的寄存器值坏掉。

---

## 1. 为什么需要停顿和旁路（先看这一段）

假设寄存器堆在**周期前半拍写、后半拍读**（本实现用 `negedge` 写、`posedge` 锁存 ID 读来模拟），流水线是 IF → ID → EX → MEM → WB。

### 数据相关：旁路解决距离 1 和 2

```
add x1, x2, x3     IF  ID  EX  MEM  WB      <- 结果在 EX 就算出来了
sub x4, x1, x5          IF  ID  EX  MEM  WB  <- EX 就要用 x1
```

`add` 的结果要到 WB 才写进寄存器堆，但 `sub` 在 EX 就要它。中间差 1~2 拍，寄存器堆里还是旧值。
**旁路单元**把 `EX/MEM.alu_result` 或 `MEM/WB.result` 直接拉回 ALU 输入端，不等写回。看 `rtl/forwarding_unit.v`。

距离 3 及以上不需要旁路：生产者在 WB 前半拍已经写好了，寄存器堆自己能读到。

### load-use：旁路也不够，必须停顿 1 拍

```
lw  x1, 0(x2)      IF  ID  EX  MEM  WB      <- 数据要等 MEM 结束才从内存出来
add x3, x1, x4          IF  ID  EX  MEM  WB  <- EX 就要用 x1
```

`lw` 在 EX 时只有**地址**，没有数据，所以 `EX/MEM` 里根本没有可转发的值。硬转发只会把 `0x4000` 这个地址当成数据送出去（`no_hazard` 配置里能亲眼看到这个错值）。
唯一办法是把 `add` 的 ID 阶段**重放一拍**，并在 EX 插一个 bubble：

```
lw  x1, 0(x2)      IF  ID  EX  MEM  WB
add x3, x1, x4          IF  ID  ID  EX  MEM  WB
                              ^ EX 槽被清零（NOP）
                                 ^ 此时 lw 在 WB，MEM/WB 旁路能给出真正的 load 数据
```

实现上就是三个精确动作，见 `rtl/hazard_unit.v` 和 `rtl/cpu.v`：

| 信号 | 动作 |
| --- | --- |
| `pc_write = 0` | PC 保持，取到的指令不丢 |
| `if_id_hold = 1` | IF/ID 保持，下拍重新译码同一条指令 |
| `id_ex_bubble = 1` | ID/EX 的**整个控制束清零**，制造一个 NOP |

隔一条指令（距离 2）就不需要停顿了：`MEM/WB` 旁路能给出 load 数据。程序 `load_use_adj.s` 把这两种情形放在一起对比。

### 控制相关：分支在 EX 才出结果 → flush

分支在 EX 阶段才判定，此时 IF 已经又取了两条**错误路径**指令。本实现不猜方向，直接把 `IF/ID` 和 `ID/EX` 的控制信号清零（"flush 就是把流水线寄存器里的 control 置 0"），代价是每次 taken 分支 2 个气泡。`branch.s` 里的哨兵寄存器验证了错误路径的指令确实没有写回。

---

## 2. 四种配置：把机制一个个关掉

| 配置 | `FORWARDING_EN` | `HAZARD_EN` | `STALL_ALL_DEP` | 结果 |
| --- | --- | --- | --- | --- |
| `full` | 1 | 1 | 0 | 正确，最快 |
| `stall_only` | 0 | 1 | 1 | 正确，但**每条 RAW 相关都停顿到生产者退休**，CPI 明显变差 |
| `no_forward` | 0 | 1 | 0 | **故意坏的**：没有旁路，距离 1 的 ALU 相关读到旧值 |
| `no_hazard` | 1 | 0 | 0 | **故意坏的**：没有 load-use 停顿，转发的是地址而不是数据 |

`no_forward` / `no_hazard` 在 CI 里**预期失败**——测试脚本会把"该坏却没坏"也算作错误。这才是"自己动手改一个小地方验证理解"：不用你手动改代码，改个参数就能看到波形/结果坏掉。

### CPI 对照（CI 实测，cycles / 已执行指令，含流水线填充开销）

| 程序 | `full` | `stall_only` | `no_forward` | `no_hazard` |
| --- | --- | --- | --- | --- |
| `basic` | 1.27 | 1.64 | ✗ 错 | 1.27 |
| `alu_hazard` | 1.46 | **2.62** | ✗ 错 | 1.46 |
| `load_use_adj` | 1.64 | **2.07** | ✗ 错 | ✗ 错 |
| `memory` | 1.32 | **1.80** | ✗ 错 | ✗ 错 |
| `stress` | 1.44 | **2.05** | ✗ 错 | 1.43 |

结论一目了然：**只靠停顿能正确但慢（CPI 涨 40%~80%），只靠旁路会在 load-use 上直接算错**。两者解决的是不同的缺口。

---

## 3. 支持的指令

R-type：`add sub sll slt sltu xor srl sra or and`
I-type：`addi slli slti sltiu xori srli srai ori andi`
Load：`lw lh lb lhu lbu`（小端、有/无符号扩展）
Store：`sw sh sb`
Branch：`beq bne blt bge bltu bgeu`
Upper / Jump：`lui auipc jal jalr`
其他：`fence`（按 NOP 处理）、`ecall`（仿真停机标记）、`nop`

**故意不做**：M 扩展、CSR、异常处理、分支预测、非对齐访问（会报告 `misaligned` 但按忽略处理）、字节使能之外的原子性。这些都是教学之外的复杂度。

### 地址映射

| 范围 | 内容 |
| --- | --- |
| `0x0000` 起 | 指令内存，`prog.hex`，4096 × 32-bit |
| `0x4000` 起 | 数据内存，`data.hex`，4096 × 32-bit |

越界读返回 0，越界写忽略——和参考解释器一致，避免 X 值污染流水线。

---

## 4. 目录结构

```
rtl/
  defs.vh               opcode / funct / ALU / 控制信号常量
  control.v             主译码器：指令 -> 控制信号束
  imm_gen.v             I/S/B/U/J 立即数生成与符号扩展
  alu.v                 纯组合逻辑 ALU（比较也在这里）
  regfile.v             2 读 1 写寄存器堆，x0 硬连线 0
  memory.v              指令 + 数据统一存储器（异步读、同步写）
  forwarding_unit.v     旁路：EX/MEM 与 MEM/WB -> EX 操作数
  hazard_unit.v         load-use 停顿 + stall_only 模式
  cpu.v                 五级流水线顶层，含流水线寄存器与控制
tb/
  cpu_tb.v              自校验 testbench（逐条比对参考 trace）
  config.vh             默认配置（CI 会用生成的头文件覆盖）
tools/
  asm.py                简易 RV32I 汇编器（标签、.word、立即数）
  ref.py                单周期黄金参考解释器，生成 ref.trace/regs/data
  run_tests.py          构建并运行 7 × 4 矩阵，判定通过/预期失败
tests/programs/*.s      7 个测试程序
.github/workflows/ci.yml  三平台 CI
docs/
  pipeline.md           流水线寄存器字段与冒险判定条件
  howto.md              本地怎么跑、怎么看波形、怎么改参数
```

---

## 5. 本地运行

> 用户要求：**本地不编译，交给 GitHub Actions**。下面这段只是备查，日常验证请直接看 CI。

需要 Python 3.9+ 和 Icarus Verilog（`iverilog` / `vvp`）。

```bash
# 全矩阵（7 程序 × 4 配置）
python -I tools/run_tests.py --workdir build/sim

# 只跑一个程序
python -I tools/run_tests.py --only load_use_adj --workdir build/sim

# 单程序手工四步（以 alu_hazard 为例）
mkdir -p /tmp/sim && cd /tmp/sim
python -I /path/to/tools/asm.py /path/to/tests/programs/alu_hazard.s .
python -I /path/to/tools/ref.py .
iverilog -g2012 -I /path/to/rtl -I /path/to/tb \
         -o sim.vvp /path/to/rtl/*.v /path/to/tb/cpu_tb.v
vvp sim.vvp +DUMP          # +DUMP 生成 dump.vcd，可用 gtkwave 看波形
```

`run_tests.py` 用 `IVERILOG` / `VVP` 环境变量（或 `--iverilog` / `--vvp`）指定模拟器路径。

### 三平台 CI

`.github/workflows/ci.yml` 在 push / PR / 手动触发时跑：

| OS | 安装方式 |
| --- | --- |
| `ubuntu-latest` | `apt-get install iverilog` |
| `macos-latest` | `brew install icarus-verilog` |
| `windows-latest` | `choco install iverilog` |

每个 job 都会：elaborate RTL（`-Wall`）→ 跑 28 组仿真 → 上传生成的程序/trace/配置头文件作为 artifact。Windows 上的 iverilog 是 Chocolatey 的 11.0，Linux/macOS 通常是 12.x，两边都要能过，所以 testbench 用 `config.vh` 宏而不是 `-P` 参数覆盖（各版本 `-P` 语法不一致）。

```bash
gh run list --repo <owner>/<repo>
gh run view <run-id> --log              # 看完整日志
gh run view <run-id> --log-failed       # 只看失败步骤
```

---

## 6. 建议的动手顺序

1. 先看 `full` 配置的 `alu_hazard` 波形：找 `forward_a/forward_b` 什么时候变成 `01` / `10`，对应哪两条指令。
2. 切到 `no_forward`，看 `x2` 从期望的 `2` 变成 `0`——这就是"寄存器堆里还是旧值"。
3. 打开 `load_use_adj` 的 `no_hazard`，看 `x3` 变成 `0x4001` 而不是 `0x2b`——转发的是**地址**。
4. 把 `rtl/hazard_unit.v` 里 `load_use_hazard` 的 `id_ex_mem_read` 条件去掉（或改成 `id_ex_reg_write`），重跑，看多停顿几拍但结果仍对不对、CPI 变成多少。
5. 给 `branch.s` 加一条 `jal` 到更远的地方，数 `flushes` 计数是不是每次 taken 分支都 +2。

**只有自己把控制信号改错过，才会真正理解"停顿"和"旁路"不是书本上的两个名词，而是流水线寄存器里控制信号的精确操作。**

## License

MIT
