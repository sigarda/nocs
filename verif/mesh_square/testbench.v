// $Id: testbench.v 5188 2012-08-30 00:31:31Z dub $

/*
 Copyright (c) 2007-2012, Trustees of The Leland Stanford Junior University
 All rights reserved.

 Redistribution and use in source and binary forms, with or without
 modification, are permitted provided that the following conditions are met:

 Redistributions of source code must retain the above copyright notice, this 
 list of conditions and the following disclaimer.
 Redistributions in binary form must reproduce the above copyright notice, this
 list of conditions and the following disclaimer in the documentation and/or
 other materials provided with the distribution.

 THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND
 ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
 WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE 
 DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT OWNER OR CONTRIBUTORS BE LIABLE FOR
 ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
 (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
 LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON
 ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
 (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
 SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
*/

`default_nettype none

module testbench
  ();
   
`include "c_functions.v"
`include "c_constants.v"
`include "rtr_constants.v"
`include "vcr_constants.v"
`include "parameters.v"
   
      // warmup time in cycles
   parameter warmup_time = 30;
   
   // measurement interval in cycles
   parameter measure_time = 4;//5765074;//5765074;//1000*num_routers_per_dim;
   
   parameter log_start = warmup_time;
   
   parameter log_stop = measure_time+warmup_time;
   
   parameter testname="fft_post";
   
   parameter Tclk = 2;
   parameter initial_seed = 0;
   
   // maximum number of packets to generate (-1 = no limit)
   parameter max_packet_count = -1;
   
   // packet injection rate (percentage of cycles)
   parameter packet_rate = 25;
   
   // flit consumption rate (percentage of cycles)
   parameter consume_rate = 100;
   
   // width of packet count register
   parameter packet_count_reg_width = 32;
   
   // channel latency in cycles
   parameter channel_latency = 1;
   
   // only inject traffic at the node ports
   parameter inject_node_ports_only = 1;
   
   // select packet length mode (0: uniform random, 1: bimodal)
   parameter packet_length_mode = 0;
   
   
   // width required to select individual resource class
   localparam resource_class_idx_width = clogb(num_resource_classes);
   
   // total number of packet classes
   localparam num_packet_classes = num_message_classes * num_resource_classes;
   
   // number of VCs
   localparam num_vcs = num_packet_classes * num_vcs_per_class;
   
   // width required to select individual VC
   localparam vc_idx_width = clogb(num_vcs);
   
   // total number of routers
   localparam num_routers
     = (num_nodes + num_nodes_per_router - 1) / num_nodes_per_router;
   
   // number of routers in each dimension
   localparam num_routers_per_dim = croot(num_routers, num_dimensions);
   
   
   // width required to select individual router in a dimension
   localparam dim_addr_width = clogb(num_routers_per_dim);
   
   // width required to select individual router in entire network
   localparam router_addr_width = num_dimensions * dim_addr_width;
   
   // connectivity within each dimension
   localparam connectivity
     = (topology == `TOPOLOGY_MESH) ?
       `CONNECTIVITY_LINE :
       (topology == `TOPOLOGY_TORUS) ?
       `CONNECTIVITY_RING :
       (topology == `TOPOLOGY_FBFLY) ?
       `CONNECTIVITY_FULL :
       -1;
   
   // number of adjacent routers in each dimension
   localparam num_neighbors_per_dim
     = ((connectivity == `CONNECTIVITY_LINE) ||
	(connectivity == `CONNECTIVITY_RING)) ?
       2 :
       (connectivity == `CONNECTIVITY_FULL) ?
       (num_routers_per_dim - 1) :
       -1;
   
   // number of input and output ports on router
   localparam num_ports
     = num_dimensions * num_neighbors_per_dim + num_nodes_per_router;
   
   // width required to select individual port
   localparam port_idx_width = clogb(num_ports);
   
   // width required to select individual node at current router
   localparam node_addr_width = clogb(num_nodes_per_router);
   
   // width required for lookahead routing information
   localparam lar_info_width = port_idx_width + resource_class_idx_width;
   
   // total number of bits required for storing routing information
   localparam dest_info_width
     = (routing_type == `ROUTING_TYPE_PHASED_DOR) ? 
       (num_resource_classes * router_addr_width + node_addr_width) : 
       -1;
   
   // total number of bits required for routing-related information
   localparam route_info_width = lar_info_width + dest_info_width;
   
   // width of flow control signals
   localparam flow_ctrl_width
     = (flow_ctrl_type == `FLOW_CTRL_TYPE_CREDIT) ? (1 + vc_idx_width) :
       -1;
   
   // width of link management signals
   localparam link_ctrl_width = enable_link_pm ? 1 : 0;
   
   // width of flit control signals
   localparam flit_ctrl_width
     = (packet_format == `PACKET_FORMAT_HEAD_TAIL) ? 
       (1 + vc_idx_width + 1 + 1) : 
       (packet_format == `PACKET_FORMAT_TAIL_ONLY) ? 
       (1 + vc_idx_width + 1) : 
       (packet_format == `PACKET_FORMAT_EXPLICIT_LENGTH) ? 
       (1 + vc_idx_width + 1) : 
       -1;
   
   // channel width
   localparam channel_width
     = link_ctrl_width + flit_ctrl_width + flit_data_width;
   
   // use atomic VC allocation
   localparam atomic_vc_allocation = (elig_mask == `ELIG_MASK_USED);
   
   // number of pipeline stages in the channels
   localparam num_channel_stages = channel_latency - 1;
   
   reg clk;
   reg reset;
   
	//wires that are directly conected to the channel/flow_ctrl ports of each router
	wire [0:num_routers*num_ports*channel_width-1] channel_ops;
	wire [0:num_routers*num_ports*channel_width-1] channel_ips;
	wire [0:num_routers*num_ports*flow_ctrl_width-1] flow_ctrl_ips;
	wire [0:num_routers*num_ports*flow_ctrl_width-1] flow_ctrl_ops;

	//wires that are connected to the flit_sink and packet_source modules
   wire [0:(num_routers*channel_width)-1] injection_channels;
   wire [0:(num_routers*flow_ctrl_width)-1] injection_flow_ctrl;
   wire [0:(num_routers*channel_width)-1] ejection_channels;
   wire [0:(num_routers*flow_ctrl_width)-1] ejection_flow_ctrl;
	
   wire [0:num_routers-1] 		flit_valid_in_ip;
   wire [0:num_routers-1] 		cred_valid_out_ip;
   wire [0:num_routers-1] 		flit_valid_out_op;
   wire [0:num_routers-1] 		cred_valid_in_op;
   
   wire [0:num_routers-1] 		ps_error_ip;
   
   reg 					run;

   wire [0:num_routers-1]				    rtr_error;
   wire [0:num_routers-1]				    rchk_error;
   
   //578 Ker printing signals
   wire [0:(num_routers*num_ports*vc_idx_width)-1] sw_out_gnt_nonspec;
   wire [0:(num_routers*num_ports*vc_idx_width)-1] sw_out_gnt_spec;
   wire [0:(num_routers*num_ports*vc_idx_width)-1] sw_in_gnt_nonspec;
   wire [0:(num_routers*num_ports*vc_idx_width)-1] sw_in_gnt_spec;
   wire [0:(num_routers*num_ports*num_vcs)-1] fb_empty;
   wire [0:(num_routers*num_ports)-1] input_link_active;
   wire [0:(num_routers*num_ports*num_ports)-1] xbr_ctrl;
   wire [0:(num_routers*num_ports*num_vcs*vc_idx_width)-1] vc_out_ocvc_gnt;
   wire [0:(num_routers*num_ports*num_vcs*port_idx_width)-1] vc_out_ip_gnt;
   wire [0:(num_routers*num_ports*num_vcs)-1] vc_allocated;
   wire [0:(num_routers*num_ports*num_vcs*num_ports*vc_idx_width)-1] vc_icvc_gnt;
   
   genvar 				ip;
      
   generate
        for(ip = 0; ip < num_routers; ip = ip + 1) //variable name is "ip" but it's really the router id
	begin:ips
        wire [0:channel_width-1]   channel;
		wire 			   flit_valid;
		wire [0:router_addr_width-1] 		router_address;
		wire [0:(router_addr_width/2)-1]    upper_router_address;
		wire [0:(router_addr_width/2)-1]    lower_router_address;
		wire [0:router_addr_width-1] router_num;
		
		wire 			   ps_error;
		
		assign upper_router_address = ip%num_routers_per_dim;
		assign lower_router_address = ip/num_routers_per_dim;		
		assign router_address = {upper_router_address,lower_router_address};
		assign router_num = ip;
	   //begin 578 changes
        if ((ip % num_routers_per_dim) == 0) begin
            assign channel_ips[ (ip*num_ports*channel_width)+(0*channel_width):       
                            (ip*num_ports*channel_width)+(1*channel_width)-1] = {channel_width{1'b0}};
            
            assign flow_ctrl_ops[(ip*num_ports*flow_ctrl_width)+(0*flow_ctrl_width):       
                            (ip*num_ports*flow_ctrl_width)+(1*flow_ctrl_width)-1] = {flow_ctrl_width{1'b0}};
        end
        else begin
            assign channel_ips[ (ip*num_ports*channel_width)+(0*channel_width):       
                            (ip*num_ports*channel_width)+(1*channel_width)-1] = 
                             channel_ops[((ip-1)*num_ports*channel_width)+(1*channel_width) :  
                            ((ip-1)*num_ports*channel_width)+(2*channel_width)-1];
            
            
            assign flow_ctrl_ops[(ip*num_ports*flow_ctrl_width)+(0*flow_ctrl_width):       
                            (ip*num_ports*flow_ctrl_width)+(1*flow_ctrl_width)-1] =
                            flow_ctrl_ips[((ip-1)*num_ports*flow_ctrl_width)+(1*flow_ctrl_width) :  
                            ((ip-1)*num_ports*flow_ctrl_width)+(2*flow_ctrl_width)-1];
        end
        
        if ((ip % num_routers_per_dim) == (num_routers_per_dim -1)) begin
            assign channel_ips[ (ip*num_ports*channel_width)+(1*channel_width):
                            (ip*num_ports*channel_width)+(2*channel_width)-1] ={channel_width{1'b0}};
  
            
            assign flow_ctrl_ops[(ip*num_ports*flow_ctrl_width)+(1*flow_ctrl_width):
                            (ip*num_ports*flow_ctrl_width)+(2*flow_ctrl_width)-1] = {flow_ctrl_width{1'b0}};
        end
        else begin
            assign channel_ips[ (ip*num_ports*channel_width)+(1*channel_width):
                            (ip*num_ports*channel_width)+(2*channel_width)-1] =
                            channel_ops[((ip+1)*num_ports*channel_width)+(0*channel_width) :
                            ((ip+1)*num_ports*channel_width)+(1*channel_width)-1];
            
            assign flow_ctrl_ops[(ip*num_ports*flow_ctrl_width)+(1*flow_ctrl_width):
                            (ip*num_ports*flow_ctrl_width)+(2*flow_ctrl_width)-1] =
                            flow_ctrl_ips[((ip+1)*num_ports*flow_ctrl_width)+(0*flow_ctrl_width) :
                            ((ip+1)*num_ports*flow_ctrl_width)+(1*flow_ctrl_width)-1];
        end

        if(ip < num_routers_per_dim) begin
            assign channel_ips[ (ip*num_ports*channel_width)+(2*channel_width):
                            (ip*num_ports*channel_width)+(3*channel_width)-1] = {channel_width{1'b0}};
            
            assign flow_ctrl_ops[(ip*num_ports*flow_ctrl_width)+(2*flow_ctrl_width):
                            (ip*num_ports*flow_ctrl_width)+(3*flow_ctrl_width)-1] = {flow_ctrl_width{1'b0}};
        end
        else begin
            assign channel_ips[ (ip*num_ports*channel_width)+(2*channel_width):
                            (ip*num_ports*channel_width)+(3*channel_width)-1] =
                            channel_ops[((ip-num_routers_per_dim)*num_ports*channel_width)+(3*channel_width) :
                            ((ip-num_routers_per_dim)*num_ports*channel_width)+(4*channel_width)-1];
            
            assign flow_ctrl_ops[(ip*num_ports*flow_ctrl_width)+(2*flow_ctrl_width):
                            (ip*num_ports*flow_ctrl_width)+(3*flow_ctrl_width)-1] =
                            flow_ctrl_ips[((ip-num_routers_per_dim)*num_ports*flow_ctrl_width)+(3*flow_ctrl_width) :
                            ((ip-num_routers_per_dim)*num_ports*flow_ctrl_width)+(4*flow_ctrl_width)-1];
        end
  
        if(ip >= (num_routers - num_routers_per_dim)) begin
            assign channel_ips[ (ip*num_ports*channel_width)+(3*channel_width):
                            (ip*num_ports*channel_width)+(4*channel_width)-1] = {channel_width{1'b0}};
            
            assign flow_ctrl_ops[(ip*num_ports*flow_ctrl_width)+(3*flow_ctrl_width):
                            (ip*num_ports*flow_ctrl_width)+(4*flow_ctrl_width)-1] = {flow_ctrl_width{1'b0}};
        end
        else begin
            assign channel_ips[ (ip*num_ports*channel_width)+(3*channel_width):
                            (ip*num_ports*channel_width)+(4*channel_width)-1] =
                            channel_ops[((ip+num_routers_per_dim)*num_ports*channel_width)+(2*channel_width) :
                            ((ip+num_routers_per_dim)*num_ports*channel_width)+(3*channel_width)-1];
            
            assign flow_ctrl_ops[(ip*num_ports*flow_ctrl_width)+(3*flow_ctrl_width):
                            (ip*num_ports*flow_ctrl_width)+(4*flow_ctrl_width)-1] =
                            flow_ctrl_ips[((ip+num_routers_per_dim)*num_ports*flow_ctrl_width)+(2*flow_ctrl_width) :
                            ((ip+num_routers_per_dim)*num_ports*flow_ctrl_width)+(3*flow_ctrl_width)-1];
        end

        assign channel_ips[ (ip*num_ports*channel_width)+(4*channel_width):
                    (ip*num_ports*channel_width)+(5*channel_width)-1] = 
                    injection_channels[ip*channel_width:((ip+1)*channel_width)-1];
        assign flow_ctrl_ops[ (ip*num_ports*flow_ctrl_width)+(4*flow_ctrl_width):
                            (ip*num_ports*flow_ctrl_width)+(5*flow_ctrl_width)-1] =
                            ejection_flow_ctrl[ip*flow_ctrl_width:((ip+1)*flow_ctrl_width)-1];



        assign injection_flow_ctrl[ip*flow_ctrl_width:((ip+1)*flow_ctrl_width)-1] = 
                         flow_ctrl_ips[(ip*num_ports*flow_ctrl_width)+(4*flow_ctrl_width) :
                                       (ip*num_ports*flow_ctrl_width)+(5*flow_ctrl_width)-1];
        assign ejection_channels[ip*channel_width:((ip+1)*channel_width)-1] = 
                        channel_ops[(ip*num_ports*channel_width)+(4*channel_width) :
                                    (ip*num_ports*channel_width)+(5*channel_width)-1];
       
       
          router_wrap
     #(.topology(topology),
       .buffer_size(buffer_size),
       .num_message_classes(num_message_classes),
       .num_resource_classes(num_resource_classes),
       .num_vcs_per_class(num_vcs_per_class),
       .num_nodes(num_nodes),
       .num_dimensions(num_dimensions),
       .num_nodes_per_router(num_nodes_per_router),
       .packet_format(packet_format),
       .flow_ctrl_type(flow_ctrl_type),
       .flow_ctrl_bypass(flow_ctrl_bypass),
       .max_payload_length(max_payload_length),
       .min_payload_length(min_payload_length),
       .router_type(router_type),
       .enable_link_pm(enable_link_pm),
       .flit_data_width(flit_data_width),
       .error_capture_mode(error_capture_mode),
       .restrict_turns(restrict_turns),
       .predecode_lar_info(predecode_lar_info),
       .routing_type(routing_type),
       .dim_order(dim_order),
       .input_stage_can_hold(input_stage_can_hold),
       .fb_regfile_type(fb_regfile_type),
       .fb_mgmt_type(fb_mgmt_type),
       .explicit_pipeline_register(explicit_pipeline_register),
       .dual_path_alloc(dual_path_alloc),
       .dual_path_allow_conflicts(dual_path_allow_conflicts),
       .dual_path_mask_on_ready(dual_path_mask_on_ready),
       .precomp_ivc_sel(precomp_ivc_sel),
       .precomp_ip_sel(precomp_ip_sel),
       .elig_mask(elig_mask),
       .vc_alloc_type(vc_alloc_type),
       .vc_alloc_arbiter_type(vc_alloc_arbiter_type),
       .vc_alloc_prefer_empty(vc_alloc_prefer_empty),
       .sw_alloc_type(sw_alloc_type),
       .sw_alloc_arbiter_type(sw_alloc_arbiter_type),
       .sw_alloc_spec_type(sw_alloc_spec_type),
       .crossbar_type(crossbar_type),
       .reset_type(reset_type))
   rtr
     (.clk(clk),
      .reset(reset),
      .router_address(router_address),
      .channel_in_ip(channel_ips[ip*num_ports*channel_width:(ip+1)*num_ports*channel_width-1]),
      .flow_ctrl_out_ip(flow_ctrl_ips[ip*num_ports*flow_ctrl_width:(ip+1)*num_ports*flow_ctrl_width-1]),
      .channel_out_op(channel_ops[ip*num_ports*channel_width:(ip+1)*num_ports*channel_width-1]),
      .flow_ctrl_in_op(flow_ctrl_ops[ip*num_ports*flow_ctrl_width:(ip+1)*num_ports*flow_ctrl_width-1]),
      .error(rtr_error[ip]));
       
       //capturing signals again I know it's ugly (though slightly prettier) 
       /*wire [0:num_ports*vc_idx_width-1] local_sw_out_gnt_nonspec;
       assign local_sw_out_gnt_nonspec = {rtr.genblk1.vcr.alo.genblk2.sw_core_sep_if.ops[0].genblk1.gnt_out_nonspec_ip_arb.genblk1.genblk1.rr_arb.genblk2.state_q,
                           rtr.genblk1.vcr.alo.genblk2.sw_core_sep_if.ops[1].genblk1.gnt_out_nonspec_ip_arb.genblk1.genblk1.rr_arb.genblk2.state_q,
                           rtr.genblk1.vcr.alo.genblk2.sw_core_sep_if.ops[2].genblk1.gnt_out_nonspec_ip_arb.genblk1.genblk1.rr_arb.genblk2.state_q,
                           rtr.genblk1.vcr.alo.genblk2.sw_core_sep_if.ops[3].genblk1.gnt_out_nonspec_ip_arb.genblk1.genblk1.rr_arb.genblk2.state_q,
                           rtr.genblk1.vcr.alo.genblk2.sw_core_sep_if.ops[4].genblk1.gnt_out_nonspec_ip_arb.genblk1.genblk1.rr_arb.genblk2.state_q};
       assign sw_out_gnt_nonspec[(ip*num_ports*vc_idx_width):((ip+1)*num_ports*vc_idx_width)-1] = local_sw_out_gnt_nonspec;*/
       
       /*wire [0:num_ports*vc_idx_width-1] local_sw_out_gnt_spec;
       assign local_sw_out_gnt_spec = { rtr.genblk1.vcr.alo.genblk2.sw_core_sep_if.ops[0].genblk2.genblk1.gnt_out_spec_ip_arb.genblk1.genblk1.rr_arb.genblk2.state_q,
                                        rtr.genblk1.vcr.alo.genblk2.sw_core_sep_if.ops[1].genblk2.genblk1.gnt_out_spec_ip_arb.genblk1.genblk1.rr_arb.genblk2.state_q,
                                        rtr.genblk1.vcr.alo.genblk2.sw_core_sep_if.ops[2].genblk2.genblk1.gnt_out_spec_ip_arb.genblk1.genblk1.rr_arb.genblk2.state_q,
                                        rtr.genblk1.vcr.alo.genblk2.sw_core_sep_if.ops[3].genblk2.genblk1.gnt_out_spec_ip_arb.genblk1.genblk1.rr_arb.genblk2.state_q,
                                        rtr.genblk1.vcr.alo.genblk2.sw_core_sep_if.ops[4].genblk2.genblk1.gnt_out_spec_ip_arb.genblk1.genblk1.rr_arb.genblk2.state_q};
       assign sw_out_gnt_spec[(ip*num_ports*vc_idx_width):((ip+1)*num_ports*vc_idx_width)-1] = local_sw_out_gnt_spec;*/
       
       /*wire [0:num_ports*vc_idx_width-1] local_sw_in_gnt_nonspec;
       assign local_sw_in_gnt_nonspec = {rtr.genblk1.vcr.alo.genblk2.sw_core_sep_if.ips[0].genblk1.gnt_in_nonspec_ivc_arb.genblk1.genblk1.rr_arb.genblk2.state_q,
                                        rtr.genblk1.vcr.alo.genblk2.sw_core_sep_if.ips[1].genblk1.gnt_in_nonspec_ivc_arb.genblk1.genblk1.rr_arb.genblk2.state_q,
                                        rtr.genblk1.vcr.alo.genblk2.sw_core_sep_if.ips[2].genblk1.gnt_in_nonspec_ivc_arb.genblk1.genblk1.rr_arb.genblk2.state_q,
                                        rtr.genblk1.vcr.alo.genblk2.sw_core_sep_if.ips[3].genblk1.gnt_in_nonspec_ivc_arb.genblk1.genblk1.rr_arb.genblk2.state_q,
                                        rtr.genblk1.vcr.alo.genblk2.sw_core_sep_if.ips[4].genblk1.gnt_in_nonspec_ivc_arb.genblk1.genblk1.rr_arb.genblk2.state_q};
       assign sw_in_gnt_nonspec[(ip*num_ports*vc_idx_width):((ip+1)*num_ports*vc_idx_width)-1] = local_sw_out_gnt_nonspec;*/
       
       /*wire [0:num_ports*vc_idx_width-1] local_sw_in_gnt_spec;
       assign local_sw_in_gnt_spec = {rtr.genblk1.vcr.alo.genblk2.sw_core_sep_if.ips[0].genblk2.genblk1.gnt_in_spec_ivc_arb.genblk1.genblk1.rr_arb.genblk2.state_q,
                                        rtr.genblk1.vcr.alo.genblk2.sw_core_sep_if.ips[1].genblk2.genblk1.gnt_in_spec_ivc_arb.genblk1.genblk1.rr_arb.genblk2.state_q,
                                        rtr.genblk1.vcr.alo.genblk2.sw_core_sep_if.ips[2].genblk2.genblk1.gnt_in_spec_ivc_arb.genblk1.genblk1.rr_arb.genblk2.state_q,
                                        rtr.genblk1.vcr.alo.genblk2.sw_core_sep_if.ips[3].genblk2.genblk1.gnt_in_spec_ivc_arb.genblk1.genblk1.rr_arb.genblk2.state_q,
                                        rtr.genblk1.vcr.alo.genblk2.sw_core_sep_if.ips[4].genblk2.genblk1.gnt_in_spec_ivc_arb.genblk1.genblk1.rr_arb.genblk2.state_q};
       assign sw_in_gnt_spec[(ip*num_ports*vc_idx_width):((ip+1)*num_ports*vc_idx_width)-1] = local_sw_in_gnt_spec;*/
       
       //KER 573 switch to empty from full
       wire [0:num_ports*num_vcs-1] local_fb_empty;
       assign local_fb_empty = { rtr.genblk1.vcr.ips[0].ipc.fb.empty_ivc,
                                rtr.genblk1.vcr.ips[1].ipc.fb.empty_ivc,
                                rtr.genblk1.vcr.ips[2].ipc.fb.empty_ivc,
                                rtr.genblk1.vcr.ips[3].ipc.fb.empty_ivc,
                                rtr.genblk1.vcr.ips[4].ipc.fb.empty_ivc};
       assign fb_empty[(ip*num_ports*num_vcs):((ip+1)*num_ports*num_vcs)-1] = local_fb_empty;
       
       wire [0:(num_ports)-1] local_input_link_active;
       assign local_input_link_active = {   rtr.genblk1.vcr.ips[0].ipc.chi.genblk1.link_active_q,
                                            rtr.genblk1.vcr.ips[1].ipc.chi.genblk1.link_active_q,
                                            rtr.genblk1.vcr.ips[2].ipc.chi.genblk1.link_active_q,
                                            rtr.genblk1.vcr.ips[3].ipc.chi.genblk1.link_active_q,
                                            rtr.genblk1.vcr.ips[4].ipc.chi.genblk1.link_active_q};
       assign input_link_active[ip*num_ports:(ip+1)*num_ports-1] = local_input_link_active;
       
       wire [0:(num_ports*num_ports)-1] local_xbr_ctrl;
       assign local_xbr_ctrl = {    rtr.genblk1.vcr.alo.ops[0].xbr_ctrl_ip_q,
                                    rtr.genblk1.vcr.alo.ops[1].xbr_ctrl_ip_q,
                                    rtr.genblk1.vcr.alo.ops[2].xbr_ctrl_ip_q,
                                    rtr.genblk1.vcr.alo.ops[3].xbr_ctrl_ip_q,
                                    rtr.genblk1.vcr.alo.ops[4].xbr_ctrl_ip_q};
       assign xbr_ctrl[ip*num_ports*num_ports:(ip+1)*num_ports*num_ports -1] = local_xbr_ctrl;
       /*
       wire [0:(num_ports*num_vcs*vc_idx_width)-1] local_vc_out_ocvc_gnt;
       assign local_vc_out_ocvc_gnt = { rtr.genblk1.vcr.alo.genblk1.vc_core_sep_if.mcs[0].ips[0].ircs[0].icvcs[0].orcs[0].gnt_ocvc_arb.genblk1.genblk1.rr_arb.genblk2.state_q,
                                        rtr.genblk1.vcr.alo.genblk1.vc_core_sep_if.mcs[0].ips[0].ircs[0].icvcs[1].orcs[0].gnt_ocvc_arb.genblk1.genblk1.rr_arb.genblk2.state_q,
                                        rtr.genblk1.vcr.alo.genblk1.vc_core_sep_if.mcs[0].ips[0].ircs[0].icvcs[2].orcs[0].gnt_ocvc_arb.genblk1.genblk1.rr_arb.genblk2.state_q,
                                        rtr.genblk1.vcr.alo.genblk1.vc_core_sep_if.mcs[0].ips[0].ircs[0].icvcs[3].orcs[0].gnt_ocvc_arb.genblk1.genblk1.rr_arb.genblk2.state_q,
                                        rtr.genblk1.vcr.alo.genblk1.vc_core_sep_if.mcs[0].ips[1].ircs[0].icvcs[0].orcs[0].gnt_ocvc_arb.genblk1.genblk1.rr_arb.genblk2.state_q,
                                        rtr.genblk1.vcr.alo.genblk1.vc_core_sep_if.mcs[0].ips[1].ircs[0].icvcs[1].orcs[0].gnt_ocvc_arb.genblk1.genblk1.rr_arb.genblk2.state_q,
                                        rtr.genblk1.vcr.alo.genblk1.vc_core_sep_if.mcs[0].ips[1].ircs[0].icvcs[2].orcs[0].gnt_ocvc_arb.genblk1.genblk1.rr_arb.genblk2.state_q,
                                        rtr.genblk1.vcr.alo.genblk1.vc_core_sep_if.mcs[0].ips[1].ircs[0].icvcs[3].orcs[0].gnt_ocvc_arb.genblk1.genblk1.rr_arb.genblk2.state_q,
                                        rtr.genblk1.vcr.alo.genblk1.vc_core_sep_if.mcs[0].ips[2].ircs[0].icvcs[0].orcs[0].gnt_ocvc_arb.genblk1.genblk1.rr_arb.genblk2.state_q,
                                        rtr.genblk1.vcr.alo.genblk1.vc_core_sep_if.mcs[0].ips[2].ircs[0].icvcs[1].orcs[0].gnt_ocvc_arb.genblk1.genblk1.rr_arb.genblk2.state_q,
                                        rtr.genblk1.vcr.alo.genblk1.vc_core_sep_if.mcs[0].ips[2].ircs[0].icvcs[2].orcs[0].gnt_ocvc_arb.genblk1.genblk1.rr_arb.genblk2.state_q,
                                        rtr.genblk1.vcr.alo.genblk1.vc_core_sep_if.mcs[0].ips[2].ircs[0].icvcs[3].orcs[0].gnt_ocvc_arb.genblk1.genblk1.rr_arb.genblk2.state_q,
                                        rtr.genblk1.vcr.alo.genblk1.vc_core_sep_if.mcs[0].ips[3].ircs[0].icvcs[0].orcs[0].gnt_ocvc_arb.genblk1.genblk1.rr_arb.genblk2.state_q,
                                        rtr.genblk1.vcr.alo.genblk1.vc_core_sep_if.mcs[0].ips[3].ircs[0].icvcs[1].orcs[0].gnt_ocvc_arb.genblk1.genblk1.rr_arb.genblk2.state_q,
                                        rtr.genblk1.vcr.alo.genblk1.vc_core_sep_if.mcs[0].ips[3].ircs[0].icvcs[2].orcs[0].gnt_ocvc_arb.genblk1.genblk1.rr_arb.genblk2.state_q,
                                        rtr.genblk1.vcr.alo.genblk1.vc_core_sep_if.mcs[0].ips[3].ircs[0].icvcs[3].orcs[0].gnt_ocvc_arb.genblk1.genblk1.rr_arb.genblk2.state_q,
                                        rtr.genblk1.vcr.alo.genblk1.vc_core_sep_if.mcs[0].ips[4].ircs[0].icvcs[0].orcs[0].gnt_ocvc_arb.genblk1.genblk1.rr_arb.genblk2.state_q,
                                        rtr.genblk1.vcr.alo.genblk1.vc_core_sep_if.mcs[0].ips[4].ircs[0].icvcs[1].orcs[0].gnt_ocvc_arb.genblk1.genblk1.rr_arb.genblk2.state_q,
                                        rtr.genblk1.vcr.alo.genblk1.vc_core_sep_if.mcs[0].ips[4].ircs[0].icvcs[2].orcs[0].gnt_ocvc_arb.genblk1.genblk1.rr_arb.genblk2.state_q,
                                        rtr.genblk1.vcr.alo.genblk1.vc_core_sep_if.mcs[0].ips[4].ircs[0].icvcs[3].orcs[0].gnt_ocvc_arb.genblk1.genblk1.rr_arb.genblk2.state_q};     
       assign vc_out_ocvc_gnt[(ip*num_ports*num_vcs*vc_idx_width):((ip+1)*num_ports*num_vcs*vc_idx_width)-1] = local_vc_out_ocvc_gnt;
       
       wire [0:(num_ports*num_vcs*port_idx_width)-1] local_vc_out_ip_gnt;
       assign local_vc_out_ip_gnt = {   rtr.genblk1.vcr.alo.genblk1.vc_core_sep_if.mcs[0].ops[0].orcs[0].ocvcs[0].gnt_out_ip_arb.genblk1.genblk1.rr_arb.genblk2.state_q,
                                        rtr.genblk1.vcr.alo.genblk1.vc_core_sep_if.mcs[0].ops[0].orcs[0].ocvcs[1].gnt_out_ip_arb.genblk1.genblk1.rr_arb.genblk2.state_q,
                                        rtr.genblk1.vcr.alo.genblk1.vc_core_sep_if.mcs[0].ops[0].orcs[0].ocvcs[2].gnt_out_ip_arb.genblk1.genblk1.rr_arb.genblk2.state_q,
                                        rtr.genblk1.vcr.alo.genblk1.vc_core_sep_if.mcs[0].ops[0].orcs[0].ocvcs[3].gnt_out_ip_arb.genblk1.genblk1.rr_arb.genblk2.state_q,
                                        rtr.genblk1.vcr.alo.genblk1.vc_core_sep_if.mcs[0].ops[1].orcs[0].ocvcs[0].gnt_out_ip_arb.genblk1.genblk1.rr_arb.genblk2.state_q,
                                        rtr.genblk1.vcr.alo.genblk1.vc_core_sep_if.mcs[0].ops[1].orcs[0].ocvcs[1].gnt_out_ip_arb.genblk1.genblk1.rr_arb.genblk2.state_q,
                                        rtr.genblk1.vcr.alo.genblk1.vc_core_sep_if.mcs[0].ops[1].orcs[0].ocvcs[2].gnt_out_ip_arb.genblk1.genblk1.rr_arb.genblk2.state_q,
                                        rtr.genblk1.vcr.alo.genblk1.vc_core_sep_if.mcs[0].ops[1].orcs[0].ocvcs[3].gnt_out_ip_arb.genblk1.genblk1.rr_arb.genblk2.state_q,
                                        rtr.genblk1.vcr.alo.genblk1.vc_core_sep_if.mcs[0].ops[2].orcs[0].ocvcs[0].gnt_out_ip_arb.genblk1.genblk1.rr_arb.genblk2.state_q,
                                        rtr.genblk1.vcr.alo.genblk1.vc_core_sep_if.mcs[0].ops[2].orcs[0].ocvcs[1].gnt_out_ip_arb.genblk1.genblk1.rr_arb.genblk2.state_q,
                                        rtr.genblk1.vcr.alo.genblk1.vc_core_sep_if.mcs[0].ops[2].orcs[0].ocvcs[2].gnt_out_ip_arb.genblk1.genblk1.rr_arb.genblk2.state_q,
                                        rtr.genblk1.vcr.alo.genblk1.vc_core_sep_if.mcs[0].ops[2].orcs[0].ocvcs[3].gnt_out_ip_arb.genblk1.genblk1.rr_arb.genblk2.state_q,
                                        rtr.genblk1.vcr.alo.genblk1.vc_core_sep_if.mcs[0].ops[3].orcs[0].ocvcs[0].gnt_out_ip_arb.genblk1.genblk1.rr_arb.genblk2.state_q,
                                        rtr.genblk1.vcr.alo.genblk1.vc_core_sep_if.mcs[0].ops[3].orcs[0].ocvcs[1].gnt_out_ip_arb.genblk1.genblk1.rr_arb.genblk2.state_q,
                                        rtr.genblk1.vcr.alo.genblk1.vc_core_sep_if.mcs[0].ops[3].orcs[0].ocvcs[2].gnt_out_ip_arb.genblk1.genblk1.rr_arb.genblk2.state_q,
                                        rtr.genblk1.vcr.alo.genblk1.vc_core_sep_if.mcs[0].ops[3].orcs[0].ocvcs[3].gnt_out_ip_arb.genblk1.genblk1.rr_arb.genblk2.state_q,
                                        rtr.genblk1.vcr.alo.genblk1.vc_core_sep_if.mcs[0].ops[4].orcs[0].ocvcs[0].gnt_out_ip_arb.genblk1.genblk1.rr_arb.genblk2.state_q,
                                        rtr.genblk1.vcr.alo.genblk1.vc_core_sep_if.mcs[0].ops[4].orcs[0].ocvcs[1].gnt_out_ip_arb.genblk1.genblk1.rr_arb.genblk2.state_q,
                                        rtr.genblk1.vcr.alo.genblk1.vc_core_sep_if.mcs[0].ops[4].orcs[0].ocvcs[2].gnt_out_ip_arb.genblk1.genblk1.rr_arb.genblk2.state_q,
                                        rtr.genblk1.vcr.alo.genblk1.vc_core_sep_if.mcs[0].ops[4].orcs[0].ocvcs[3].gnt_out_ip_arb.genblk1.genblk1.rr_arb.genblk2.state_q};
       assign vc_out_ip_gnt[(ip*num_ports*num_vcs*port_idx_width):((ip+1)*num_ports*num_vcs*port_idx_width)-1] = local_vc_out_ip_gnt;
       
       wire [0:(num_ports*num_vcs)-1] local_vc_allocated;
       assign local_vc_allocated = {    rtr.genblk1.vcr.ips[0].ipc.ivcs[0].ivcc.vc_allocated_q,
                                        rtr.genblk1.vcr.ips[0].ipc.ivcs[1].ivcc.vc_allocated_q,
                                        rtr.genblk1.vcr.ips[0].ipc.ivcs[2].ivcc.vc_allocated_q,
                                        rtr.genblk1.vcr.ips[0].ipc.ivcs[3].ivcc.vc_allocated_q,
                                        rtr.genblk1.vcr.ips[1].ipc.ivcs[0].ivcc.vc_allocated_q,
                                        rtr.genblk1.vcr.ips[1].ipc.ivcs[1].ivcc.vc_allocated_q,
                                        rtr.genblk1.vcr.ips[1].ipc.ivcs[2].ivcc.vc_allocated_q,
                                        rtr.genblk1.vcr.ips[1].ipc.ivcs[3].ivcc.vc_allocated_q,
                                        rtr.genblk1.vcr.ips[2].ipc.ivcs[0].ivcc.vc_allocated_q,
                                        rtr.genblk1.vcr.ips[2].ipc.ivcs[1].ivcc.vc_allocated_q,
                                        rtr.genblk1.vcr.ips[2].ipc.ivcs[2].ivcc.vc_allocated_q,
                                        rtr.genblk1.vcr.ips[2].ipc.ivcs[3].ivcc.vc_allocated_q,
                                        rtr.genblk1.vcr.ips[3].ipc.ivcs[0].ivcc.vc_allocated_q,
                                        rtr.genblk1.vcr.ips[3].ipc.ivcs[1].ivcc.vc_allocated_q,
                                        rtr.genblk1.vcr.ips[3].ipc.ivcs[2].ivcc.vc_allocated_q,
                                        rtr.genblk1.vcr.ips[3].ipc.ivcs[3].ivcc.vc_allocated_q,
                                        rtr.genblk1.vcr.ips[4].ipc.ivcs[0].ivcc.vc_allocated_q,
                                        rtr.genblk1.vcr.ips[4].ipc.ivcs[1].ivcc.vc_allocated_q,
                                        rtr.genblk1.vcr.ips[4].ipc.ivcs[2].ivcc.vc_allocated_q,
                                        rtr.genblk1.vcr.ips[4].ipc.ivcs[3].ivcc.vc_allocated_q};
       assign vc_allocated[(ip*num_ports*num_vcs):((ip+1)*num_ports*num_vcs)-1] = local_vc_allocated;
       
       wire [0:(num_ports*num_vcs*num_ports*vc_idx_width)-1] local_vc_icvc_gnt;
       assign local_vc_icvc_gnt = { rtr.genblk1.vcr.alo.genblk1.vc_core_sep_if.mcs[0].ops[0].orcs[0].ocvcs[0].ips[0].gnt_our_irc_icvc_arb.genblk1.genblk1.rr_arb.genblk2.state_q,
                                    rtr.genblk1.vcr.alo.genblk1.vc_core_sep_if.mcs[0].ops[0].orcs[0].ocvcs[0].ips[1].gnt_our_irc_icvc_arb.genblk1.genblk1.rr_arb.genblk2.state_q,
                                    rtr.genblk1.vcr.alo.genblk1.vc_core_sep_if.mcs[0].ops[0].orcs[0].ocvcs[0].ips[2].gnt_our_irc_icvc_arb.genblk1.genblk1.rr_arb.genblk2.state_q,
                                    rtr.genblk1.vcr.alo.genblk1.vc_core_sep_if.mcs[0].ops[0].orcs[0].ocvcs[0].ips[3].gnt_our_irc_icvc_arb.genblk1.genblk1.rr_arb.genblk2.state_q,
                                    rtr.genblk1.vcr.alo.genblk1.vc_core_sep_if.mcs[0].ops[0].orcs[0].ocvcs[0].ips[4].gnt_our_irc_icvc_arb.genblk1.genblk1.rr_arb.genblk2.state_q,
                                    rtr.genblk1.vcr.alo.genblk1.vc_core_sep_if.mcs[0].ops[0].orcs[0].ocvcs[1].ips[0].gnt_our_irc_icvc_arb.genblk1.genblk1.rr_arb.genblk2.state_q,
                                    rtr.genblk1.vcr.alo.genblk1.vc_core_sep_if.mcs[0].ops[0].orcs[0].ocvcs[1].ips[1].gnt_our_irc_icvc_arb.genblk1.genblk1.rr_arb.genblk2.state_q,
                                    rtr.genblk1.vcr.alo.genblk1.vc_core_sep_if.mcs[0].ops[0].orcs[0].ocvcs[1].ips[2].gnt_our_irc_icvc_arb.genblk1.genblk1.rr_arb.genblk2.state_q,
                                    rtr.genblk1.vcr.alo.genblk1.vc_core_sep_if.mcs[0].ops[0].orcs[0].ocvcs[1].ips[3].gnt_our_irc_icvc_arb.genblk1.genblk1.rr_arb.genblk2.state_q,
                                    rtr.genblk1.vcr.alo.genblk1.vc_core_sep_if.mcs[0].ops[0].orcs[0].ocvcs[1].ips[4].gnt_our_irc_icvc_arb.genblk1.genblk1.rr_arb.genblk2.state_q,
                                    rtr.genblk1.vcr.alo.genblk1.vc_core_sep_if.mcs[0].ops[0].orcs[0].ocvcs[2].ips[0].gnt_our_irc_icvc_arb.genblk1.genblk1.rr_arb.genblk2.state_q,
                                    rtr.genblk1.vcr.alo.genblk1.vc_core_sep_if.mcs[0].ops[0].orcs[0].ocvcs[2].ips[1].gnt_our_irc_icvc_arb.genblk1.genblk1.rr_arb.genblk2.state_q,
                                    rtr.genblk1.vcr.alo.genblk1.vc_core_sep_if.mcs[0].ops[0].orcs[0].ocvcs[2].ips[2].gnt_our_irc_icvc_arb.genblk1.genblk1.rr_arb.genblk2.state_q,
                                    rtr.genblk1.vcr.alo.genblk1.vc_core_sep_if.mcs[0].ops[0].orcs[0].ocvcs[2].ips[3].gnt_our_irc_icvc_arb.genblk1.genblk1.rr_arb.genblk2.state_q,
                                    rtr.genblk1.vcr.alo.genblk1.vc_core_sep_if.mcs[0].ops[0].orcs[0].ocvcs[2].ips[4].gnt_our_irc_icvc_arb.genblk1.genblk1.rr_arb.genblk2.state_q,
                                    rtr.genblk1.vcr.alo.genblk1.vc_core_sep_if.mcs[0].ops[0].orcs[0].ocvcs[3].ips[0].gnt_our_irc_icvc_arb.genblk1.genblk1.rr_arb.genblk2.state_q,
                                    rtr.genblk1.vcr.alo.genblk1.vc_core_sep_if.mcs[0].ops[0].orcs[0].ocvcs[3].ips[1].gnt_our_irc_icvc_arb.genblk1.genblk1.rr_arb.genblk2.state_q,
                                    rtr.genblk1.vcr.alo.genblk1.vc_core_sep_if.mcs[0].ops[0].orcs[0].ocvcs[3].ips[2].gnt_our_irc_icvc_arb.genblk1.genblk1.rr_arb.genblk2.state_q,
                                    rtr.genblk1.vcr.alo.genblk1.vc_core_sep_if.mcs[0].ops[0].orcs[0].ocvcs[3].ips[3].gnt_our_irc_icvc_arb.genblk1.genblk1.rr_arb.genblk2.state_q,
                                    rtr.genblk1.vcr.alo.genblk1.vc_core_sep_if.mcs[0].ops[0].orcs[0].ocvcs[3].ips[4].gnt_our_irc_icvc_arb.genblk1.genblk1.rr_arb.genblk2.state_q,
                                    
                                    rtr.genblk1.vcr.alo.genblk1.vc_core_sep_if.mcs[0].ops[1].orcs[0].ocvcs[0].ips[0].gnt_our_irc_icvc_arb.genblk1.genblk1.rr_arb.genblk2.state_q,
                                    rtr.genblk1.vcr.alo.genblk1.vc_core_sep_if.mcs[0].ops[1].orcs[0].ocvcs[0].ips[1].gnt_our_irc_icvc_arb.genblk1.genblk1.rr_arb.genblk2.state_q,
                                    rtr.genblk1.vcr.alo.genblk1.vc_core_sep_if.mcs[0].ops[1].orcs[0].ocvcs[0].ips[2].gnt_our_irc_icvc_arb.genblk1.genblk1.rr_arb.genblk2.state_q,
                                    rtr.genblk1.vcr.alo.genblk1.vc_core_sep_if.mcs[0].ops[1].orcs[0].ocvcs[0].ips[3].gnt_our_irc_icvc_arb.genblk1.genblk1.rr_arb.genblk2.state_q,
                                    rtr.genblk1.vcr.alo.genblk1.vc_core_sep_if.mcs[0].ops[1].orcs[0].ocvcs[0].ips[4].gnt_our_irc_icvc_arb.genblk1.genblk1.rr_arb.genblk2.state_q,
                                    rtr.genblk1.vcr.alo.genblk1.vc_core_sep_if.mcs[0].ops[1].orcs[0].ocvcs[1].ips[0].gnt_our_irc_icvc_arb.genblk1.genblk1.rr_arb.genblk2.state_q,
                                    rtr.genblk1.vcr.alo.genblk1.vc_core_sep_if.mcs[0].ops[1].orcs[0].ocvcs[1].ips[1].gnt_our_irc_icvc_arb.genblk1.genblk1.rr_arb.genblk2.state_q,
                                    rtr.genblk1.vcr.alo.genblk1.vc_core_sep_if.mcs[0].ops[1].orcs[0].ocvcs[1].ips[2].gnt_our_irc_icvc_arb.genblk1.genblk1.rr_arb.genblk2.state_q,
                                    rtr.genblk1.vcr.alo.genblk1.vc_core_sep_if.mcs[0].ops[1].orcs[0].ocvcs[1].ips[3].gnt_our_irc_icvc_arb.genblk1.genblk1.rr_arb.genblk2.state_q,
                                    rtr.genblk1.vcr.alo.genblk1.vc_core_sep_if.mcs[0].ops[1].orcs[0].ocvcs[1].ips[4].gnt_our_irc_icvc_arb.genblk1.genblk1.rr_arb.genblk2.state_q,
                                    rtr.genblk1.vcr.alo.genblk1.vc_core_sep_if.mcs[0].ops[1].orcs[0].ocvcs[2].ips[0].gnt_our_irc_icvc_arb.genblk1.genblk1.rr_arb.genblk2.state_q,
                                    rtr.genblk1.vcr.alo.genblk1.vc_core_sep_if.mcs[0].ops[1].orcs[0].ocvcs[2].ips[1].gnt_our_irc_icvc_arb.genblk1.genblk1.rr_arb.genblk2.state_q,
                                    rtr.genblk1.vcr.alo.genblk1.vc_core_sep_if.mcs[0].ops[1].orcs[0].ocvcs[2].ips[2].gnt_our_irc_icvc_arb.genblk1.genblk1.rr_arb.genblk2.state_q,
                                    rtr.genblk1.vcr.alo.genblk1.vc_core_sep_if.mcs[0].ops[1].orcs[0].ocvcs[2].ips[3].gnt_our_irc_icvc_arb.genblk1.genblk1.rr_arb.genblk2.state_q,
                                    rtr.genblk1.vcr.alo.genblk1.vc_core_sep_if.mcs[0].ops[1].orcs[0].ocvcs[2].ips[4].gnt_our_irc_icvc_arb.genblk1.genblk1.rr_arb.genblk2.state_q,
                                    rtr.genblk1.vcr.alo.genblk1.vc_core_sep_if.mcs[0].ops[1].orcs[0].ocvcs[3].ips[0].gnt_our_irc_icvc_arb.genblk1.genblk1.rr_arb.genblk2.state_q,
                                    rtr.genblk1.vcr.alo.genblk1.vc_core_sep_if.mcs[0].ops[1].orcs[0].ocvcs[3].ips[1].gnt_our_irc_icvc_arb.genblk1.genblk1.rr_arb.genblk2.state_q,
                                    rtr.genblk1.vcr.alo.genblk1.vc_core_sep_if.mcs[0].ops[1].orcs[0].ocvcs[3].ips[2].gnt_our_irc_icvc_arb.genblk1.genblk1.rr_arb.genblk2.state_q,
                                    rtr.genblk1.vcr.alo.genblk1.vc_core_sep_if.mcs[0].ops[1].orcs[0].ocvcs[3].ips[3].gnt_our_irc_icvc_arb.genblk1.genblk1.rr_arb.genblk2.state_q,
                                    rtr.genblk1.vcr.alo.genblk1.vc_core_sep_if.mcs[0].ops[1].orcs[0].ocvcs[3].ips[4].gnt_our_irc_icvc_arb.genblk1.genblk1.rr_arb.genblk2.state_q,
                                    
                                    rtr.genblk1.vcr.alo.genblk1.vc_core_sep_if.mcs[0].ops[2].orcs[0].ocvcs[0].ips[0].gnt_our_irc_icvc_arb.genblk1.genblk1.rr_arb.genblk2.state_q,
                                    rtr.genblk1.vcr.alo.genblk1.vc_core_sep_if.mcs[0].ops[2].orcs[0].ocvcs[0].ips[1].gnt_our_irc_icvc_arb.genblk1.genblk1.rr_arb.genblk2.state_q,
                                    rtr.genblk1.vcr.alo.genblk1.vc_core_sep_if.mcs[0].ops[2].orcs[0].ocvcs[0].ips[2].gnt_our_irc_icvc_arb.genblk1.genblk1.rr_arb.genblk2.state_q,
                                    rtr.genblk1.vcr.alo.genblk1.vc_core_sep_if.mcs[0].ops[2].orcs[0].ocvcs[0].ips[3].gnt_our_irc_icvc_arb.genblk1.genblk1.rr_arb.genblk2.state_q,
                                    rtr.genblk1.vcr.alo.genblk1.vc_core_sep_if.mcs[0].ops[2].orcs[0].ocvcs[0].ips[4].gnt_our_irc_icvc_arb.genblk1.genblk1.rr_arb.genblk2.state_q,
                                    rtr.genblk1.vcr.alo.genblk1.vc_core_sep_if.mcs[0].ops[2].orcs[0].ocvcs[1].ips[0].gnt_our_irc_icvc_arb.genblk1.genblk1.rr_arb.genblk2.state_q,
                                    rtr.genblk1.vcr.alo.genblk1.vc_core_sep_if.mcs[0].ops[2].orcs[0].ocvcs[1].ips[1].gnt_our_irc_icvc_arb.genblk1.genblk1.rr_arb.genblk2.state_q,
                                    rtr.genblk1.vcr.alo.genblk1.vc_core_sep_if.mcs[0].ops[2].orcs[0].ocvcs[1].ips[2].gnt_our_irc_icvc_arb.genblk1.genblk1.rr_arb.genblk2.state_q,
                                    rtr.genblk1.vcr.alo.genblk1.vc_core_sep_if.mcs[0].ops[2].orcs[0].ocvcs[1].ips[3].gnt_our_irc_icvc_arb.genblk1.genblk1.rr_arb.genblk2.state_q,
                                    rtr.genblk1.vcr.alo.genblk1.vc_core_sep_if.mcs[0].ops[2].orcs[0].ocvcs[1].ips[4].gnt_our_irc_icvc_arb.genblk1.genblk1.rr_arb.genblk2.state_q,
                                    rtr.genblk1.vcr.alo.genblk1.vc_core_sep_if.mcs[0].ops[2].orcs[0].ocvcs[2].ips[0].gnt_our_irc_icvc_arb.genblk1.genblk1.rr_arb.genblk2.state_q,
                                    rtr.genblk1.vcr.alo.genblk1.vc_core_sep_if.mcs[0].ops[2].orcs[0].ocvcs[2].ips[1].gnt_our_irc_icvc_arb.genblk1.genblk1.rr_arb.genblk2.state_q,
                                    rtr.genblk1.vcr.alo.genblk1.vc_core_sep_if.mcs[0].ops[2].orcs[0].ocvcs[2].ips[2].gnt_our_irc_icvc_arb.genblk1.genblk1.rr_arb.genblk2.state_q,
                                    rtr.genblk1.vcr.alo.genblk1.vc_core_sep_if.mcs[0].ops[2].orcs[0].ocvcs[2].ips[3].gnt_our_irc_icvc_arb.genblk1.genblk1.rr_arb.genblk2.state_q,
                                    rtr.genblk1.vcr.alo.genblk1.vc_core_sep_if.mcs[0].ops[2].orcs[0].ocvcs[2].ips[4].gnt_our_irc_icvc_arb.genblk1.genblk1.rr_arb.genblk2.state_q,
                                    rtr.genblk1.vcr.alo.genblk1.vc_core_sep_if.mcs[0].ops[2].orcs[0].ocvcs[3].ips[0].gnt_our_irc_icvc_arb.genblk1.genblk1.rr_arb.genblk2.state_q,
                                    rtr.genblk1.vcr.alo.genblk1.vc_core_sep_if.mcs[0].ops[2].orcs[0].ocvcs[3].ips[1].gnt_our_irc_icvc_arb.genblk1.genblk1.rr_arb.genblk2.state_q,
                                    rtr.genblk1.vcr.alo.genblk1.vc_core_sep_if.mcs[0].ops[2].orcs[0].ocvcs[3].ips[2].gnt_our_irc_icvc_arb.genblk1.genblk1.rr_arb.genblk2.state_q,
                                    rtr.genblk1.vcr.alo.genblk1.vc_core_sep_if.mcs[0].ops[2].orcs[0].ocvcs[3].ips[3].gnt_our_irc_icvc_arb.genblk1.genblk1.rr_arb.genblk2.state_q,
                                    rtr.genblk1.vcr.alo.genblk1.vc_core_sep_if.mcs[0].ops[2].orcs[0].ocvcs[3].ips[4].gnt_our_irc_icvc_arb.genblk1.genblk1.rr_arb.genblk2.state_q,
                                    
                                    rtr.genblk1.vcr.alo.genblk1.vc_core_sep_if.mcs[0].ops[3].orcs[0].ocvcs[0].ips[0].gnt_our_irc_icvc_arb.genblk1.genblk1.rr_arb.genblk2.state_q,
                                    rtr.genblk1.vcr.alo.genblk1.vc_core_sep_if.mcs[0].ops[3].orcs[0].ocvcs[0].ips[1].gnt_our_irc_icvc_arb.genblk1.genblk1.rr_arb.genblk2.state_q,
                                    rtr.genblk1.vcr.alo.genblk1.vc_core_sep_if.mcs[0].ops[3].orcs[0].ocvcs[0].ips[2].gnt_our_irc_icvc_arb.genblk1.genblk1.rr_arb.genblk2.state_q,
                                    rtr.genblk1.vcr.alo.genblk1.vc_core_sep_if.mcs[0].ops[3].orcs[0].ocvcs[0].ips[3].gnt_our_irc_icvc_arb.genblk1.genblk1.rr_arb.genblk2.state_q,
                                    rtr.genblk1.vcr.alo.genblk1.vc_core_sep_if.mcs[0].ops[3].orcs[0].ocvcs[0].ips[4].gnt_our_irc_icvc_arb.genblk1.genblk1.rr_arb.genblk2.state_q,
                                    rtr.genblk1.vcr.alo.genblk1.vc_core_sep_if.mcs[0].ops[3].orcs[0].ocvcs[1].ips[0].gnt_our_irc_icvc_arb.genblk1.genblk1.rr_arb.genblk2.state_q,
                                    rtr.genblk1.vcr.alo.genblk1.vc_core_sep_if.mcs[0].ops[3].orcs[0].ocvcs[1].ips[1].gnt_our_irc_icvc_arb.genblk1.genblk1.rr_arb.genblk2.state_q,
                                    rtr.genblk1.vcr.alo.genblk1.vc_core_sep_if.mcs[0].ops[3].orcs[0].ocvcs[1].ips[2].gnt_our_irc_icvc_arb.genblk1.genblk1.rr_arb.genblk2.state_q,
                                    rtr.genblk1.vcr.alo.genblk1.vc_core_sep_if.mcs[0].ops[3].orcs[0].ocvcs[1].ips[3].gnt_our_irc_icvc_arb.genblk1.genblk1.rr_arb.genblk2.state_q,
                                    rtr.genblk1.vcr.alo.genblk1.vc_core_sep_if.mcs[0].ops[3].orcs[0].ocvcs[1].ips[4].gnt_our_irc_icvc_arb.genblk1.genblk1.rr_arb.genblk2.state_q,
                                    rtr.genblk1.vcr.alo.genblk1.vc_core_sep_if.mcs[0].ops[3].orcs[0].ocvcs[2].ips[0].gnt_our_irc_icvc_arb.genblk1.genblk1.rr_arb.genblk2.state_q,
                                    rtr.genblk1.vcr.alo.genblk1.vc_core_sep_if.mcs[0].ops[3].orcs[0].ocvcs[2].ips[1].gnt_our_irc_icvc_arb.genblk1.genblk1.rr_arb.genblk2.state_q,
                                    rtr.genblk1.vcr.alo.genblk1.vc_core_sep_if.mcs[0].ops[3].orcs[0].ocvcs[2].ips[2].gnt_our_irc_icvc_arb.genblk1.genblk1.rr_arb.genblk2.state_q,
                                    rtr.genblk1.vcr.alo.genblk1.vc_core_sep_if.mcs[0].ops[3].orcs[0].ocvcs[2].ips[3].gnt_our_irc_icvc_arb.genblk1.genblk1.rr_arb.genblk2.state_q,
                                    rtr.genblk1.vcr.alo.genblk1.vc_core_sep_if.mcs[0].ops[3].orcs[0].ocvcs[2].ips[4].gnt_our_irc_icvc_arb.genblk1.genblk1.rr_arb.genblk2.state_q,
                                    rtr.genblk1.vcr.alo.genblk1.vc_core_sep_if.mcs[0].ops[3].orcs[0].ocvcs[3].ips[0].gnt_our_irc_icvc_arb.genblk1.genblk1.rr_arb.genblk2.state_q,
                                    rtr.genblk1.vcr.alo.genblk1.vc_core_sep_if.mcs[0].ops[3].orcs[0].ocvcs[3].ips[1].gnt_our_irc_icvc_arb.genblk1.genblk1.rr_arb.genblk2.state_q,
                                    rtr.genblk1.vcr.alo.genblk1.vc_core_sep_if.mcs[0].ops[3].orcs[0].ocvcs[3].ips[2].gnt_our_irc_icvc_arb.genblk1.genblk1.rr_arb.genblk2.state_q,
                                    rtr.genblk1.vcr.alo.genblk1.vc_core_sep_if.mcs[0].ops[3].orcs[0].ocvcs[3].ips[3].gnt_our_irc_icvc_arb.genblk1.genblk1.rr_arb.genblk2.state_q,
                                    rtr.genblk1.vcr.alo.genblk1.vc_core_sep_if.mcs[0].ops[3].orcs[0].ocvcs[3].ips[4].gnt_our_irc_icvc_arb.genblk1.genblk1.rr_arb.genblk2.state_q,
                                    
                                    rtr.genblk1.vcr.alo.genblk1.vc_core_sep_if.mcs[0].ops[4].orcs[0].ocvcs[0].ips[0].gnt_our_irc_icvc_arb.genblk1.genblk1.rr_arb.genblk2.state_q,
                                    rtr.genblk1.vcr.alo.genblk1.vc_core_sep_if.mcs[0].ops[4].orcs[0].ocvcs[0].ips[1].gnt_our_irc_icvc_arb.genblk1.genblk1.rr_arb.genblk2.state_q,
                                    rtr.genblk1.vcr.alo.genblk1.vc_core_sep_if.mcs[0].ops[4].orcs[0].ocvcs[0].ips[2].gnt_our_irc_icvc_arb.genblk1.genblk1.rr_arb.genblk2.state_q,
                                    rtr.genblk1.vcr.alo.genblk1.vc_core_sep_if.mcs[0].ops[4].orcs[0].ocvcs[0].ips[3].gnt_our_irc_icvc_arb.genblk1.genblk1.rr_arb.genblk2.state_q,
                                    rtr.genblk1.vcr.alo.genblk1.vc_core_sep_if.mcs[0].ops[4].orcs[0].ocvcs[0].ips[4].gnt_our_irc_icvc_arb.genblk1.genblk1.rr_arb.genblk2.state_q,
                                    rtr.genblk1.vcr.alo.genblk1.vc_core_sep_if.mcs[0].ops[4].orcs[0].ocvcs[1].ips[0].gnt_our_irc_icvc_arb.genblk1.genblk1.rr_arb.genblk2.state_q,
                                    rtr.genblk1.vcr.alo.genblk1.vc_core_sep_if.mcs[0].ops[4].orcs[0].ocvcs[1].ips[1].gnt_our_irc_icvc_arb.genblk1.genblk1.rr_arb.genblk2.state_q,
                                    rtr.genblk1.vcr.alo.genblk1.vc_core_sep_if.mcs[0].ops[4].orcs[0].ocvcs[1].ips[2].gnt_our_irc_icvc_arb.genblk1.genblk1.rr_arb.genblk2.state_q,
                                    rtr.genblk1.vcr.alo.genblk1.vc_core_sep_if.mcs[0].ops[4].orcs[0].ocvcs[1].ips[3].gnt_our_irc_icvc_arb.genblk1.genblk1.rr_arb.genblk2.state_q,
                                    rtr.genblk1.vcr.alo.genblk1.vc_core_sep_if.mcs[0].ops[4].orcs[0].ocvcs[1].ips[4].gnt_our_irc_icvc_arb.genblk1.genblk1.rr_arb.genblk2.state_q,
                                    rtr.genblk1.vcr.alo.genblk1.vc_core_sep_if.mcs[0].ops[4].orcs[0].ocvcs[2].ips[0].gnt_our_irc_icvc_arb.genblk1.genblk1.rr_arb.genblk2.state_q,
                                    rtr.genblk1.vcr.alo.genblk1.vc_core_sep_if.mcs[0].ops[4].orcs[0].ocvcs[2].ips[1].gnt_our_irc_icvc_arb.genblk1.genblk1.rr_arb.genblk2.state_q,
                                    rtr.genblk1.vcr.alo.genblk1.vc_core_sep_if.mcs[0].ops[4].orcs[0].ocvcs[2].ips[2].gnt_our_irc_icvc_arb.genblk1.genblk1.rr_arb.genblk2.state_q,
                                    rtr.genblk1.vcr.alo.genblk1.vc_core_sep_if.mcs[0].ops[4].orcs[0].ocvcs[2].ips[3].gnt_our_irc_icvc_arb.genblk1.genblk1.rr_arb.genblk2.state_q,
                                    rtr.genblk1.vcr.alo.genblk1.vc_core_sep_if.mcs[0].ops[4].orcs[0].ocvcs[2].ips[4].gnt_our_irc_icvc_arb.genblk1.genblk1.rr_arb.genblk2.state_q,
                                    rtr.genblk1.vcr.alo.genblk1.vc_core_sep_if.mcs[0].ops[4].orcs[0].ocvcs[3].ips[0].gnt_our_irc_icvc_arb.genblk1.genblk1.rr_arb.genblk2.state_q,
                                    rtr.genblk1.vcr.alo.genblk1.vc_core_sep_if.mcs[0].ops[4].orcs[0].ocvcs[3].ips[1].gnt_our_irc_icvc_arb.genblk1.genblk1.rr_arb.genblk2.state_q,
                                    rtr.genblk1.vcr.alo.genblk1.vc_core_sep_if.mcs[0].ops[4].orcs[0].ocvcs[3].ips[2].gnt_our_irc_icvc_arb.genblk1.genblk1.rr_arb.genblk2.state_q,
                                    rtr.genblk1.vcr.alo.genblk1.vc_core_sep_if.mcs[0].ops[4].orcs[0].ocvcs[3].ips[3].gnt_our_irc_icvc_arb.genblk1.genblk1.rr_arb.genblk2.state_q,
                                    rtr.genblk1.vcr.alo.genblk1.vc_core_sep_if.mcs[0].ops[4].orcs[0].ocvcs[3].ips[4].gnt_our_irc_icvc_arb.genblk1.genblk1.rr_arb.genblk2.state_q};
       assign vc_icvc_gnt[(ip*num_ports*num_vcs*num_ports*vc_idx_width):((ip+1)*num_ports*num_vcs*num_ports*vc_idx_width)-1] = local_vc_icvc_gnt;
*/
    /*  this is causing simulation failure... the fact that it is failing perhaps should be determined but...
    
    running lu_con
    ERROR: X value detected at checker: testbench.ips[37].rchk, op=          0, cyc=                  30
================================
valid=1, head=1, tail=x, vcs=0100, data=0847a4c95f0140b9
external error detected, cyc=                  32

     */
        router_checker
     #(.buffer_size(buffer_size),
       .num_message_classes(num_message_classes),
       .num_resource_classes(num_resource_classes),
       .num_vcs_per_class(num_vcs_per_class),
       .num_routers_per_dim(num_routers_per_dim),
       .num_dimensions(num_dimensions),
       .num_nodes_per_router(num_nodes_per_router),
       .connectivity(connectivity),
       .packet_format(packet_format),
       .max_payload_length(max_payload_length),
       .min_payload_length(min_payload_length),
       .enable_link_pm(enable_link_pm),
       .flit_data_width(flit_data_width),
       .error_capture_mode(error_capture_mode),
       .routing_type(routing_type),
       .dim_order(dim_order),
       .reset_type(reset_type))
   rchk
     (.clk(clk),
      .reset(reset),
      .router_address(router_address),
      .channel_in_ip(channel_ips[ip*num_ports*channel_width:(ip+1)*num_ports*channel_width-1]),
      .channel_out_op(channel_ops[ip*num_ports*channel_width:(ip+1)*num_ports*channel_width-1]),
      .error(rchk_error[ip]));
       
       //end 578 changes

	   
	   
	   
	   wire [0:flow_ctrl_width-1] flow_ctrl_out;
	   assign flow_ctrl_out = injection_flow_ctrl[ip*flow_ctrl_width:
						   (ip+1)*flow_ctrl_width-1];
	   
	   assign cred_valid_out_ip[ip] = flow_ctrl_out[0];
	   
		wire [0:flow_ctrl_width-1] flow_ctrl_dly;
		c_shift_reg
		  #(.width(flow_ctrl_width),
		    .depth(num_channel_stages),
		    .reset_type(reset_type))
		flow_ctrl_dly_sr
		  (.clk(clk),
		   .reset(reset),
		   .active(1'b1),
		   .data_in(flow_ctrl_out),
		   .data_out(flow_ctrl_dly));
		
		packet_source
		  #(.testname(testname),
		    .initial_seed(initial_seed+ip),
		    .max_packet_count(max_packet_count),
		    .packet_rate(packet_rate),
		    .packet_count_reg_width(packet_count_reg_width),
		    .packet_length_mode(packet_length_mode),
		    .topology(topology),
		    .buffer_size(buffer_size),
		    .num_message_classes(num_message_classes),
		    .num_resource_classes(num_resource_classes),
		    .num_vcs_per_class(num_vcs_per_class),
		    .num_nodes(num_nodes),
		    .num_dimensions(num_dimensions),
		    .num_nodes_per_router(num_nodes_per_router),
		    .packet_format(packet_format),
		    .flow_ctrl_type(flow_ctrl_type),
		    .flow_ctrl_bypass(flow_ctrl_bypass),
		    .max_payload_length(max_payload_length),
		    .min_payload_length(min_payload_length),
		    .enable_link_pm(enable_link_pm),
		    .flit_data_width(flit_data_width),
		    .routing_type(routing_type),
		    .dim_order(dim_order),
		    .fb_mgmt_type(fb_mgmt_type),
		    .disable_static_reservations(disable_static_reservations),
		    .elig_mask(elig_mask),
		    .port_id(4), //hardcoded to the injection port, port 4
		    .reset_type(reset_type),
		    .router_num(ip))
		ps
		  (.clk(clk),
		   .reset(reset),
		   .router_address(router_address),
		   .channel(channel),
		   .flit_valid(flit_valid),
		   .flow_ctrl(flow_ctrl_dly),
		   .run(run),
		   .error(ps_error));
		
		assign ps_error_ip[ip] = ps_error;
		
		wire [0:channel_width-1]    channel_dly;
		c_shift_reg
		  #(.width(channel_width),
		    .depth(num_channel_stages),
		    .reset_type(reset_type))
		channel_dly_sr
		  (.clk(clk),
		   .reset(reset),
		   .active(1'b1),
		   .data_in(channel),
		   .data_out(channel_dly));
		
		assign injection_channels[ip*channel_width:(ip+1)*channel_width-1]
		  = channel_dly;
		
		wire 			    flit_valid_dly;
		c_shift_reg
		  #(.width(1),
		    .depth(num_channel_stages),
		    .reset_type(reset_type))
		flit_valid_dly_sr
		  (.clk(clk),
		   .reset(reset),
		   .active(1'b1),
		   .data_in(flit_valid),
		   .data_out(flit_valid_dly));
		
		assign flit_valid_in_ip[ip] = flit_valid_dly;
		
	end
      
   endgenerate
   
   wire [0:num_routers-1] 		      fs_error_op;
   
   genvar 				      op;
   
   generate
      
      for(op = 0; op < num_routers; op = op + 1)  //variable name is "op" but it's really the router id
	begin:ops
	   
	   wire [0:channel_width-1] channel_out;
	   assign channel_out = ejection_channels[op*channel_width:
					       (op+1)*channel_width-1];
	   
	   wire [0:flit_ctrl_width-1] flit_ctrl_out;
	   assign flit_ctrl_out
	     = channel_out[link_ctrl_width:link_ctrl_width+flit_ctrl_width-1];
	   
	   assign flit_valid_out_op[op] = flit_ctrl_out[0];
	   
	   wire [0:channel_width-1] channel_dly;
	   c_shift_reg
	     #(.width(channel_width),
	       .depth(num_channel_stages),
	       .reset_type(reset_type))
	   channel_dly_sr
	     (.clk(clk),
	      .reset(reset),
	      .active(1'b1),
	      .data_in(channel_out),
	      .data_out(channel_dly));
	   
	   wire [0:flow_ctrl_width-1] flow_ctrl;
	   
	   wire 		      fs_error;
	   
	   flit_sink
	     #(.initial_seed(initial_seed + num_routers + op),
	       .consume_rate(consume_rate),
	       .buffer_size(buffer_size),
	       .num_vcs(num_vcs),
	       .packet_format(packet_format),
	       .flow_ctrl_type(flow_ctrl_type),
	       .max_payload_length(max_payload_length),
	       .min_payload_length(min_payload_length),
	       .route_info_width(route_info_width),
	       .enable_link_pm(enable_link_pm),
	       .flit_data_width(flit_data_width),
	       .fb_regfile_type(fb_regfile_type),
	       .fb_mgmt_type(fb_mgmt_type),
	       .atomic_vc_allocation(atomic_vc_allocation),
	       .reset_type(reset_type))
	   fs
	     (.clk(clk),
	      .reset(reset),
	      .channel(channel_dly),
	      .flow_ctrl(flow_ctrl),
	      .error(fs_error));
	   
	   assign fs_error_op[op] = fs_error;
	   
	   wire [0:flow_ctrl_width-1] flow_ctrl_dly;
	   c_shift_reg
	     #(.width(flow_ctrl_width),
	       .depth(num_channel_stages),
	       .reset_type(reset_type))
	   flow_ctrl_in_sr
	     (.clk(clk),
	      .reset(reset),
	      .active(1'b1),
	      .data_in(flow_ctrl),
	      .data_out(flow_ctrl_dly));
	   
	   assign ejection_flow_ctrl[op*flow_ctrl_width:(op+1)*flow_ctrl_width-1]
		    = flow_ctrl_dly;
	   
	   assign cred_valid_in_op[op] = flow_ctrl_dly[0];
	   
	end
      
   endgenerate
   
   wire [0:2] tb_errors;
   assign tb_errors = {|ps_error_ip, |fs_error_op, |rchk_error};
   
   wire       tb_error;
   assign tb_error = |tb_errors;
   
   wire [0:31] in_flits_s, in_flits_q;
   assign in_flits_s = in_flits_q + pop_count(flit_valid_in_ip);
   c_dff
     #(.width(32),
       .reset_type(reset_type))
   in_flitsq
     (.clk(clk),
      .reset(reset),
      .active(1'b1),
      .d(in_flits_s),
      .q(in_flits_q));
   
   wire [0:31] in_flits;
   assign in_flits = in_flits_s;
   
   wire [0:31] in_creds_s, in_creds_q;
   assign in_creds_s = in_creds_q + pop_count(cred_valid_out_ip);
   c_dff
     #(.width(32),
       .reset_type(reset_type))
   in_credsq
     (.clk(clk),
      .reset(reset),
      .active(1'b1),
      .d(in_creds_s),
      .q(in_creds_q));
   
   wire [0:31] in_creds;
   assign in_creds = in_creds_q;
   
   wire [0:31] out_flits_s, out_flits_q;
   assign out_flits_s = out_flits_q + pop_count(flit_valid_out_op);
   c_dff
     #(.width(32),
       .reset_type(reset_type))
   out_flitsq
     (.clk(clk),
      .reset(reset),
      .active(1'b1),
      .d(out_flits_s),
      .q(out_flits_q));
   
   wire [0:31] out_flits;
   assign out_flits = out_flits_s;
   
   wire [0:31] out_creds_s, out_creds_q;
   assign out_creds_s = out_creds_q + pop_count(cred_valid_in_op);
   c_dff
     #(.width(32),
       .reset_type(reset_type))
   out_credsq
     (.clk(clk),
      .reset(reset),
      .active(1'b1),
      .d(out_creds_s),
      .q(out_creds_q));
   
   wire [0:31] out_creds;
   assign out_creds = out_creds_q;
   
   reg 	       count_en;
   
   wire [0:31] count_in_flits_s, count_in_flits_q;
   assign count_in_flits_s
     = count_en ?
       count_in_flits_q + pop_count(flit_valid_in_ip) :
       count_in_flits_q;
   c_dff
     #(.width(32),
       .reset_type(reset_type))
   count_in_flitsq
     (.clk(clk),
      .reset(reset),
      .active(1'b1),
      .d(count_in_flits_s),
      .q(count_in_flits_q));
   
   wire [0:31] count_in_flits;
   assign count_in_flits = count_in_flits_s;
   
   wire [0:31] count_out_flits_s, count_out_flits_q;
   assign count_out_flits_s
     = count_en ?
       count_out_flits_q + pop_count(flit_valid_out_op) :
       count_out_flits_q;
   c_dff
     #(.width(32),
       .reset_type(reset_type))
   count_out_flitsq
     (.clk(clk),
      .reset(reset),
      .active(1'b1),
      .d(count_out_flits_s),
      .q(count_out_flits_q));
   
   wire [0:31] count_out_flits;
   assign count_out_flits = count_out_flits_s;
   
   reg 	       clk_en;
   
   always
   begin
      clk <= clk_en;
      #(Tclk/2);
      clk <= 1'b0;
      #(Tclk/2);
   end
   
   always @(posedge clk)
     begin
	if(|rtr_error)
	  begin
	     $display("internal error detected, cyc=%d", $time);
	     $stop;
	  end
	if(tb_error)
	  begin
	     $display("external error detected, cyc=%d", $time);
	     $stop;
	  end
     end
     

      //578 adding the monitoring signals note current router type is VC arbiter round robin
     integer router;
     integer signaloff;
     integer portoff;
     integer vcoff;
     integer outfiles[0:num_routers/8];
     string filename;
     
     always @(posedge clk)
     begin
    // $write("STATE");
        for(router = 0; router<num_routers; router = router+1)
        begin:printrtr
             /*if(!reset) begin
                $display("making files");
                if(router%num_routers_per_dim==0 && router<10)
                    $sformat(filename, "/media/C719-5A45/%s/statefile_%1d.out",testname,router); 
                else if(router%num_routers_per_dim==0)
                    $sformat(filename, "/media/C719-5A45/%s/statefile_%2d.out",testname,router); 

                outfiles[router] = $fopen(filename,"w"); 
                $display("making files");
            end
            else /*if($realtime>log_start&& $realtime<=log_stop)*///begin
            //$fwrite(outfiles[router/num_routers_per_dim],"%d", $realtime);
            /*for(signaloff = 0; signaloff<num_ports*vc_idx_width; signaloff = signaloff+vc_idx_width)
            begin:printswon
                $write(",%d",sw_out_gnt_nonspec [(router*num_ports*vc_idx_width)+signaloff+:vc_idx_width] );
            end//printswon
            for(signaloff = 0; signaloff<num_ports*vc_idx_width; signaloff = signaloff+vc_idx_width)
            begin:printswos
                $write(",%d",sw_out_gnt_spec [(router*num_ports*vc_idx_width)+signaloff+:vc_idx_width] );
            end//printswos
            for(signaloff = 0; signaloff<num_ports*vc_idx_width; signaloff = signaloff+vc_idx_width)
            begin:printswin
               $write(",%d",sw_in_gnt_nonspec [(router*num_ports*vc_idx_width)+signaloff+:vc_idx_width] );
            end//printswin
            for(signaloff = 0; signaloff<num_ports*vc_idx_width; signaloff = signaloff+vc_idx_width)
            begin:printswis
               $write(",%d",sw_in_gnt_spec [(router*num_ports*vc_idx_width)+signaloff+:vc_idx_width] );
            end//printswis*/
            $write("%2d",router);
            for(signaloff = 0; signaloff<num_ports*num_vcs; signaloff = signaloff+num_vcs)
            begin:printfbe
                //$fwrite(outfiles[router],",%d",fb_empty [(router*num_ports*vc_idx_width)+signaloff+:num_vcs] );
                $write(",%d",fb_empty [(router*num_ports*vc_idx_width)+signaloff+:num_vcs] );
            end//printfbe
            for(signaloff = 0; signaloff<num_ports; signaloff = signaloff+1)
            begin:printila
                //$fwrite(outfiles[router],",%d",input_link_active [(router*num_ports)+signaloff] );
                $write(",%d",input_link_active [(router*num_ports)+signaloff] );                
            end//printila
            for(signaloff = 0; signaloff<num_ports*num_ports; signaloff = signaloff+num_ports)
            begin:printxbc
                //$fwrite(outfiles[router],",%d",xbr_ctrl [(router*num_ports)+signaloff+:num_ports] );
                $write(",%d",xbr_ctrl [(router*num_ports)+signaloff+:num_ports] );                
            end
            $write("\t");
            //printxbc
            /*for(portoff = 0; portoff<num_ports; portoff = portoff+1)
            begin:printvcoop
                for(signaloff = 0; signaloff<num_vcs*vc_idx_width; signaloff = signaloff+vc_idx_width)
                begin:printvcoo
                    $write(",%d",vc_out_ocvc_gnt [(router*num_ports*num_vcs*vc_idx_width)+(portoff*num_vcs*vc_idx_width)+signaloff+:vc_idx_width] );
                end//printvcoo
            end//vcoop
            
            for(portoff = 0; portoff<num_ports; portoff = portoff+1)
            begin:printvcoip
                for(signaloff = 0; signaloff<num_vcs*port_idx_width; signaloff = signaloff+port_idx_width)
                begin:printvcoi
                    $write(",%d",vc_out_ip_gnt [(router*num_ports*num_vcs*port_idx_width)+(portoff*num_vcs*port_idx_width)+signaloff+:port_idx_width] );
                end//printvcoi
            end//vcoip
            
            for(portoff = 0; portoff<num_ports; portoff = portoff+1)
            begin:printvcap
                for(signaloff = 0; signaloff<num_vcs; signaloff = signaloff+1)
                begin:printvca
                    $write(",%d",vc_allocated [(router*num_ports*num_vcs)+(portoff*num_vcs)+signaloff] );
                end//printvca
            end//vcap
            
            for(portoff = 0; portoff<num_ports; portoff = portoff+1)
            begin:printvcip
                for(vcoff = 0; vcoff<num_vcs; vcoff = vcoff+1)
                begin:printvcic
                    for(signaloff = 0; signaloff<num_ports*vc_idx_width; signaloff=signaloff+vc_idx_width)
                    begin:printvci
                        $write(",%d",vc_icvc_gnt[(router*num_ports*num_vcs*num_ports*vc_idx_width)+(portoff*num_vcs*num_ports*vc_idx_width)+(vcoff*num_ports*vc_idx_width) +signaloff+:vc_idx_width  ]);
                    end//printvci
                end//printvcic
            end//vcip   */
        end//printrtr
     $write("\n");
     
     end//always@ 

   integer cycles;
   integer d;
   
   initial
   begin
      
      reset = 1'b0;
      clk_en = 1'b1;
      run = 1'b1;
      count_en = 1'b1;
      cycles = 0;
      
      #(Tclk);
      
      #(Tclk/2);
      
      reset = 1'b1;
      
      #(Tclk);
      
      reset = 1'b0;
      
      /*#(Tclk);
      
      clk_en = 1'b1;
      
      #(Tclk/2);
      
      $display("warming up...");
      
      run = 1'b1;*/

      while(cycles < warmup_time)
	begin
	   cycles = cycles + 1;
	   #(Tclk);
	end
      
      $display("measuring...");
      
      count_en = 1'b1;
      
      while(cycles < warmup_time + measure_time)
	begin
	   cycles = cycles + 1;
	   #(Tclk);
	end
      
      count_en = 1'b0;
      
      $display("measured %d cycles", measure_time);
      
      $display("%d flits in, %d flits out", count_in_flits, count_out_flits);
      
      $display("cooling down...");
      
      run = 1'b0;
      
      /*while((in_flits > out_flits) || (in_flits > in_creds))
	begin
	   cycles = cycles + 1;
	   #(Tclk);
	end*/
      
      #(Tclk*10);
      
      $display("simulation ended after %d cycles", cycles);
      
      $display("%d flits received, %d flits sent", in_flits, out_flits);
      
      $finish;
      
   end
   
endmodule
