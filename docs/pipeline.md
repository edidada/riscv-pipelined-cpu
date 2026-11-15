# 流水线寄存器字段与冒险判定条件

本文是 `rtl/cpu.v` 的速查表，用来对照波形看信号。所有控制信号在流水线寄存器里**显式传递**，所以 flush / bubble 就是把它们清零，没有隐藏的隐式状态。

## 五级与流水线寄存器

```
 IF        ID          EX            MEM           WB
  |  IF/ID  |   ID/EX   |   EX/MEM    |   MEM/WB    |
  v         v           v             v             v
 PC -> imem -> decode -> ALU / 目标 -> dmem / store -> 写回寄存器堆
            regfile    forwarding   mem_rdata     wb_result
```

| 寄存器 | 数据字段 | 控制字段 |
| --- | --- | --- |
| `IF/ID` | `pc`, `instr` | —（译码在 ID 组合完成） |
| `ID/EX` | `pc`, `instr`, `rs1`, `rs2`, `rd`, `rdata1`, `rdata2`, `imm` | `wb_sel`, `reg_write`, `mem_read`, `mem_write`, `mem_width`, `mem_unsigned`, `branch`, `jump`, `jalr`, `alu_src_a`, `alu_src_b`, `alu_op`, `uses_rs1`, `uses_rs2`, `is_store`, `illegal` |
| `EX/MEM` | `pc`, `instr`, `rd`, `alu_result`, `store_data` | `wb_sel`, `reg_write`, `mem_read`, `mem_write`, `mem_width`, `mem_unsigned`, `illegal` |
| `MEM/WB` | `pc`, `instr`, `rd`, **`result`（已选好的写回值）** | `reg_write`, `illegal` |

注意 `MEM/WB.result` 是**锁存后的写回值**，不是组合逻辑从 MEM/WB 再算一遍。原因：如果在同一拍组合地算，寄存器堆的写可能采到"下一条指令"的数据，距离 3 的依赖会静默出错。`wb_mux_pre` 在 EX/MEM 阶段算好，`posedge` 时锁进 `mem_wb_result_r`。

## 三个动作的精确含义

### 1. 旁路（forwarding，`rtl/forwarding_unit.v`）

```
if (id_ex_uses_rs1 && id_ex_rs1 != 0) begin
    if      (ex_mem_reg_write && ex_mem_rd == id_ex_rs1) forward_a = 01;  // EX/MEM -> EX
    else if (mem_wb_reg_write && mem_wb_rd == id_ex_rs1) forward_a = 10;  // MEM/WB -> EX
end
// rs2 同理；rd == x0 永不转发
```

* 优先级 `EX/MEM > MEM/WB`：更年轻的指令覆盖更老的。
* `fwd == 01` 的源是 `ex_mem_early_value`：ALU 结果 / U 立即数 / PC+4。**对 load 来说这里只有地址，没有数据**。
* `fwd == 10` 的源是 `wb_result`：完整写回 mux，**包含 load 的数据**。这是 `lw; nop; add`（距离 2）能不停顿就正确的原因。
* store 有**独立的** `fwd_store`：ALU 的 B 输入是 S 立即数（算地址），但存进内存的值必须来自 rs2。复用 `operand_b` 会把立即数写进内存。

### 2. load-use 停顿（`rtl/hazard_unit.v`）

```
load_use_hazard = id_ex_mem_read && id_ex_reg_write && id_ex_rd != 0 &&
                  ((if_id_uses_rs1 && if_id_rs1 == id_ex_rd) ||
                   (if_id_uses_rs2 && if_id_rs2 == id_ex_rd))
```

成立时：

```
pc_write     = 0    // PC 保持，不取新指令
if_id_hold   = 1    // IF/ID 保持，下拍重译码同一条
id_ex_bubble = 1    // ID/EX 控制束全清 0 => EX 槽是 NOP
```

停顿 1 拍后，消费者到达 EX 时生产者正好在 WB，此时 `MEM/WB -> EX` 旁路给出的是真正的 load 数据。所以**恰好一拍就够**，不需要两拍。

### 3. flush（控制相关）

分支 / 跳转在 **EX** 才出结果（`redirect_taken = jump || (branch && alu_result != 0)`），此时 IF 已取进两条错误路径指令。处理：

```
flush_if_id = redirect_taken   // IF/ID 装成 NOP
flush_id_ex = redirect_taken   // ID/EX 控制束清零
pc_reg     <= branch_target    // 下拍从正确目标取指
```

分支目标由独立加法器 `id_ex_pc + imm_B` 算出；`jalr` 的目标由 ALU 算 `rs1 + imm_I`，所以比较和取目标是并行的。

### 优先级

```
redirect (flush)  >  stall (replay)  >  normal PC+4
```

重定向与停顿同拍出现时以重定向为准：错误路径指令本来就要被清掉，没必要为它停顿。见 `rtl/cpu.v` 里 `if_id_hold = hz_if_id_hold & ~redirect_taken`。

## 寄存器堆时序（容易踩的坑）

`rtl/regfile.v` 在 **negedge 写**。这是教材里"前半拍写、后半拍读"的单时钟实现：

* 生产者在 WB 的 negedge 写入，ID 在随后 posedge 把读值锁进 ID/EX；
* 所以距离 3 的依赖靠寄存器堆自己就对了，**不需要也没有** EX 旁路可用（生产者已离开流水线）；
* 距离 1、2 仍然必须旁路——这正是 `no_forward` 坏掉的原因。

## 四种配置的信号差异

| 配置 | `fwd_a/b` | `fwd_store` | `stall` | 结果 |
| --- | --- | --- | --- | --- |
| `full` | EXMEM + MEMWB | EXMEM + MEMWB | 仅 load-use | 正确 |
| `stall_only` | 仅 MEMWB | 仅 MEMWB | 所有 RAW（ID/EX、EX/MEM 生产者） | 正确但慢 |
| `no_forward` | 全 0 | 全 0 | 仅 load-use | 距离 1 ALU 相关读旧值 |
| `no_hazard` | EXMEM + MEMWB | EXMEM + MEMWB | 永不 | 紧邻 load-use 转发地址 |

`stall_only` 的停顿条件是"生产者在 ID/EX 或 EX/MEM"，**不包括 MEM/WB**：那时再停一拍是浪费。两拍停顿后生产者在 WB、消费者在 ID，寄存器堆前半拍写入正好对上。

## NOP / 气泡编码

`0x00000013`（`addi x0, x0, 0`）是规范 NOP，也是 bubble 和 flush 后填入流水线寄存器的值。译码器对 `rd == x0` 的指令一律令 `reg_write = 0`、`uses_rs* = 0`（见 `rtl/control.v`），否则一个"NOP"会被冒险单元当成生产者/消费者，造成假停顿。这是调试时很容易忽略的一点。
