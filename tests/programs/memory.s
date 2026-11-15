# 程序 5：存储器冒险与数据转发
# 覆盖 sw/sh/sb 字节序、store -> load 转发（同一地址）、
# store 的操作数旁路、以及地址计算中的 load-use。
.data
    .word 0x00000000        # 0x4000
    .word 0x00000000        # 0x4004
    .word 0x00000000        # 0x4008
    .word 0xaabbccdd        # 0x400c
.text
    lui  x1, 0x4            # x1 = 0x4000
    addi x2, x0, 0x234      # 12 位立即数范围内
    sw   x2, 0(x1)          # dmem[0x4000] = 0x00000234
    lw   x3, 0(x1)          # x3 = 0x234（紧邻 store，无需停顿，内存同一拍可见）
    addi x4, x3, 1          # load-use 停顿
    sw   x4, 4(x1)          # dmem[0x4004] = 0x235
    lbu  x5, 0(x1)          # x5 = 0x34（小端低字节）
    lbu  x6, 1(x1)          # x6 = 0x02
    lhu  x7, 0(x1)          # x7 = 0x0234
    lb   x8, 3(x1)          # x8 = 0x00
    lhu  x9, 12(x1)         # x9 = 0xccdd
    lhu  x10, 14(x1)        # x10 = 0xaabb
    lb   x11, 15(x1)        # x11 = 0xffffffaa（有符号）
    lbu  x12, 15(x1)        # x12 = 0xaa（无符号）

    addi x13, x0, 0x5a
    sb   x13, 8(x1)         # 字节写
    lbu  x14, 8(x1)         # x14 = 0x5a
    addi x15, x0, 0x789
    sh   x15, 10(x1)        # 半字写（地址 0x400a, 2 字节对齐）
    lhu  x16, 10(x1)        # x16 = 0x0789

    # store 数据来自紧邻前一条 ALU 指令：需要 EX/MEM -> EX 的 store-data 旁路
    add  x17, x3, x4
    sw   x17, 0(x1)
    lw   x18, 0(x1)         # x18 = 0x235 + 0x234 = 0x469

    # 地址来自紧邻 load：需要停顿
    lw   x19, 4(x1)
    lw   x20, 0(x19)        # 以 x19 的值作为地址（越界读回 0，可观察停顿）
    ecall
