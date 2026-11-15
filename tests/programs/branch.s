# 程序 4：控制冒险 —— 分支在 EX 才出结果，取进来的两条错误路径指令
# 必须被 flush（控制信号清零），不能写寄存器 / 不能写内存。
#
# 同时覆盖：taken / not-taken、beq/bne/blt/bge/bltu/bgeu、
# jal 链接地址、jalr 返回、以及一个用循环累加的小程序。
.text
    addi x1, x0, 3
    addi x2, x0, 3
    addi x3, x0, 0         # x3 用作"错误路径是否被写入"的哨兵

    beq  x1, x2, taken     # taken：跳过下面两条
    addi x3, x0, 111       # 这两条应该被 flush，x3 必须仍为 0
    addi x3, x0, 222
taken:
    addi x4, x0, 7         # x4 = 7

    bne  x1, x2, bad       # not taken
    addi x5, x0, 8         # x5 = 8
bad:
    blt  x1, x2, bad2      # not taken (3 < 3 false)
    addi x6, x0, 9         # x6 = 9
bad2:
    bge  x2, x1, ge_ok     # taken
    addi x7, x0, 10        # 应被 flush
ge_ok:
    addi x7, x0, 11        # x7 = 11

    addi x8, x0, -1        # x8 = 0xffffffff
    addi x9, x0, 1
    bltu x9, x8, u_ok      # taken (1 < 0xffffffff)
    addi x10, x0, 12       # 应被 flush
u_ok:
    bgeu x8, x9, uge_ok    # taken
    addi x11, x0, 13       # 应被 flush
uge_ok:
    addi x12, x0, 0        # 循环累加器

    jal  x13, loop         # x13 = pc+4（链接地址）
    jal  x0, after
loop:
    addi x12, x12, 1
    blt  x12, x1, loop     # 循环 3 次
    jalr x0, x13, 0        # 返回到 after
after:
    addi x14, x12, 100     # x14 = 103
    ecall
