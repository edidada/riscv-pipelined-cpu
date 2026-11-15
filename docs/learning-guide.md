# Verilog 是干什么的 & 自学路线（面向自学 / 就业视角）

> 本文服务于本仓库：你已经（或即将）用 Verilog 写出一个五级流水线 CPU，然后自然会问——**这东西在真实世界处在什么位置、接下来该学什么、学完能去哪儿**。
>
> 定位：一份带方向的索引，不是百科全书。书籍版本、平台功能会变，文中标注了"以官网为准"；本次未能联网核验的部分明确标注，不冒充事实（见第 7 节）。

---

## 1. Verilog 到底是什么：先纠正三个自学最常见的误解

### 1.1 它不是"写程序"，是"描述电路"

C/Python 描述的是**一条条按时间先后执行的指令**，目标是让 CPU 跑起来。
Verilog/SystemVerilog 是 **HDL（Hardware Description Language，硬件描述语言）**，描述的是**一堆同时存在的电路元件和它们之间的连线**，目标是生成一张网表（netlist），最后变成硅片上的门电路或 FPGA 里的查找表/LUT。

```verilog
// 这两条 always 块在物理上是两块同时工作的电路，
// 不存在"先执行哪个"的问题 —— 这是初学者最大的思维坎
always @(posedge clk)  a <= a + 1;   // 一个加法器 + 一组触发器
always @(posedge clk)  b <= b ^ a;   // 另一个寄存器 + 异或门，和上一块并行
```

由此推出三条铁律：

| 误解 | 真相 |
| --- | --- |
| "`<=` 就是赋值，和 `=` 差不多" | `<=` 是非阻塞赋值，描述**触发器**；`=` 是阻塞赋值，常用于组合逻辑。混用会产生仿真/综合不一致，这是面试必考题 |
| "for 循环就是循环执行" | 可综合的 for 是**把同一份电路复制 N 份**（生成 N 个加法器），不是串行执行 N 次 |
| "仿真过了就能上板" | 仿真（simulation）只验证你写的 RTL 行为；综合（synthesis）才把它变成门电路。两者语义不同（X 值、初始化、延迟 `#`、不可综合语句），必须分开验证 |

### 1.2 它在整个链条里的位置

```
需求/架构 (ISA、微架构、性能功耗面积 PPA)
      ↓
RTL 设计  ← ★ Verilog / SystemVerilog / VHDL 在这里
      ↓  功能仿真 (Icarus / Verilator / Questa / VCS / Xcelium)
      ↓  形式验证 (formal: SymbiYosys / Jasper / VC Formal)
      ↓  逻辑综合 (Design Compiler / Genus / Vivado / Yosys)
      ↓  布局布线 P&R / 时序收敛 STA / DFT / 物理验证
      ↓  流片 (ASIC) 或 生成比特流 (FPGA)
      ↓  硅后验证 / 原型验证 (Palladium / Zebu / HAPS / FPGA 原型)
```

同一份 Verilog 有两个完全不同的用途：

- **可综合 RTL（design）**：要变成真实电路，占整个链条最上游一小段。
- **验证平台（testbench / verification）**：不变成电路，只在仿真里产生激励、比对结果。**本仓库的 `tb/cpu_tb.v` 就是这一半。**

> 一个重要且常被自学者忽略的事实：工业界里**验证工程师数量通常多于设计工程师**，UVM/SystemVerilog 验证、形式验证、仿真加速是独立的大方向。你写的 `cpu_tb.v` 里"逐条比对参考解释器"的思路，本质上就是最朴素的 scoreboard + reference model，和工业界验证方法学是同一件事的简化版。

### 1.3 Verilog、SystemVerilog、VHDL 的关系（别选错起手式）

