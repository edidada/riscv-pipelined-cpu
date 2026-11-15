# 程序 7：专门验证"没有 load-use 停顿就一定会错"的相邻依赖
#
#   lw   x1, 0(x2)      IF ID EX MEM WB   <- 数据 MEM 末尾才出现
#   addi x3, x1, 1      IF ID EX MEM WB   <- EX 就要用 x1
#
# 无停顿（no_hazard）时，旁路只能从 EX/MEM 拿到 lw 的"地址"，
# 结果必然是 address+1 而不是 load_value+1。
# 有一条 NOP 间隔时（距离 2），MEM/WB 旁路可以解决，无需停顿。
.data
    .word 0x0000002a        # 0x4000 -> 42
    .word 0x00000100        # 0x4004 -> 256
    .word 0xfffffffe        # 0x4008 -> -2
.text
    lui  x2, 0x4
    lw   x1, 0(x2)
    addi x3, x1, 1          # 必须停顿：期望 43
    lw   x4, 4(x2)
    add  x5, x4, x3         # 必须停顿：期望 299
    lw   x6, 8(x2)
    sub  x7, x0, x6         # 必须停顿：期望 2
    lw   x8, 0(x2)
    nop
    addi x9, x8, 7          # 距离 2：只需要 MEM/WB 旁路，无需停顿
    lw   x10, 4(x2)
    nop
    nop
    addi x11, x10, 5        # 距离 3：寄存器堆已写回
    ecall
