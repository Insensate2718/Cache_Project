set profile $::env(WAVE_PROFILE)
set output_file $::env(WAVE_PS_OUTPUT)
set range_start $::env(WAVE_RANGE_START)
set range_end $::env(WAVE_RANGE_END)

if {$profile eq "cold_miss"} {
    set signals [list \
        {tb_smoke.clk} \
        {tb_smoke.req_valid} \
        {tb_smoke.req_ready} \
        {tb_smoke.req_addr[15:0]} \
        {tb_smoke.req_write} \
        {tb_smoke.resp_valid} \
        {tb_smoke.resp_ready} \
        {tb_smoke.resp_rdata[31:0]} \
        {tb_smoke.mem_req_valid} \
        {tb_smoke.mem_req_ready} \
        {tb_smoke.mem_req_write} \
        {tb_smoke.mem_req_addr[15:0]} \
        {tb_smoke.mem_resp_valid} \
        {tb_smoke.mem_resp_ready} \
        {tb_smoke.dut.cache_controller_inst.state[4:0]}]
} elseif {$profile eq "tag_parity"} {
    set signals [list \
        {tb_smoke.clk} \
        {tb_smoke.req_valid} \
        {tb_smoke.req_ready} \
        {tb_smoke.req_addr[15:0]} \
        {tb_smoke.resp_valid} \
        {tb_smoke.resp_ready} \
        {tb_smoke.resp_tag_parity_err} \
        {tb_smoke.resp_fatal_err} \
        {tb_smoke.dut.compare_parity_error_any} \
        {tb_smoke.dut.compare_parity_error_vector[3:0]} \
        {tb_smoke.dut.tag_lookup_valid[3:0]} \
        {tb_smoke.dut.tag_lookup_dirty[3:0]} \
        {tb_smoke.dut.tag_meta_write_en} \
        {tb_smoke.dut.tag_meta_write_valid} \
        {tb_smoke.dut.cache_controller_inst.state[4:0]}]
} else {
    error "Unknown WAVE_PROFILE: $profile"
}

set added [gtkwave::addSignalsFromList $signals]
if {$added != [llength $signals]} {
    error "Only added $added of [llength $signals] requested signals"
}

gtkwave::/Edit/Set_Trace_Max_Hier 0
gtkwave::setZoomRangeTimes $range_start $range_end
gtkwave::/File/Print_To_File PS {Letter (8.5" x 11")} Full $output_file
gtkwave::/File/Quit
