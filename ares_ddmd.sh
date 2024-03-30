#!/bin/bash

SHORTENED_PIPELINE=false
SKIP_SIM=true
MD_RUNS=32
ITER_COUNT=3 # TBD
SIM_LENGTH=0.1

DROP_CACHE=false

# export HDF5_PAGE_BUFFER_SIZE=1048576 # 4096 8192 32768 65536 131072 262144 524288 1048576 4194304 8388608
# echo "HDF5_PAGE_BUFFER_SIZE=$HDF5_PAGE_BUFFER_SIZE"

NODE_COUNT=1
GPU_PER_NODE=6
MD_START=0
MD_SLICE=$(($MD_RUNS/$NODE_COUNT))
STAGE_IDX=0
STAGE_IDX_FORMAT=$(seq -f "stage%04g" $STAGE_IDX $STAGE_IDX)

# NODE_NAMES=`echo $SLURM_JOB_NODELIST|scontrol show hostnames`
NODE_NAMES="localhost"

SIZE=$(echo "$SIM_LENGTH * 1000" | bc)
SIZE=${SIZE%.*}
TRIAL="nfs1"
FS_PATH="NFS"

TEST_OUT_PATH=test_${SIZE}ps_i${ITER_COUNT}_${TRIAL}

set -x
if [ "$FS_PATH" == "NFS" ]
then
    echo "Running on NFS"
    export EXPERIMENT_PATH=~/experiments/ddmd_runs/$TEST_OUT_PATH #NFS
    export DDMD_PATH="`scspkg pkg src ddmd`"/deepdrivemd #/home/$USER/scripts/deepdrivemd #NFS
    export MOLECULES_PATH=$DDMD_PATH/submodules/molecules #NFS
else
    echo "Running on Local Storage"
    echo "PFS not available yet"
    export EXPERIMENT_PATH=/mnt/ssd/$USER/ddmd_runs/$TEST_OUT_PATH
    export DDMD_PATH="`scspkg pkg src ddmd`"/deepdrivemd #NFS
    export MOLECULES_PATH=$DDMD_PATH/submodules/molecules #NFS
fi
set +x

mkdir -p $EXPERIMENT_PATH

