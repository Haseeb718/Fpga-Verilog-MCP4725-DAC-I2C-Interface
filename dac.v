`timescale 1ns / 1ps

module dac(
    input        I_clk,
    input        I_rst_n,
    input [11:0] DAC_VALUE,
    output       O_scl,
    inout        IO_sda,
   

    output reg [3:0] state,
    output reg [4:0] bit_cnt,
    output reg [7:0] byte_data,
    output reg [2:0] byte_cnt,   // <-- widened
    output reg [7:0] scl_cnt,
    output reg       sda_out,
    output reg scl_reg,
    output reg scl_en,
    output reg [8:0]count ,
    output reg is_counting = 0,
    output reg high_imp
);

reg first_edge_seen;
reg scl_delayed;
parameter I2C_ADDR  = 7'd96;     // 0x60
parameter DIV       = 8'd250;    // 100 kHz

assign O_scl  = scl_reg;
assign IO_sda = high_imp ? sda_out : 1'bz;

always @(posedge I_clk) begin
    // 1. Button Press / Start
    if (!I_rst_n) begin
        is_counting <= 1'b1;
        first_edge_seen <= 1'b0; // Reset the edge tracker
        count <= 9'd0;
        high_imp <= 1'b1;
    end

    scl_delayed <= O_scl;

    // 2. Level Detection
    if (is_counting && (O_scl != scl_delayed)) begin
        if (!first_edge_seen) begin
            first_edge_seen <= 1'b1;
            count <= 9'd0; 
        end else begin
            if (count < 9'd18) begin
                count <= count + 1'b1;
            end else begin
                count <= 9'd1;
            end
        end
    end


    if (is_counting && first_edge_seen) begin
      if (  count == 9'd16 || count == 9'd17 ) begin
   
            high_imp <= 1'b0;
        end else begin
            high_imp <= 1'b1;
        end
    end else begin
        high_imp <= 1'b1;
    end
end



////////////////////////////////////////////////////////////
// SCL generator
////////////////////////////////////////////////////////////
always @(posedge I_clk or negedge I_rst_n) begin
    if(!I_rst_n) begin
        scl_cnt <= 0;
        scl_reg <= 1;
    end else if(scl_en) begin
        if(scl_cnt == DIV-1) begin
            scl_cnt <= 0;
            scl_reg <= ~scl_reg;
        end else
            scl_cnt <= scl_cnt + 1;
    end else begin
        scl_cnt <= 0;
        scl_reg <= 1;
    end
end

////////////////////////////////////////////////////////////
// I2C FSM
////////////////////////////////////////////////////////////
always @(posedge I_clk or negedge I_rst_n) begin
    if(!I_rst_n) begin
        state    <= 0;
        bit_cnt  <= 0;
        byte_cnt <= 0;
        scl_en   <= 0;
        sda_out  <= 1;
    end else begin
        case(state)

        // ---------------- IDLE ----------------
        0: begin
            sda_out  <= 1;
            scl_en   <= 0;
            bit_cnt  <= 0;
            byte_cnt <= 0;
            state    <= 1;
        end

        // ---------------- START ----------------
        1: begin
            scl_en <= 1;
            if(scl_reg == 1 && scl_cnt == 0) begin
                sda_out <= 0;       // START
                state   <= 2;
            end
        end

        // ---------------- LOAD BYTE ----------------
        2: begin
            case(byte_cnt)
                3'd0: byte_data <= {I2C_ADDR,1'b0};   // Address + W
                3'd1: byte_data <= 8'h40;             // Control byte
                3'd2: byte_data <= DAC_VALUE[11:4];   // MSB
                3'd3: byte_data <= {DAC_VALUE[3:0],4'b0000}; // LSB
            endcase
            bit_cnt <= 0;
            state   <= 3;
        end

        // ---------------- SEND BYTE ----------------
        3: begin
     
            if(scl_reg == 0 && scl_cnt == 0)
                sda_out <= byte_data[7-bit_cnt];

            if(scl_reg == 1 && scl_cnt == 0) begin
                if(bit_cnt == 7) begin
                    bit_cnt <= 0;
                    state   <= 4;   // ACK
                end else
                    bit_cnt <= bit_cnt + 1;
            end
        end

        // ---------------- ACK (9th CLOCK) ----------------
        4: begin
        

            // complete ACK clock
            if(scl_reg == 1 && scl_cnt == 0) begin
                byte_cnt <= byte_cnt + 1;

                if(byte_cnt == 3)
                    state <= 5;   // all 4 bytes done
                else
                    state <= 2;   // next byte
            end
        end

        // ---------------- STOP ----------------
        5: begin
            if(scl_reg == 0 && scl_cnt == 0)
                sda_out <= 0;

            if(scl_reg == 1 && scl_cnt == 0) begin
                sda_out <= 1;   // STOP
                scl_en  <= 0;
                state   <= 6;
            end
        end

        // ---------------- DONE ----------------
        6: begin
            sda_out <= 1;
        end

        endcase
    end
end

endmodule
