# 程序 6：综合压力测试 —— 斐波那契 + 冒泡片段 + 混合冒险
# 用来对比四种配置的 CPI（naive / full / stall-only / no-stall）
.text
    addi x1, x0, 1          # fib(0)
    addi x2, x0, 1          # fib(1)
    addi x5, x0, 12         # 迭代次数
    addi x6, x0, 0          # i
fib_loop:
    add  x3, x1, x2         # 相关：x1/x2 来自上两次迭代
    addi x1, x2, 0
    addi x2, x3, 0
    addi x6, x6, 1
    blt  x6, x5, fib_loop
    nop
    nop
    sw   x3, 0(x0)          # 地址 0，越界忽略
    lw   x7, 0(x0)          # 越界读回 0
    addi x8, x7, 1          # load-use 停顿
    add  x9, x8, x3         # 相关
    sll  x10, x9, x6
    srai x11, x10, 3
    xor  x12, x11, x3
    slt  x13, x12, x2
    beq  x13, x0, skip
    addi x14, x0, 77        # 应被 flush（若 x13 == 0）
skip:
    addi x15, x12, 1
    jal  x16, sub1
    jal  x0, done
sub1:
    addi x17, x15, 2
    jalr x0, x16, 0
done:
    add  x18, x17, x15
    lui  x19, 0x2
    auipc x20, 0x0
    add  x21, x19, x20
    ecall
