`include "enc_defines.v"

module hevc_encode_system_ctrl#
(
    parameter GOP_LENGTH    =   1,
    parameter FRAME_WIDTH   =   1920,
    parameter FRAME_HEIGHT  =   1080,
    parameter FRAME_SIZE    =   FRAME_WIDTH * FRAME_HEIGHT
)
(
    input clk_i,
    input rst_n_i,
    output reg skip_frame_flag_o,
    /* Video Buffer 相关信号 */
    output reg pixel_type_o,
    output reg pixel_buffer_rd_en_o,
    input pixel_buffer_full_i,
    input [10:0] pixel_buffer_rd_cnt_i,
    /* extif 相关信号 */
    output reg extif_wr_en_o,
    output reg extif_rd_en_o,
    output reg [31:0] fdma_addr_o,
    output reg [15:0] fdma_size_o,
    input fdma_busy_i,
    /* HEVC 编码核相关信号*/
    output reg hevc_sys_start_o,
    output reg hevc_sys_type_o,
    input hevc_sys_done_i,
    input hevc_extif_start_i,
    output hevc_extif_done_o,
    input [4:0] hevc_extif_mode_i,
    input [11:0] hevc_extif_x_i,
    input [11:0] hevc_extif_y_i,
    input [7:0] hevc_extif_width_i,
    input [7:0] hevc_extif_height_i
);

/*************************** 参数定义 ****************************/
    // 状态机状态
    localparam  S0_INIT         =   0,
                S1_FIFO_READ    =   1,
                S2_EXTIF        =   2,
                S3_HEVC_ENC     =   3;

    // 外部存储数据访问操作
    localparam  LOAD_CUR_SUB      = 01 ,
                LOAD_REF_SUB      = 02 ,
                LOAD_CUR_LUMA     = 03 ,    // 加载当前 LCU 的亮度块
                LOAD_REF_LUMA     = 04 ,    
                LOAD_CUR_CHROMA   = 05 ,    // 加载当前色度块
                LOAD_REF_CHROMA   = 06 ,
                LOAD_DB_LUMA      = 07 ,    // 加载重建后的亮度块
                LOAD_DB_CHROMA    = 08 ,    // 加载重建后的色度块
                STORE_DB_LUMA     = 09 ,    // 保存重建后的亮度块
                STORE_DB_CHROMA   = 10 ;    // 保存重建后的色度块

/************************** 信号线定义 ***************************/
    // 状态机当前状态
    reg [1:0] state;

    // 相关标志位
    reg extif_busy;
    reg frdw_busy;
    reg hevc_enc_busy;

    reg hevc_extif_done;

    // 状态缓存
    reg [1 :0] fdma_busy_cache;
    reg [4 :0] extif_mode_cache;
    reg [11:0] extif_x_cache;
    reg [11:0] extif_y_cache;
    reg [7 :0] extif_width_cache;
    reg [7 :0] extif_height_cache; 

    // 帧缓存序号
    reg [15:0] hevc_enc_frame_nums;
    reg [1:0] current_read_frame_serial_number;
    reg [1:0] current_write_frame_serial_number;
    reg [1:0] previous_write_frame_serial_number;

    // extif 已操作的行数
    reg [7:0] hevc_extif_operated_rows;

    // DDR 内存地址分配
    // 输入视频流缓存地址
    // 为解决画面撕裂和速率不同步问题，将开辟 3 帧缓存区（首位为重建图像缓冲区）
    reg [31:0] video_frame_baseaddr[3:0];

    reg [31:0] video_buffer_y_write_in_cnt;
    reg [31:0] video_buffer_uv_write_in_cnt;

/**************************** 标志位 *****************************/    
    // extif 数据交互开始标志
    // hevc_extif_start_i 置位表明 HEVC 编码核要求缓冲交互数据
    // hevc_extif_done 清零表明 HEVC 编码核与缓存的数据交互结束
    always@(posedge clk_i or negedge rst_n_i) begin
        if(!rst_n_i) begin
            extif_busy <= 1'b0;
            extif_mode_cache <= 5'b0;
            extif_x_cache <= 12'b0;
            extif_y_cache <= 12'b0;
            extif_width_cache <= 8'b0;
            extif_height_cache <= 8'b0;
        end
        else if(hevc_extif_start_i) begin
            extif_busy <= 1'b1;
            extif_mode_cache <= hevc_extif_mode_i;
            extif_x_cache <= hevc_extif_x_i;
            extif_y_cache <= hevc_extif_y_i;
            extif_width_cache <= hevc_extif_width_i;
            extif_height_cache <= hevc_extif_height_i;
        end
        else if(hevc_extif_done) begin
            extif_busy <= 1'b0;
        end
    end

    // HEVC 编码开始标志
    // hevc_sys_start_o 置位表明要求 HEVC 开始编码
    // hevc_sys_done_i 置位表明 HEVC 该帧编码结束
    always@(posedge clk_i or negedge rst_n_i) begin
        if(!rst_n_i) begin
            hevc_enc_busy <= 1'b0;
        end
        else if(hevc_sys_start_o) begin
            hevc_enc_busy <= 1'b1;
        end
        else if(hevc_sys_done_i) begin
            hevc_enc_busy <= 1'b0;
        end
    end

    // STATE2_FRDW 相关逻辑
    // frdw_busy 表示该状态正忙，不允许切换至其他状态，其他状态空闲时应立即切换至该状态
    always@(posedge clk_i or negedge rst_n_i) begin
        if(!rst_n_i) begin
            frdw_busy <= 1'b0;
            fdma_busy_cache <= 2'b0;
        end
        else begin
            fdma_busy_cache <= { fdma_busy_cache[0], fdma_busy_i };
            if(pixel_buffer_full_i) begin
                frdw_busy <= 1'b1;
            end
            else if(fdma_busy_cache[0] && (!fdma_busy_i) && pixel_type_o) begin
                frdw_busy <= 1'b0;
            end
        end
    end
    
    // HEVC 编码模式设置（帧内/帧间）
    // GOP 首帧采用帧内编码，其余采用帧间编码
    always@(posedge clk_i or negedge rst_n_i) begin
        if(!rst_n_i) begin
            hevc_sys_type_o <= `INTRA;
            hevc_enc_frame_nums <= 16'b0;
        end
        else if(hevc_sys_done_i) begin
            hevc_sys_type_o <= (hevc_enc_frame_nums < GOP_LENGTH - 1'b1) ? `INTER : `INTRA;
            hevc_enc_frame_nums <= (hevc_enc_frame_nums < GOP_LENGTH - 1'b1) ? (hevc_enc_frame_nums + 1'b1) : 16'b0;
        end
        else begin
            hevc_sys_type_o <= hevc_sys_type_o;
            hevc_enc_frame_nums <= hevc_enc_frame_nums;
        end
    end

/*************************** 状态转换 ****************************/
    always@(posedge clk_i or negedge rst_n_i) begin
        if(!rst_n_i) begin
            // 初始化状态
            state <= S0_INIT;
            // 初始化帧操作序号
            current_read_frame_serial_number <= 2'b0;
            // 初始化标志位
            skip_frame_flag_o <= 1'b0;
            // 初始化帧缓冲区地址
            video_frame_baseaddr[0] <= 32'h000_0000;
            video_frame_baseaddr[1] <= 32'h100_0000;
            video_frame_baseaddr[2] <= 32'h200_0000;
            video_frame_baseaddr[3] <= 32'h300_0000;
            // 初始化 EXTIF 已操作行数
            hevc_extif_operated_rows <= 8'b0;
            // 初始化 video_buffer 读取计数器
            video_buffer_y_write_in_cnt <= 32'h0;
            video_buffer_uv_write_in_cnt <= 32'h0;
            // 初始化视频输入流缓存指针
            current_write_frame_serial_number <= 2'b1;
            previous_write_frame_serial_number <= 2'b0;
            // 初始化读写使能信号
            pixel_type_o <= 1'b0;
            pixel_buffer_rd_en_o <= 1'b0;
            // 初始化 extif 相关信号
            extif_wr_en_o <= 1'b0;
            extif_rd_en_o <= 1'b0;
            // 初始化 fdma 相关信号
            fdma_addr_o <= 32'b0;
            fdma_size_o <= 16'b0;
            // 初始化 HEVC 相关信号
            hevc_sys_start_o <= 1'b0;
            hevc_extif_done <= 1'b0;
        end
        else begin
            // 状态机实体
            case(state)
                S0_INIT: begin
                    state <= frdw_busy ? S1_FIFO_READ : S0_INIT;
                end
                S1_FIFO_READ: begin
                    // 将 YUV 缓冲区 FIFO 数据写入 DDR
                    if(frdw_busy) begin
                        // FDMA 处于空闲状态且未启动一次新的缓存
                        // 首先判断缓冲区指针是否需要移动，之后启动传输
                        if((!fdma_busy_i) && (!fdma_busy_cache[1]) && (!pixel_buffer_rd_en_o)) begin
                            // 根据 YUV 像素计数器判断是否需要更改写指针（current & previous）
                            if(video_buffer_uv_write_in_cnt == (FRAME_SIZE >> 1)) begin
                                // 清空 YUV 计数器
                                video_buffer_y_write_in_cnt <= 32'b0;
                                video_buffer_uv_write_in_cnt <= 32'b0;
                                // 切换写指针
                                case({ current_write_frame_serial_number, current_read_frame_serial_number})
                                    { 2'd1, 2'd0 }: current_write_frame_serial_number <= 2'd2;
                                    { 2'd1, 2'd2 }: current_write_frame_serial_number <= 2'd3;
                                    { 2'd1, 2'd3 }: current_write_frame_serial_number <= 2'd2;
                                    { 2'd2, 2'd1 }: current_write_frame_serial_number <= 2'd3;
                                    { 2'd2, 2'd3 }: current_write_frame_serial_number <= 2'd1;
                                    { 2'd3, 2'd1 }: current_write_frame_serial_number <= 2'd2;
                                    { 2'd3, 2'd2 }: current_write_frame_serial_number <= 2'd1;
                                    default: current_write_frame_serial_number <= current_write_frame_serial_number;
                                endcase 
                                previous_write_frame_serial_number <= current_write_frame_serial_number;
                                // 控制帧跳过标志位
                                case({ current_write_frame_serial_number, current_read_frame_serial_number})
                                    { 2'd1, 2'd2 }: skip_frame_flag_o <= 1'b1;
                                    { 2'd2, 2'd3 }: skip_frame_flag_o <= 1'b1;
                                    { 2'd3, 2'd1 }: skip_frame_flag_o <= 1'b1;
                                    default: skip_frame_flag_o <= skip_frame_flag_o;
                                endcase 
                            end
                            else begin
                                // 启动一次新的 Y 分量缓存
                                if(video_buffer_y_write_in_cnt == (video_buffer_uv_write_in_cnt << 1)) begin
                                    pixel_type_o <= 1'b0;
                                    pixel_buffer_rd_en_o <= 1'b1;
                                    fdma_addr_o <= video_frame_baseaddr[current_write_frame_serial_number] + video_buffer_y_write_in_cnt;
                                    if(pixel_buffer_rd_cnt_i >= ((FRAME_SIZE - video_buffer_y_write_in_cnt) >> 4)) begin 
                                        // 缓冲区可读取数量大于该帧尾部大小
                                        video_buffer_y_write_in_cnt <= FRAME_SIZE;
                                        fdma_size_o <= ((FRAME_SIZE - video_buffer_y_write_in_cnt) >> 4);
                                    end
                                    else begin
                                        // 此处读取的 Y 块数目必须为 2 的倍数
                                        // 否则 UV 块读取的数目无法匹配 Y 块读取的数目
                                        video_buffer_y_write_in_cnt <= video_buffer_y_write_in_cnt + ((pixel_buffer_rd_cnt_i >> 1) << 5);
                                        fdma_size_o <= ((pixel_buffer_rd_cnt_i >> 1) << 1);
                                    end
                                end
                                else begin
                                    // 启动一次新的 UV 分量缓存
                                    // UV 缓存首地址为帧缓存首地址 + FRAME_SIZE
                                    pixel_type_o <= 1'b1;
                                    pixel_buffer_rd_en_o <= 1'b1;
                                    video_buffer_uv_write_in_cnt <= (video_buffer_y_write_in_cnt >> 1);
                                    fdma_size_o <= (fdma_size_o >> 1);
                                    fdma_addr_o <= video_frame_baseaddr[current_write_frame_serial_number] + FRAME_SIZE + video_buffer_uv_write_in_cnt;
                                end
                            end
                        end
                        else if(pixel_buffer_rd_en_o) begin
                            pixel_buffer_rd_en_o <= 1'b0;
                        end
                    end
                    else begin
                        if(extif_busy) begin
                            state <= S2_EXTIF;
                            hevc_extif_operated_rows <= 8'b0;
                        end
                        else begin
                            state <= S3_HEVC_ENC;
                        end
                    end 
                end
                S2_EXTIF: begin
                    if(extif_busy) begin
                        case(extif_mode_cache)
                            LOAD_CUR_LUMA: begin
                                if(hevc_extif_operated_rows < extif_height_cache) begin
                                    if((!fdma_busy_i) && (!extif_rd_en_o)) begin
                                        // 启动 extif 数据读取
                                        // 设置读取起始地址和突发传输数目
                                        // 一行需要传输的字节数为 hevc_extif_width_i，fdma 单次传输 16 字节，因此突发传输数量为 hevc_extif_width / 16
                                        extif_rd_en_o <= 1'b1;
                                        fdma_addr_o <= video_frame_baseaddr[current_read_frame_serial_number] + (extif_y_cache + hevc_extif_operated_rows) * FRAME_WIDTH + extif_x_cache;
                                        fdma_size_o <= (extif_width_cache >> 4);
                                        // 更新 EXTIF 操作行数
                                        hevc_extif_operated_rows <= hevc_extif_operated_rows + 1'b1;
                                    end
                                    else if(extif_rd_en_o) begin
                                        extif_rd_en_o <= 1'b0;
                                    end
                                end
                                else begin 
                                    if((!hevc_extif_done) && fdma_busy_cache[0] && (!fdma_busy_i) && (!hevc_extif_done)) begin
                                        hevc_extif_done <= 1'b1;
                                    end
                                    else begin
                                        hevc_extif_done <= 1'b0;
                                    end
                                    if(extif_rd_en_o) begin
                                        extif_rd_en_o <= 1'b0;
                                    end
                                end
                            end
                            LOAD_CUR_CHROMA: begin
                                if(hevc_extif_operated_rows < (extif_height_cache >> 1)) begin
                                    if((!fdma_busy_i) && (!extif_rd_en_o)) begin
                                        // 启动 extif 数据读取
                                        // 设置读取起始地址和突发传输数目
                                        // 一行需要传输的字节数为 hevc_extif_width_i，fdma 单次传输 16 字节，因此突发传输数量为 hevc_extif_width / 16
                                        extif_rd_en_o <= 1'b1;
                                        fdma_addr_o <= video_frame_baseaddr[current_read_frame_serial_number] + FRAME_WIDTH * FRAME_HEIGHT + ((extif_y_cache >> 1) + hevc_extif_operated_rows) * FRAME_WIDTH + extif_x_cache;
                                        fdma_size_o <= (extif_width_cache >> 4);
                                        // 更新 EXTIF 操作行数
                                        hevc_extif_operated_rows <= hevc_extif_operated_rows + 1'b1;
                                    end
                                    else if(extif_rd_en_o) begin
                                        extif_rd_en_o <= 1'b0;
                                    end
                                end
                                else begin 
                                    if((!hevc_extif_done) && fdma_busy_cache[0] && (!fdma_busy_i) && (!hevc_extif_done)) begin
                                        hevc_extif_done <= 1'b1;
                                    end
                                    else begin
                                        hevc_extif_done <= 1'b0;
                                    end
                                    if(extif_rd_en_o) begin
                                        extif_rd_en_o <= 1'b0;
                                    end
                                end
                            end
                            LOAD_DB_LUMA: begin
                                if(hevc_extif_operated_rows < extif_height_cache) begin
                                    if((!fdma_busy_i) && (!extif_rd_en_o)) begin
                                        // 启动 extif 数据读取
                                        // 设置读取起始地址和突发传输数目
                                        // 一行需要传输的字节数为 hevc_extif_width_i，fdma 单次传输 16 字节，因此突发传输数量为 hevc_extif_width / 16
                                        extif_rd_en_o <= 1'b1;
                                        fdma_addr_o <= video_frame_baseaddr[0] + (extif_y_cache + hevc_extif_operated_rows) * FRAME_WIDTH + extif_x_cache;
                                        fdma_size_o <= (extif_width_cache >> 4);
                                        // 更新 EXTIF 操作行数
                                        hevc_extif_operated_rows <= hevc_extif_operated_rows + 1'b1;
                                    end
                                    else if(extif_rd_en_o) begin
                                        extif_rd_en_o <= 1'b0;
                                    end
                                end
                                else begin 
                                    if((!hevc_extif_done) && fdma_busy_cache[0] && (!fdma_busy_i) && (!hevc_extif_done)) begin
                                        hevc_extif_done <= 1'b1;
                                    end
                                    else begin
                                        hevc_extif_done <= 1'b0;
                                    end
                                    if(extif_rd_en_o) begin
                                        extif_rd_en_o <= 1'b0;
                                    end
                                end
                            end
                            LOAD_DB_CHROMA: begin
                                if(hevc_extif_operated_rows < (extif_height_cache >> 1)) begin
                                    if((!fdma_busy_i) && (!extif_rd_en_o)) begin
                                        // 启动 extif 数据读取
                                        // 设置读取起始地址和突发传输数目
                                        // 一行需要传输的字节数为 hevc_extif_width_i，fdma 单次传输 16 字节，因此突发传输数量为 hevc_extif_width / 16
                                        extif_rd_en_o <= 1'b1;
                                        fdma_addr_o <= video_frame_baseaddr[0] + FRAME_WIDTH * FRAME_HEIGHT + ((extif_y_cache >> 1) + hevc_extif_operated_rows) * FRAME_WIDTH + extif_x_cache;
                                        fdma_size_o <= (extif_width_cache >> 4);
                                        // 更新 EXTIF 操作行数
                                        hevc_extif_operated_rows <= hevc_extif_operated_rows + 1'b1;
                                    end
                                    else if(extif_rd_en_o) begin
                                        extif_rd_en_o <= 1'b0;
                                    end
                                end
                                else begin 
                                    if((!hevc_extif_done) && fdma_busy_cache[0] && (!fdma_busy_i) && (!hevc_extif_done)) begin
                                        hevc_extif_done <= 1'b1;
                                    end
                                    else begin
                                        hevc_extif_done <= 1'b0;
                                    end
                                    if(extif_rd_en_o) begin
                                        extif_rd_en_o <= 1'b0;
                                    end
                                end
                            end
                            STORE_DB_LUMA: begin
                                if(hevc_extif_operated_rows < extif_height_cache) begin
                                    if((!fdma_busy_i) && (!extif_wr_en_o)) begin
                                        // 启动 extif 数据写入
                                        // 设置读取起始地址和突发传输数目
                                        // 一行需要传输的字节数为 hevc_extif_width_i，fdma 单次传输 16 字节，因此突发传输数量为 hevc_extif_width / 16
                                        extif_wr_en_o <= 1'b1;
                                        fdma_addr_o <= video_frame_baseaddr[0] + (extif_y_cache + hevc_extif_operated_rows) * FRAME_WIDTH + extif_x_cache;
                                        fdma_size_o <= (extif_width_cache >> 4);
                                        // 更新 EXTIF 操作行数
                                        hevc_extif_operated_rows <= hevc_extif_operated_rows + 1'b1;
                                    end
                                    else if(extif_wr_en_o) begin
                                        extif_wr_en_o <= 1'b0;
                                    end
                                end
                                else begin 
                                    if((!hevc_extif_done) && fdma_busy_cache[0] && (!fdma_busy_i) && (!hevc_extif_done)) begin
                                        hevc_extif_done <= 1'b1;
                                    end
                                    else begin
                                        hevc_extif_done <= 1'b0;
                                    end
                                    if(extif_wr_en_o) begin
                                        extif_wr_en_o <= 1'b0;
                                    end
                                end
                            end
                            STORE_DB_CHROMA: begin
                                if(hevc_extif_operated_rows < (extif_height_cache >> 1)) begin
                                    if((!fdma_busy_i) && (!extif_wr_en_o)) begin
                                        // 启动 extif 数据读取
                                        // 设置读取起始地址和突发传输数目
                                        // 一行需要传输的字节数为 hevc_extif_width_i，fdma 单次传输 16 字节，因此突发传输数量为 hevc_extif_width / 16
                                        extif_wr_en_o <= 1'b1;
                                        fdma_addr_o <= video_frame_baseaddr[0] + FRAME_WIDTH * FRAME_HEIGHT + ((extif_y_cache >> 1) + hevc_extif_operated_rows) * FRAME_WIDTH + extif_x_cache;
                                        fdma_size_o <= (extif_width_cache >> 4);
                                        // 更新 EXTIF 操作行数
                                        hevc_extif_operated_rows <= hevc_extif_operated_rows + 1'b1;
                                    end
                                    else if(extif_wr_en_o) begin
                                        extif_wr_en_o <= 1'b0;
                                    end
                                end
                                else begin 
                                    if((!hevc_extif_done) && fdma_busy_cache[0] && (!fdma_busy_i) && (!hevc_extif_done)) begin
                                        hevc_extif_done <= 1'b1;
                                    end
                                    else begin
                                        hevc_extif_done <= 1'b0;
                                    end
                                    if(extif_wr_en_o) begin
                                        extif_wr_en_o <= 1'b0;
                                    end
                                end
                            end
                            default begin
                                if((!hevc_extif_done) && fdma_busy_cache[0] && (!fdma_busy_i) && (!hevc_extif_done)) begin
                                        hevc_extif_done <= 1'b1;
                                end
                                else begin
                                    hevc_extif_done <= 1'b0;
                                end
                            end 
                        endcase
                    end
                    else begin
                        state <= frdw_busy ? S1_FIFO_READ : S3_HEVC_ENC;
                    end
                end
                S3_HEVC_ENC: begin
                    if(frdw_busy) begin
                        state <= S1_FIFO_READ;
                    end
                    else if(extif_busy) begin 
                        state <= S2_EXTIF;
                        hevc_extif_operated_rows <= 8'b0;
                    end
                    else begin
                        // 根据 pwfsn 和 crfsn 启动 HEVC 编码
                        if(hevc_enc_busy) 
                            hevc_sys_start_o <= 1'b0;
                        else begin
                            if((previous_write_frame_serial_number > 0) && (current_read_frame_serial_number != previous_write_frame_serial_number)) begin
                                hevc_sys_start_o <= 1'b1;
                                current_read_frame_serial_number <= previous_write_frame_serial_number;
                            end
                        end
                        state <= S3_HEVC_ENC;
                    end
                end
            endcase
        end
    end

    time_shift#(
        .DATA_WIDTH(1)
    ) extif_done_time_shift(
        .clk_i(clk_i),
        .rst_n_i(rst_n_i),
        .data_i(hevc_extif_done),
        .data_o(hevc_extif_done_o)
    );
endmodule