| 语言 | 定位 | 建议 |
| --- | --- | --- |
| **Verilog (IEEE 1364)** | 1984 年起，最后一个独立标准是 **1364-2005**。语法简洁、资料极多 | 适合入门；本仓库用的就是它（`-g2012` 兼容模式） |
| **SystemVerilog (IEEE 1800)** | Verilog 的超集，2005 年后**合并进 1800**，加了 `logic`、interface、assertion (SVA)、class、约束随机、覆盖率、UVM 基础 | **工业界设计和验证的主流**。学会 Verilog 后必须转 |
| **VHDL (IEEE 1076)** | 欧洲/航空/军工/部分老项目更常见，强类型、冗长 | 不必先学；遇到再补 |
| 其他 | Chisel / SpinalHDL（Scala 生成 Verilog）、HLS（C++ 综合）、Bluespec、TL-Verilog | 进阶，先别碰 |

**结论**：从这个仓库的 Verilog 起步是对的，但要把"Verilog 2001 风格的 `reg`/`wire`"当作跳板，尽快补 SystemVerilog 的 `logic`、always_comb/always_ff、SVA、interface。

### 1.4 那 CPU 设计属于哪一块？

属于**数字前端设计（digital front-end / RTL design）** 中最硬核的一支：**处理器微架构**。核心技能不是"会写 always 块"，而是：

- 时序、流水线、冒险、旁路、分支预测、乱序执行、缓存一致性、总线协议（AXI/CHI/TileLink）；
- 用 **PPA（Performance / Power / Area）** 和 **IPC、频率、时序收敛** 衡量设计，而不是"功能对不对"；
- 与验证、物理设计、编译器、软件栈协同。

本仓库的五级流水线 + forwarding + stall 正是这个领域的**入门第一课**：它把"时序"和"并发"从抽象概念变成了 `pc_write`/`if_id_hold`/`id_ex_bubble` 三个具体信号。

---

## 2. 国内外教学书籍

### 2.1 国外经典（按阅读顺序）

| 书 | 作者 / 出版社 | 干什么用 | 备注 |
| --- | --- | --- | --- |
| **Digital Design and Computer Architecture** | Harris & Harris, Morgan Kaufmann | **最佳单本起点**：从门电路 → 组合/时序 → 汇编 → 单周期/流水线 MIPS/RISC-V 处理器，HDL 与体系结构一起讲 | 有 RISC-V 版与 MIPS 版，别买错。和本仓库内容几乎一一对应 |
| **Computer Organization and Design: The Hardware/Software Interface** | Patterson & Hennessy, Morgan Kaufmann | 体系结构"圣经"，流水线章节（冒险、转发、停顿）是本项目 README 引用的那章 | 偏原理，HDL 少；配合前一本看 |
| **Computer Architecture: A Quantitative Approach** | Hennessy & Patterson | 进阶：流水线深度、分支预测、乱序、多级缓存、存储墙、向量/SIMD、多核 | 工作 1–2 年后再读，自学阶段别硬啃 |
| **Verilog HDL** | Samir Palnitkar, Prentice Hall | 纯语言语法参考，例子多 | 当字典用，不必通读 |
| **RTL Modeling with SystemVerilog for Simulation and Synthesis** | Stuart Sutherland | 讲清"什么能综合、什么不能"，专治仿真/综合不一致 | 从 Verilog 转 SV 的最佳桥 |
| **SystemVerilog for Verification** | Chris Spear & Greg Tumbush | UVM/验证方向入门 | 想走验证岗必读 |
| **Digital Design and Computer Architecture: RISC-V Edition** 实验配套 | — | 若配合 Harris 的 lab，可直接对照本仓库 | — |

> 版本提示：Patterson & Hennessy 与 Harris & Harris 都已出到多版且有 RISC-V 版，购买时认准 **RISC-V Edition**；具体版次以出版社官网为准。

### 2.2 中文教材 / 国内课程

