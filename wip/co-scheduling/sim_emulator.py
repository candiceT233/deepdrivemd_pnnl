import scipy.sparse
import argparse
import numpy as np
import h5py
from pathlib import Path
try:
    import MDAnalysis as mda
except:
    mda = None

class SimEmulator:

    def __init__(self, 
            n_residues = 50, 
            n_atoms = 500, 
            n_frames = 100, 
            n_jobs = 1):

        self.n_residues = n_residues
        self.n_atoms = n_atoms
        self.n_frames = n_frames
        self.n_jobs = n_jobs
        self.nbytes = 0
        self.universe = None

    def contact_map(self, density=None, dtype='int16'):

        if not self.is_contact_map:
            return None

        if density is None:
            density = np.random.uniform(low=0.23, high=.235, size=(1,))[0]
        S = scipy.sparse.random(self.n_residues, self.n_residues, density=density, dtype=dtype)
        row = S.tocoo().row.astype(dtype)
        col = S.tocoo().col.astype(dtype)

        self.nbytes += row.nbytes
        self.nbytes += col.nbytes

        return [row, col]

    def contact_maps(self):
        cms = [ self.contact_map() for x in range(self.n_frames) ] 
        r = [np.concatenate(x) for x in cms]
        ret = np.empty(len(r), dtype=object)
        ret[...] = r
        return ret

    def point_cloud(self, dtype='float32'):
        
        if not self.is_point_cloud:
            return None

        r = np.random.randn(3, self.n_residues).astype(dtype)
        self.nbytes += r.nbytes
        return r

    def point_clouds(self):
        pcs = [ self.point_cloud() for x in range(self.n_frames) ]
        return pcs

    def h5file(self, data, ds_name, fname=None):

        if fname is None:
            fname = "{}.h5".format(self.output_filename)

        if isinstance(data, list):
            dtype = data[0].dtype
        elif data.dtype == object:
            dtype = h5py.vlen_dtype(np.dtype(data[0].dtype))

        with h5py.File(fname, "a", swmr=False) as h5_file:
            h5_file.create_dataset(
                    ds_name,
                    data=data,
                    dtype=dtype,
                    )

    def trajectory(self):
        coordinates = np.random.rand(self.n_atoms, 3)
        return coordinates

    def trajectories(self):
        ret = [ self.trajectory() for x in range(self.n_frames) ]
        return ret

    def dcdfile(self, coordinates, fname=None, u=None):

        if mda is None:
            return

        if fname is None:
            fname = "{}.dcd".format(self.output_filename)

        if u is None:
            if self.universe:
                u = self.universe
            else:
                u = mda.Universe.empty(n_atoms=self.n_atoms)
                self.universe = u

        w = mda.coordinates.DCD.DCDWriter(fname, self.n_atoms)
        for c in coordinates:
            u.load_new(c)
            w.write(u.trajectory)
        w.close()

        return u

    def h5_setting(self, 
            output_filename, 
            is_contact_map, 
            is_point_cloud,
            is_rmsd, 
            is_fnc):
        if output_filename is None:
           self.output_filename = "residue_{}".format(self.n_residues)
        self.is_contact_map = is_contact_map
        self.is_point_cloud = is_point_cloud
        self.is_rmsd = is_rmsd
        self.is_fnc = is_fnc


def user_input():
    parser = argparse.ArgumentParser()
    parser.add_argument('-r', '--residue', type=int, required=True)
    parser.add_argument('-a', '--atom', type=int)
    parser.add_argument('-f', '--frame', default=100, type=int)
    parser.add_argument('-n', '--number_of_jobs', default=1, type=int)
    parser.add_argument('--fnc', default=True)
    parser.add_argument('--rmsd', default=True)
    parser.add_argument('--contact_map', default=True)
    parser.add_argument('--point_cloud', default=True)
    parser.add_argument('--trajectory', default=False)
    parser.add_argument('--output_filename')
    args = parser.parse_args()

    return args

def main():

    args = user_input()
    obj = SimEmulator(n_residues = args.residue,
            n_atoms = args.atom,
            n_frames = args.frame,
            n_jobs= args.number_of_jobs)

    obj.h5_setting(output_filename = args.output_filename,
            is_contact_map = args.contact_map,
            is_point_cloud = args.point_cloud,
            is_rmsd = args.rmsd,
            is_fnc = args.fnc)

    for i in range(obj.n_jobs):
        task_dir = "task{:04d}/".format(i)
        Path(task_dir).mkdir(parents=True, exist_ok=True)
        cms = obj.contact_maps()
        pcs = obj.point_clouds()
        if cms is not None:
            obj.h5file(cms, 'contact_map', task_dir + obj.output_filename + ".h5")# + f"_ins_{i}.h5")
        if pcs is not None:
            obj.h5file(pcs, 'point_cloud', task_dir + obj.output_filename + ".h5")#f"_ins_{i}.h5")
        dcd = obj.trajectories()
        if dcd is not None:
            obj.dcdfile(dcd, task_dir + obj.output_filename + ".dcd")#f"_ins_{i}.dcd")
    print("total bytes written:{} in {} file(s)".format(obj.nbytes, i + 1))


if __name__ == "__main__":
    main()