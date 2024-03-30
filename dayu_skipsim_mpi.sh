#!/bin/bash
#SBATCH --job-name=ddmd100ps_2n12ti1_nfs0
#SBATCH --time=00:30:00
#SBATCH -N 2
#SBATCH -n 12
#SBATCH --output=./R_%x.out
#SBATCH --error=./R_%x.err

SHORTENED_PIPELINE=true
SKIP_SIM=true
MD_RUNS=32
ITER_COUNT=3 # TBD
SIM_LENGTH=0.1

DROP_CACHE=false

# export HDF5_PAGE_BUFFER_SIZE=1048576 # 4096 8192 32768 65536 131072 262144 524288 1048576 4194304 8388608
# echo "HDF5_PAGE_BUFFER_SIZE=$HDF5_PAGE_BUFFER_SIZE"
SCRIPT_DIR="`pwd`"

NODE_NAMES=( "ares-comp-30" "ares-comp-32" )
NODE_COUNT=${#NODE_NAMES[@]}
GPU_PER_NODE=6
MD_START=0
MD_SLICE=$(($MD_RUNS/$NODE_COUNT))

INFERENCE_NODE=${NODE_NAMES[0]}
TRAINING_NODE=${NODE_NAMES[1]}
echo "INFERENCE_NODE=$INFERENCE_NODE"
echo "TRAINING_NODE=$TRAINING_NODE"

# Turn NODE_NAMES into comma seperated host list
HOST_LIST=""
for node in ${NODE_NAMES[@]}; do
    HOST_LIST="$HOST_LIST,$node"
done

# NODE_NAMES=`echo $SLURM_JOB_NODELIST|scontrol show hostnames`
# NODE_NAMES="localhost"



SIZE=$(echo "$SIM_LENGTH * 1000" | bc)
SIZE=${SIZE%.*}
TRIAL="1"
FS_PATH="NFS"

# TEST_OUT_NAME=test_${SIZE}ps_i${ITER_COUNT}_${TRIAL}
# TEST_OUT_NAME=test_${SIZE}ps_i3_${TRIAL}

TEST_OUT_NAME=test_${SIZE}ps_i${ITER_COUNT}_${TRIAL}

set -x
if [ "$FS_PATH" == "NFS" ]
then
    echo "Running on NFS"
    export EXPERIMENT_PATH=~/experiments/ddmd_runs/$TEST_OUT_NAME #NFS
    export DDMD_PATH="`scspkg pkg src ddmd`"/deepdrivemd #/home/$USER/scripts/deepdrivemd #NFS
    export MOLECULES_PATH=$DDMD_PATH/submodules/molecules #NFS
    export LOCAL_STORAGE=/mnt/nvme/$USER/ddmd_runs/$TEST_OUT_NAME
else
    echo "Running on Local Storage"
    echo "PFS not available yet"
    export EXPERIMENT_PATH=/mnt/nvme/$USER/ddmd_runs/$TEST_OUT_NAME
    export DDMD_PATH="`scspkg pkg src ddmd`"/deepdrivemd #NFS
    export MOLECULES_PATH=$DDMD_PATH/submodules/molecules #NFS
fi

mkdir -p $EXPERIMENT_PATH
mpirun -hosts $HOST_LIST -np 1 mkdir -p $LOCAL_STORAGE
mpirun -hosts $HOST_LIST -np 1 rm -rf $LOCAL_STORAGE/*
set +x

if [ "$SKIP_SIM" == "true" ]
then
    echo "Skipping simulation"
    mkdir -p $EXPERIMENT_PATH/molecular_dynamics_runs
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
# schema_file_path=$DDMD_PATH/dayu_stat_s32ps1000i3_short
schema_file_path=$DDMD_PATH/dayu_stat
mkdir -p $schema_file_path
# clean up the schema files
rm -rf $schema_file_path/*vfd_data_stat.json
rm -rf $schema_file_path/*vol_data_stat.json
TRACKER_PRELOAD_DIR="`scspkg pkg root dayu_tracker`"/lib
TRACKER_VFD_PAGE_SIZE=65536 # 8192 16384 32768 65536 131072 262144 524288 1048576
echo "TRACKER_PRELOAD_DIR : `ls -l $TRACKER_PRELOAD_DIR/*`"
export HDF5_VOL_CONNECTOR="tracker under_vol=0;under_info={};path=$schema_file_path;level=2;format="
export HDF5_PLUGIN_PATH="$TRACKER_PRELOAD_DIR/vol:$TRACKER_PRELOAD_DIR/vfd"
export HDF5_DRIVER=hdf5_tracker_vfd
export HDF5_DRIVER_CONFIG="${schema_file_path};${TRACKER_VFD_PAGE_SIZE}"
export HDF5_USE_FILE_LOCKING='FALSE'

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

STAGE_UPDATE() {

    STAGE_IDX=$(($STAGE_IDX + 1))
    tmp=$(seq -f "stage%04g" $STAGE_IDX $STAGE_IDX)
    echo $tmp
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

CHECK_OUTPUT(){
    # ls $EXPERIMENT_PATH/agent_runs/*/* -hl
    # ls $EXPERIMENT_PATH/molecular_dynamics_runs/*/task0000 -hl
    # ls $EXPERIMENT_PATH/inference_runs/*/* -hl
    # ls $EXPERIMENT_PATH/machine_learning_runs/*/* -hl
    # ls $EXPERIMENT_PATH/model_selection_runs/*/* -hl
    ls $EXPERIMENT_PATH/*/*/* -hl
}

