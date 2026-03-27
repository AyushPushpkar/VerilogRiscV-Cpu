`timescale 1ns/1ns

module mux2x1 #(
    parameter DATA_WIDTH = 8
)(
    input sel,
    input [DATA_WIDTH-1:0] in0,
    input [DATA_WIDTH-1:0] in1,
    output [DATA_WIDTH-1:0] out
);

// Ternary operator: If sel is 1, output in1. Else, output in0.
assign out = sel ? in1 : in0;

endmodule