| 资料 | 说明 |
| --- | --- |
| **《计算机组成与设计：硬件/软件接口》（RISC-V 版）** | Patterson & Hennessy 中文译本，机械工业出版社。国内高校"计组"主流参考 |
| **《数字逻辑与计算机组成》/《计算机组成原理》** | 国内计组教材（唐朔飞、白中英、袁春风等版本），偏概念与考试，HDL 实践少，适合补术语 |
| **《Verilog HDL 程序设计教程》/《Verilog 数字系统设计教程》（夏宇闻）** | 国内最经典的 Verilog 入门书，语法 + 实例，老派但覆盖面广 |
| **清华大学《数字逻辑设计》、国防科大/哈工大/上交的"计算机组成原理"实验课** | 很多已公开实验讲义与开源实验框架；国内大量高校用 MIPS/RISC-V 五级流水线做课程设计，和本仓库同一难度带 |
| **"一生一芯"（中国科学院计算技术研究所 / 国科大）** | 国内非常有影响力的开源芯片设计自学/培养计划：从零写 RTL、跑 Linux、流片。公开课程 slides 与实验素材，**是自学者从"写个 CPU"走向"能跑操作系统的 SoC"最贴近的路径** |
| **RISC-V 中文社区、CNRV、openEuler/香山相关公开材料** | 中文社区译文与工程博客；香山（XiangShan）是国产开源高性能 RISC-V 核，公开文档/代码适合进阶阅读 |

> 国内教材普遍**重概念、轻工程验证**。补上这一环最有效的办法，恰恰就是本仓库在做的事：写自校验 testbench、跨配置回归、CI 自动跑。

### 2.3 免费 / 开源教程（英文，质量很高）

| 资源 | 内容 |
| --- | --- |
| **HDLBits**（已核验） | 浏览器里的 Verilog 小型电路练习集，提交后**用测试向量仿真并与参考解比对、即时判分**；分 Getting Started / Verilog Language / Combinational Logic / Sequential Logic / Reading Simulations 等主题，站内直接提供 Icarus Verilog 仿真。同站还有 ASMBits（汇编）与 CPUlator（Nios II / ARMv7 / MIPS 模拟器） |
| **ZipCPU 教程**（已核验） | Gisselquist Technology 的 FPGA/RTL 博客与 **Formal Training 形式验证教程 + Quizzes**，讲 AXI、跨时钟域、DDR 控制器、形式验证等真实坑，进阶极佳 |
| **fpga4fun**（已核验） | 从点 LED 到 PCI Express / HDMI / SDRAM 的动手项目，含 Verilog tips、CDC、ISE/Quartus 快速上手 |
| **EDA Playground**（已核验） | Doulos 出品的浏览器 HDL 环境，支持 SystemVerilog/Verilog、VHDL、UVM、Python+SV 等，可选免费与商用仿真器（商用需注册/批准邮箱），适合随手试语法、分享可复现链接 |
| **Nandland** | FPGA 入门（NAND 到 Verilog），常与 HDLBits 一起推荐 |
| **ChipVerify / Verification Guide** | SystemVerilog、UVM 语法与面试向速查 |
| **MIT 6.004 / 6.823、UCB CS61C、CMU 18-447、ETH "Digital Design and Computer Architecture"** | 公开课，CS61C 的 RISC-V 项目与本仓库几乎同构 |

---

## 3. 学习路线（自学，按"能产出作品"划分阶段）

> 原则：**每个阶段都要有一个能跑、能自测、能放进 GitHub 的东西**。不要停留在"看懂了"。你现在的仓库已经是阶段 2 的成品。

### 阶段 0 · 工具与心智（1–2 周）

- 装 **Icarus Verilog + GTKWave**（本仓库已用，见 `docs/howto.md`）；再加 **Verilator**（快、lint 严格）、**Yosys**（开源综合）、**SymbiYosys**（形式验证）。
- 在 **HDLBits** 把 Verilog Language + Combinational + Sequential 前几节刷完，建立"always 块 = 电路"的直觉。
- 搞清三个区别：阻塞/非阻塞、`reg`/`wire`（以及 SV 的 `logic`）、仿真 vs 综合。
- 产出：一个 LED 闪烁 / 计数器 + testbench + 波形截图。

