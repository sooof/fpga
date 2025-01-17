//
// Copyright 2013 Ettus Research LLC
// testing
// testing
// radio top level module for b200
//  Contains all clock-rate DSP components, all radio and hardware controls and settings
module radio_legacy
  #(
    parameter RADIO_FIFO_SIZE = 13,
    parameter SAMPLE_FIFO_SIZE = 11,
    parameter FP_GPIO = 0,
    parameter NEW_HB_INTERP = 0,
    parameter NEW_HB_DECIM = 0,
    parameter SOURCE_FLOW_CONTROL = 0,
    parameter USER_SETTINGS = 1,
    parameter DEVICE = "SPARTAN6",
    parameter CUSTOM_ON = 1
  )
  (input radio_clk, input radio_rst,
   input [31:0] rx, output reg [31:0] tx,
   input [31:0] fe_gpio_in, output [31:0] fe_gpio_out, output [31:0] fe_gpio_ddr,
   input [9:0] fp_gpio_in, output [9:0] fp_gpio_out, output [9:0] fp_gpio_ddr,
   input pps, input time_sync,
   input bus_clk, input bus_rst,
   input [63:0]  tx_tdata, input tx_tlast, input tx_tvalid, output tx_tready,
   output [63:0] rx_tdata, output rx_tlast, output rx_tvalid, input rx_tready,
   input [63:0]  ctrl_tdata, input ctrl_tlast, input ctrl_tvalid, output ctrl_tready,
   output [63:0] resp_tdata, output resp_tlast, output resp_tvalid, input resp_tready,

   output reg [63:0] vita_time_b,

   output [63:0] debug
   );

