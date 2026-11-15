# 操作手册：跑仿真、看波形、改参数

> 本项目按要求**不在本地编译**，日常验证看 GitHub Actions。本文是备查手册。

## 1. 一键跑全矩阵

```bash
python -I tools/run_tests.py --workdir build/sim
```

输出形如：

```
[alu_hazard  /full       ] PASS expected=PASS CPI=1.4615   ok
[alu_hazard  /stall_only ] PASS expected=PASS CPI=2.6153   ok
[alu_hazard  /no_forward ] FAIL expected=FAIL CPI=1.4615   ok
...
28 runs, 0 unexpected outcomes
```

`FAIL expected=FAIL ... ok` 是**故意坏掉的配置如预期地坏了**，属于测试通过。只有 `UNEXPECTED` 才是真问题：要么是正确配置算错了，要么是该坏的配置居然没坏（说明测试程序没覆盖到那个冒险）。

脚本会为每个程序做：

1. `asm.py` 汇编 `.s` → `prog.hex` / `data.hex` / `symbols.txt`
2. `ref.py` 单周期解释执行 → `ref.trace` / `ref.regs` / `ref.data` / `ref.steps`
3. 为每种配置生成 `inc_<cfg>/config.vh`
4. `iverilog` 编译 → `<cfg>.vvp`
5. `vvp` 运行 → 解析 `PASS`/`FAIL`/`CPI`

指定模拟器路径：

```bash
python -I tools/run_tests.py \
  --iverilog /c/iverilog/bin/iverilog.exe \
  --vvp      /c/iverilog/bin/vvp.exe
# 或者环境变量 IVERILOG=... VVP=...
```

只跑一个程序：

```bash
python -I tools/run_tests.py --only load_use_adj --workdir build/sim
```

`--workdir` 会保留中间产物；不传则用临时目录并在结束时删除。

## 2. 手工跑单个配置

```bash
mkdir -p /tmp/sim && cd /tmp/sim
python -I /path/to/tools/asm.py /path/to/tests/programs/alu_hazard.s .
python -I /path/to/tools/ref.py .

# 用默认配置（tb/config.vh 里是 full）
iverilog -g2012 -I /path/to/rtl -I /path/to/tb \
         -o sim.vvp /path/to/rtl/*.v /path/to/tb/cpu_tb.v
vvp sim.vvp
```

### 改成别的配置

不要用 `iverilog -P`（各版本/各 shell 语法不一致，Windows 上尤其麻烦）。生成一个 `config.vh` 放到**优先级更高的 `-I` 目录**：

```bash
mkdir -p inc_no_forward
cat > inc_no_forward/config.vh <<'EOF'
`ifndef CPU_TB_CONFIG_VH
`define CPU_TB_CONFIG_VH
`define TB_PROG          "prog.hex"
`define TB_DATA          "data.hex"
`define TB_TRACE         "ref.trace"
`define TB_REFDATA       "ref.data"
`define TB_REFREGS       "ref.regs"
`define TB_FORWARDING_EN 0
`define TB_HAZARD_EN     1
`define TB_STALL_ALL_DEP 0
`define TB_CFG_NAME      "no_forward"
`define TB_MAX_CYCLES    5000
`endif
EOF