### 阶段 1 · 组合与时序电路（2–4 周）

- 多路选择器、译码器、加法器、ALU、优先编码器；FSM（序列检测、交通灯）、FIFO、跨时钟域（CDC：两级同步器、握手、异步 FIFO）。
- 学会写 testbench：时钟/复位、激励、自动比对（`$display` + 自检），而不是只看波形。
- 产出：一个带自检 testbench 的 ALU + FSM 小项目。

### 阶段 2 · 单周期 / 流水线 CPU（4–8 周）★ 你在这里

- 单周期 → 五级流水线 → **冒险 / 停顿 / 旁路 / flush** → 分支 → Cache 初探。
- 本仓库已完成的部分：RTL、汇编器、参考解释器、跨配置回归、三平台 CI、5 个可复现实验（`tools/exercises.py`）。
- 下一步可加（难度递增）：分支预测（BTB/BHT）、例外与中断、乘法器/除法器、AXI-Lite 或 TileLink 总线、指令/数据 Cache、多级流水线、简易乱序（scoreboard / Tomasulo）。
- 产出：本仓库 + 一份记录 CPI/面积/频率变化的 README。

### 阶段 3 · 上板 & SoC（1–3 个月）

- 买一块便宜 FPGA 板（国内常见的 FPGA 入门板、或基于 iCE40 / ECP5 / Artix-7 的开源友好板卡均可），把 CPU 综合、时序收敛、接 UART / VGA / GPIO / SPI。
- 用 **Yosys + nextpnr** 走完整开源 FPGA 流程（不依赖厂商 IDE），或 Vivado / Quartus 走工业流程。
- 理解约束文件（XDC/SDC）、时序报告、建立/保持时间、CDC 报告。
- 产出：CPU 在板上跑程序、串口打印结果；能解释时序报告里的 WNS/TNS。

### 阶段 4 · 工业级设计与验证（3–6 个月）

- 转 **SystemVerilog**：`always_ff`/`always_comb`、interface、package、enum、struct。
- 验证方向：UVM（driver/monitor/scoreboard/sequence、factory、config db）、功能覆盖率、约束随机、断言 SVA；形式验证（SymbiYosys / 等价性检查）。
- 设计方向：AMBA **AXI/ACE/CHI**、低功耗（clock gating / power domain / UPF）、DFT（scan、BIST）、时序收敛、CDC/RDC。
- 读真实开源核：**Ibex / CV32E40P、CVA6 (Ariane)、Rocket Chip / Chipyard、BOOM、香山 XiangShan、OpenTitan、PicoRV32 / VexRiscv / NEORV32**。这些是"国内外最先进公司应用场景"最直接的公开参照物。
- 产出：给现有 CPU 加一个 AXI 接口 + 一个 UVM/SVA 验证环境，或一个形式验证证明（例如证明流水线控制不会死锁）。

### 阶段 5 · 选定方向深挖

| 方向 | 要补的东西 | 典型岗位 |
| --- | --- | --- |
| 处理器微架构 / CPU IP | 乱序、分支预测、缓存一致性、虚拟化、性能建模、编译器协同 | CPU Architect / RTL Design Engineer |
| 前端设计（通用数字 IP） | 高速接口、SerDes 数字侧、总线、低功耗、时序收敛 | Digital Design Engineer / FPGA Engineer |
| 验证 | UVM、形式验证、覆盖率收敛、仿真加速、emulation | DV Engineer / Formal Verification Engineer |
| 物理设计 / 后端 | 综合、P&R、STA、CTS、DFM、IR drop | Physical Design / STA Engineer |
| FPGA / 原型 / 加速 | HLS、原型平台、软硬件协同、PCIe/DDR | FPGA / Prototyping Engineer |
| 体系结构与研究 | 加速器（AI/DSA）、存内计算、Chiplet、RISC-V 扩展 | Research / Architecture |

---

## 4. 练手平台与工具清单

### 4.1 在线刷题 / 立刻能跑（零安装）

