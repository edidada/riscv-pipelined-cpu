# 程序 2：ALU->ALU 数据相关（RAW），这是"旁路为什么存在"的核心
#
# 每条 add 的结果都要到 WB 才写回寄存器堆，但下一条指令在 EX 就要用它。
# 没有 forwarding 时，下面的链条会读到旧值（全部为 0）。
#
#   add x1,x0,1     IF ID EX MEM WB
#   add x2,x1,x1    IF ID EX MEM WB   <- EX 需要 x1，x1 此时还在 MEM
#   add x3,x2,x2    IF ID EX MEM WB
#
.text
    addi x1, x0, 1
    add  x2, x1, x1        # 距离 1：需要 EX/MEM 旁路
    add  x3, x2, x2        # 距离 1：需要 EX/MEM 旁路
    add  x4, x3, x1        # 两个操作数分别距离 1 和 3
    add  x5, x4, x2        # 距离 1 和 3
    nop
    add  x6, x5, x5        # 距离 2：需要 MEM/WB 旁路
    nop
    nop
    add  x7, x6, x1        # 距离 3：此时已写回，无需旁路
    sub  x8, x7, x3        # 混合 SUB
    add  x9, x0, x8        # rs1 = x0 必须不被旁路
    add  x10, x9, x0       # rs2 = x0 必须不被旁路
    ecall
