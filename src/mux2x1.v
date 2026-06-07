`timescale 1ns/1ns

module mux2x1 #(
     parameter XLEN = 64
)(
    input sel,
    input [XLEN-1:0] in0,
    input [XLEN-1:0] in1,
    output [XLEN-1:0] out
);

// Ternary operator: If sel is 1, output in1. Else, output in0.
assign out = sel ? in1 : in0;

endmodule