| 平台 | 特点 |
| --- | --- |
| **HDLBits** | 已核验：浏览器写 Verilog、提交即仿真比对参考解、即时反馈；含 Icarus Verilog 在线仿真入口；配套 ASMBits / CPUlator |
| **EDA Playground** | 已核验：Doulos 提供，浏览器里可选多种免费/商用仿真器，支持 SV/Verilog/VHDL/UVM/Python+SV，方便分享可复现链接 |
| **HackerRank / LeetCode 的 Verilog 题区** | 题量少，适合碎片时间，别当主线（可用性以官网为准） |
| **CPUlator / ASMBits** | HDLBits 同站，练汇编与 CPU 模拟器，配合计组课程 |

### 4.2 本地开源工具链（本仓库已用前两个）

| 工具 | 用途 | 备注 |
| --- | --- | --- |
| **Icarus Verilog + GTKWave** | 仿真 + 看波形 | 本仓库 CI 三平台都装它（Windows/choco 11.0、Ubuntu/apt 12.x、macOS/brew 13.0，见 `README.md`） |
| **Verilator** | 把 RTL 编译成 C++ 高速仿真，lint 极严 | 工业界常用；严格模式能抓出 Icarus 放过的坑 |
| **Yosys** | 开源综合（RTL → 门级网表） | 配 nextpnr 可跑完整开源 FPGA 流程 |
| **SymbiYosys / yosys-smtbmc** | 开源形式验证 | 证明"控制逻辑不会死锁/不会丢指令"，比仿真的覆盖更强 |
| **GTKWave / Surfer / WaveTrace** | 波形查看 | VCD/FST |
| **Vivado / Quartus / Questa / VCS / Xcelium / Verdi** | 厂商/商用全流程 | 个人通常用免费版或公司授权；自学不必一开始碰 |
| **cocotb / VUnit / UVVM / OSVVM** | Python 或 SV 的验证框架 | cocotb 用 Python 写 testbench，自学者容易上手 |
| **GitHub Actions** | 回归自动化 | 本仓库已示范：三 OS × 28 组仿真 + 5 个实验，push 即跑 |

### 4.3 开源项目 / 竞赛 / 社区

- **开源 RISC-V 核**：PicoRV32（极简，适合读第一行）、NEORV32、VexRiscv、Ibex、CVA6、Rocket/BOOM（Chipyard）、香山 XiangShan（国产高性能）、OpenTitan（安全芯片，完整验证方法学范本）。
- **"一生一芯"**（中科院/国科大）：国内最贴近"自学 → 能跑 Linux 的芯片 → 流片"的公开路径。
- **竞赛 / 活动**：国内 FPGA/集成电路设计竞赛、集创赛、RISC-V 相关开源活动；国外 **Google/SkyWater OpenMPW / TinyTapeout / ChipIgnite**（低成本或免费 shuttle 流片，TinyTapeout 尤其适合个人提交小设计）。可用性以各项目官网为准。
- **开源流片生态**：SkyWater 130nm / GlobalFoundries 180nm 开源 PDK、OpenROAD / OpenLane 全自动 RTL-to-GDS 流程——自学也能走完"RTL → GDSII"全链条。

---

## 5. 国内外最先进公司的真实应用场景

> 这一节只描述**公开、可推断的行业分工**，避免编造具体公司内部项目。判断依据：各家公开的产品形态、招聘岗位、开源贡献、公开论文与 ISA/接口标准。个别细节请以公司官网/招聘页为准。

### 5.1 共同事实：Verilog/SV 用在哪，不用在哪

- **用**：CPU/GPU/NPU/ISP/DDR-PCIe 控制器等自研 IP 的 RTL、SoC 集成与总线矩阵、FPGA 原型与仿真加速、验证环境（UVM/SVA/形式验证）、DFT 插入、FPGA 产品逻辑。
- **不用**：写驱动/固件/编译器/上层软件（那些是 C/C++/Rust/汇编）；模拟电路（用 SPICE/原理图）；算法原型（先 Python/ MATLAB）；物理版图（用后端工具与 PDK）。

