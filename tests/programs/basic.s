# 程序 1：基本算术 / 逻辑 / 立即数 / LUI / AUIPC
# 覆盖 R-type、I-type、U-type，无相关（用来确认数据通路本身正确）
.text
    addi x1, x0, 5          # x1 = 5
    addi x2, x0, 12         # x2 = 12
    add  x3, x1, x2         # x3 = 17
    sub  x4, x2, x1         # x4 = 7
    and  x5, x3, x4         # x5 = 17 & 7 = 1
    or   x6, x3, x4         # x6 = 17 | 7 = 23
    xor  x7, x3, x4         # x7 = 17 ^ 7 = 22
    sll  x8, x1, x2         # x8 = 5 << 12 = 0x5000
    srl  x9, x8, x2         # x9 = 0x5000 >> 12 = 5
    slt  x10, x1, x2        # x10 = 1
    sltu x11, x1, x2        # x11 = 1
    addi x12, x0, -1        # x12 = 0xffffffff
    slt  x13, x12, x1       # x13 = 1 (-1 < 5)
    sltu x14, x12, x1       # x14 = 0 (0xffffffff > 5)
    srai x15, x12, 3        # x15 = 0xffffffff (算术右移)
    srli x16, x12, 3        # x16 = 0x1fffffff (逻辑右移)
    lui  x17, 0x12345       # x17 = 0x12345000
    auipc x18, 0x1          # x18 = pc + 0x1000
    andi x19, x3, 7         # x19 = 1
    ori  x20, x1, 0x30      # x20 = 0x35
    xori x21, x3, 0xf       # x21 = 17 ^ 15 = 30
    slli x22, x1, 4         # x22 = 80
    ecall
