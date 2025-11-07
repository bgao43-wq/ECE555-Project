`timescale 1ns/1ps

module piezo_drv_tb;

    //==================== 1. 信号定义 ====================
    logic clk;
    logic rst_n;
    logic en_steer;
    logic too_fast;
    logic batt_low;
    logic piezo;
    logic piezo_n;

    //==================== 2. DUT 实例化 ====================
    piezo_drv #(.fast_sim(1'b1)) dut (
        .clk       (clk),
        .rst_n     (rst_n),
        .en_steer  (en_steer),
        .too_fast  (too_fast),
        .batt_low  (batt_low),
        .piezo     (piezo),
        .piezo_n   (piezo_n)
    );

    //==================== 3. 生成时钟 ====================
    initial clk = 0;
    always #10 clk = ~clk;  // 50MHz, 20ns period

    //==================== 4. 仿真控制流程 ====================
    initial begin
        // 初始化
        rst_n     = 0;
        en_steer  = 0;
        too_fast  = 0;
        batt_low  = 0;

        #100;
        rst_n = 1;
        #100;

        

        // ===================== Case 2: en_steer =====================
        $display("[%0t] === en_steer ON ===", $time);
        en_steer = 1;
        #10_000_000;
        en_steer = 0;
        wait (dut.state == dut.IDLE);
        #100;

        // ===================== Case 3: too_fast =====================
        $display("[%0t] === too_fast ON ===", $time);
        too_fast = 1;
        #5_000_000;
        too_fast = 0;
        wait (dut.state == dut.IDLE);
        #100;
// ===================== Case 1: batt_low =====================
        $display("[%0t] === batt_low ON ===", $time);
        batt_low = 1;
        #5_000_000;   // 短暂触发
        batt_low = 0;
        // 等待 DUT 播放完毕（状态机回到 IDLE）
        wait (dut.state == dut.IDLE);
        #100;  // 给波形一点时间停稳
        // ===================== Case 4: 优先级测试 batt_low + too_fast =====================
        $display("[%0t] === batt_low + too_fast 测试 ===", $time);
        batt_low = 1;
        too_fast = 1;  // too_fast 优先
        #3_000_000;
        too_fast = 0;
        
        #10_000_000;
        batt_low = 0;
        
        wait (dut.state == dut.IDLE);
        #100;

        $display("[%0t] === 仿真结束 ===", $time);
        $finish;
    end

endmodule