### 5.2 国外（公开产品形态）

| 公司类型 | 代表（举例） | 用 HDL 做什么 | 值得自学者关注的点 |
| --- | --- | --- | --- |
| 自研 CPU/SoC | Apple、Qualcomm、AMD、Intel、Arm、Samsung、NVIDIA、Google(Tensor/TPU 相关) | 高性能乱序核、缓存一致性互连、GPU/NPU 阵列、内存控制器、ISP、定制加速器 | 他们的公开论文/招聘 JD 就是"阶段 5"的路线图：分支预测、一致性协议、PPA 权衡、验证覆盖率 |
| FPGA 厂商 | AMD(Xilinx)、Intel(Altera)、Lattice、Microchip | FPGA 架构本身的硅设计 + 客户侧的原型/加速逻辑 + HLS 工具链 | 开源 Yosys/nextpnr 支持的正是 Lattice iCE40/ECP5 一类器件 |
| EDA / IP | Synopsys、Cadence、Siemens EDA、Arm (IP)、Imagination、Rambus | 仿真器/综合器/形式验证工具本身、可授权 IP 核、验证 IP (VIP)、UVM 方法学 | 验证岗需求量常大于设计岗；UVM/SVA/formal 是硬门槛 |
| 云 / 超大规模 | AWS、Microsoft、Meta、Google | 自研加速芯片（AI 推理/训练、视频转码、DPU/IPU、智能网卡）、FPGA 加速卡 | 软硬协同、PCIe/CXL、HBM、DSA；通常要求"能定义架构"而不只是写 RTL |
| IP/开源生态 | SiFive、Andes、Codasip、lowRISC、OpenHW Group、CHIPS Alliance | RISC-V 核与 SoC 平台、开源验证方法学 | 这些组织的开源仓库（Ibex/CVA6/OpenTitan/Chipyard）是自学能直接读到的"工业级 RTL" |

### 5.3 国内（公开产品形态）

> 下表里的公司名称只是**行业场景举例**（依据各家公开的产品形态与招聘岗位归类），不是逐家公司核实的官方陈述，也不代表其内部项目细节；以公司官网/招聘页为准。

| 公司类型 | 代表（举例） | 用 HDL 做什么 | 值得自学者关注的点 |
| --- | --- | --- | --- |
| CPU / 处理器 IP | 华为海思、龙芯、飞腾、兆芯、平头哥，以及众多 RISC-V IP 厂商；香山（XiangShan）开源高性能核 | 从嵌入式 MCU 核到高性能乱序核、多核互连、Cache 一致性 | 香山与"一生一芯"是中文世界里最透明的进阶教材 |
| AI / 加速芯片 | 寒武纪、壁仞、摩尔线程、燧原、地平线、黑芝麻等 NPU/GPU 公司 | 脉动阵列/向量单元、片上网络 NoC、HBM/DDR 控制器、数据搬运 DMA、互联 | 需要懂体系结构和编译器栈，不只是 RTL |
| 通信 / 消费电子 SoC | 紫光展锐，以及手机 SoC、基站芯片、图像 ISP、视频编解码、显示驱动厂商 | ISP、VPU、高速 SerDes 数字侧、DDR/LPDDR 控制器、低功耗电源域 | 国内岗位量最大的方向之一，重 CDC、低功耗、时序收敛 |
| 制造 / 封测 / EDA | 中芯国际等制造企业，国产 FPGA 厂商（复旦微、紫光同创等）、国产 EDA 与 IP 公司 | 制造侧偏工艺与 PDK；FPGA 架构与工具链；综合/STA/形式验证工具、接口 IP | 国产 EDA 是明确的产业方向，验证/STA/形式化人才稀缺 |
| 汽车电子 / 工业 / 存储 | 车规 MCU、SSD 控制器、功率/电机控制芯片厂商 | 高可靠 RTL、功能安全 (ISO 26262 流程)、锁步核、ECC、DFT | 重流程与验证完备性，适合喜欢严谨验证的人 |

