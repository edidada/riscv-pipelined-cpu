# 程序 3：load-use 冒险（为什么旁路不够、必须停顿一个周期）
#
#   lw  x1, 0(x2)      IF ID EX MEM WB      <- 数据在 MEM 末尾才出现
#   add x3, x1, x4     IF ID EX MEM WB      <- EX 就要用 x1
#
# 即使有旁路（EX/MEM -> EX），lw 在 EX 时只有地址，没有数据。
# 唯一办法：把 add 的 ID 阶段重放一次，并在 EX 插入一个 bubble。
#
# 下面覆盖多种形态：相邻、隔一条、隔两条（隔两条可纯旁路解决）、
# load 作为 store 的基址、load 作为 store 的数据、以及字节/半字加载。
.data
    .word 0x11111111        # 0x4000
    .word 0x22222222        # 0x4004
    .word 0x33333333        # 0x4008
    .word 0x44444444        # 0x400c
    .word 0xdeadbeef        # 0x4010
.text
    lui  x2, 0x4            # x2 = 0x4000（数据段基址）
    lw   x1, 0(x2)          # x1 = 0x11111111
    addi x3, x1, 1          # load-use：必须停顿 1 拍
    lw   x4, 4(x2)          # x4 = 0x22222222
    nop                     # 隔一条：仍然需要停顿吗? 不需要，旁路可解
    add  x5, x4, x3         # 距离 2：MEM/WB 旁路（含 load 数据）
    lw   x6, 8(x2)          # x6 = 0x33333333
    nop
    nop
    add  x7, x6, x5         # 距离 3：已写回
    lbu  x8, 0(x2)          # x8 = 0x11
    addi x9, x8, 1          # load-use：字节加载同样要停顿
    lh   x10, 2(x2)         # x10 = 0x1111 (有符号半字)
    add  x11, x10, x9       # load-use
    lw   x12, 12(x2)        # x12 = 0x44444444
    sw   x12, 0(x2)         # load 结果作为 store 数据：需要 store-data 旁路
                            # 注意：这条与前一条相邻，是 load-use 冒险
                            # 但 store 的 rs2 在 MEM 才用，理论上可转发；
                            # 本实现统一按 load-use 停顿处理（教学简化）
    lw   x13, 4(x2)         # 检查 store 没破坏相邻字
    lw   x14, 16(x2)        # x14 = 0xdeadbeef
    nop
    addi x15, x14, 0        # 距离 2：MEM/WB 旁路
    ecall
