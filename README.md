# Dependencies

You can setup environments two ways
- [create environment from config files](#ddmd-conda-environment-from-config-files)
- [buid the conda environment from scratch](https://github.com/candiceT233/deepdrivemd_pnnl/blob/main/docs/conda_env/README.md)



## Prepare Conda Environment from Config Files



### 1. Prepare Conda
Get the `miniconda3` installation script and run it
```
wget https://repo.anaconda.com/miniconda/Miniconda3-latest-Linux-x86_64.sh
bash Miniconda3-latest-Linux-x86_64.sh.sh
```
The current conda version tested work that works `conda 23.3.1`.



### 2. First git clone this repo and save it to `$DDMD_PATH`
```
export CONDA_OPENMM=openmm7_ddmd
export CONDA_PYTORCH=ddmd_pytorch
export DDMD_PATH=${PWD}/deepdrivemd
export MOLECULES_PATH=$DDMD_PATH/submodules/molecules
git clone --recursive https://github.com/candiceT233/deepdrivemd_pnnl.git $DDMD_PATH
cd $DDMD_PATH
```


### 3. Create the two conda environments
Name your two environment names `$CONDA_OPENMM` `$CONDA_PYTORCH`.
```
cd $DDMD_PATH
conda env create -f ${DDMD_PATH}/docs/conda_env/ddmd_openmm7.yaml --name=${CONDA_OPENMM}
conda env create -f ${DDMD_PATH}/docs/conda_env/ddmd_pytorch.yaml --name=${CONDA_PYTORCH}
```

If mdtools fails to install, that's ok. It will be handled in step 4.



### 4. Update python packages in both conda environments
Update CONDA_OPENMM
```
source activate $CONDA_OPENMM
cd $DDMD_PATH/submodules/MD-tools
pip install .
cd $DDMD_PATH/submodules/molecules
pip install .
conda deactivate
```

Update CONDA_PYTORCH
```
source activate $CONDA_PYTORCH
cd $DDMD_PATH/submodules/MD-tools
pip install .
cd $DDMD_PATH/submodules/molecules
pip install .
conda deactivate
```



## Hermes Dependencies



### In Ares:
```
module load hermes/pnnl-tz3s7yx
```
this automatically loads the Hermes build with VFD, and it's HDF5 dependency.



### Personal Machine:
If building Hermes yourself:
- Sequential HDF5 >= 1.14.0
- Hermes>=1.0 with VFD and POSIX Adaptor support

Build HDF5
```
scspkg create hdf5
cd `scspkg pkg src hdf5`
git clone https://github.com/HDFGroup/hdf5.git -b hdf5_1_14_0
cd hdf5
mkdir build
cd build
cmake ../ -DHDF5_BUILD_HL_LIB=ON -DCMAKE_INSTALL_PREFIX=`scspkg pkg root hdf5`
make -j8
make install
```

Install Hermes with Custom HDF5
```
spack install mochi-thallium~cereal@0.10.1 cereal catch2@3.0.1 mpich@3.3.2 yaml-cpp boost@1.7
spack load mochi-thallium~cereal@0.10.1 cereal catch2@3.0.1 mpich@3.3.2 yaml-cpp boost@1.7
module load hdf5
```

NOTE: this only needs to be done for the CONDA_OPENMM environment, since both environment use the same exact python version. HDF5 will be compiled the same. However, these commands must be executed before source active $CONDA_PYTORCH to avoid overriding the python version.



# Installation
- `h5py==3.8.0` is required for `hdf5-1.14.0` and `Hermes>=1.0`
- `pip install h5py==3.8.0` should be run after deepdrivemd installation due to version restriction with pip
- makesure you have `hdf5-1.14.0` installed and added to $PATH before installing h5py (otherwise it will download hdf5-1.12.0 by default)
```
module load hdf5

cd $DDMD_PATH
source activate $CONDA_OPENMM
pip install -e .
pip uninstall h5py; pip install h5py==3.8.0
conda deactivate

source activate $CONDA_PYTORCH
pip install -e .
pip uninstall h5py; pip install h5py==3.8.0
conda deactivate
```



# Usage
Below describes running one iteration of the 4-stages pipeline. \
Set up experiment path in `$EXPERIMENT_PATH`, this will store all output files and log files from all stages.
```bash
EXPERIMENT_PATH=~/ddmd_runs
mkdir -p $EXPERIMENT_PATH
```



---
## Stage 1 : OPENMM


This stage runs simulation, minimally you have to run 12 simulation tasks for stage 3 & 4 to work. So you must run the above command at least 12 times and each time with a different `TASK_IDX_FORMAT`.


### Environment variables note
Setup environment variables and paths
```bash
TASK_IDX="task0000"
YAML_PATH=$DDMD_PATH/examples/hermes_ddmd/ddmd_configs/openmm_configs/stage0000/$TASK_IDX

OUTPUT_PATH=$EXPERIMENT_PATH/molecular_dynamics_runs/stage0000/$TASK_IDX
mkdir -p $OUTPUT_PATH
```

- `TASK_IDX_FORMAT` : give a different task ID format for each openmm task, starts with `task0000` up to `task0011` for 12 tasks.
- `YAML_PATH` : The yaml file that contains the test configuration for the first stage



In the yaml file [`molecular_dynamics_stage_test.yaml`](https://github.com/candiceT233/deepdrivemd_pnnl/blob/main/examples/hermes_ddmd/ddmd_configs/openmm_configs/stage0000/task0000/molecular_dynamics_stage_test.yaml), makesure to modify the following fields accordingly:
```
nano ${YAML_PATH}/molecular_dynamics_stage_test.yaml
```
```yaml
experiment_directory: $EXPERIMENT_PATH
pdb_file: $DDMD_PATH/data/bba/system/1FME-unfolded.pdb
initial_pdb_dir: $DDMD_PATH/data/bba
reference_pdb_file: $DDMD_PATH/data/bba/1FME-folded.pdb
```

Run code:
```bash
source activate $CONDA_OPENMM

PYTHONPATH=$DDMD_PATH:$MOLECULES_PATH python $DDMD_PATH/deepdrivemd/sim/openmm/run_openmm.py -c $YAML_PATH/molecular_dynamics_stage_test.yaml
```

Sample output under one task folder (total 12 tasks folders):
```shell
cd $OUTPUT_PATH
du -h *
604K    stage0000_task0000.dcd
164K    stage0000_task0000.h5
12K     stage0000_task0000.log
40K     system__1FME-unfolded.pdb
```

### Run 12 tasks:

Set new task id with `TASK_IDX` from "task0000" to "task0011"
```bash
TASK_IDX="task0001"
```

Repeat the below code after setting new `TASK_IDX`
```bash
YAML_PATH=$DDMD_PATH/examples/hermes_ddmd/ddmd_configs/openmm_configs/stage0000/$TASK_IDX
OUTPUT_PATH=$EXPERIMENT_PATH/molecular_dynamics_runs/stage0000/$TASK_IDX
mkdir -p $OUTPUT_PATH

sed -i "s#\$EXPERIMENT_PATH#${EXPERIMENT_PATH}#g" "$YAML_PATH/molecular_dynamics_stage_test.yaml"
sed -i "s#\$DDMD_PATH#${DDMD_PATH}#g" "$YAML_PATH/molecular_dynamics_stage_test.yaml"

source activate $CONDA_OPENMM

PYTHONPATH=$DDMD_PATH:$MOLECULES_PATH python $DDMD_PATH/deepdrivemd/sim/openmm/run_openmm.py -c $YAML_PATH/molecular_dynamics_stage_test.yaml
```


---
## Stage 2 : AGGREGATE

In the yaml file [`aggregate_stage_test.yaml`](https://github.com/candiceT233/deepdrivemd_pnnl/blob/main/examples/hermes_ddmd/ddmd_configs/aggregate_configs/aggregate_stage_test.yaml), makesure to modify the `$EXPERIMENT_PATH` and `DDMD_PATH` like previous stage:
```bash
YAML_PATH=$DDMD_PATH/examples/hermes_ddmd/ddmd_configs/aggregate_configs

sed -i "s#\$EXPERIMENT_PATH#${EXPERIMENT_PATH}#g" "$YAML_PATH/aggregate_stage_test.yaml"
sed -i "s#\$DDMD_PATH#${DDMD_PATH}#g" "$YAML_PATH/aggregate_stage_test.yaml"
```

Run code:
```bash
source activate $CONDA_OPENMM

PYTHONPATH=$DDMD_PATH/ python $DDMD_PATH/deepdrivemd/aggregation/basic/aggregate.py -c $YAML_PATH/aggregate_stage_test.yaml
```
This stage only need to be run one time, it aggregates all the `stage0000_task0000.h5` files from simulation into a single `aggregated.h5` file.



Output is saved at `$EXPERIMENT_PATH/machine_learning_runs/stage0000/task0000`.



Expected output:
```bash
OUTPUT_PATH=$EXPERIMENT_PATH/machine_learning_runs/stage0000/task0000
cd $OUTPUT_PATH
du -h * | grep aggregate
1.6M    aggregated.h5
4.0K    aggregate_stage_test.yaml
```



---
## Stage 3 : TRAINING



Setup configuration `training_stage_test.yaml` and `OUTPUT_PATH` 
```bash
TASK_IDX="task0000"

YAML_PATH=$DDMD_PATH/examples/hermes_ddmd/ddmd_configs/train_configs

sed -i "s#\$EXPERIMENT_PATH#${EXPERIMENT_PATH}#g" "$YAML_PATH/training_stage_test.yaml"

OUTPUT_PATH=$EXPERIMENT_PATH/machine_learning_runs/stage0002/$TASK_IDX
mkdir -p $OUTPUT_PATH
```



Run code:
```bash
conda deactivate
source activate $CONDA_PYTORCH

PYTHONPATH=$DDMD_PATH/:$MOLECULES_PATH python $DDMD_PATH/deepdrivemd/models/aae/train.py -c $YAML_PATH/training_stage_test.yaml
```
When the code run, python might show warning messages that can be ignored.



Expected output files:
```bash
cd $OUTPUT_PATH
du -h * 
717M    checkpoint
1.5M    discriminator-weights.pt
8.5M    embeddings
2.0M    encoder-weights.pt
2.7M    generator-weights.pt
4.0K    loss.json
4.0K    model-hparams.json
4.0K    optimizer-hparams.json
4.0K    virtual-h5-metadata.json
12K     virtual_stage0000_task0000.h5
```


---
## Stage 4 : INFERENCE



Setup experiment paths:
```bash
MODEL_PATH=$EXPERIMENT_PATH/model_selection_runs/stage0002/task0000
AGENT_PATH=$EXPERIMENT_PATH/agent_runs/stage0003/task0000
OUTPUT_PATH=$EXPERIMENT_PATH/inference_runs/stage0003/$TASK_IDX

mkdir -p $MODEL_PATH $OUTPUT_PATH $AGENT_PATH
```



Setup experiment configuration `inference_stage_test.yaml` and `stage0000_task0000.json` 
```bash
TASK_IDX="task0000"

YAML_PATH=$DDMD_PATH/examples/hermes_ddmd/ddmd_configs/inference_configs
sed -i "s#\$EXPERIMENT_PATH#${EXPERIMENT_PATH}#g" "$YAML_PATH/inference_stage_test.yaml"
# cp $YAML_PATH/inference_stage_test.yaml $OUTPUT_PATH
```



Setup to use the last checkpoints:
```bash
MODEL_CHECKPOINT=$(find $EXPERIMENT_PATH/machine_learning_runs/*/*/checkpoint -type f -printf '%T@ %p\n' | sort -n | tail -1 | cut -f2- -d" ") #use last checkpoint

cp -p $DDMD_PATH/test/bba/stage0000_task0000.json $MODEL_PATH/stage0002_task0000.json
sed -i -e "s/\$MODEL_CHECKPOINT/${MODEL_CHECKPOINT//\//\\/}/" $MODEL_PATH/stage0002_task0000.json
```
User can also use any checkpoint `epoch-10-<date>-<time>.pt`, time stamp varies depending on experiment
```bash
MODEL_CHECKPOINT=$EXPERIMENT_PATH/machine_learning_runs/stage0002/task0000/checkpoint/epoch-10-20231121-163550.pt
```


Run code:
```bash
conda deactivate
source activate $CONDA_PYTORCH

cd $YAML_PATH # must run from here

OMP_NUM_THREADS=4 PYTHONPATH=$DDMD_PATH/:$MOLECULES_PATH python $DDMD_PATH/deepdrivemd/agents/lof/lof.py -c $YAML_PATH/inference_stage_test.yaml
```
`OMP_NUM_THREADS` can be changed.



Expected output files:
```bash
cd $OUTPUT_PATH
du -h *
4.0K    virtual-h5-metadata.json
20K     virtual_stage0003_task0000.h5
```