### 5.4 对自学者最有用的三个判断

1. **"会写 RTL"只是入场券**：工业界真正稀缺的是能收敛时序、能写出完备验证环境、能解释 PPA 取舍的人。本仓库里 `cpu_tb.v` 的自校验 + 跨配置回归 + CI，比"多实现一个指令"更接近真实工作。
2. **验证岗是更宽的入口**：岗位多、对"从零写过 CPU"的容忍度更高、成长路径清晰（UVM → formal → emulation）。如果目标是尽快就业，别把所有时间都花在加流水线级数上。
3. **RISC-V 是自学者最好的杠杆**：ISA 开放、开源核与开源工具链（Icarus/Yosys/Verilator/SymbiYosys/OpenLane）完整、国内产业与教材都在向它迁移。你把本仓库做完，读 Ibex / CVA6 / 香山的代码不会有门槛——这正是"国内外最先进公司在做的事"的公开入口。

---

## 6. 和本仓库的对应关系（学完这段该往哪走）

| 你在这里学到的 | 对应工业界的概念 | 下一步 |
| --- | --- | --- |
| `defs.vh` / 控制信号束 | 微架构文档、decode table | 改成 SystemVerilog `package` + `enum` |
| 五级流水线寄存器 | 时序路径、流水线级数与频率权衡 | 加时序约束，跑 STA，看 WNS |
| forwarding / stall / flush | 数据与控制冒险、IPC 损失 | 分支预测、乱序发射 |
| `cpu_tb.v` 逐条比对 `ref.trace` | reference model + scoreboard | cocotb / UVM / SVA / 形式验证 |
| `run_tests.py` 7×4 矩阵 | 回归测试、配置覆盖、CI/CD | 覆盖率驱动验证、随机约束测试 |
| `.github/workflows/ci.yml` 三 OS | 可复现构建、跨版本兼容（Icarus 11/12/13） | 加入 lint（Verilator）、综合（Yosys）、formal |
| `tools/exercises.py` 的"改坏再验证" | fault injection / mutation testing | 故意注入 bug 检验验证环境是否抓得住 |

---

## 7. 核验与免责说明

- **已联网核验（本文写作时）**：[HDLBits](https://hdlbits.01xz.net/wiki/Main_Page)（浏览器 Verilog 练习、测试向量比对、站内 Icarus 仿真、主题分类）、[EDA Playground](https://www.edaplayground.com/)（Doulos、浏览器仿真器、SV/Verilog/VHDL/UVM 支持、商用仿真器需注册）、[ZipCPU](https://zipcpu.com/)（FPGA 博客、Formal Training、Quizzes、AXI/跨时钟域等主题）、[fpga4fun](https://www.fpga4fun.com/)（从 LED 到 PCIe 的动手项目与 Verilog tips）。
- **基于公开常识但本次未能逐条联网核验**：书籍具体版次/ISBN、公司具体内部项目、免费流片计划与竞赛的当期名额、HackerRank/LeetCode 题区现状、各开源核的当前版本状态。这些信息变化快，请以出版社、公司招聘页、项目官网为准。
- 关于"最先进公司应用场景"，本文只描述**可由公开产品形态与招聘岗位推断的行业分工**，不涉及任何公司内部未公开信息。

> 一句话收尾：这个仓库让你把"流水线冒险"从名词变成信号；接下来把**验证、时序、SystemVerilog、上板**补上，就能把"会写 Verilog"变成"能交付 RTL"。

---

## Sources

- [HDLBits — Verilog Practice](https://hdlbits.01xz.net/wiki/Main_Page)
- [EDA Playground](https://www.edaplayground.com/)
- [The ZipCPU by Gisselquist Technology](https://zipcpu.com/)
- [fpga4fun.com — where FPGAs are fun](https://www.fpga4fun.com/)