iverilog -g2012 -I inc_no_forward -I /path/to/rtl -I /path/to/tb \
         -o nf.vvp /path/to/rtl/*.v /path/to/tb/cpu_tb.v
vvp nf.vvp
```

四个配置的参数组合见 `README.md` 第 2 节 / `docs/pipeline.md`。

## 3. 看波形

```bash
vvp sim.vvp +DUMP        # 生成 dump.vcd
gtkwave dump.vcd

vvp sim.vvp +TRACE       # 直接把每拍流水线状态打到 stdout，不用装 gtkwave
python -I /path/to/tools/exercises.py   # README §6 的 5 个实验，逐条核对结论
```

`+TRACE` 输出格式（`tb/cpu_tb.v`）：

```
TRACE c=<拍> pc=<PC> IFID=<指令>[<该指令PC>] IDEX=... EXMEM=... MEMWB=...
      fwd=<a><b> store=<fwd_store> stall=<0/1> lu=<0/1> flush=<if_id><id_ex>
      opA=<旁路后ALU输入A> opB=<B> alu=<结果> memrd=<load数据> wb=<写回值>
```

其中 `fwd` 是 4 个字符（`forward_a` 2 位 + `forward_b` 2 位），例如 `0101` 表示两个操作数都从 EX/MEM 旁路。`tools/exercises.py` 就是解析这行输出来核对 README §6 每条断言的，不需要图形界面。

建议加入的信号（都在 `cpu_tb` / `cpu_tb.dut` 下）：

| 信号 | 用途 |
| --- | --- |
| `clk`, `reset`, `pc` | 取指进度 |
| `if_id_instr`, `id_ex_instr`, `ex_mem_instr`, `mem_wb_instr` | 五级里各是哪条指令 |
| `forward_a`, `forward_b` | `01` = EX/MEM 旁路，`10` = MEM/WB 旁路 |
| `stall_out`, `load_use_hazard` | 停顿发生在哪一拍 |
| `flush_if_id`, `flush_id_ex` | taken 分支的 squash |
| `pc_src` | `PC_JUMP` / `PC_STALL` / `PC_PC4` |
| `retired_valid`, `retired_pc`, `retired_rd`, `retired_result` | 每条写回指令 |
| `dut.id_ex_rd_r`, `dut.ex_mem_rd_r`, `dut.mem_wb_rd_r` | 三个在飞的生产者 |
| `dut.operand_a_raw`, `dut.operand_b_raw` | 旁路 mux 之后的真实 ALU 输入 |
| `dut.id_ex_alu_result_r`, `dut.mem_rdata` | load 的**地址** vs **数据** |

### 三个具体观察点

**a) `add x1,.. ; sub x4,x1,..`（`alu_hazard.s`）**
在 `sub` 处于 ID/EX 的那拍，`forward_a` 应为 `01`，`operand_a_raw` 等于上一条的 `alu_result`。把 `no_forward` 的波形并排看，`operand_a_raw` 会停在 `0`。

**b) `lw x1,0(x2) ; addi x3,x1,1`（`load_use_adj.s`）**
`full` 配置：`lw` 在 ID/EX 时 `stall_out` 拉高一拍，下一拍 `id_ex_instr` 变成 NOP，`addi` 的 `if_id_instr` 保持不变（重放）。再下一拍 `addi` 进 EX，`forward_a` = `10`，源是 `wb_result`（此时是 `mem_rdata`）。
`no_hazard` 配置：没有那一拍停顿，`forward_a` = `01`，`operand_a_raw` 是 `0x4000` 地址，结果 `x3 = 0x4001`。

**c) taken 分支（`branch.s`）**
`beq` 在 EX 时 `flush_if_id`/`flush_id_ex` 同时拉高，随后两拍的 `id_ex_instr` 是 NOP。哨兵寄存器 `x3` 最终仍是 `0`。

## 4. 写一个新测试程序

`.s` 语法（`tools/asm.py`）：

```asm
.data
    .word 0x12345678       # 从 0x4000 开始，每 .word 一个 32 位字
.text
start:
    addi x1, x0, 5
    lui  x2, 0x4           # x2 = 0x4000（U 立即数占高 20 位）
    lw   x3, 0(x2)
    addi x4, x3, 1
    bne  x4, x0, start     # 标签，相对偏移自动算
    ecall                  # 停机标记（必须写，否则参考解释器跑到上限）
```

要点：

* 寄存器支持 `x0..x31` 和 ABI 名（`t0`、`a0`、`sp`、`ra`…）。
* 立即数支持十进制、`0x` 十六进制、`-` 负数；I 型立即数必须落在 12 位有符号范围内。
* `lw x3, 4(x2)` / `sw x3, 4(x2)` 的偏移写法固定。
* `ecall` 是唯一停机方式；程序里不要无限循环（除非你想测超时）。
* `0x00000013` 是 NOP；`rd` 为 `x0` 的指令一律不写寄存器。

新文件放进 `tests/programs/` 即可被 `run_tests.py` 自动发现。**还要在 `tools/run_tests.py` 的 `SHOULD_FAIL` 表里登记**哪些坏配置应该在这个程序上失败——这张表本身就是在说明"哪种冒险需要哪种机制"。

## 5. CI 与日志

```bash
gh run list --repo <owner>/<repo>
gh run view <run-id>                 # 概览
gh run view <run-id> --log          # 全部日志（含三个 OS 的 CPI 表）
gh run view <run-id> --log-failed   # 只看失败
gh run watch <run-id>               # 等它跑完
```

三个 job 的名字是 `ubuntu-latest / 3.11`、`macos-latest / 3.11`、`windows-latest / 3.11`，另有 `ubuntu-latest / 3.13`。每个 job 上传 `sim-<os>-py<ver>` artifact，里面是生成的 `prog.hex`、`ref.trace`、各配置 `config.vh`，可以直接拿来复现。

### 常见失败排查

| 现象 | 可能原因 |
| --- | --- |
| `iverilog: command not found` | 该 OS 的安装步骤失败，看对应 `Install Icarus Verilog (...)` 日志 |
| `FATAL: cannot open reference trace` | `ref.py` 没跑成功，检查 `.s` 有没有 `ecall`、有没有死循环 |
| `FAIL ... TIMEOUT` | 程序没停机（漏 `ecall`），或流水线卡死（PC 不再前进） |
| `ERROR: expected write never retired` | flush 过头，或 halt 提前结束让流水线没排空 |
| `UNEXPECTED`（该坏的没坏） | 新程序没真正制造那个冒险，或 `SHOULD_FAIL` 登记不对 |
| `Not enough words in ...` | `asm.py` 已经把 hex 补齐到 4096 行，正常不应出现 |
