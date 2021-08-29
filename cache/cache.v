// | ----------- address 32 ----------- |
// | 31   9 | 8     4 | 3    2 | 1    0 |
// | tag 23 | index 5 | word 2 | byte 2 |

`define ADDR_BITS 32
`define WORD_BYTES 4
`define WORD_BYTES_WIDTH 2   // log2(4 (WORD_BYTES))
`define WORD_BITS (`WORD_BYTES * 8)
`define LINE_WORDS 4
`define LINE_WORDS_WIDTH 2   // log2(4 (LINE_WORDS))
`define BLOCK_WIDTH (`LINE_WORDS_WIDTH + `WORD_BYTES_WIDTH)   // 4
`define LINE_NUM 64
`define WAYS 2
`define LINE_INDEX_WIDTH 6   // log2(64)
`define SET_INDEX_WIDTH 5   // log2(64 / 2 (WAYS))
`define TAG_BITS (`ADDR_BITS - `SET_INDEX_WIDTH - `BLOCK_WIDTH)  // 32 - 5 - 4 = 23

module cache (
	input wire clk,  // clock
	input wire rst,  // reset
	input wire [`ADDR_BITS-1:0] addr,  // address
    input wire load,    //  read refreshes recent bit
	input wire store,  // set valid to 1 and reset dirty to 0
	input wire edit,  // set dirty to 1
	input wire invalid,  // reset valid to 0
    input wire [2:0] u_b_h_w, // select signed or not & data width
                              // please refer to definition of LB, LH, LW, LBU, LHU in RV32I Instruction Set  
	input wire [31:0] din,  // data write in
	output reg hit,  // hit or not
	output reg [31:0] dout,  // data read out
	output reg valid,  // valid bit
	output reg dirty,  // dirty bit
	output reg [`TAG_BITS-1:0] tag  // tag bits
	);

    wire [31:0] word1, word2;
    wire [15:0] half_word1, half_word2;
    wire [7:0]  byte1, byte2;
    wire recent1, recent2, valid1, valid2, dirty1, dirty2;
    wire [`TAG_BITS-1:0] tag1, tag2;
    wire hit1, hit2;

    reg [`LINE_NUM-1:0] inner_recent = 0;
    reg [`LINE_NUM-1:0] inner_valid = 0;
    reg [`LINE_NUM-1:0] inner_dirty = 0;
    reg [`TAG_BITS-1:0] inner_tag [0:`LINE_NUM-1];
    // 64 lines, 2 ways set associative => 32 sets
    reg [31:0] inner_data [0:`LINE_NUM*`LINE_WORDS-1];

    // initialize tag and data with 0
    integer i;
    initial begin
        for (i = 0; i < `LINE_NUM; i = i + 1)
            inner_tag[i] = 0;

        for (i = 0; i < `LINE_NUM*`LINE_WORDS; i = i + 1)
            inner_data[i] = 0;
    end

    // the bits in an input address:
    wire [`TAG_BITS-1:0] addr_tag;
    wire [`SET_INDEX_WIDTH-1:0] addr_index;     // idx of set
    wire [`LINE_INDEX_WIDTH-1:0] addr_line1; 
    wire [`LINE_INDEX_WIDTH-1:0] addr_line2;     // idx of line
    wire [`LINE_INDEX_WIDTH+`LINE_WORDS_WIDTH-1:0] addr_word1;
    wire [`LINE_INDEX_WIDTH+`LINE_WORDS_WIDTH-1:0] addr_word2; // line index + word index

    // debug
    reg write_miss;

    assign addr_tag = addr[`ADDR_BITS-1:`ADDR_BITS-`TAG_BITS];
    assign addr_index = addr[`SET_INDEX_WIDTH+`LINE_WORDS_WIDTH+`WORD_BYTES_WIDTH-1:
                             `LINE_WORDS_WIDTH+`WORD_BYTES_WIDTH];
    assign addr_line1 = {addr_index, 1'b0};
    assign addr_line2 = {addr_index, 1'b1};
    assign addr_word1 = {addr_line1, addr[`LINE_WORDS_WIDTH+`WORD_BYTES_WIDTH-1:`WORD_BYTES_WIDTH]};
    assign addr_word2 = {addr_line2, addr[`LINE_WORDS_WIDTH+`WORD_BYTES_WIDTH-1:`WORD_BYTES_WIDTH]};

    assign word1 = inner_data[addr_word1];
    assign word2 = inner_data[addr_word2];
    assign half_word1 = addr[1] ? word1[31:16] : word1[15:0];
    assign half_word2 = addr[1] ? word2[31:16] : word2[15:0];
    assign byte1 = addr[1] ?
                    addr[0] ? word1[31:24] : word1[23:16] :
                    addr[0] ? word1[15:8] :  word1[7:0]   ;
    assign byte2 = addr[1] ?
                    addr[0] ? word2[31:24] : word2[23:16] :
                    addr[0] ? word2[15:8] :  word2[7:0]   ;

    assign recent1 = inner_recent[addr_line1];
    assign recent2 = inner_recent[addr_line2];
    assign valid1 = inner_valid[addr_line1];
    assign valid2 = inner_valid[addr_line2];
    assign dirty1 = inner_dirty[addr_line1];
    assign dirty2 = inner_dirty[addr_line2];
    assign tag1 = inner_tag[addr_line1];
    assign tag2 = inner_tag[addr_line2];

    assign hit1 = valid1 & (tag1 == addr_tag);
    assign hit2 = valid2 & (tag2 == addr_tag);

    always @ (posedge clk) begin
        write_miss <= 1'b0;

        valid <= recent1 ? valid2 : valid1;
        dirty <= recent1 ? dirty2 : dirty1;
        tag <= recent1 ? tag2 : tag1;
        hit <= hit1 | hit2;
        
        // read $ with load==0 means moving data from $ to mem
        // no need to update recent bit
        // otherwise the refresh process will be affected
        if (load) begin
            if (hit1) begin
                dout <=
                    u_b_h_w[1] ? word1 :
                    u_b_h_w[0] ? {u_b_h_w[2] ? 16'b0 : {16{half_word1[15]}}, half_word1} :
                    {u_b_h_w[2] ? 24'b0 : {24{byte1[7]}}, byte1};
                
                // inner_recent will be refreshed only on r/w hit
                // (including the r/w hit after miss and replacement)
                inner_recent[addr_line1] <= 1'b1;
                inner_recent[addr_line2] <= 1'b0;
            end
            else if (hit2) begin
                dout <=
                    u_b_h_w[1] ? word2 :
                    u_b_h_w[0] ? {u_b_h_w[2] ? 16'b0 : {16{half_word2[15]}}, half_word2} :
                    {u_b_h_w[2] ? 24'b0 : {24{byte2[7]}}, byte2};
                
                inner_recent[addr_line1] <= 1'b0;
                inner_recent[addr_line2] <= 1'b1;
            end
        end
        else dout <= inner_data[ recent1 ? addr_word2 : addr_word1 ];

        if (edit) begin
            if (hit1) begin
                inner_data[addr_word1] <= 
                    u_b_h_w[1] ?        // word?
                        din
                    :
                        u_b_h_w[0] ?    // half word?
                            addr[1] ?       // upper / lower?
                                {din[15:0], word1[15:0]} 
                            :
                                {word1[31:16], din[15:0]} 
                        :   // byte
                            addr[1] ?
                                addr[0] ?
                                    {din[7:0], word1[23:0]}   // 11
                                :
                                    {word1[31:24], din[7:0], word1[15:0]} // 10
                            :
                                addr[0] ?
                                    {word1[31:16], din[7:0], word1[7:0]}   // 01
                                :
                                    {word1[31:8], din[7:0]} // 00
                ;
                inner_dirty[addr_line1] <= 1'b1;
                inner_recent[addr_line1] <= 1'b1;
                inner_recent[addr_line2] <= 1'b0;
            end
            else if (hit2) begin
                inner_data[addr_word2] <= 
                    u_b_h_w[1] ?        // word
                        din
                    :
                        u_b_h_w[0] ?    // half word
                            addr[1] ?       // upper / lower?
                                {din[15:0], word2[15:0]} 
                            :
                                {word2[31:16], din[15:0]} 
                        :   // byte
                            addr[1] ?
                                addr[0] ?
                                    {din[7:0], word2[23:0]}   // 11
                                :
                                    {word2[31:24], din[7:0], word2[15:0]} // 10
                            :
                                addr[0] ?
                                    {word2[31:16], din[7:0], word2[7:0]}   // 01
                                :
                                    {word2[31:8], din[7:0]} // 00
                ;
                inner_dirty[addr_line2] <= 1'b1;
                inner_recent[addr_line1] <= 1'b0;
                inner_recent[addr_line2] <= 1'b1;
            end else begin
                write_miss <= 1'b1;
            end
        end

        if (store) begin
            if (recent1) begin  // replace 2
                inner_data[addr_word2] <= din;
                inner_valid[addr_line2] <= 1'b1;
                inner_dirty[addr_line2] <= 1'b0;
                inner_tag[addr_line2] <= addr_tag;
            end else begin
                // recent2 == 1 => replace 1
                // recent2 == 0 => no data in this set, place to 1
                inner_data[addr_word1] <= din;
                inner_valid[addr_line1] <= 1'b1;
                inner_dirty[addr_line1] <= 1'b0;
                inner_tag[addr_line1] <= addr_tag;
            end
        end

        // not used currently, can be used to reset the cache.
        if (invalid) begin
            inner_recent[addr_line1] <= 1'b0;
            inner_recent[addr_line2] <= 1'b0;
            inner_valid[addr_line1] <= 1'b0;
            inner_valid[addr_line2] <= 1'b0;
            inner_dirty[addr_line1] <= 1'b0;
            inner_dirty[addr_line2] <= 1'b0;
        end
    end

endmodule
