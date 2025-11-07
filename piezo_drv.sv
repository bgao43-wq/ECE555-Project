module piezo_drv #(
    parameter bit fast_sim = 1'b1  // 仿真加速参数，1=加速，0=正常
)(
    input  logic clk,        // 50MHz 时钟
    input  logic rst_n,      // 异步低有效复位
    input  logic en_steer,   // “正常骑行”触发信号（最低优先级）
    input  logic too_fast,   // “速度过快”触发信号（最高优先级）
    input  logic batt_low,   // “低电量”触发信号（第二优先级）
    output logic piezo,      // 蜂鸣器差分输出正
    output logic piezo_n     // 蜂鸣器差分输出负
);

    //============================================================
    // 1. 音符频率与持续时间定义（来自 PDF）
    //============================================================
    // 6 个音符的频率（Hz）
    localparam int FREQ[6] = '{1568, 2093, 2637, 3136, 2637, 3136};

    // 每个音符对应的持续时钟周期数（PDF: 2^23 等）
    localparam longint DUR_CLKS[6] = '{
        8_388_608,   // G6
        8_388_608,   // C7
        8_388_608,   // E7
        12_582_912,  // G7 (2^23 + 2^22)
        4_194_304,   // E7 (2^22)
        33_554_432   // G7 (2^25)
    };

    //============================================================
    // 2. 仿真加速步长
    //============================================================
    // fast_sim=1 时，计数器步长为 64；
    // fast_sim=0 时，计数器步长为 1；
    localparam int INCR = fast_sim ? 64 : 1;

    //============================================================
    // 3. 3秒定时器（控制播放间隔）
    //============================================================
    localparam longint CYCLES_3SEC = 150_000_000; // 3s * 50MHz
    logic [31:0] repeat_cnt;   // 3秒计数器
    logic repeat_done;         // 完成标志

    //============================================================
    // 4. 状态机定义
    //============================================================
    typedef enum logic [2:0] {
        IDLE,       // 0: 静音等待
        PLAY,       // 1: 正在播放
        WAIT_3SEC   // 2: 播放后等待3秒
    } state_t;

    state_t state, next_state; // FSM 状态寄存器

    //============================================================
    // 5. 状态寄存器 (FSM 时序逻辑)
    //============================================================
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            state <= IDLE;
        else
            state <= next_state;
    end

    //============================================================
    // 6. 状态机组合逻辑（状态转移条件）
    //============================================================
    logic [3:0] note_idx;   // 当前音符索引（0~11）
    logic reverse;          // 是否倒放（batt_low 模式）
    logic note_done;        // 当前音符播放完成信号
    logic last_note;        // 当前序列的最后一个音符标志
    logic [1:0] mode;       // 锁存的播放模式

    always_comb begin
        next_state = state; // 默认保持当前状态
        reverse    = 1'b0; // 默认不倒放

        case (state)
            IDLE: begin
                // 检查优先级：too_fast > batt_low > en_steer
                if (too_fast) begin
                    next_state = PLAY;
                    reverse    = 1'b0; // 正放 (mode 将被锁存为 FAST)
                end else if (batt_low) begin
                    next_state = PLAY;
                    reverse    = 1'b1; // 倒放 (mode 将被锁存为 BATT)
                end else if (en_steer) begin
                    next_state = PLAY;
                    reverse    = 1'b0; // 正放 (mode 将被锁存为 STEER)
                end
            end

            PLAY: begin
                // 【修复】必须同时检查 note_done 和 last_note
                // 否则会在最后一个音符刚开始时就跳走
                if (note_done && last_note)
                    // 【修复】重新检查 'too_fast' 信号 (live)，
                    // 允许 'too_fast' 模式循环
                    next_state = too_fast ? PLAY : WAIT_3SEC;
            end

            WAIT_3SEC: begin
                // 【修复】too_fast 必须有最高优先级，可以立即中断等待
                if (too_fast)
                    next_state = PLAY;
                else if (repeat_done)
                    next_state = IDLE; 
            end
        endcase
    end

    //============================================================
    // 7. 3秒重复定时器逻辑
    //============================================================
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n || state == IDLE)
            repeat_cnt <= '0;
        else if (state == WAIT_3SEC)
            repeat_cnt <= repeat_cnt + INCR;
        else
            repeat_cnt <= '0; // 在 PLAY 状态时也清零
    end
    assign repeat_done = (repeat_cnt >= CYCLES_3SEC - 1);

    //============================================================
    // 8. 播放模式 (Mode) 和音符索引 (note_idx) 控制
    //============================================================
    
    // 模式定义
    localparam MODE_STEER = 2'd0; // 0=en_steer (播放 0-5)
    localparam MODE_BATT  = 2'd1; // 1=batt_low (播放 6-11)
    localparam MODE_FAST  = 2'd2; // 2=too_fast (播放 0-2 循环)

    // 模式锁存器 (Latch)
    // 在 FSM 从 IDLE -> PLAY 的瞬间，锁存当前的播放模式
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            mode <= MODE_STEER;
        else if (state == IDLE && next_state == PLAY) begin
            if (too_fast)      mode <= MODE_FAST;
            else if (batt_low) mode <= MODE_BATT;
            else               mode <= MODE_STEER;
        end
    end

    // 'last_note' 判断逻辑 (组合)
    // 根据锁存的 'mode'，判断 'note_idx' 是否到达了序列的末尾
    assign last_note = (mode == MODE_FAST) ? (note_idx == 4'd2) :
                       (mode == MODE_BATT) ? (note_idx == 4'd11) :
                                             (note_idx == 4'd5);

    // 音符索引 (note_idx) 计数器
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            note_idx <= 4'd0;
        else if (state == IDLE && next_state == PLAY) begin
            // 刚进入 PLAY 时，根据倒放标志 'reverse' 设置初始索引
            note_idx <= reverse ? 4'd6 : 4'd0; // 倒放(BATT)从6开始, 正放(STEER/FAST)从0开始
        end
        else if (state == PLAY && note_done) begin
            // 【修复】检查是否为 too_fast 模式且刚播完最后一个音符
            if (mode == MODE_FAST && last_note)
                note_idx <= 4'd0; // 立即循环归零
            else
                note_idx <= note_idx + 4'd1; // 否则才 +1
        end
    end

    //============================================================
    // 9. 当前音符参数查表 (LUT)
    //============================================================
    logic [31:0] curr_freq;
    longint curr_dur_clks; // SystemVerilog 'longint' 是 64 位

    always_comb begin
        // 默认赋值，防止 latch
        {curr_freq, curr_dur_clks} = {32'd0, 64'd1};
        case (note_idx)
            // en_steer (mode=0) 使用 0-5
            4'd0:  {curr_freq, curr_dur_clks} = {FREQ[0], DUR_CLKS[0]};
            4'd1:  {curr_freq, curr_dur_clks} = {FREQ[1], DUR_CLKS[1]};
            4'd2:  {curr_freq, curr_dur_clks} = {FREQ[2], DUR_CLKS[2]};
            4'd3:  {curr_freq, curr_dur_clks} = {FREQ[3], DUR_CLKS[3]};
            4'd4:  {curr_freq, curr_dur_clks} = {FREQ[4], DUR_CLKS[4]};
            4'd5:  {curr_freq, curr_dur_clks} = {FREQ[5], DUR_CLKS[5]};
            
            // batt_low (mode=1) 使用 6-11
            4'd6:  {curr_freq, curr_dur_clks} = {FREQ[5], DUR_CLKS[5]}; // 倒放
            4'd7:  {curr_freq, curr_dur_clks} = {FREQ[4], DUR_CLKS[4]};
            4'd8:  {curr_freq, curr_dur_clks} = {FREQ[3], DUR_CLKS[3]};
            4'd9:  {curr_freq, curr_dur_clks} = {FREQ[2], DUR_CLKS[2]};
            4'd10: {curr_freq, curr_dur_clks} = {FREQ[1], DUR_CLKS[1]};
            4'd11: {curr_freq, curr_dur_clks} = {FREQ[0], DUR_CLKS[0]};
            
            // too_fast (mode=2) 使用 0-2
            
            default: {curr_freq, curr_dur_clks} = {FREQ[0], DUR_CLKS[0]};
        endcase
    end

    //============================================================
    // 10. 音符持续时间计数器
    //============================================================
    logic [31:0] dur_cnt;
    logic note_done_r; // 'note_done' 信号的寄存器版本

    // 时长计数器
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n || state != PLAY)
            dur_cnt <= 32'd0;
        else if (note_done_r)
            dur_cnt <= 32'd0; // 音符完成后清零, 准备下一个
        else
            dur_cnt <= dur_cnt + INCR;
    end

    // 'note_done' 标志位寄存器
    // (这是一种安全的 FSM 握手方式)
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n || state != PLAY)
            note_done_r <= 1'b0;
        else
            note_done_r <= (dur_cnt >= curr_dur_clks - 1);
    end

    assign note_done = note_done_r; // FSM 使用寄存器后的 'note_done'

    //============================================================
    // 11. 方波频率计数器（控制音高）
    //============================================================
    logic [31:0] per_cnt;
    logic [31:0] half_period;
    logic piezo_raw; // 内部原始方波

    // 【修复】计算半周期。不再需要 /INCR
    assign half_period = (50_000_000 / (curr_freq * 2));

    // 频率(半周期)计数器
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n || state != PLAY)
            per_cnt <= '0;
        else if (per_cnt >= half_period - 1)
            per_cnt <= '0; // 数满半周期后清零
        else
            per_cnt <= per_cnt + INCR; // 使用步长 INCR (1 或 64)
    end

    // 方波翻转逻辑
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n || state != PLAY)
            piezo_raw <= 1'b0;
        else if (state == PLAY && per_cnt >= half_period - 1)
            piezo_raw <= ~piezo_raw; // 每半周期翻转一次
    end

    //============================================================
    // 12. 输出控制：静音与差分输出
    //============================================================
    // 只有在 PLAY 状态才输出方波，否则静音
    assign piezo   = (state == PLAY) ? piezo_raw : 1'b0;
    assign piezo_n = (state == PLAY) ? ~piezo_raw : 1'b1;

endmodule