if [ "$SKIP_SIM" == "true" ]
then
    echo "Skipping simulation"
    rm -rf $EXPERIMENT_PATH/agent_runs
    rm -rf $EXPERIMENT_PATH/aggregate_runs
    rm -rf $EXPERIMENT_PATH/inference_runs
    rm -rf $EXPERIMENT_PATH/machine_learning_runs
    rm -rf $EXPERIMENT_PATH/model_selection_runs
    rm -rf $EXPERIMENT_PATH/*/*/*/aggregated.h5
    ls $EXPERIMENT_PATH/* -hl
else
    rm -rf $EXPERIMENT_PATH/*
    ls $EXPERIMENT_PATH/* -hl
fi

CONDA_OPENMM="hermes_openmm7_ddmd" # openmm7_ddmd hermes_openmm7_ddmd
CONDA_PYTORCH="hm_ddmd_pytorch" # pytorch_ddmd hm_ddmd_pytorch

## Setup DaYu Tracker
schema_file_path=$DDMD_PATH/dayu_stat_s32ps1000i3_short
mkdir -p $schema_file_path
# clean up the schema files
rm -rf $schema_file_path/*vfd_data_stat.json
rm -rf $schema_file_path/*vol_data_stat.json
TRACKER_PRELOAD_DIR="`scspkg pkg root dayu_tracker`"/lib
TRACKER_VFD_PAGE_SIZE=65536 # 8192 16384 32768 65536 131072 262144 524288 1048576
echo "TRACKER_PRELOAD_DIR : `ls -l $TRACKER_PRELOAD_DIR/*`"

SET_CONDA_ENV_VARS(){
    
    for env in $CONDA_OPENMM $CONDA_PYTORCH
    do
        echo "Setting Conda Environment Variables in $env..."
        set -x
        conda env config vars set -n $env HDF5_VOL_CONNECTOR=$HDF5_VOL_CONNECTOR
        conda env config vars set -n $env HDF5_PLUGIN_PATH=$HDF5_PLUGIN_PATH 
        conda env config vars set -n $env HDF5_DRIVER=$HDF5_DRIVER
        conda env config vars set -n $env HDF5_DRIVER_CONFIG=$HDF5_DRIVER_CONFIG
        set +x
    done
}

# SET_CONDA_ENV_VARS

UNSET_CONDA_ENV_VARS(){
    
    for env in $CONDA_OPENMM $CONDA_PYTORCH
    do
        echo "Unsetting Conda Environment Variables in $env..."
        conda env config vars set -n $env HDF5_VOL_CONNECTOR
        conda env config vars set -n $env HDF5_PLUGIN_PATH
        conda env config vars set -n $env HDF5_DRIVER
        conda env config vars set -n $env HDF5_DRIVER_CONFIG
    done
}


PREP_TASK_NAME () {
    TASK_NAME=$1
    export CURR_TASK=$TASK_NAME
    export WORKFLOW_NAME="ddmd"
    export PATH_FOR_TASK_FILES="/tmp/$USER/$WORKFLOW_NAME"
    mkdir -p $PATH_FOR_TASK_FILES
    > $PATH_FOR_TASK_FILES/${WORKFLOW_NAME}_vfd.curr_task # clear the file
    > $PATH_FOR_TASK_FILES/${WORKFLOW_NAME}_vol.curr_task # clear the file

    echo -n "$TASK_NAME" > $PATH_FOR_TASK_FILES/${WORKFLOW_NAME}_vfd.curr_task
    echo -n "$TASK_NAME" > $PATH_FOR_TASK_FILES/${WORKFLOW_NAME}_vol.curr_task
}


OPENMM(){

    task_id=$(seq -f "task%04g" $1 $1)
    gpu_idx=$(($1 % $GPU_PER_NODE))
    node_id=$2
    yaml_path=$3
    stage_name="molecular_dynamics"
    dest_path=$EXPERIMENT_PATH/${stage_name}_runs/$STAGE_IDX_FORMAT/$task_id
    PREP_TASK_NAME "openmm"

    if [ "$yaml_path" == "" ]
    then
        yaml_path=$DDMD_PATH/test/bba/${stage_name}_stage_test.yaml
    fi

    eval "$(~/miniconda3/bin/conda shell.bash hook)" # conda init bash
    source activate $CONDA_OPENMM

    mkdir -p $dest_path
    cd $dest_path
    echo "Running OPENMM at $node_id in $dest_path ..."

    sed -e "s/\$SIM_LENGTH/${SIM_LENGTH}/" -e "s/\$OUTPUT_PATH/${dest_path//\//\\/}/" -e "s/\$EXPERIMENT_PATH/${EXPERIMENT_PATH//\//\\/}/" -e "s/\$DDMD_PATH/${DDMD_PATH//\//\\/}/" -e "s/\$GPU_IDX/${gpu_idx}/" -e "s/\$STAGE_IDX/${STAGE_IDX}/" $yaml_path  > $dest_path/$(basename $yaml_path)
    yaml_path=$dest_path/$(basename $yaml_path)

    set -x

        PYTHONPATH=$DDMD_PATH:$MOLECULES_PATH python $DDMD_PATH/deepdrivemd/sim/openmm/run_openmm.py -c $yaml_path &> ${task_id}_${FUNCNAME[0]}.log &
    
    set +x

}

AGGREGATE(){
    echo "Running AGGREGATE ..."

    task_id=task0000
    stage_name="aggregate"
    STAGE_IDX=$(($STAGE_IDX - 1))
    STAGE_IDX_FORMAT=$(seq -f "stage%04g" $STAGE_IDX $STAGE_IDX)
    dest_path=$EXPERIMENT_PATH/molecular_dynamics_runs/$STAGE_IDX_FORMAT/task0000
    yaml_path=$DDMD_PATH/test/bba/${stage_name}_stage_test.yaml
    PREP_TASK_NAME "$stage_name"

    eval "$(~/miniconda3/bin/conda shell.bash hook)" # conda init bash
    source activate $CONDA_OPENMM

    cd $dest_path
    echo cd $dest_path

    sed -e "s/\$SIM_LENGTH/${SIM_LENGTH}/" -e "s/\$OUTPUT_PATH/${dest_path//\//\\/}/" -e "s/\$EXPERIMENT_PATH/${EXPERIMENT_PATH//\//\\/}/" -e "s/\$STAGE_IDX/${STAGE_IDX}/" $yaml_path  > $dest_path/$(basename $yaml_path)
    yaml_path=$dest_path/$(basename $yaml_path)

    # { time PYTHONPATH=$DDMD_PATH/ python $DDMD_PATH/deepdrivemd/aggregation/basic/aggregate.py -c $yaml_path ; } &> $dest_path/${task_id}_${FUNCNAME[0]}.log 

    # PYTHONPATH=$DDMD_PATH/ ~/miniconda3/envs/${CONDA_OPENMM}/bin/python $DDMD_PATH/deepdrivemd/aggregation/basic/aggregate.py -c $yaml_path &> $dest_path/${task_id}_${FUNCNAME[0]}.log 
    set -x

        python $DDMD_PATH/deepdrivemd/aggregation/basic/aggregate.py -c $yaml_path &> $dest_path/${task_id}_${FUNCNAME[0]}.log 
    
    set +x

    #env LD_PRELOAD=/qfs/people/leeh736/git/tazer_forked/build.h5.pread64.bluesky/src/client/libclient.so PYTHONPATH=$DDMD_PATH/ python /files0/oddite/deepdrivemd/src/deepdrivemd/aggregation/basic/aggregate.py -c /qfs/projects/oddite/leeh736/ddmd_runs/1k/agg_test.yaml &> agg_test_output.log
}

TRAINING () {

    task_id=task0000
    stage_name="machine_learning"
    dest_path=$EXPERIMENT_PATH/${stage_name}_runs/$STAGE_IDX_FORMAT/$task_id
    stage_name="training"
    yaml_path=$DDMD_PATH/test/bba/${stage_name}_stage_test.yaml
    PREP_TASK_NAME "$stage_name"

    mkdir -p $EXPERIMENT_PATH/model_selection_runs/$STAGE_IDX_FORMAT/task0000/
    cp -p $DDMD_PATH/test/bba/stage0000_task0000.json $EXPERIMENT_PATH/model_selection_runs/$STAGE_IDX_FORMAT/task0000/${STAGE_IDX_FORMAT}_task0000.json


    eval "$(~/miniconda3/bin/conda shell.bash hook)" # conda init bash
    source activate $CONDA_PYTORCH

    mkdir -p $dest_path
    cd $dest_path
    echo cd $dest_path

    sed -e "s/\$SIM_LENGTH/${SIM_LENGTH}/" -e "s/\$OUTPUT_PATH/${dest_path//\//\\/}/" -e "s/\$EXPERIMENT_PATH/${EXPERIMENT_PATH//\//\\/}/" -e "s/\$STAGE_IDX/${STAGE_IDX}/" $yaml_path  > $dest_path/$(basename $yaml_path)
    yaml_path=$dest_path/$(basename $yaml_path)

    #    echo PYTHONPATH=$DDMD_PATH/:$MOLECULES_PATH srun -n1 -N1 --exclusive python $DDMD_PATH/deepdrivemd/models/aae/train.py -c $yaml_path ${task_id}_${FUNCNAME[0]}.log 
   if [ "$SHORTENED_PIPELINE" == true ]
   then

        PYTHONPATH=$DDMD_PATH/:$MOLECULES_PATH python $DDMD_PATH/deepdrivemd/models/aae/train.py -c $yaml_path &> ${task_id}_${FUNCNAME[0]}.log &
   else

        PYTHONPATH=$DDMD_PATH/:$MOLECULES_PATH python $DDMD_PATH/deepdrivemd/models/aae/train.py -c $yaml_path &> ${task_id}_${FUNCNAME[0]}.log
   fi

}


INFERENCE(){
    echo "Running INFERENCE ..."

    task_id=task0000
    stage_name="inference"
    dest_path=$EXPERIMENT_PATH/${stage_name}_runs/$STAGE_IDX_FORMAT/$task_id
    yaml_path=$DDMD_PATH/test/bba/${stage_name}_stage_test.yaml
    pretrained_model=$DDMD_PATH/data/bba/epoch-130-20201203-150026.pt
    PREP_TASK_NAME "$stage_name"


    eval "$(~/miniconda3/bin/conda shell.bash hook)" # conda init bash
    source activate $CONDA_PYTORCH

    mkdir -p $dest_path
    cd $dest_path
    echo cd $dest_path

    mkdir -p $EXPERIMENT_PATH/agent_runs/$STAGE_IDX_FORMAT/task0000/


    sed -e "s/\$SIM_LENGTH/${SIM_LENGTH}/" -e "s/\$OUTPUT_PATH/${dest_path//\//\\/}/" -e "s/\$EXPERIMENT_PATH/${EXPERIMENT_PATH//\//\\/}/" -e "s/\$STAGE_IDX/${STAGE_IDX}/" $yaml_path  > $dest_path/$(basename $yaml_path)
    yaml_path=$dest_path/$(basename $yaml_path)

    # latest model search
    model_checkpoint=$(find $EXPERIMENT_PATH/machine_learning_runs/*/*/checkpoint -type f -printf '%T@ %p\n' | sort -n | tail -1 | cut -f2- -d" ")
    if [ "$model_checkpoint" == "" ] && [ "$SHORTENED_PIPELINE" == true ]
    then
        model_checkpoint=$pretrained_model
    fi
    

    STAGE_IDX_PREV=$((STAGE_IDX - 1))
    STAGE_IDX_FORMAT_PREV=$(seq -f "stage%04g" $STAGE_IDX_PREV $STAGE_IDX_PREV)


    sed -i -e "s/\$MODEL_CHECKPOINT/${model_checkpoint//\//\\/}/"  $EXPERIMENT_PATH/model_selection_runs/$STAGE_IDX_FORMAT_PREV/task0000/${STAGE_IDX_FORMAT_PREV}_task0000.json

    echo "model_checkpoint = $model_checkpoint"

    OMP_NUM_THREADS=4 PYTHONPATH=$DDMD_PATH/:$MOLECULES_PATH python $DDMD_PATH/deepdrivemd/agents/lof/lof.py -c $yaml_path &> ${task_id}_${FUNCNAME[0]}.log     

}


