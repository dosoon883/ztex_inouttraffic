`timescale 1ns / 1ps

// *********************************************************
//
// Packet-Based Communication for FPGA Application
//
// Host Software sends data:
// * to different subsystems of FPGA application
// * in sequential packets
//
// see pkt_comm.h for packet format
//
// Naming: in*, out* from the point of view from FPGA application
//
// *********************************************************

module pkt_comm #(
	parameter VERSION = 1,
	parameter PKT_MAX_LEN = 16*65536,
	parameter PKT_LEN_MSB = `MSB(PKT_MAX_LEN)
	)(
	input CLK,
	input WORD_GEN_CLK,
	input CORE_CLK,
	input CMP_CLK,

	// read from some internal FIFO (recieved via high-speed interface)
	input [7:0] din,
	output rd_en,
	input empty,

	// write into some internal FIFO (to be send via high-speed interface)
	//output [63:0] dout,
	output [15:0] dout,
	output wr_en,
	input full,
	
	// control input (VCR interface)
	input [7:0] app_mode,
	// status output (VCR interface)
	output [7:0] app_status,
	output [7:0] pkt_comm_status,
	output [7:0] debug2
	);
	

	assign debug2 = 8'hd2;
	assign app_status = 8'h00;


	localparam DISABLE_TEST_MODES_0_AND_1 = 0;

	//assign rd_en = inpkt_rd_en;
	//assign wr_en = output_fifo_wr_en;
	//assign dout = dout_mode2;
		
	// **************************************************
	//
	// Application modes 0 & 1: send back what received
	// used by simple_test.c and test.c
	//
	// **************************************************
	//assign dout = din;

	// convert 8-bit to 16-bit
	reg [15:0] dout_app_mode01;
	reg dout_app_mode01_ready = 0;
	reg counter = 0;

	assign rd_en =
		DISABLE_TEST_MODES_0_AND_1 | app_mode==2 || app_mode==3 ? inpkt_rd_en :
		app_mode==0 || app_mode==1 ? ~empty & ~full :
		1'b0;
		
	assign wr_en =
		DISABLE_TEST_MODES_0_AND_1 | app_mode==2 ? output_fifo_wr_en :
		app_mode==0 || app_mode==1 ? dout_app_mode01_ready :
		//app_mode==3 ?
		1'b0;
	
	assign dout =
		DISABLE_TEST_MODES_0_AND_1 | app_mode==2 ? dout_app_mode2 :
		app_mode==0 || app_mode==1 ? dout_app_mode01 :
		//app_mode==3 ? 
		16'b0;//64'b0;
		
	if (!DISABLE_TEST_MODES_0_AND_1) begin

		always @(posedge CLK) begin
			if (counter == 0) begin
				dout_app_mode01_ready <= 0;
			end
			if (rd_en && (app_mode == 8'h00 || app_mode == 8'h01) ) begin
				if (counter == 0) begin
					dout_app_mode01[7:0] <= din;
				end
				else if (counter == 1) begin
					dout_app_mode01[15:8] <= din;
					dout_app_mode01_ready <= 1;
				end
				counter <= counter + 1'b1;
			end
		end // CLK

	end // !DISABLE_TEST_MODES_0_AND_1


	assign pkt_comm_status = {
		1'b0, err_word_gen_conf, err_word_list_len, err_word_list_count,
		err_pkt_version, err_inpkt_type, err_inpkt_len, err_inpkt_checksum
	};	


	// **************************************************
	//
	// Application mode 2 & 3: read packets
	// process data base on packet type
	//
	// **************************************************

	localparam PKT_TYPE_WORD_LIST = 1;
	localparam PKT_TYPE_WORD_GEN = 2;
	localparam PKT_TYPE_CONFIG = 3;

	localparam PKT_MAX_TYPE = 3;

	reg error = 0;
	always @(posedge CLK)
		error <= inpkt_err | err_word_gen_conf | err_word_list_len | err_word_list_count;
	

	wire [`MSB(PKT_MAX_TYPE):0] inpkt_type;
	wire [15:0] inpkt_id;
	
	inpkt_header #(
		.VERSION(VERSION),
		.PKT_MAX_LEN(PKT_MAX_LEN),
		.PKT_MAX_TYPE(PKT_MAX_TYPE)
	) inpkt_header(
		.CLK(CLK), 
		.din(din), 
		.wr_en(inpkt_rd_en),
		.pkt_type(inpkt_type), .pkt_id(inpkt_id), .pkt_data(inpkt_data),
		.pkt_end(inpkt_end), .pkt_err(inpkt_err),
		.err_pkt_version(err_pkt_version), .err_pkt_type(err_inpkt_type),
		.err_pkt_len(err_inpkt_len), .err_pkt_checksum(err_inpkt_checksum)
	);

	// input packet processing: read enable
	assign inpkt_rd_en = ~empty & ~error
			& (~inpkt_data | word_gen_conf_en | word_list_wr_en);


	localparam WORD_MAX_LEN = 8;
	localparam CHAR_BITS = 7;
	localparam RANGES_MAX = 8;


	// **************************************************
	//
	// input packet type WORD_LIST (0x01)
	//
	// **************************************************
	wire word_list_wr_en = ~empty & ~error
			& inpkt_type == PKT_TYPE_WORD_LIST & inpkt_data & ~word_list_full;

	wire [WORD_MAX_LEN * CHAR_BITS - 1:0] word_list_dout;
	wire [`MSB(WORD_MAX_LEN):0] word_len;
	wire [15:0] word_id;

	word_list #(
		.CHAR_BITS(CHAR_BITS), .WORD_MAX_LEN(WORD_MAX_LEN)
	) word_list(
		.wr_clk(CLK), .din(din), 
		.wr_en(word_list_wr_en), .full(word_list_full), .inpkt_end(inpkt_end),

		.rd_clk(WORD_GEN_CLK),
		.dout(word_list_dout), .word_len(word_len), .word_id(word_id), .word_list_end(word_list_end),
		.rd_en(word_list_rd_en), .empty(word_list_empty),
		
		.err_word_list_len(err_word_list_len), .err_word_list_count(err_word_list_count)
	);

	
	// **************************************************
	//
	// input packet type WORD_GEN (0x02)
	//
	// **************************************************
	wire word_gen_conf_en = ~empty & ~error
			& inpkt_type == PKT_TYPE_WORD_GEN & inpkt_data & ~word_gen_conf_full;

	wire word_wr_en = ~word_list_empty & ~word_full;
	assign word_list_rd_en = word_wr_en;
	
	wire [WORD_MAX_LEN * CHAR_BITS - 1:0] word_gen_dout;
	wire [15:0] pkt_id, word_id_out;
	wire [31:0] gen_id;

	word_gen #(
		.CHAR_BITS(CHAR_BITS), .RANGES_MAX(RANGES_MAX), .WORD_MAX_LEN(WORD_MAX_LEN)
	) word_gen(
		.CLK(CLK), .din(din), 
		.inpkt_id(inpkt_id), .wr_conf_en(word_gen_conf_en), .conf_full(word_gen_conf_full),
		
		.word_in(word_list_dout), .word_len(word_len), .word_id(word_id), .word_list_end(word_list_end),
		.word_wr_en(word_wr_en), .word_full(word_full),
		
		.WORD_GEN_CLK(WORD_GEN_CLK),
		.rd_en(word_gen_rd_en), .empty(word_gen_empty),
		.dout(word_gen_dout), .pkt_id(pkt_id), .word_id_out(word_id_out), .gen_id(gen_id), .gen_end(gen_end),
		
		.err_word_gen_conf(err_word_gen_conf)
	);
	//
	// OK. Got words with ID's.
	//
	//wire [32 + 16 + WORD_MAX_LEN * CHAR_BITS -1 :0] word_gen_out =
	//		{ gen_id, word_id_out, word_gen_dout };
	//
	// also [15:0] pkt_id from incoming packet.

	
	// *************************************************************
	//
	// Going to output generated plaintext words via outpkt
	//
