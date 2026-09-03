# 1. Setup the project environment in the gen folder
# This creates a workspace for Vivado to generate the IP
create_project -force managed_ip_project ./src/ip/gen/managed_ip_project -part xc7a35tcpg236-1

# 2. Create the XADC Wizard IP
create_ip -name xadc_wiz -vendor xilinx.com -library ip -version 3.3 -module_name xadc_wiz_0

# 3. Configure the IP (Sequencer mode for JXADC pins)
set_property -dict [list \
  CONFIG.INTERFACE_SELECTION {ENABLE_DRP} \
  CONFIG.TIMING_MODE {Continuous} \
  CONFIG.XADC_STARUP_SELECTION {channel_sequencer} \
  CONFIG.SEQUENCER_MODE {Continuous} \
  CONFIG.DCLK_FREQUENCY {100} \
  CONFIG.ADC_CONVERSION_RATE {1000} \
  CONFIG.CHANNEL_ENABLE_VAUXP6_VAUXN6 {true} \
  CONFIG.CHANNEL_ENABLE_VAUXP14_VAUXN14 {true} \
  CONFIG.EXTERNAL_MUX_CHANNEL {VP_VN} \
  CONFIG.SINGLE_CHANNEL_SELECTION {TEMPERATURE} \
] [get_ips xadc_wiz_0]

# 4. Generate the IP (Synthesis files and Instantiation Template)
generate_target {instantiation_template synthesis} [get_ips xadc_wiz_0]

# 5. Export for simulation (Creates the .v and .vhd wrappers)
export_ip_user_files -of_objects [get_ips xadc_wiz_0] -no_script -sync -force -quiet

# 6. Exit batch mode
exit
