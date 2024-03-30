#!/bin/bash

LOCAL_STORAGE=$1
STAGE_IDX=$2
STAGE_IDX_FORMAT=$(seq -f "stage%04g" $STAGE_IDX $STAGE_IDX)
SIM_LENGTH=$3
EXPERIMENT_PATH=$4
DDMD_PATH=$5
MOLECULES_PATH=$6
CONDA_PYTORCH=$7


# set -x
echo "Running TRAINING in node `hostname`..."
task_id=task0000
stage_name="machine_learning"
dest_path=$LOCAL_STORAGE/${stage_name}_runs/$STAGE_IDX_FORMAT/$task_id # data ready in local storage
stage_name="training"
yaml_path=$DDMD_PATH/test/bba/${stage_name}_stage_test.yaml
# PREP_TASK_NAME "$stage_name"

# Need to make two copies of the stage file, one for the training and one for the inference
## For Local TRAINING
mkdir -p $LOCAL_STORAGE/model_selection_runs/$STAGE_IDX_FORMAT/task0000/
cp -p $DDMD_PATH/test/bba/stage0000_task0000.json $LOCAL_STORAGE/model_selection_runs/$STAGE_IDX_FORMAT/task0000/${STAGE_IDX_FORMAT}_task0000.json

## Fore Remote INFERENCE
mkdir -p $EXPERIMENT_PATH/model_selection_runs/$STAGE_IDX_FORMAT/task0000/
cp -p $DDMD_PATH/test/bba/stage0000_task0000.json $EXPERIMENT_PATH/model_selection_runs/$STAGE_IDX_FORMAT/task0000/${STAGE_IDX_FORMAT}_task0000.json


eval "$(~/miniconda3/bin/conda shell.bash hook)" # conda init bash
source activate $CONDA_PYTORCH


mkdir -p $dest_path
cd $dest_path
echo cd $dest_path


sed -e "s/\$SIM_LENGTH/${SIM_LENGTH}/" -e "s/\$OUTPUT_PATH/${dest_path//\//\\/}/" -e "s/\$EXPERIMENT_PATH/${EXPERIMENT_PATH//\//\\/}/" -e "s/\$STAGE_IDX/${STAGE_IDX}/" $yaml_path  > $dest_path/$(basename $yaml_path)
yaml_path=$dest_path/$(basename $yaml_path)

PYTHONPATH=$DDMD_PATH/:$MOLECULES_PATH python $DDMD_PATH/deepdrivemd/models/aae/train.py -c $yaml_path &> ${task_id}_TRAINING_LOCAL.log
set +x


# Stage out data
training_local_dest_path=$LOCAL_STORAGE/machine_learning_runs
training_dest_path=$EXPERIMENT_PATH/machine_learning_runs
mkdir -p $training_dest_path
cp -r $training_local_dest_path/* $training_dest_path