`define DELETE_FORMAT_CONVERSION 1

   // ///////////////////////////////////////////////////////////////////////////////
   // FIFO Interfacing to the bus clk domain
   // in_tdata splits to tx_tdata and ctrl_tdata
   // rx_tdata and resp_tdata get muxed to out_tdata
   // Everything except rx flow control must cross in to radio_clk domain before further use
   // _b signifies bus_clk domain, _r signifies radio_clk domain

   wire [63:0] 	 ctrl_tdata_r;
   wire 	 ctrl_tready_r, ctrl_tvalid_r;
   wire 	 ctrl_tlast_r;

   wire [63:0] 	 resp_tdata_r;
   wire 	 resp_tready_r, resp_tvalid_r;
   wire 	 resp_tlast_r;

   wire [63:0] 	 rx_tdata_r;
   wire 	 rx_tready_r, rx_tvalid_r;
   wire 	 rx_tlast_r;

   wire [63:0] 	 rx_err_tdata_r;
   wire 	 rx_err_tready_r, rx_err_tvalid_r;
   wire 	 rx_err_tlast_r;

   wire [63:0]     rx_prefc_tdata_r;
   wire   rx_prefc_tready_r, rx_prefc_tvalid_r;
   wire   rx_prefc_tlast_r;

   wire [63:0]     rx_postfc_tdata_r;
   wire   rx_postfc_tready_r, rx_postfc_tvalid_r;
   wire   rx_postfc_tlast_r;

   wire [63:0] 	 tx_tdata_r;
   wire 	 tx_tready_r, tx_tvalid_r;
   wire 	 tx_tlast_r;

   wire [63:0] 	 txresp_tdata, txresp_tdata_r;
   wire 	 txresp_tready, txresp_tready_r, txresp_tvalid, txresp_tvalid_r;
   wire 	 txresp_tlast, txresp_tlast_r;

   wire [63:0] 	 rmux_tdata_r;
   wire 	 rmux_tlast_r, rmux_tvalid_r, rmux_tready_r;

   wire [31:0] 	 tx_idle;
   wire [3:0] 	 ibs_state;
   wire [63:0] 	 rx_tdata_int;
   wire 	 rx_tready_int, rx_tvalid_int;
   wire 	 rx_tlast_int;


   axi_fifo_2clk #(.WIDTH(65), .SIZE(0/*minimal*/)) ctrl_fifo
     (.reset(bus_rst),
      .i_aclk(bus_clk), .i_tvalid(ctrl_tvalid), .i_tready(ctrl_tready), .i_tdata({ctrl_tlast, ctrl_tdata}),
      .o_aclk(radio_clk), .o_tvalid(ctrl_tvalid_r), .o_tready(ctrl_tready_r), .o_tdata({ctrl_tlast_r, ctrl_tdata_r}));

   axi_fifo_2clk #(.WIDTH(65), .SIZE(RADIO_FIFO_SIZE)) tx_fifo
     (.reset(bus_rst),
      .i_aclk(bus_clk), .i_tvalid(tx_tvalid), .i_tready(tx_tready), .i_tdata({tx_tlast, tx_tdata}),
      .o_aclk(radio_clk), .o_tvalid(tx_tvalid_r), .o_tready(tx_tready_r), .o_tdata({tx_tlast_r, tx_tdata_r}));

   axi_fifo_2clk #(.WIDTH(65), .SIZE(0/*minimal*/)) resp_fifo
     (.reset(radio_rst),
      .i_aclk(radio_clk), .i_tvalid(rmux_tvalid_r), .i_tready(rmux_tready_r), .i_tdata({rmux_tlast_r, rmux_tdata_r}),
      .o_aclk(bus_clk), .o_tvalid(resp_tvalid), .o_tready(resp_tready), .o_tdata({resp_tlast, resp_tdata}));

   axi_fifo_2clk #(.WIDTH(65), .SIZE(0)) rx_fifo
     (.reset(radio_rst),
      .i_aclk(radio_clk), .i_tvalid(rx_tvalid_r), .i_tready(rx_tready_r), .i_tdata({rx_tlast_r, rx_tdata_r}),
      .o_aclk(bus_clk), .o_tvalid(rx_tvalid_int), .o_tready(rx_tready_int), .o_tdata({rx_tlast_int, rx_tdata_int}));

   axi_packet_gate #(.WIDTH(64), .SIZE(RADIO_FIFO_SIZE)) buffer_whole_pkt
     (
      .clk(bus_clk), .reset(bus_rst), .clear(1'b0),
      .i_tdata(rx_tdata_int), .i_tlast(rx_tlast_int), .i_terror(1'b0), .i_tvalid(rx_tvalid_int), .i_tready(rx_tready_int),
      .o_tdata(rx_tdata), .o_tlast(rx_tlast), .o_tvalid(rx_tvalid), .o_tready(rx_tready));

   ///////////////////////////////////////////////////////////////////////////////////////
   // Setting bus and controls

   wire [63:0]    ctrl_tdata_proc;
   wire           ctrl_tready_proc, ctrl_tvalid_proc;
   wire           ctrl_tlast_proc;

   localparam SR_LOOPBACK     = 8'd6;
   localparam SR_SPI          = 8'd8;
   localparam SR_ATR          = 8'd12; // thorugh 8'd16
   localparam SR_TEST         = 8'd21;
   localparam SR_CODEC_IDLE   = 8'd22;
   localparam SR_READBACK     = 8'd32;
   localparam SR_TX_CTRL      = 8'd64;
   localparam SR_RX_CTRL      = 8'd96;
   localparam SR_TIME         = 8'd128;
   localparam SR_RX_FMT       = 8'd136;
   localparam SR_TX_FMT       = 8'd138;
   localparam SR_RX_DSP       = 8'd144;
   localparam SR_TX_DSP       = 8'd184;
   localparam SR_FP_GPIO      = 8'd200;
   localparam SR_USER_SR_BASE = 8'd253;
   localparam SR_USER_RB_ADDR = 8'd255;
   
  //JTL start 
   localparam SR_CMD_RX      = 8'd160;//sr_cmd_tx
   localparam SR_TIME_H_RX   = 8'd161;//sr_time_h_tx
   localparam SR_TIME_L_RX   = 8'd162;//sr_time_l_tx
   localparam SR_CNTRL       = 8'd163;//sr_cntrl
   localparam SR_LLR_REG0    = 8'd164;//sr_llr_reg0  x"00" & "000" & "00110" & x"0" & "1010" & "00101000" 
   localparam SR_LLR_REG1    = 8'd165;//sr_llr_reg1
   localparam SR_LLR_REG2    = 8'd166;//sr_llr_reg2
   localparam SR_LLR_REG3    = 8'd167;//sr_llr_reg3
   localparam SR_LLR_REG4    = 8'd168;//sr_llr_reg4
   localparam SR_LLR_REG5    = 8'd169;//sr_llr_reg1
   localparam SR_LLR_REG6    = 8'd170;//sr_llr_reg2
   localparam SR_LLR_REG7    = 8'd171;//sr_llr_reg3
   localparam SR_LLR_REG8    = 8'd172;//sr_llr_reg4
   localparam SR_LLR_REG9    = 8'd173;//sr_llr_reg4
	localparam SR_LLR_REG10   = 8'd174;
	localparam SR_LLR_REG11	  = 8'd175;
	localparam SR_LLR_REG12	  = 8'd176;
	localparam SR_LLR_REG13	  = 8'd177;
	localparam SR_LLR_REG14	  = 8'd178;
	localparam SR_LLR_REG15	  = 8'd179;
	localparam SR_LLR_REG16	  = 8'd180;
	localparam SR_LLR_REG17	  = 8'd181;
	localparam SR_LLR_REG18	  = 8'd182;
	localparam SR_LLR_REG19	  = 8'd183;
	/*
 	localparam SR_LLR_REG20	= 8'd185;
	localparam SR_LLR_REG21	= 8'd185;
	localparam SR_LLR_REG22	= 8'd186;
	localparam SR_LLR_REG23	= 8'd187;
	localparam SR_LLR_REG24	= 8'd188;
	localparam SR_LLR_REG25	= 8'd189;
	localparam SR_LLR_REG26	= 8'd190;
	localparam SR_LLR_REG27	= 8'd191;
	localparam SR_LLR_REG28	= 8'd192;
	localparam SR_LLR_REG29	= 8'd193;
	localparam SR_LLR_REG30	= 8'd194;
	localparam SR_LLR_REG31	= 8'd195;
	localparam SR_LLR_REG32	= 8'd196;
	localparam SR_LLR_REG33	= 8'd197;
	localparam SR_LLR_REG34	= 8'd198;
	localparam SR_LLR_REG35	= 8'd199;
	localparam SR_LLR_REG36	= 8'd201;
	localparam SR_LLR_REG37	= 8'd201;
	localparam SR_LLR_REG38	= 8'd202;
	localparam SR_LLR_REG39	= 8'd203;
	localparam SR_LLR_REG40	= 8'd204;
	localparam SR_LLR_REG41	= 8'd205;
	localparam SR_LLR_REG42	= 8'd206;
	localparam SR_LLR_REG43	= 8'd207;
	localparam SR_LLR_REG44	= 8'd208;
	localparam SR_LLR_REG45	= 8'd209;
	localparam SR_LLR_REG46	= 8'd210;
	localparam SR_LLR_REG47	= 8'd211;
	localparam SR_LLR_REG48	= 8'd212;
	localparam SR_LLR_REG49	= 8'd213;  
	*/
	// JTL end	

   wire           set_stb;
   wire [7:0]     set_addr;
   wire [31:0]    set_data;
   wire [31:0]    test_readback;
   wire [9:0] 	  fp_gpio_readback;
   wire           run_rx, run_tx, run_tx2;
   wire           rx_flow_ctrl_busy;

   reg [63:0]     rb_data;
   wire [2:0]     rb_addr;

   wire [63:0] vita_time, vita_time_lastpps;
   timekeeper #(.SR_TIME_HI(SR_TIME), .SR_TIME_LO(SR_TIME+1), .SR_TIME_CTRL(SR_TIME+2)) timekeeper
     (.clk(radio_clk), .reset(radio_rst), .pps(pps), .sync_in(time_sync), .strobe(1'b1),
      .set_stb(set_stb), .set_addr(set_addr), .set_data(set_data),
      .vita_time(vita_time), .vita_time_lastpps(vita_time_lastpps),
      .sync_out());

   wire [31:0] debug_radio_ctrl_proc;
   radio_ctrl_proc radio_ctrl_proc
     (.clk(radio_clk), .reset(radio_rst), .clear(1'b0),
      .ctrl_tdata(ctrl_tdata_proc), .ctrl_tlast(ctrl_tlast_proc), .ctrl_tvalid(ctrl_tvalid_proc), .ctrl_tready(ctrl_tready_proc),
      .resp_tdata(resp_tdata_r), .resp_tlast(resp_tlast_r), .resp_tvalid(resp_tvalid_r), .resp_tready(resp_tready_r),
      .vita_time(vita_time),
      .set_stb(set_stb), .set_addr(set_addr), .set_data(set_data),
      .ready(1'b1), .readback(rb_data),
      .debug(debug_radio_ctrl_proc));

   reg [63:0]     rb_data_user;
generate
   if (USER_SETTINGS == 1) begin
      wire           set_stb_user;
      wire [7:0]     set_addr_user;
      wire [31:0]    set_data_user;
      wire [7:0]     rb_addr_user;

      user_settings #(.BASE(SR_USER_SR_BASE)) user_settings
        (.clk(radio_clk), .rst(radio_rst),
         .set_stb(set_stb), .set_addr(set_addr), .set_data(set_data),
         .set_stb_user(set_stb_user), .set_addr_user(set_addr_user), .set_data_user(set_data_user));

      setting_reg #(.my_addr(SR_USER_RB_ADDR), .awidth(8), .width(8)) user_rb_addr
        (.clk(radio_clk), .rst(radio_rst), .strobe(set_stb), .addr(set_addr), .in(set_data),
         .out(rb_addr_user), .changed());

      // ----------------------------------
      // Enter user settings registers here
      // ----------------------------------

      /*
      //Example code for 32-bit settings registers and 64-bit readback registers

      wire [31:0] user_reg_0_value, user_reg_1_value;

      setting_reg #(.my_addr(8'd0), .awidth(8), .width(32)) user_reg_0
        (.clk(radio_clk), .rst(radio_rst), .strobe(set_stb_user), .addr(set_addr_user), .in(set_data_user),
         .out(user_reg_0_value), .changed());

      setting_reg #(.my_addr(8'd1), .awidth(8), .width(32)) user_reg_1
        (.clk(radio_clk), .rst(radio_rst), .strobe(set_stb_user), .addr(set_addr_user), .in(set_data_user),
         .out(user_reg_1_value), .changed());

      always @* begin
         case(rb_addr_user)
            8'd0 : rb_data_user <= {user_reg_1_value, user_reg_0_value};
            default : rb_data_user <= 64'd0;
         endcase
      end
      */

   end else begin    //for USER_SETTINGS == 1
      always @* rb_data_user <= 64'd0;
   end
endgenerate

   always @*
     case(rb_addr)
       3'd0 : rb_data <= { 32'b0, test_readback };
       3'd1 : rb_data <= vita_time;
       3'd2 : rb_data <= vita_time_lastpps;
       3'd3 : rb_data <= {tx, rx};
       3'd4 : rb_data <= {54'h0,fp_gpio_readback};
       3'd5 : rb_data <= {59'h0,rx_flow_ctrl_busy,ibs_state[3:0]}; // Monitor state of RX state machine.
//     3'd6 : rb_data <= <unused>;
       3'd7 : rb_data <= rb_data_user;
       default : rb_data <= 64'd0;
     endcase // case (rb_addr)

   //
   // Sample VITA_TIME into the bus_clk domain for use by instrumentation.
   //
   wire [63:0] vita_time_b_int;
   wire        vita_time_b_valid;

    axi_fifo_2clk #(.WIDTH(64), .SIZE(0)) vita_time_fifo
     (.reset(radio_rst),
      .i_aclk(radio_clk), .i_tvalid(1'b1), .i_tready(), .i_tdata(vita_time),
      .o_aclk(bus_clk), .o_tvalid(vita_time_b_valid), .o_tready(1'b1), .o_tdata(vita_time_b_int));

   always @(posedge bus_clk)
     if (vita_time_b_valid)
       vita_time_b <= vita_time_b_int;

   // Set this register to loop TX data directly to RX data.
   setting_reg #(.my_addr(SR_LOOPBACK), .awidth(8), .width(1)) sr_loopback
     (.clk(radio_clk), .rst(radio_rst), .strobe(set_stb), .addr(set_addr), .in(set_data),
      .out(loopback), .changed());

   setting_reg #(.my_addr(SR_TEST), .awidth(8), .width(32)) sr_test
     (.clk(radio_clk), .rst(radio_rst), .strobe(set_stb), .addr(set_addr), .in(set_data),
      .out(test_readback), .changed());

   setting_reg #(.my_addr(SR_CODEC_IDLE), .awidth(8), .width(32)) sr_codec_idle
     (.clk(radio_clk), .rst(radio_rst), .strobe(set_stb), .addr(set_addr), .in(set_data),
      .out(tx_idle), .changed());

   setting_reg #(.my_addr(SR_READBACK), .awidth(8), .width(3)) sr_rdback
     (.clk(radio_clk), .rst(radio_rst), .strobe(set_stb), .addr(set_addr), .in(set_data),
      .out(rb_addr), .changed());

   //The fe_atr pins driven by this module are always configured as outputs so default
   //the DDR (data direction register) to be all ones (outputs) so that the drive direction
   //these lines does not change during/after resets.
   gpio_atr #(.BASE(SR_ATR), .WIDTH(32), .DEFAULT_DDR(32'hFFFFFFFF), .DEFAULT_IDLE(32'h00000000)) fe_gpio_atr
     (.clk(radio_clk),.reset(radio_rst),
      .set_stb(set_stb),.set_addr(set_addr),.set_data(set_data),
      .rx(run_rx), .tx(run_tx2),
      .gpio_in(fe_gpio_in), .gpio_out(fe_gpio_out), .gpio_ddr(fe_gpio_ddr), .gpio_sw_rb() );

   generate
      if (FP_GPIO != 0) begin: add_fp_gpio
         gpio_atr #(.BASE(SR_FP_GPIO), .WIDTH(10)) fp_gpio_atr
            (.clk(radio_clk),.reset(radio_rst),
            .set_stb(set_stb),.set_addr(set_addr),.set_data(set_data),
            .rx(run_rx), .tx(run_tx2),
            .gpio_in(fp_gpio_in), .gpio_out(fp_gpio_out), .gpio_ddr(fp_gpio_ddr), .gpio_sw_rb(fp_gpio_readback));
      end
   endgenerate



   ///////////////////////////////////////////////////////////////////////////////////////
   // Source flow control

generate
   if (SOURCE_FLOW_CONTROL == 1) begin

      localparam SID_PREFIX_CTRL = 2'd0;
      localparam SID_PREFIX_FC   = 2'd1;

      wire [63:0]    ctrl_tdata_fc;
      wire           ctrl_tready_fc, ctrl_tvalid_fc;
      wire           ctrl_tlast_fc;

      wire [63:0]    ctrl_hdr;
      wire [1:0]     ctrl_dest;

      assign ctrl_dest = (ctrl_hdr[1:0] == SID_PREFIX_FC) ? 2'd1 : 2'd0;

      axi_demux4 #(.ACTIVE_CHAN(4'b0011), .WIDTH(64), .BUFFER(1)) demux_proc_fc
        (.clk(radio_clk), .reset(radio_rst), .clear(1'b0),
         .header(ctrl_hdr), .dest(ctrl_dest),
         .i_tdata(ctrl_tdata_r), .i_tlast(ctrl_tlast_r), .i_tvalid(ctrl_tvalid_r), .i_tready(ctrl_tready_r),                  //Input
         .o0_tdata(ctrl_tdata_proc), .o0_tlast(ctrl_tlast_proc), .o0_tvalid(ctrl_tvalid_proc), .o0_tready(ctrl_tready_proc),  //Settings/Readback
         .o1_tdata(ctrl_tdata_fc), .o1_tlast(ctrl_tlast_fc), .o1_tvalid(ctrl_tvalid_fc), .o1_tready(ctrl_tready_fc),          //Flow control
         .o2_tdata(), .o2_tlast(), .o2_tvalid(), .o2_tready(1'b0),                                                            //Unused
         .o3_tdata(), .o3_tlast(), .o3_tvalid(), .o3_tready(1'b0));                                                           //Unused

      source_flow_control_legacy #(.BASE(SR_RX_CTRL+6)) rx_sfc
        (.clk(radio_clk), .reset(radio_rst), .clear(1'b0),
         .set_stb(set_stb), .set_addr(set_addr), .set_data(set_data),
         .fc_tdata(ctrl_tdata_fc), .fc_tlast(ctrl_tlast_fc), .fc_tvalid(ctrl_tvalid_fc), .fc_tready(ctrl_tready_fc),                      //Flow control In
         .in_tdata(rx_prefc_tdata_r), .in_tlast(rx_prefc_tlast_r), .in_tvalid(rx_prefc_tvalid_r), .in_tready(rx_prefc_tready_r),          //RX Input
         .out_tdata(rx_postfc_tdata_r), .out_tlast(rx_postfc_tlast_r), .out_tvalid(rx_postfc_tvalid_r), .out_tready(rx_postfc_tready_r),  //RX Output
         .busy(rx_flow_ctrl_busy));

   end else begin    //for SOURCE_FLOW_CONTROL == 1

      assign ctrl_tdata_proc  = ctrl_tdata_r;
      assign ctrl_tlast_proc  = ctrl_tlast_r;
      assign ctrl_tvalid_proc = ctrl_tvalid_r;
      assign ctrl_tready_r    = ctrl_tready_proc;

      assign rx_postfc_tdata_r   = rx_prefc_tdata_r;
      assign rx_postfc_tlast_r   = rx_prefc_tlast_r;
      assign rx_postfc_tvalid_r  = rx_prefc_tvalid_r;
      assign rx_prefc_tready_r   = rx_postfc_tready_r;

      assign rx_flow_ctrl_busy   = 1'b0;

   end

endgenerate
/////////////////////////////////////////////////////////////////////////////////////
// Starting JTL
/////////////////////////////////////////////////////////////////////////////////////

   // /////////////////////////////////////////////////////////////////////////////////
   //  TX Chain

   wire [175:0] txsample_tdata;
   wire 	txsample_tvalid, txsample_tready;
   wire [31:0] 	sample_tx,sample_tx2;
   wire 	ack_or_error, packet_consumed;
   wire [11:0] 	seqnum;
   wire [63:0] 	error_code;
   wire [31:0] 	sid;
   wire [23:0] tx_fe_i, tx_fe_q;
   wire strobe_tx2, strobe_tx;

   wire [31:0] debug_tx_control;

   // Starting JTL code
	// EXPAND
   wire [31:0] get_tx_sin, get_tx_cos, get_tx;
   wire [31:0] llr_reg0_val, llr_reg1_val, llr_reg2_val,llr_reg3_val,llr_reg4_val,llr_reg5_val,llr_reg6_val,llr_reg7_val,llr_reg8_val,llr_reg9_val, llr_reg10_val, llr_reg11_val, llr_reg12_val, llr_reg13_val, llr_reg14_val, llr_reg15_val, llr_reg16_val, llr_reg17_val, llr_reg18_val, llr_reg19_val, llr_reg21_val, llr_reg22_val, llr_reg23_val, llr_reg24_val, llr_reg25_val, llr_reg26_val, llr_reg27_val, llr_reg28_val, llr_reg29_val, llr_reg30_val, llr_reg31_val, llr_reg32_val, llr_reg33_val, llr_reg34_val, llr_reg35_val, llr_reg36_val, llr_reg37_val, llr_reg38_val, llr_reg39_val, llr_reg40_val, llr_reg41_val, llr_reg42_val, llr_reg43_val, llr_reg44_val, llr_reg45_val, llr_reg46_val, llr_reg47_val, llr_reg48_val, llr_reg49_val;
;

// EXPAND
	input_signal_sin inp_sig(.radio_clk(radio_clk), .codeword0(llr_reg0_val), .codeword1(llr_reg1_val), .codeword2(llr_reg2_val), .codeword3(llr_reg3_val), .codeword4(llr_reg4_val), .codeword5(llr_reg5_val), .codeword6(llr_reg6_val), .codeword7(llr_reg7_val), .codeword8(llr_reg8_val), .codeword9(llr_reg9_val), .codeword10(llr_reg10_val), .codeword11(llr_reg11_val), .codeword12(llr_reg12_val), .codeword13(llr_reg13_val), .codeword14(llr_reg14_val), .codeword15(llr_reg15_val), .codeword16(llr_reg16_val), .codeword17(llr_reg17_val), .codeword18(llr_reg18_val), .codeword19(llr_reg19_val), .codeword20(llr_reg20_val), .codeword21(llr_reg21_val), .codeword22(llr_reg22_val), .codeword23(llr_reg23_val), .codeword24(llr_reg24_val), .codeword25(llr_reg25_val), .codeword26(llr_reg26_val), .codeword27(llr_reg27_val), .codeword28(llr_reg28_val), .codeword29(llr_reg29_val), .codeword30(llr_reg30_val), .codeword31(llr_reg31_val), .codeword32(llr_reg32_val), .codeword33(llr_reg33_val), .codeword34(llr_reg34_val), .codeword35(llr_reg35_val), .codeword36(llr_reg36_val), .codeword37(llr_reg37_val), .codeword38(llr_reg38_val), .codeword39(llr_reg39_val), .codeword40(llr_reg40_val), .codeword41(llr_reg41_val), .codeword42(llr_reg42_val), .codeword43(llr_reg43_val), .codeword44(llr_reg44_val), .codeword45(llr_reg45_val), .codeword46(llr_reg46_val), .codeword47(llr_reg47_val), .codeword48(llr_reg48_val), .codeword49(llr_reg49_val), .get_tx(get_tx_sin));

	input_signal_cos inp_sig2(.radio_clk(radio_clk), .codeword0(llr_reg0_val), .codeword1(llr_reg1_val), .codeword2(llr_reg2_val), .codeword3(llr_reg3_val), .codeword4(llr_reg4_val), .codeword5(llr_reg5_val), .codeword6(llr_reg6_val), .codeword7(llr_reg7_val), .codeword8(llr_reg8_val), .codeword9(llr_reg9_val), .codeword10(llr_reg10_val), .codeword11(llr_reg11_val), .codeword12(llr_reg12_val), .codeword13(llr_reg13_val), .codeword14(llr_reg14_val), .codeword15(llr_reg15_val), .codeword16(llr_reg16_val), .codeword17(llr_reg17_val), .codeword18(llr_reg18_val), .codeword19(llr_reg19_val), .codeword20(llr_reg20_val), .codeword21(llr_reg21_val), .codeword22(llr_reg22_val), .codeword23(llr_reg23_val), .codeword24(llr_reg24_val), .codeword25(llr_reg25_val), .codeword26(llr_reg26_val), .codeword27(llr_reg27_val), .codeword28(llr_reg28_val), .codeword29(llr_reg29_val), .codeword30(llr_reg30_val), .codeword31(llr_reg31_val), .codeword32(llr_reg32_val), .codeword33(llr_reg33_val), .codeword34(llr_reg34_val), .codeword35(llr_reg35_val), .codeword36(llr_reg36_val), .codeword37(llr_reg37_val), .codeword38(llr_reg38_val), .codeword39(llr_reg39_val), .codeword40(llr_reg40_val), .codeword41(llr_reg41_val), .codeword42(llr_reg42_val), .codeword43(llr_reg43_val), .codeword44(llr_reg44_val), .codeword45(llr_reg45_val), .codeword46(llr_reg46_val), .codeword47(llr_reg47_val), .codeword48(llr_reg48_val), .codeword49(llr_reg49_val), .get_tx(get_tx_cos));

	//input_signal inp_sig3(.radio_clk(radio_clk), .codeword0(llr_reg0_val), .codeword1(llr_reg1_val), .codeword2(llr_reg2_val), .codeword3(llr_reg3_val), .codeword4(llr_reg4_val), .codeword5(llr_reg5_val), .codeword6(llr_reg6_val), .codeword7(llr_reg7_val), .codeword8(llr_reg8_val), .codeword9(llr_reg9_val), .codeword10(llr_reg10_val), .codeword11(llr_reg11_val), .codeword12(llr_reg12_val), .codeword13(llr_reg13_val), .codeword14(llr_reg14_val), .codeword15(llr_reg15_val), .codeword16(llr_reg16_val), .codeword17(llr_reg17_val), .codeword18(llr_reg18_val), .codeword19(llr_reg19_val), .codeword20(llr_reg20_val), .codeword21(llr_reg21_val), .codeword22(llr_reg22_val), .codeword23(llr_reg23_val), .codeword24(llr_reg24_val), .codeword25(llr_reg25_val), .codeword26(llr_reg26_val), .codeword27(llr_reg27_val), .codeword28(llr_reg28_val), .codeword29(llr_reg29_val), .codeword30(llr_reg30_val), .codeword31(llr_reg31_val), .codeword32(llr_reg32_val), .codeword33(llr_reg33_val), .codeword34(llr_reg34_val), .codeword35(llr_reg35_val), .codeword36(llr_reg36_val), .codeword37(llr_reg37_val), .codeword38(llr_reg38_val), .codeword39(llr_reg39_val), .codeword40(llr_reg40_val), .codeword41(llr_reg41_val), .codeword42(llr_reg42_val), .codeword43(llr_reg43_val), .codeword44(llr_reg44_val), .codeword45(llr_reg45_val), .codeword46(llr_reg46_val), .codeword47(llr_reg47_val), .codeword48(llr_reg48_val), .codeword49(llr_reg49_val), .get_tx(get_tx));


//   input_signal2 inp_sig(.radio_clk(radio_clk), .data0(llr_reg0_val), .data1(llr_reg1_val), .data2(llr_reg2_val), .get_tx(get_tx));

   always @(posedge radio_clk) begin
      	tx[31:16] <= (run_tx) ? get_tx_cos[31:16] : tx_idle[31:16]; // I channel
      	tx[15:0] <= (run_tx) ? get_tx_sin[31:16] : tx_idle[15:0]; // Q channel
   end
   /////////////////////////////////////////////////////////////////////////////////////
// Ending JTL code
/////////////////////////////////////////////////////////////////////////////////////





    wire [63:0] tx_tdata_i; wire tx_tlast_i, tx_tvalid_i, tx_tready_i;

   new_tx_deframer tx_deframer
     (.clk(radio_clk), .reset(radio_rst), .clear(1'b0),
      .i_tdata(tx_tdata_i), .i_tlast(tx_tlast_i), .i_tvalid(tx_tvalid_i), .i_tready(tx_tready_i),
      .sample_tdata(txsample_tdata), .sample_tvalid(txsample_tvalid), .sample_tready(txsample_tready),
      .debug());

   new_tx_control #(.BASE(SR_TX_CTRL)) tx_control
     (.clk(radio_clk), .reset(radio_rst), .clear(1'b0),
      .set_stb(set_stb), .set_addr(set_addr), .set_data(set_data),
      .vita_time(vita_time),
      .ack_or_error(ack_or_error), .packet_consumed(packet_consumed),
      .seqnum(seqnum), .error_code(error_code), .sid(sid),
      .sample_tdata(txsample_tdata), .sample_tvalid(txsample_tvalid), .sample_tready(txsample_tready),
      .sample(sample_tx), .run(run_tx), .strobe(strobe_tx2),
      .debug(debug_tx_control));

   tx_responder #(.BASE(SR_TX_CTRL+2)) tx_responder
     (.clk(radio_clk), .reset(radio_rst), .clear(1'b0),
      .set_stb(set_stb), .set_addr(set_addr), .set_data(set_data),
      .ack_or_error(ack_or_error), .packet_consumed(packet_consumed),
      .seqnum(seqnum), .error_code(error_code), .sid(sid),
      .vita_time(vita_time),
      .o_tdata(txresp_tdata_r), .o_tlast(txresp_tlast_r), .o_tvalid(txresp_tvalid_r), .o_tready(txresp_tready_r));
///////////////////////////////////////////////////////////////////////////////////////////
// Starting JTL Code
///////////////////////////////////////////////////////////////////////////////////////////
// NOTE from Rohit: This code is about to get ugly. Like, very ugly. 
// I'm pasting in 128 different frequencies, because the array syntax didn't work.
		
	   wire [63:0] 	  new_time;
	   wire [31:0] 	  new_command;
	   wire chg0,chg1,chg2,chg3;//,early,late;
	   wire [31:0]    cntrl_reg_val;// llr_reg2_val,  llr_reg3_val, llr_reg4_val; //llr_reg0_val, llr_reg1_val,  
	   wire rst_wfrm,rst_local;	

	   setting_reg #(.my_addr(SR_CMD_RX), .awidth(8), .width(32)) sr_cmd_rx
        (.clk(radio_clk), .rst(radio_rst), .strobe(set_stb), .addr(set_addr), .in(set_data),
         .out(new_command), .changed(chg0));
         
	   setting_reg #(.my_addr(SR_TIME_H_RX), .awidth(8), .width(32)) sr_time_h_rx
        (.clk(radio_clk), .rst(radio_rst), .strobe(set_stb), .addr(set_addr), .in(set_data),
         .out(new_time[63:32]), .changed(chg1));
	   
	   setting_reg #(.my_addr(SR_TIME_L_RX), .awidth(8), .width(32)) sr_time_l_rx
        (.clk(radio_clk), .rst(radio_rst), .strobe(set_stb), .addr(set_addr), .in(set_data),
         .out(new_time[31:0]), .changed(chg2));
      
      setting_reg #(.my_addr(SR_CNTRL), .awidth(8), .width(32)) sr_cntrl
        (.clk(radio_clk), .rst(radio_rst), .strobe(set_stb), .addr(set_addr), .in(set_data),
         .out(cntrl_reg_val), .changed());

      setting_reg #(.my_addr(SR_LLR_REG0), .awidth(8), .width(32)) sr_llr_reg0
        (.clk(radio_clk), .rst(radio_rst), .strobe(set_stb), .addr(set_addr), .in(set_data),
         .out(llr_reg0_val), .changed());

		setting_reg #(.my_addr(SR_LLR_REG1), .awidth(8), .width(32)) sr_llr_reg1
			(.clk(radio_clk), .rst(radio_rst), .strobe(set_stb), .addr(set_addr), .in(set_data),
			.out(llr_reg1_val), .changed());

		setting_reg #(.my_addr(SR_LLR_REG2), .awidth(8), .width(32)) sr_llr_reg2
			(.clk(radio_clk), .rst(radio_rst), .strobe(set_stb), .addr(set_addr), .in(set_data),
			.out(llr_reg2_val), .changed());

		setting_reg #(.my_addr(SR_LLR_REG3), .awidth(8), .width(32)) sr_llr_reg3
			(.clk(radio_clk), .rst(radio_rst), .strobe(set_stb), .addr(set_addr), .in(set_data),
			.out(llr_reg3_val), .changed());

		setting_reg #(.my_addr(SR_LLR_REG4), .awidth(8), .width(32)) sr_llr_reg4
			(.clk(radio_clk), .rst(radio_rst), .strobe(set_stb), .addr(set_addr), .in(set_data),
			.out(llr_reg4_val), .changed());

		setting_reg #(.my_addr(SR_LLR_REG5), .awidth(8), .width(32)) sr_llr_reg5
			(.clk(radio_clk), .rst(radio_rst), .strobe(set_stb), .addr(set_addr), .in(set_data),
			.out(llr_reg5_val), .changed());

		setting_reg #(.my_addr(SR_LLR_REG6), .awidth(8), .width(32)) sr_llr_reg6
			(.clk(radio_clk), .rst(radio_rst), .strobe(set_stb), .addr(set_addr), .in(set_data),
			.out(llr_reg6_val), .changed());

		setting_reg #(.my_addr(SR_LLR_REG7), .awidth(8), .width(32)) sr_llr_reg7
			(.clk(radio_clk), .rst(radio_rst), .strobe(set_stb), .addr(set_addr), .in(set_data),
			.out(llr_reg7_val), .changed());

		setting_reg #(.my_addr(SR_LLR_REG8), .awidth(8), .width(32)) sr_llr_reg8
			(.clk(radio_clk), .rst(radio_rst), .strobe(set_stb), .addr(set_addr), .in(set_data),
			.out(llr_reg8_val), .changed());

		setting_reg #(.my_addr(SR_LLR_REG9), .awidth(8), .width(32)) sr_llr_reg9
			(.clk(radio_clk), .rst(radio_rst), .strobe(set_stb), .addr(set_addr), .in(set_data),
			.out(llr_reg9_val), .changed());

		setting_reg #(.my_addr(SR_LLR_REG10), .awidth(8), .width(32)) sr_llr_reg10
			(.clk(radio_clk), .rst(radio_rst), .strobe(set_stb), .addr(set_addr), .in(set_data),
			.out(llr_reg10_val), .changed());

		setting_reg #(.my_addr(SR_LLR_REG11), .awidth(8), .width(32)) sr_llr_reg11
			(.clk(radio_clk), .rst(radio_rst), .strobe(set_stb), .addr(set_addr), .in(set_data),
			.out(llr_reg11_val), .changed());

		setting_reg #(.my_addr(SR_LLR_REG12), .awidth(8), .width(32)) sr_llr_reg12
			(.clk(radio_clk), .rst(radio_rst), .strobe(set_stb), .addr(set_addr), .in(set_data),
			.out(llr_reg12_val), .changed());

		setting_reg #(.my_addr(SR_LLR_REG13), .awidth(8), .width(32)) sr_llr_reg13
			(.clk(radio_clk), .rst(radio_rst), .strobe(set_stb), .addr(set_addr), .in(set_data),
			.out(llr_reg13_val), .changed());

		setting_reg #(.my_addr(SR_LLR_REG14), .awidth(8), .width(32)) sr_llr_reg14
			(.clk(radio_clk), .rst(radio_rst), .strobe(set_stb), .addr(set_addr), .in(set_data),
			.out(llr_reg14_val), .changed());

		setting_reg #(.my_addr(SR_LLR_REG15), .awidth(8), .width(32)) sr_llr_reg15
			(.clk(radio_clk), .rst(radio_rst), .strobe(set_stb), .addr(set_addr), .in(set_data),
			.out(llr_reg15_val), .changed());

		setting_reg #(.my_addr(SR_LLR_REG16), .awidth(8), .width(32)) sr_llr_reg16
			(.clk(radio_clk), .rst(radio_rst), .strobe(set_stb), .addr(set_addr), .in(set_data),
			.out(llr_reg16_val), .changed());

		setting_reg #(.my_addr(SR_LLR_REG17), .awidth(8), .width(32)) sr_llr_reg17
			(.clk(radio_clk), .rst(radio_rst), .strobe(set_stb), .addr(set_addr), .in(set_data),
			.out(llr_reg17_val), .changed());

		setting_reg #(.my_addr(SR_LLR_REG18), .awidth(8), .width(32)) sr_llr_reg18
			(.clk(radio_clk), .rst(radio_rst), .strobe(set_stb), .addr(set_addr), .in(set_data),
			.out(llr_reg18_val), .changed());

		setting_reg #(.my_addr(SR_LLR_REG19), .awidth(8), .width(32)) sr_llr_reg19
			(.clk(radio_clk), .rst(radio_rst), .strobe(set_stb), .addr(set_addr), .in(set_data),
			.out(llr_reg19_val), .changed());

/*
		setting_reg #(.my_addr(SR_LLR_REG20), .awidth(8), .width(16)) sr_llr_reg20
			(.clk(radio_clk), .rst(radio_rst), .strobe(set_stb), .addr(set_addr), .in(set_data),
			.out(llr_reg20_val), .changed());
		setting_reg #(.my_addr(SR_LLR_REG21), .awidth(8), .width(16)) sr_llr_reg21
			(.clk(radio_clk), .rst(radio_rst), .strobe(set_stb), .addr(set_addr), .in(set_data),
			.out(llr_reg21_val), .changed());

		setting_reg #(.my_addr(SR_LLR_REG22), .awidth(8), .width(16)) sr_llr_reg22
			(.clk(radio_clk), .rst(radio_rst), .strobe(set_stb), .addr(set_addr), .in(set_data),
			.out(llr_reg22_val), .changed());

		setting_reg #(.my_addr(SR_LLR_REG23), .awidth(8), .width(16)) sr_llr_reg23
			(.clk(radio_clk), .rst(radio_rst), .strobe(set_stb), .addr(set_addr), .in(set_data),
			.out(llr_reg23_val), .changed());

		setting_reg #(.my_addr(SR_LLR_REG24), .awidth(8), .width(16)) sr_llr_reg24
			(.clk(radio_clk), .rst(radio_rst), .strobe(set_stb), .addr(set_addr), .in(set_data),
			.out(llr_reg24_val), .changed());

		setting_reg #(.my_addr(SR_LLR_REG25), .awidth(8), .width(16)) sr_llr_reg25
			(.clk(radio_clk), .rst(radio_rst), .strobe(set_stb), .addr(set_addr), .in(set_data),
			.out(llr_reg25_val), .changed());

		setting_reg #(.my_addr(SR_LLR_REG26), .awidth(8), .width(16)) sr_llr_reg26
			(.clk(radio_clk), .rst(radio_rst), .strobe(set_stb), .addr(set_addr), .in(set_data),
			.out(llr_reg26_val), .changed());

		setting_reg #(.my_addr(SR_LLR_REG27), .awidth(8), .width(16)) sr_llr_reg27
			(.clk(radio_clk), .rst(radio_rst), .strobe(set_stb), .addr(set_addr), .in(set_data),
			.out(llr_reg27_val), .changed());

		setting_reg #(.my_addr(SR_LLR_REG28), .awidth(8), .width(16)) sr_llr_reg28
			(.clk(radio_clk), .rst(radio_rst), .strobe(set_stb), .addr(set_addr), .in(set_data),
			.out(llr_reg28_val), .changed());

		setting_reg #(.my_addr(SR_LLR_REG29), .awidth(8), .width(16)) sr_llr_reg29
			(.clk(radio_clk), .rst(radio_rst), .strobe(set_stb), .addr(set_addr), .in(set_data),
			.out(llr_reg29_val), .changed());

		setting_reg #(.my_addr(SR_LLR_REG30), .awidth(8), .width(16)) sr_llr_reg30
			(.clk(radio_clk), .rst(radio_rst), .strobe(set_stb), .addr(set_addr), .in(set_data),
			.out(llr_reg30_val), .changed());

		setting_reg #(.my_addr(SR_LLR_REG31), .awidth(8), .width(16)) sr_llr_reg31
			(.clk(radio_clk), .rst(radio_rst), .strobe(set_stb), .addr(set_addr), .in(set_data),
			.out(llr_reg31_val), .changed());

		setting_reg #(.my_addr(SR_LLR_REG32), .awidth(8), .width(16)) sr_llr_reg32
			(.clk(radio_clk), .rst(radio_rst), .strobe(set_stb), .addr(set_addr), .in(set_data),
			.out(llr_reg32_val), .changed());

		setting_reg #(.my_addr(SR_LLR_REG33), .awidth(8), .width(16)) sr_llr_reg33
			(.clk(radio_clk), .rst(radio_rst), .strobe(set_stb), .addr(set_addr), .in(set_data),
			.out(llr_reg33_val), .changed());

		setting_reg #(.my_addr(SR_LLR_REG34), .awidth(8), .width(16)) sr_llr_reg34
			(.clk(radio_clk), .rst(radio_rst), .strobe(set_stb), .addr(set_addr), .in(set_data),
			.out(llr_reg34_val), .changed());

		setting_reg #(.my_addr(SR_LLR_REG35), .awidth(8), .width(16)) sr_llr_reg35
			(.clk(radio_clk), .rst(radio_rst), .strobe(set_stb), .addr(set_addr), .in(set_data),
			.out(llr_reg35_val), .changed());

		setting_reg #(.my_addr(SR_LLR_REG36), .awidth(8), .width(16)) sr_llr_reg36
			(.clk(radio_clk), .rst(radio_rst), .strobe(set_stb), .addr(set_addr), .in(set_data),
			.out(llr_reg36_val), .changed());

		setting_reg #(.my_addr(SR_LLR_REG37), .awidth(8), .width(16)) sr_llr_reg37
			(.clk(radio_clk), .rst(radio_rst), .strobe(set_stb), .addr(set_addr), .in(set_data),
			.out(llr_reg37_val), .changed());

		setting_reg #(.my_addr(SR_LLR_REG38), .awidth(8), .width(16)) sr_llr_reg38
			(.clk(radio_clk), .rst(radio_rst), .strobe(set_stb), .addr(set_addr), .in(set_data),
			.out(llr_reg38_val), .changed());

		setting_reg #(.my_addr(SR_LLR_REG39), .awidth(8), .width(16)) sr_llr_reg39
			(.clk(radio_clk), .rst(radio_rst), .strobe(set_stb), .addr(set_addr), .in(set_data),
			.out(llr_reg39_val), .changed());

		setting_reg #(.my_addr(SR_LLR_REG40), .awidth(8), .width(16)) sr_llr_reg40
			(.clk(radio_clk), .rst(radio_rst), .strobe(set_stb), .addr(set_addr), .in(set_data),
			.out(llr_reg40_val), .changed());

		setting_reg #(.my_addr(SR_LLR_REG41), .awidth(8), .width(16)) sr_llr_reg41
			(.clk(radio_clk), .rst(radio_rst), .strobe(set_stb), .addr(set_addr), .in(set_data),
			.out(llr_reg41_val), .changed());

		setting_reg #(.my_addr(SR_LLR_REG42), .awidth(8), .width(16)) sr_llr_reg42
			(.clk(radio_clk), .rst(radio_rst), .strobe(set_stb), .addr(set_addr), .in(set_data),
			.out(llr_reg42_val), .changed());

		setting_reg #(.my_addr(SR_LLR_REG43), .awidth(8), .width(16)) sr_llr_reg43
			(.clk(radio_clk), .rst(radio_rst), .strobe(set_stb), .addr(set_addr), .in(set_data),
			.out(llr_reg43_val), .changed());

		setting_reg #(.my_addr(SR_LLR_REG44), .awidth(8), .width(16)) sr_llr_reg44
			(.clk(radio_clk), .rst(radio_rst), .strobe(set_stb), .addr(set_addr), .in(set_data),
			.out(llr_reg44_val), .changed());

		setting_reg #(.my_addr(SR_LLR_REG45), .awidth(8), .width(16)) sr_llr_reg45
			(.clk(radio_clk), .rst(radio_rst), .strobe(set_stb), .addr(set_addr), .in(set_data),
			.out(llr_reg45_val), .changed());

		setting_reg #(.my_addr(SR_LLR_REG46), .awidth(8), .width(16)) sr_llr_reg46
			(.clk(radio_clk), .rst(radio_rst), .strobe(set_stb), .addr(set_addr), .in(set_data),
			.out(llr_reg46_val), .changed());

		setting_reg #(.my_addr(SR_LLR_REG47), .awidth(8), .width(16)) sr_llr_reg47
			(.clk(radio_clk), .rst(radio_rst), .strobe(set_stb), .addr(set_addr), .in(set_data),
			.out(llr_reg47_val), .changed());

		setting_reg #(.my_addr(SR_LLR_REG48), .awidth(8), .width(16)) sr_llr_reg48
			(.clk(radio_clk), .rst(radio_rst), .strobe(set_stb), .addr(set_addr), .in(set_data),
			.out(llr_reg48_val), .changed());

		setting_reg #(.my_addr(SR_LLR_REG49), .awidth(8), .width(16)) sr_llr_reg49
			(.clk(radio_clk), .rst(radio_rst), .strobe(set_stb), .addr(set_addr), .in(set_data),
			.out(llr_reg49_val), .changed());
			*/

	assign rst_wfrm =  cntrl_reg_val[0];//Resets RX

	assign rst_local = radio_rst | rst_wfrm;


	assign run_tx2 = run_tx;
	assign sample_tx2 = sample_tx;
	assign strobe_tx2 = strobe_tx;
/////////////////////////////////////////////////////////////////////////////////////
// Ending JTL code
/////////////////////////////////////////////////////////////////////////////////////

   wire [31:0]       debug_duc_chain;
   duc_chain #(.BASE(SR_TX_DSP), .DSPNO(0), .WIDTH(24), .NEW_HB_INTERP(NEW_HB_INTERP),.DEVICE(DEVICE)) duc_chain
     (.clk(radio_clk), .rst(radio_rst), .clr(1'b0),
      .set_stb(set_stb),.set_addr(set_addr),.set_data(set_data),
      .tx_fe_i(tx_fe_i),.tx_fe_q(tx_fe_q),
      .sample(sample_tx2), .run(run_tx2), .strobe(strobe_tx),
      .debug(debug_duc_chain) );

`ifdef DELETE_FORMAT_CONVERSION
   assign 	     tx_tdata_i = tx_tdata_r;
   assign 	     tx_tlast_i = tx_tlast_r;
   assign 	     tx_tvalid_i = tx_tvalid_r;
   assign 	     tx_tready_r = tx_tready_i;
