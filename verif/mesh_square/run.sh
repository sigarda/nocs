#!/bin/sh
# $Id: run.sh 1853 2010-03-24 03:06:21Z dub $

#source ~/.profile  #578 commenting out not sure what that does

#cd ${rundir} #578 commenting out don't want to change dir

source ./config_base.sh
source ./config.sh

sed -i "s/\(parameter *tclk *=\) [0-9]*/\1 ${tclk}/" testbench.v
sed -i "s/\(parameter *sim_cycles *=\) [0-9]*/\1 ${sim_cycles}/" testbench.v
sed -i "s/\(parameter *warmup_cycles *=\) [0-9]*/\1 ${warmup_cycles}/" testbench.v
sed -i "s/\(parameter *initial_seed *=\) [0-9]*/\1 ${initial_seed}/" testbench.v
sed -i "s/\(parameter *reset_type *=\) [a-z0-9_]*/\1 ${reset_type}/" testbench.v
sed -i "s/\(parameter *buffer_occupancy *=\) [0-9]*/\1 ${buffer_occupancy}/" testbench.v
sed -i "s/\(parameter *output_as_csv *=\) [0-9]*/\1 ${output_as_csv}/" testbench.v
#sed -i "s/\(parameter *ignore_same_port *=\) [0-9]*/\1 ${restrict}/" ../../src/config.v #578 commenting out file not found
#sed -i "s/\(parameter *restrict_vcs *=\) [0-9]*/\1 ${restrict}/" ../../src/config.v #578 commenting out file not found

make clean all > /dev/null

#./simv | grep "SIM: " | sed s/"SIM: "//g | tee matching.csv #578 commenting this out for now may change the grep to our custom tag
./simv #this will actually run the testbench