STAGE_UPDATE() {

    STAGE_IDX=$(($STAGE_IDX + 1))
    tmp=$(seq -f "stage%04g" $STAGE_IDX $STAGE_IDX)
    echo $tmp
}


# # conda environment on Deception
eval "$(~/miniconda3/bin/conda shell.bash hook)" # conda init bash

sudo drop_caches

total_start_time=$SECONDS
# total_drop_cache_time=$(($(date +%s%N)/1000000))
drop_cache_time=0

for iter in $(seq $ITER_COUNT);
do

    # Drop Cache
    if [ "$DROP_CACHE" == true ] 
    then
        dc_start_time=$(($(date +%s%N)/1000000))
        srun -n$SLURM_JOB_NUM_NODES -w $hostlist sudo /sbin/sysctl vm.drop_caches=3
        dc_duration=$(( $(date +%s%N)/1000000 - $dc_start_time))
        drop_cache_time=$(( $drop_cache_time + $dc_duration ))
        echo "Current drop_cache_time (ms) : $drop_cache_time"
    fi

    # STAGE 1: OpenMM
    if [ "$SKIP_SIM" == "false" ]
    then
        start_time=$SECONDS
        for node in $NODE_NAMES
        do
            while [ $MD_SLICE -gt 0 ] && [ $MD_START -lt $MD_RUNS ]
            do
                echo $node
                OPENMM $MD_START $node
                MD_START=$(($MD_START + 1))
                MD_SLICE=$(($MD_SLICE - 1))
            done
            MD_SLICE=$(($MD_RUNS/$NODE_COUNT))
        done

        MD_START=0
        wait
        duration=$(($SECONDS - $start_time))
        echo "OpenMM done... $(($duration / 60)) minutes and $(($duration % 60)) seconds elapsed ($duration secs)."
    else
        echo "Skipping OpenMM ..."
    fi



    STAGE_IDX_FORMAT="$(STAGE_UPDATE)"
    STAGE_IDX=$((STAGE_IDX + 1))
    echo $STAGE_IDX_FORMAT

    # Drop Cache
    if [ "$DROP_CACHE" == true ]
    then
        dc_start_time=$(($(date +%s%N)/1000000))
        # srun -n$SLURM_JOB_NUM_NODES -w $hostlist sudo /sbin/sysctl vm.drop_caches=3

        dc_duration=$(( $(date +%s%N)/1000000 - $dc_start_time))
        drop_cache_time=$(( $drop_cache_time + $dc_duration ))
        # echo "Current drop_cache_time (ms) : $drop_cache_time"
    fi

    # STAGE 2: Aggregate
    if [ "$SHORTENED_PIPELINE" != true ]
    then
        start_time=$SECONDS
        # srun -N1 $( AGGREGATE )
        AGGREGATE
        wait 
        duration=$(($SECONDS - $start_time))
        echo "Aggregate done... $(($duration / 60)) minutes and $(($duration % 60)) seconds elapsed ($duration secs)."
    else
        echo "No AGGREGATE, SHORTENED_PIPELINE = $SHORTENED_PIPELINE..."
    fi

    STAGE_IDX_FORMAT="$(STAGE_UPDATE)"
    STAGE_IDX=$((STAGE_IDX + 1))
    echo $STAGE_IDX_FORMAT

    # Drop Cache
    if [ "$DROP_CACHE" == true ] 
    then
        dc_start_time=$(($(date +%s%N)/1000000))
        srun -n$SLURM_JOB_NUM_NODES -w $hostlist sudo /sbin/sysctl vm.drop_caches=3
        dc_duration=$(( $(date +%s%N)/1000000 - $dc_start_time))
        drop_cache_time=$(( $drop_cache_time + $dc_duration ))
        # echo "Current drop_cache_time (ms) : $drop_cache_time"
    fi
    # STAGE 3: Training
    start_time=$SECONDS
    if [ "$SHORTENED_PIPELINE" != true ]
    then
        TRAINING
        duration=$(($SECONDS - $start_time))
        echo "Training done... $(($duration / 60)) minutes and $(($duration % 60)) seconds elapsed ($duration secs)."
    else
        TRAINING
        echo "Training not waited, SHORTENED_PIPELINE = $SHORTENED_PIPELINE..."
    fi
    

    STAGE_IDX_FORMAT="$(STAGE_UPDATE)"
    STAGE_IDX=$((STAGE_IDX + 1))
    echo $STAGE_IDX_FORMAT
    if [ "$SHORTENED_PIPELINE" != true ]
    then
        wait
    fi

    # Drop Cache
    if [ "$DROP_CACHE" == true ]
    then
        dc_start_time=$(($(date +%s%N)/1000000))
        srun -n$SLURM_JOB_NUM_NODES -w $hostlist sudo /sbin/sysctl vm.drop_caches=3
        dc_duration=$(( $(date +%s%N)/1000000 - $dc_start_time))
        drop_cache_time=$(( $drop_cache_time + $dc_duration ))
        # echo "Current drop_cache_time (ms) : $drop_cache_time"
    fi
    # STAGE 4: Inference
    start_time=$SECONDS
    # srun -N1 $( INFERENCE )
    INFERENCE

    wait
    duration=$(($SECONDS - $start_time))
    echo "Inference done... $(($duration / 60)) minutes and $(($duration % 60)) seconds elapsed ($duration secs)."

    STAGE_IDX_FORMAT="$(STAGE_UPDATE)"
    STAGE_IDX=$((STAGE_IDX + 1))
    echo $STAGE_IDX_FORMAT

done


total_duration=$(($SECONDS - $total_start_time))
echo "All done... $(($total_duration / 60)) minutes and $(($total_duration % 60)) seconds elapsed ($total_duration secs)."
echo "Drop cache time: $drop_cache_time milliseconds elapsed."

ls $EXPERIMENT_PATH/*/*/* -hl

hostname;date;
# UNSET_CONDA_ENV_VARS
# sacct -j $SLURM_JOB_ID -o jobid,submit,start,end,state