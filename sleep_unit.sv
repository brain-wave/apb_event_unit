// Copyright 2017 ETH Zurich and University of Bologna.
// Copyright and related rights are licensed under the Solderpad Hardware
// License, Version 0.51 (the “License”); you may not use this file except in
// compliance with the License.  You may obtain a copy of the License at
// http://solderpad.org/licenses/SHL-0.51. Unless required by applicable law
// or agreed to in writing, software, hardware and materials distributed under
// this License is distributed on an “AS IS” BASIS, WITHOUT WARRANTIES OR
// CONDITIONS OF ANY KIND, either express or implied. See the License for the
// specific language governing permissions and limitations under the License.

`include "defines_event_unit.sv"

module sleep_unit
#(
    parameter APB_ADDR_WIDTH = 12  //APB slaves are 4KB by default
)
(
    input  logic                      clk32_i,
    input  logic                      HCLK,
    input  logic                      HRESETn,
    input  logic [APB_ADDR_WIDTH-1:0] PADDR,
    input  logic               [31:0] PWDATA,
    input  logic                      PWRITE,
    input  logic                      PSEL,
    input  logic                      PENABLE,
    output logic               [31:0] PRDATA,
    output logic                      PREADY,
    output logic                      PSLVERR,

    input  logic                      irq_i,   // interrupt signal
    input  logic                      event_i, // event signal
    input  logic                      core_busy_i, // check if core is busy
    output logic                      fetch_en_o,
    output logic                      clk_gate_core_o, // output to core's clock gate - blocking the clock when low
    
    output logic                      mem_sleep_o,
    output logic                      mem_gate_small_o,
    output logic                      mem_gate_large_o
);

    localparam integer DELAY_TICKS = $ceil((`REF_CLK_FREQ * `MIN_WAKEUP_DELAY)/(1.0*10**9));

    enum    logic[2:0]      {RUN, SHUTDOWN, SLEEP, EXT_SLEEP, WAKEUP_S1, WAKEUP_S2} SLEEP_STATE_N, SLEEP_STATE_Q;
    // registers
    logic [0:`REGS_SLEEP_MAX_IDX] [31:0]  regs_q, regs_n;
    logic [$clog2(DELAY_TICKS+1)-1:0] cntr_q, cntr_n;
    
    logic [2:0] r_ls_clk_sync;
    assign s_rise_ls_clk = ~r_ls_clk_sync[2] & r_ls_clk_sync[1]; // edge detector

    ////////////////////////////////
    //   _____ _                  //
    //  / ____| |                 //
    // | (___ | | ___  ___ _ __   //
    //  \___ \| |/ _ \/ _ \ '_ \  //
    //  ____) | |  __/  __/ |_) | //
    // |_____/|_|\___|\___| .__/  //
    //                    | |     //
    //                    |_|     //
    //                            //
    ////////////////////////////////

    logic core_sleeping_int;
    logic core_ext_sleeping_int;

    // next state logic
    always_comb
    begin
        SLEEP_STATE_N = SLEEP_STATE_Q;
        cntr_n = cntr_q;

        case(SLEEP_STATE_Q)

            RUN:
            begin
                // if sleep is enforced by writing one to the sleep control register
                // and currently no interrupt/event is pending
                if (regs_q[`REG_SLEEP_CTRL][`SLEEP_ENABLE]) begin
                  if (~event_i) // if there was an event pending, we don't go to sleep
                    SLEEP_STATE_N = SHUTDOWN;
                end
            end

            // wait for shutdown
            SHUTDOWN:
            begin
                // if an event occured while waiting - switch back to running
                if (event_i)
                    SLEEP_STATE_N = RUN;
                // if no event occured and the core has finished processing go to sleep
                else if ((~core_busy_i) && (~irq_i))
                    SLEEP_STATE_N = SLEEP;
            end

            SLEEP:
            begin
                // wake up when an interrupt is present
                if (event_i)
                    SLEEP_STATE_N = RUN;
                else if (irq_i)
                    SLEEP_STATE_N = SHUTDOWN;
                else if (regs_q[`REG_SLEEP_CTRL][`EXT_SLEEP_ENABLE])
                    SLEEP_STATE_N = EXT_SLEEP;
            end
            
            EXT_SLEEP:
            begin
               if (event_i) // stay until an event arrives
                    SLEEP_STATE_N = WAKEUP_S1;
            end
            
            WAKEUP_S1:
            begin
               if (s_rise_ls_clk)
                    cntr_n = cntr_q + 1'b1;
               if (DELAY_TICKS == cntr_q) begin // if right amount of time expired...
                    SLEEP_STATE_N = WAKEUP_S2;
                    cntr_n = 0;
               end
            end
            
            WAKEUP_S2:
            begin
               if (s_rise_ls_clk)
                    cntr_n = cntr_q + 1'b1;
               if (DELAY_TICKS == cntr_q) begin // if right amount of time expired...
                    SLEEP_STATE_N = RUN;
                    cntr_n = 0;
               end
            end

            default:
                SLEEP_STATE_N = RUN;
        endcase

    end

    // output logic
    always_comb
    begin
        fetch_en_o = 1'b1;
        clk_gate_core_o = 1'b1;
        core_sleeping_int = 1'b0;
        core_ext_sleeping_int = 1'b0;
        mem_gate_small_o = 1'b0;
        mem_gate_large_o = 1'b0;
        mem_sleep_o = 1'b0; 

        unique case(SLEEP_STATE_Q)

            RUN:
            begin
                // try to go to sleep immediately - necessary if wfi is called
                // directly after setting the sleep register.
                if (regs_q[`REG_SLEEP_CTRL][`SLEEP_ENABLE] && (~event_i))
                    fetch_en_o = 1'b0;
                else
                    fetch_en_o = 1'b1;
            end
            
            SHUTDOWN:
            begin
                // stop fetching instructions and wait until the core has finished processing
                fetch_en_o = 1'b0;
            end
            
            SLEEP:
            begin
                // switch off core clock
                clk_gate_core_o = event_i ? 1'b1 : 1'b0;
                core_sleeping_int = 1'b1;
                fetch_en_o = 1'b0;
            end
            
            EXT_SLEEP:
            begin
               // put memories in retention mode (ignore events/interrupts)
               clk_gate_core_o = 1'b0;
               core_ext_sleeping_int = 1'b1;
               fetch_en_o = 1'b0;
               
               // pull up memory sleep pins
               mem_gate_small_o = 1'b1;
               mem_gate_large_o = 1'b1;
               mem_sleep_o = 1'b1;
            end
            
            WAKEUP_S1:
            begin
               clk_gate_core_o = 1'b0; // keep core gated
               core_ext_sleeping_int = 1'b1;
               fetch_en_o = 1'b0;
               
               // pull down small memory embedded switches
               mem_gate_small_o = 1'b0;
               mem_gate_large_o = 1'b1;
               mem_sleep_o = 1'b1; 
            end
            
            WAKEUP_S2:
            begin
               clk_gate_core_o = 1'b0; // keep core gated
               core_ext_sleeping_int = 1'b1;
               fetch_en_o = 1'b0;
               
               // pull down large memory embedded switches
               mem_gate_small_o = 1'b0;
               mem_gate_large_o = 1'b0;
               mem_sleep_o = 1'b1; 
            end

            default:
            begin
                fetch_en_o = 1'b1;
                clk_gate_core_o = 1'b1;
                core_sleeping_int = 1'b0;
                mem_gate_small_o = 1'b0;
                mem_gate_large_o = 1'b0;
                mem_sleep_o = 1'b1; 
            end
        endcase

    end

    /////////////////////////////
    //           _____  ____   //
    //     /\   |  __ \|  _ \  //
    //    /  \  | |__) | |_) | //
    //   / /\ \ |  ___/|  _ <  //
    //  / ____ \| |    | |_) | //
    // /_/    \_\_|    |____/  //
    //                         //
    /////////////////////////////

    // APB register interface
    logic [`REGS_SLEEP_MAX_IDX-1:0]       register_adr;
    assign register_adr = PADDR[`REGS_SLEEP_MAX_IDX + 2:2];

    // APB logic: we are always ready to capture the data into our regs
    // not supporting transfare failure
    assign PREADY = 1'b1;
    assign PSLVERR = 1'b0;

    // register write logic
    always_comb
    begin
        regs_n = regs_q;

        // update sleeping status register
        regs_n[`REG_SLEEP_STATUS][`SLEEP_STATUS] = core_sleeping_int;
        regs_n[`REG_SLEEP_STATUS][`EXT_SLEEP_STATUS] = core_ext_sleeping_int;

        // clear ctrl bit if core is asleep or an interrupt/event is present
        if (core_sleeping_int || event_i)
            regs_n[`REG_SLEEP_CTRL][`SLEEP_ENABLE] =  1'b0;
        
        // clear ctrl bit if core is asleep or an interrupt/event is present
        if (core_ext_sleeping_int || event_i)
            regs_n[`REG_SLEEP_CTRL][`EXT_SLEEP_ENABLE] = 1'b0;

        // written from APB bus
        if (PSEL && PENABLE && PWRITE)
        begin

            case (register_adr)
                `REG_SLEEP_CTRL:
                    regs_n[`REG_SLEEP_CTRL] = PWDATA;

                // can't write sleeping status reg
            endcase
        end


    end

    // register read logic
    always_comb
    begin
        PRDATA = 'b0;

        if (PSEL && PENABLE && !PWRITE)
        begin

            case (register_adr)
                `REG_SLEEP_CTRL:
                    PRDATA = regs_q[`REG_SLEEP_CTRL];

                `REG_SLEEP_STATUS:
                    PRDATA = regs_q[`REG_SLEEP_STATUS];

                default:
                    PRDATA = 'b0;
            endcase
        end
    end


    // low-speed clock synchronizer
    always_ff @(posedge HCLK, negedge HRESETn) 
    begin
        if(~HRESETn) begin
            r_ls_clk_sync <= 'h0;
        end else begin
            r_ls_clk_sync <= {r_ls_clk_sync[1:0],clk32_i};
        end
    end

    // synchronous part
    always_ff @(posedge HCLK, negedge HRESETn)
    begin
        if(~HRESETn)
        begin
            SLEEP_STATE_Q   <= RUN;
            regs_q          <= '{default: 32'b0};
            cntr_q          <= '0;
        end
        else
        begin
            SLEEP_STATE_Q   <= SLEEP_STATE_N;
            regs_q          <= regs_n;
            cntr_q <= cntr_n;
        end
    end

endmodule