`else
    chdr_xxxx_to_16sc_chain #(.BASE(SR_TX_FMT)) convert_xxxx_to_16sc
     (.clk(radio_clk), .reset(radio_rst),
      .set_stb(set_stb),.set_addr(set_addr),.set_data(set_data),
      .i_tdata(tx_tdata_r), .i_tlast(tx_tlast_r), .i_tvalid(tx_tvalid_r), .i_tready(tx_tready_r),
      .o_tdata(tx_tdata_i), .o_tlast(tx_tlast_i), .o_tvalid(tx_tvalid_i), .o_tready(tx_tready_i),
      .debug());
`endif // !`ifdef DELETE_FORMAT_CONVERSION

   // /////////////////////////////////////////////////////////////////////////////////
   //  RX Chain

   wire 	full, eob_rx;
   wire 	strobe_rx,strobe_rx2;
   wire [31:0] 	sample_rx,sample_rx2;
   wire [31:0] 	  rx_sid;
   wire [11:0] 	  rx_seqnum;
   wire [63:0] rx_tdata_i; wire rx_tlast_i, rx_tvalid_i, rx_tready_i;

   wire [31:0] debug_rx_framer;
   new_rx_framer #(.BASE(SR_RX_CTRL+4),.SAMPLE_FIFO_SIZE(SAMPLE_FIFO_SIZE)) new_rx_framer
     (.clk(radio_clk), .reset(radio_rst), .clear(1'b0),
      .set_stb(set_stb), .set_addr(set_addr), .set_data(set_data),
      .vita_time(vita_time),
      .strobe(strobe_rx2), .sample(sample_rx2), .run(run_rx), .eob(eob_rx), .full(full),
      .sid(rx_sid), .seqnum(rx_seqnum),
      .o_tdata(rx_tdata_i), .o_tlast(rx_tlast_i), .o_tvalid(rx_tvalid_i), .o_tready(rx_tready_i),
      .debug(debug_rx_framer));

   wire [31:0]       debug_rx_control;
   new_rx_control #(.BASE(SR_RX_CTRL)) new_rx_control
     (.clk(radio_clk), .reset(radio_rst), .clear(1'b0),
      .set_stb(set_stb), .set_addr(set_addr), .set_data(set_data),
      .vita_time(vita_time),
      .strobe(strobe_rx2), .run(run_rx), .eob(eob_rx), .full(full),
      .sid(rx_sid), .seqnum(rx_seqnum),
      .err_tdata(rx_err_tdata_r), .err_tlast(rx_err_tlast_r), .err_tvalid(rx_err_tvalid_r), .err_tready(rx_err_tready_r),
      .ibs_state(ibs_state),
      .debug(debug_rx_control));

///////////////////////////////////////////////////////////////////////////////////////////
//CUSTOM SEDR MODULE
///////////////////////////////////////////////////////////////////////////////////////////
generate
	if (CUSTOM_ON == 1) begin

end else begin
	assign sample_rx2 = sample_rx;
	assign strobe_rx2 = strobe_rx;
end
endgenerate	
///////////////////////////////////////////////////////////////////////////////////////////

   wire [31:0] 	     debug_ddc_chain;

   // Digital Loopback TX -> RX (Pipeline immediately inside rx_frontend).
   wire [31:0] 	     rx_fe = loopback ? tx : rx;

   ddc_chain #(.BASE(SR_RX_DSP), .DSPNO(0), .WIDTH(24), .NEW_HB_DECIM(NEW_HB_DECIM), .DEVICE(DEVICE)) ddc_chain
     (.clk(radio_clk), .rst(radio_rst), .clr(1'b0),
      .set_stb(set_stb),.set_addr(set_addr),.set_data(set_data),
      .rx_fe_i({rx_fe[31:16],8'd0}),.rx_fe_q({rx_fe[15:0],8'd0}),
      .sample(sample_rx), .run(run_rx), .strobe(strobe_rx),
      .debug(debug_ddc_chain) );



`ifdef DELETE_FORMAT_CONVERSION
   assign 	     rx_prefc_tdata_r = rx_tdata_i;
   assign 	     rx_prefc_tlast_r = rx_tlast_i;
   assign 	     rx_prefc_tvalid_r = rx_tvalid_i;
   assign 	     rx_tready_i = rx_prefc_tready_r;
`else
   chdr_16sc_to_xxxx_chain #(.BASE(SR_RX_FMT)) convert_16sc_to_xxxx
     (.clk(radio_clk), .reset(radio_rst),
      .set_stb(set_stb),.set_addr(set_addr),.set_data(set_data),
      .i_tdata(rx_tdata_i), .i_tlast(rx_tlast_i), .i_tvalid(rx_tvalid_i), .i_tready(rx_tready_i),
      .o_tdata(rx_prefc_tdata_r), .o_tlast(rx_prefc_tlast_r), .o_tvalid(rx_prefc_tvalid_r), .o_tready(rx_prefc_tready_r),
      .debug());
`endif
   // /////////////////////////////////////////////////////////////////////////////////
   //  RX Channel Muxing

   axi_mux4 #(.PRIO(1), .WIDTH(64), .BUFFER(1)) rx_mux
     (.clk(radio_clk), .reset(radio_rst), .clear(1'b0),
      .i0_tdata(rx_postfc_tdata_r), .i0_tlast(rx_postfc_tlast_r), .i0_tvalid(rx_postfc_tvalid_r), .i0_tready(rx_postfc_tready_r),
      .i1_tdata(rx_err_tdata_r), .i1_tlast(rx_err_tlast_r), .i1_tvalid(rx_err_tvalid_r), .i1_tready(rx_err_tready_r),
      .i2_tdata(64'h0), .i2_tlast(1'b0), .i2_tvalid(1'b0), .i2_tready(),
      .i3_tdata(64'h0), .i3_tlast(1'b0), .i3_tvalid(1'b0), .i3_tready(),
      .o_tdata(rx_tdata_r), .o_tlast(rx_tlast_r), .o_tvalid(rx_tvalid_r), .o_tready(rx_tready_r));

   // /////////////////////////////////////////////////////////////////////////////////
   //  Response Channel Muxing

   axi_mux4 #(.PRIO(0), .WIDTH(64)) response_mux
     (.clk(radio_clk), .reset(radio_rst), .clear(1'b0),
      .i0_tdata(txresp_tdata_r), .i0_tlast(txresp_tlast_r), .i0_tvalid(txresp_tvalid_r), .i0_tready(txresp_tready_r),
      .i1_tdata(resp_tdata_r), .i1_tlast(resp_tlast_r), .i1_tvalid(resp_tvalid_r), .i1_tready(resp_tready_r),
      .i2_tdata(64'h0), .i2_tlast(1'b0), .i2_tvalid(1'b0), .i2_tready(),
      .i3_tdata(64'h0), .i3_tlast(1'b0), .i3_tvalid(1'b0), .i3_tready(),
      .o_tdata(rmux_tdata_r), .o_tlast(rmux_tlast_r), .o_tvalid(rmux_tvalid_r), .o_tready(rmux_tready_r));

   /*******************************************************************
    * Debug only logic below here.
    ******************************************************************/
 assign debug = 0;

endmodule // radio_legacy
