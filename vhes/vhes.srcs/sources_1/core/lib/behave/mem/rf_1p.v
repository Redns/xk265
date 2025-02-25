//-------------------------------------------------------------------
//                                                                 
//  COPYRIGHT (C) 2011, VIPcore Group, Fudan University
//                                                                  
//  THIS FILE MAY NOT BE MODIFIED OR REDISTRIBUTED WITHOUT THE      
//  EXPRESSED WRITTEN CONSENT OF VIPcore Group
//                                                                  
//  VIPcore       : http://soc.fudan.edu.cn/vip    
//  IP Owner 	  : Yibo FAN
//  Contact       : fanyibo@fudan.edu.cn             
//-------------------------------------------------------------------
// Filename       : rf_1p.v
// Author         : Yibo FAN 
// Created        : 2012-04-01
// Description    : one port register file
//               
// $Id$ 
//------------------------------------------------------------------- 
`include "enc_defines.v"

module rf_1p (
		        clk    ,
		        cen_i  ,
		        wen_i  ,
		        addr_i ,
		        data_i ,		
		        data_o		        
);

// ********************************************
//                                             
//    Parameter DECLARATION                    
//                                             
// ********************************************
parameter                 Word_Width = 32;
parameter                 Addr_Width = 8;

// ********************************************
//                                             
//    Input/Output DECLARATION                    
//                                             
// ********************************************
input                     clk;      // clock input
input   		          cen_i;    // chip enable, low active
input   		          wen_i;    // write enable, low active
input   [Addr_Width-1:0]  addr_i;   // address input
input   [Word_Width-1:0]  data_i;   // data input
output	[Word_Width-1:0]  data_o;   // data output

// ********************************************
//                                             
//    Register DECLARATION                 
//                                             
// ********************************************
`ifdef USE_BRAM
    (*ram_style="block"*)reg    [Word_Width-1:0]   mem_array[(1<<Addr_Width)-1:0];
`else
    reg    [Word_Width-1:0]   mem_array[(1<<Addr_Width)-1:0];
`endif

// ********************************************
//                                             
//    Wire DECLARATION                 
//                                             
// ********************************************
reg	   [Word_Width-1:0]  data_r;

// ********************************************
//                                             
//    Logic DECLARATION                 
//                                             
// ********************************************
// mem write
always @(posedge clk) begin                
	if(!cen_i && !wen_i)   
		mem_array[addr_i] <= data_i;    
end

// mem read
always @(posedge clk) begin 
	if (!cen_i && wen_i)
		data_r <= mem_array[addr_i];
	else
		data_r <= 'bx;
end

assign data_o = data_r;

endmodule