`define RESULT_LEN 8

	// 1. Convert 7-bit to 8-bit if necessary <-- skipped, outpkt takes 7-bit chars
	//
	wire [CHAR_BITS * `RESULT_LEN - 1 :0] plaintext = word_gen_dout;
		
	// 2. Data is entering different clock domain
	//
	wire [15:0] pkt_id_2, word_id_out_2;
	wire [31:0] gen_id_2;
	wire [CHAR_BITS * `RESULT_LEN - 1 :0] plaintext_2;	

	assign word_gen_rd_en = ~word_gen_empty & ~xdc_reg_full;
	
	xdc_reg #( .WIDTH(16 + 16 + 32 + CHAR_BITS * `RESULT_LEN)
	) xdc_reg (
		.wr_clk(WORD_GEN_CLK), .wr_en(word_gen_rd_en), .full(xdc_reg_full),
		.din({ pkt_id, word_id_out, gen_id, plaintext }),
		.rd_clk(CLK), .rd_en(outpkt_wr_en), .empty(xdc_reg_empty),
		.dout({ pkt_id_2, word_id_out_2, gen_id_2, plaintext_2 })
	);
	

	// 3. Write data into outpkt_v2
	//
	assign outpkt_wr_en = ~xdc_reg_empty & ~outpkt_full;


	// **************************************************
	//
	// Application mode 2.
	//
	// each word (wire [WORD_MAX_LEN * CHAR_BITS -1:0] word_gen_dout)
	// converted to 8-bit ascii
	// and sent in a separate packet along with
	// word_id, gen_id.
	// pkt_id (that comes from input packet_id) goes into packet_id.
	//
	// **************************************************

	// **************************************************
	//
	// output packet type 0x81
	// header is 10 bytes
	// contains 1 word (8 bytes) + IDs (6 bytes)
	//
	// **************************************************
	wire [15:0] outpkt_dout;
	
	outpkt_word outpkt(
		.CLK(CLK),
		//.din({ 32'b0, word_id, word_list_dout }), .pkt_id(inpkt_id),
		//.din({ gen_id, word_id_out, word_gen_dout }), .pkt_id(pkt_id),
		.din({ gen_id_2, word_id_out_2, plaintext_2 }), .pkt_id(pkt_id_2),
		.wr_en(outpkt_wr_en), .full(outpkt_full),
		
		.dout(outpkt_dout), .pkt_new(outpkt_new), .pkt_end(outpkt_end),
		.rd_en(rd_en_outpkt), .empty(empty_outpkt)
	);


	wire [15:0] dout_app_mode2;

	assign rd_en_outpkt = ~empty_outpkt & ~full_outpkt_checksum;
	wire wr_en_outpkt_checksum = rd_en_outpkt;

	outpkt_checksum outpkt_checksum(
		.CLK(CLK), .din(outpkt_dout), .pkt_new(outpkt_new), .pkt_end(outpkt_end),
		.wr_en(wr_en_outpkt_checksum), .full(full_outpkt_checksum),
		.dout(dout_app_mode2), .rd_en(rd_en_outpkt_checksum), .empty(empty_outpkt_checksum)
	);

	assign rd_en_outpkt_checksum = ~empty_outpkt_checksum & ~full;
	assign output_fifo_wr_en = rd_en_outpkt_checksum;

endmodule

