# 1. Setup Project
set outputDir ./syn/gen/build_output
file mkdir $outputDir
create_project -force fpga_power_quality ./syn/gen/project -part xc7a35tcpg236-1

# 2. Add Source Files (Robust Globbing)
add_files [glob -nocomplain ./src/hdl/**/*.sv ./src/hdl/**/*.v]
add_files -fileset constrs_1 ./syn/xdc/basys3.xdc

# 3. Set Top Module
set_property top basys3_top [current_fileset]
update_compile_order -fileset sources_1

# 4. Run Synthesis
synth_design -top basys3_top -part xc7a35tcpg236-1
write_checkpoint -force $outputDir/post_synth.dcp

# 5. Run Implementation
opt_design
place_design
route_design

# 6. Generate Reports
report_utilization -file $outputDir/utilization.txt
report_timing_summary -file $outputDir/timing_summary.txt

# 7. Check for Timing Violations
set WNS [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -setup]]
if {$WNS < 0} {
    puts "ERROR: Timing constraints not met! WNS = $WNS"
}

# 8. Write Bitstream
write_bitstream -force $outputDir/system_top.bit

exit