PREPARE_INPUT_FILE_TO_LOCAL(){
: <<'OPT'
This step is used to set up such that when the simulation is skipped, the experiment data exists in the local storage of each node
OPT

    task_id=$(seq -f "task%04g" $1 $1)
    node_id=$2
    dest_path=$LOCAL_STORAGE/molecular_dynamics_runs/$STAGE_IDX_FORMAT
    orig_data_path=$EXPERIMENT_PATH/molecular_dynamics_runs/$STAGE_IDX_FORMAT/$task_id

    echo "Skipping simulation..."
    set -x
    mpirun --host $node_id -np 1 rm -rf $dest_path/$task_id
    mpirun --host $node_id -np 1 cp -r $orig_data_path $dest_path/
    set +x
}

MD_START=0
MD_SLICE=$(($MD_RUNS/$NODE_COUNT))
STAGE_IDX=0
STAGE_IDX_FORMAT=$(seq -f "stage%04g" $STAGE_IDX $STAGE_IDX)

for iter in $(seq $ITER_COUNT);
do
    for node in ${NODE_NAMES[@]}
    do
        dest_path=$LOCAL_STORAGE/molecular_dynamics_runs/$STAGE_IDX_FORMAT
        mpirun --host $node -np 1 mkdir -p $dest_path
        while [ $MD_SLICE -gt 0 ] && [ $MD_START -lt $MD_RUNS ]
        do
            echo $node
            PREPARE_INPUT_FILE_TO_LOCAL $MD_START $node &
            MD_START=$(($MD_START + 1))
            MD_SLICE=$(($MD_SLICE - 1))
        done
        MD_SLICE=$(($MD_RUNS/$NODE_COUNT))
    done

    # Additional folders to prepare for TRAINING_NODE

    dest_path=$LOCAL_STORAGE/molecular_dynamics_runs/$STAGE_IDX_FORMAT
    orig_data_path=$EXPERIMENT_PATH/molecular_dynamics_runs/$STAGE_IDX_FORMAT/task0000
    # orig_data_path=$EXPERIMENT_PATH/molecular_dynamics_runs/$STAGE_IDX_FORMAT/task0002
    set -x
    mpirun --host $TRAINING_NODE -np 1 cp -r $orig_data_path $dest_path/ # for storing aggregate.h5
    set +x

    # Check output
    echo "Checking PREPARE_INPUT_FILE_TO_LOCAL files..."
    mpirun -hosts $HOST_LIST ls $LOCAL_STORAGE/molecular_dynamics_runs/$STAGE_IDX_FORMAT/* -hl

    STAGE_IDX_FORMAT="$(STAGE_UPDATE)"
    STAGE_IDX_FORMAT="$(STAGE_UPDATE)"
    STAGE_IDX_FORMAT="$(STAGE_UPDATE)"
    STAGE_IDX_FORMAT="$(STAGE_UPDATE)"

    STAGE_IDX=$((STAGE_IDX + 4))
    echo $STAGE_IDX_FORMAT
done
wait

OPENMM_LOCAL () {

    task_id=$(seq -f "task%04g" $1 $1)
    gpu_idx=$(($1 % $GPU_PER_NODE))
    node_id=$2
    yaml_path=$3

    stage_name="molecular_dynamics"
    # dest_path=$EXPERIMENT_PATH/${stage_name}_runs/$STAGE_IDX_FORMAT/$task_id
    dest_path=$LOCAL_STORAGE/${stage_name}_runs/$STAGE_IDX_FORMAT/$task_id
    PREP_TASK_NAME "openmm"

    if [ "$yaml_path" == "" ]
    then
        yaml_path=$DDMD_PATH/test/bba/${stage_name}_stage_test.yaml
    fi

    # eval "$(~/miniconda3/bin/conda shell.bash hook)" # conda init bash
    # source activate $CONDA_OPENMM

    mpirun --host $node_id -np 1 mkdir -p $dest_path
    cd $dest_path
    echo "Running OPENMM_LOCAL at $node_id in $dest_path ..."

    mpirun --host $node_id -np 1 sed -e "s/\$SIM_LENGTH/${SIM_LENGTH}/" -e "s/\$OUTPUT_PATH/${dest_path//\//\\/}/" -e "s/\$EXPERIMENT_PATH/${EXPERIMENT_PATH//\//\\/}/" -e "s/\$DDMD_PATH/${DDMD_PATH//\//\\/}/" -e "s/\$GPU_IDX/${gpu_idx}/" -e "s/\$STAGE_IDX/${STAGE_IDX}/" $yaml_path  > $dest_path/$(basename $yaml_path)
        yaml_path=$dest_path/$(basename $yaml_path)

    if [ "$SKIP_SIM" == "true" ]
    then
        ## For testing purpose, simulation is skipped
        echo "Skipping simulation..."
    else
        mpirun --host $node_id -np 1 \
        -env PYTHONPATH=$DDMD_PATH:$MOLECULES_PATH \
        python $DDMD_PATH/deepdrivemd/sim/openmm/run_openmm.py -c $yaml_path &> ${task_id}_${FUNCNAME[0]}.log &
    fi

    ## Copy to shared storage 
    echo "OPENMM_LOCAL Copying to shared storage ..."
    shared_dest_path=$EXPERIMENT_PATH/${stage_name}_runs/$STAGE_IDX_FORMAT
    set -x
    mpirun --host $node_id -np 1 cp -r $dest_path $shared_dest_path/
    set +x

}


AGGREGATE(){
    echo "Running AGGREGATE ..."

    task_id=task0000
    stage_name="aggregate"
    STAGE_IDX=$(($STAGE_IDX - 1))
    STAGE_IDX_FORMAT=$(seq -f "stage%04g" $STAGE_IDX $STAGE_IDX)
    dest_path=$LOCAL_STORAGE/molecular_dynamics_runs/$STAGE_IDX_FORMAT/task0000 # Data already staged in local storage
    # yaml_path=$DDMD_PATH/test/bba/${stage_name}_stage_test.yaml
    yaml_path=$DDMD_PATH/test/bba/${stage_name}_stage_test_nocm.yaml
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
    mpirun --host $INFERENCE_NODE -np 1 \
        python $DDMD_PATH/deepdrivemd/aggregation/basic/aggregate.py -c $yaml_path #&> $dest_path/${task_id}_${FUNCNAME[0]}.log 
    set +x

    shared_dest_path=$EXPERIMENT_PATH/molecular_dynamics_runs/$STAGE_IDX_FORMAT/task0000
    mv $dest_path/aggregated.h5 $shared_dest_path/

    #env LD_PRELOAD=/qfs/people/leeh736/git/tazer_forked/build.h5.pread64.bluesky/src/client/libclient.so PYTHONPATH=$DDMD_PATH/ python /files0/oddite/deepdrivemd/src/deepdrivemd/aggregation/basic/aggregate.py -c /qfs/projects/oddite/leeh736/ddmd_runs/1k/agg_test.yaml &> agg_test_output.log
}

TRAINING_STAGEIN(){
: <<'OPT'
Aggregate need to send result data to Training node
OPT

    echo "Running TRAINING_STAGEIN ..."
    
    shared_dest_path=$EXPERIMENT_PATH/molecular_dynamics_runs/$STAGE_IDX_FORMAT/task0000
    local_dest_path=$LOCAL_STORAGE/molecular_dynamics_runs/$STAGE_IDX_FORMAT/task0000
    
    set -x
    mpirun --host $TRAINING_NODE -np 1 cp -r $shared_dest_path/aggregated.h5 $local_dest_path/
    set +x
}



INFERENCE_STAGEIN(){
    echo "Running INFERENCE_STAGEIN ..."
    shared_dest_path=$EXPERIMENT_PATH/molecular_dynamics_runs/$STAGE_IDX_FORMAT
    dest_path=$LOCAL_STORAGE/molecular_dynamics_runs/$STAGE_IDX_FORMAT

    # Move all molecular_dynamic_runs to local storage
    mpirun --host $INFERENCE_NODE -np 1 mkdir -p $dest_path
    mpirun --host $INFERENCE_NODE -np 1 cp -r $shared_dest_path/* $dest_path
}

INFERENCE(){
    echo "Running INFERENCE ..."

    task_id=task0000
    stage_name="inference"
    dest_path=$LOCAL_STORAGE/${stage_name}_runs/$STAGE_IDX_FORMAT/$task_id
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

    # if [ "$STAGE_IDX_PREV" == "2" ]
    # then
    #     model_checkpoint=$pretrained_model
    # fi

    sed -i -e "s/\$MODEL_CHECKPOINT/${model_checkpoint//\//\\/}/"  $EXPERIMENT_PATH/model_selection_runs/$STAGE_IDX_FORMAT_PREV/task0000/${STAGE_IDX_FORMAT_PREV}_task0000.json

    echo "model_checkpoint = $model_checkpoint"

    # OMP_NUM_THREADS=4 PYTHONPATH=$DDMD_PATH/:$MOLECULES_PATH srun -N1 ~/.conda/envs/hm_ddmd_pytorch/bin/python $DDMD_PATH/deepdrivemd/agents/lof/lof.py -c $yaml_path &> ${task_id}_${FUNCNAME[0]}.log 
    # OMP_NUM_THREADS=4 PYTHONPATH=$DDMD_PATH/:$MOLECULES_PATH ~/miniconda3/envs/${CONDA_PYTORCH}/bin/python $DDMD_PATH/deepdrivemd/agents/lof/lof.py -c $yaml_path &> ${task_id}_${FUNCNAME[0]}.log     

    # HDF5_VOL_CONNECTOR="tracker under_vol=0;under_info={};path=$schema_file_path;level=2;format=" \
    # HDF5_PLUGIN_PATH="$TRACKER_PRELOAD_DIR/vol:$TRACKER_PRELOAD_DIR/vfd:$HDF5_PLUGIN_PATH" \
    # HDF5_DRIVER=hdf5_tracker_vfd \
    # HDF5_DRIVER_CONFIG="${schema_file_path};${TRACKER_VFD_PAGE_SIZE}" \
    OMP_NUM_THREADS=4 PYTHONPATH=$DDMD_PATH/:$MOLECULES_PATH python $DDMD_PATH/deepdrivemd/agents/lof/lof.py -c $yaml_path &> ${task_id}_${FUNCNAME[0]}.log     

}

DATA_STAGE_OUT (){


    echo "Running DATA_STAGE_OUT ..."
    infernce_local_dest_path=$LOCAL_STORAGE/inference_runs
    inference_dest_path=$EXPERIMENT_PATH/inference_runs
    mkdir -p $inference_dest_path
    
    set -x
    mpirun --host $INFERENCE_NODE -np 1 cp -r $infernce_local_dest_path/* $inference_dest_path
    # mpirun --host $TRAINING_NODE -np 1 cp -r $training_local_dest_path/* $training_dest_path
    set +x

}


# # conda environment on Deception
eval "$(~/miniconda3/bin/conda shell.bash hook)" # conda init bash

# Reset stage format before workflow loop
MD_START=0
MD_SLICE=$(($MD_RUNS/$NODE_COUNT))
STAGE_IDX=0
STAGE_IDX_FORMAT=$(seq -f "stage%04g" $STAGE_IDX $STAGE_IDX)

sudo drop_caches

total_start_time=$SECONDS
# total_drop_cache_time=$(($(date +%s%N)/1000000))
drop_cache_time=0

for iter in $(seq $ITER_COUNT);
do


    # STAGE 1: OpenMM
    start_time=$SECONDS
    for node in ${NODE_NAMES[@]}
    do
        while [ $MD_SLICE -gt 0 ] && [ $MD_START -lt $MD_RUNS ]
        do
            echo $node
            set -x
            OPENMM_LOCAL $MD_START $node
            # mpirun --host $node -np 1 $SCRIPT_DIR/OPENMM_LOCAL.sh \
            #     $MD_START $node \
            #     $LOCAL_STORAGE $STAGE_IDX $SIM_LENGTH \
            #     $EXPERIMENT_PATH $DDMD_PATH $MOLECULES_PATH \
            #     $CONDA_OPENMM $SKIP_SIM &
            set +x
            MD_START=$(($MD_START + 1))
            MD_SLICE=$(($MD_SLICE - 1))
        done
        MD_SLICE=$(($MD_RUNS/$NODE_COUNT))
    done

    MD_START=0
    wait
    duration=$(($SECONDS - $start_time))
    echo "OpenMM done... $(($duration / 60)) minutes and $(($duration % 60)) seconds elapsed ($duration secs)."


: <<'OPT'
- Must run data stagein immediate after OPENMM here to use the same STAGE_IDX_FORMAT
OPT
    start_time=$SECONDS
    INFERENCE_STAGEIN
    wait
    duration=$(($SECONDS - $start_time))
    echo "INFERENCE_STAGEIN done... $(($duration / 60)) minutes and $(($duration % 60)) seconds elapsed ($duration secs)."

    STAGE_IDX_FORMAT="$(STAGE_UPDATE)"
    STAGE_IDX=$((STAGE_IDX + 1))
    echo $STAGE_IDX_FORMAT

    # STAGE 2: Aggregate
    start_time=$SECONDS
    # srun -N1 $( AGGREGATE )
    AGGREGATE
    wait 
    duration=$(($SECONDS - $start_time))
    echo "AGGREGATE done... $(($duration / 60)) minutes and $(($duration % 60)) seconds elapsed ($duration secs)."

: <<'OPT'
- Must run data stagein immediate after AGGREGATE here to use the same STAGE_IDX_FORMAT
OPT
    start_time=$SECONDS
    TRAINING_STAGEIN
    wait
    duration=$(($SECONDS - $start_time))
    echo "TRAINING_STAGEIN done... $(($duration / 60)) minutes and $(($duration % 60)) seconds elapsed ($duration secs)."

    STAGE_IDX_FORMAT="$(STAGE_UPDATE)"
    STAGE_IDX=$((STAGE_IDX + 1))
    echo $STAGE_IDX_FORMAT

    # STAGE 3: Training
    start_time=$SECONDS
    if [ "$SHORTENED_PIPELINE" == true ]
    then
        mpirun --host $TRAINING_NODE -np 1 $SCRIPT_DIR/TRAINING_LOCAL.sh \
            $LOCAL_STORAGE $STAGE_IDX $SIM_LENGTH \
            $EXPERIMENT_PATH $DDMD_PATH \
            $MOLECULES_PATH $CONDA_PYTORCH &
        echo "TRAINING not waited..."
    else
        start_time=$SECONDS
        mpirun --host $TRAINING_NODE -np 1 $SCRIPT_DIR/TRAINING_LOCAL.sh \
            $LOCAL_STORAGE $STAGE_IDX $SIM_LENGTH \
            $EXPERIMENT_PATH $DDMD_PATH \
            $MOLECULES_PATH $CONDA_PYTORCH
        wait
        duration=$(($SECONDS - $start_time))
        echo "TRAINING done... $(($duration / 60)) minutes and $(($duration % 60)) seconds elapsed ($duration secs)."
    fi

    STAGE_IDX_FORMAT="$(STAGE_UPDATE)"
    STAGE_IDX=$((STAGE_IDX + 1))
    echo $STAGE_IDX_FORMAT


    # STAGE 4: Inference
    start_time=$SECONDS
    # srun -N1 $( INFERENCE )
    INFERENCE

    # wait # No need to wait since OpenMM of next iteration will wait
    duration=$(($SECONDS - $start_time))
    echo "INFERENCE done... $(($duration / 60)) minutes and $(($duration % 60)) seconds elapsed ($duration secs)."

    STAGE_IDX_FORMAT="$(STAGE_UPDATE)"
    STAGE_IDX=$((STAGE_IDX + 1))
    echo $STAGE_IDX_FORMAT


    # STAGE 5: Data Stage Out
    wait # need to wait for TRAINING!!
    DATA_STAGE_OUT &
    # - Data stageout can happen asynchrounously after INFERENCE, continue to next iterations


done

wait

total_duration=$(($SECONDS - $total_start_time))
echo "All done... $(($total_duration / 60)) minutes and $(($total_duration % 60)) seconds elapsed ($total_duration secs)."
echo "Drop cache time: $drop_cache_time milliseconds elapsed."

CHECK_OUTPUT

hostname;date;
# UNSET_CONDA_ENV_VARS
# sacct -j $SLURM_JOB_ID -o jobid,submit,start,end,state