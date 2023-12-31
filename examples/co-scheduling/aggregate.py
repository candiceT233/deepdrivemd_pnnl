import h5py
import argparse
import numpy as np
from deepdrivemd.data.api import DeepDriveMD_API
from adios_prodcons import AdiosProducerConsumer

def concatenate_last_n_h5(args):


    fields = []
    if args.no_rmsd is False:
        fields.append("rmsd")
    if args.no_fnc is False:
        fields.append("fnc")
    if args.no_contact_map is False:
        fields.append("contact_map")
    if args.no_point_cloud is False:
        fields.append("point_cloud")

    # Get list of input h5 files
    api = DeepDriveMD_API(args.input_path)
    md_data = api.get_last_n_md_runs()
    files = md_data["data_files"]

    if args.verbose:
        print(f"Collected {len(files)} h5 files.")

    # Open output file
    fout = h5py.File(args.output_path, "w", libver="latest")

    # Initialize data buffers
    data = {x: [] for x in fields}

    for in_file in files:

        if args.verbose:
            print("Reading", in_file)

        with h5py.File(in_file, "r") as fin:
            for field in fields:
                data[field].append(fin[field][...])

    # Concatenate data
    for field in data:
        data[field] = np.concatenate(data[field])

    # Centor of mass (CMS) subtraction
    if "point_cloud" in data:
        if args.verbose:
            print("Subtract center of mass (CMS) from point cloud")
        cms = np.mean(
            data["point_cloud"][:, 0:3, :].astype(np.float128), axis=2, keepdims=True
        ).astype(np.float32)
        data["point_cloud"][:, 0:3, :] -= cms
        if args.dtype:
            data['point_cloud'] = data['point_cloud'].astype(args.dtype)

    # Create new dsets from concatenated dataset
    for field, concat_dset in data.items():
        if field == "traj_file":
            utf8_type = h5py.string_dtype("utf-8")
            fout.create_dataset("traj_file", data=concat_dset, dtype=utf8_type)
            continue

        shape = concat_dset.shape
        chunkshape = (1,) + shape[1:]
        # Create dataset
        if concat_dset.dtype != np.object:
            if np.any(np.isnan(concat_dset)):
                raise ValueError("NaN detected in concat_dset.")
            dset = fout.create_dataset(
                field, shape, chunks=chunkshape, dtype=concat_dset.dtype
            )
        else:
            dset = fout.create_dataset(
                field, shape, chunks=chunkshape, dtype=h5py.vlen_dtype(np.int16)
            )
        # write data
        dset[...] = concat_dset[...]

    # Clean up
    fout.flush()
    fout.close()


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument('-no_pc', '--no-point_cloud', action='store_true', help='Skip to collect "point_cloud" dataset')
    parser.add_argument('-no_cm', '--no-contact_map', action='store_true', help='Skip to collect "contact_map" dataset')
    parser.add_argument('-no_rmsd', '--no-root-mean-square-deviation', dest='no_rmsd', action='store_true', help='Skip to collect "rmsd" dataset')
    parser.add_argument('-no_fnc', '--no-fraction_of_contacts', dest='no_fnc', action='store_true', help='Skip collect "fnc" dataset')
    parser.add_argument("--input_path")
    '''parser.add_argument(
            'input', metavar='N', type=str, nargs='+', help='h5 file(s)'
    )'''
    parser.add_argument('--verbose', action='store_true')
    parser.add_argument('--output_path')
    parser.add_argument('--dtype', help='output dtype to cast')
    parser.add_argument('--adios', help='read adios "bp" files to aggregate')

    args = parser.parse_args()
    return args


if __name__ == "__main__":
    args = parse_args()
    concatenate_last_n_h5(args)
