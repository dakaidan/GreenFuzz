#!/usr/bin/env python3
# Copyright 2016-2025 Google Inc.
# Copyright 2025 AFLplusplus Project. All rights reserved.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#      http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#
import argparse
import array
import base64
import collections
import ctypes
import glob
import hashlib
import itertools
import logging
import multiprocessing
import os
import shutil
import subprocess
import sys
import uuid
import re

ENERGY_RE = re.compile(rb"Total\s+energy\s*=\s*\S+\s*J\s*\((\d+)\s*uJ\)")


# https://more-itertools.readthedocs.io/en/stable/_modules/more_itertools/recipes.html#batched
from sys import hexversion


def _batched(iterable, n, *, strict=False):
    """Batch data into tuples of length *n*. If the number of items in
    *iterable* is not divisible by *n*:
    * The last batch will be shorter if *strict* is ``False``.
    * :exc:`ValueError` will be raised if *strict* is ``True``.

    >>> list(batched('ABCDEFG', 3))
    [('A', 'B', 'C'), ('D', 'E', 'F'), ('G',)]

    On Python 3.13 and above, this is an alias for :func:`itertools.batched`.
    """
    if n < 1:
        raise ValueError("n must be at least one")
    iterator = iter(iterable)
    while batch := tuple(itertools.islice(iterator, n)):
        if strict and len(batch) != n:
            raise ValueError("batched(): incomplete batch")
        yield batch


if hexversion >= 0x30D00A2:  # pragma: no cover
    from itertools import batched as itertools_batched

    def batched(iterable, n, *, strict=False):
        return itertools_batched(iterable, n, strict=strict)

else:
    batched = _batched

    batched.__doc__ = _batched.__doc__

try:
    from tqdm import tqdm
except ImportError:
    print('Hint: install python module "tqdm" to show progress bar')

    class tqdm:

        def __init__(self, data=None, *args, **argd):
            self.data = data

        def __iter__(self):
            yield from self.data

        def __enter__(self):
            return self

        def __exit__(self, exc_type, exc_value, traceback):
            pass

        def update(self, *args):
            pass


parser = argparse.ArgumentParser()

cpu_count = multiprocessing.cpu_count()
group = parser.add_argument_group("Required parameters")
group.add_argument(
    "-i",
    dest="input",
    action="append",
    metavar="dir",
    required=True,
)
group.add_argument(
    "--no-batch",
    dest="no_batch",
    action="store_true",
)

group.add_argument(
    "-o",
    dest="output",
    metavar="dir",
    required=True,
    help="output directory for minimized files",
)

group = parser.add_argument_group("Execution control settings")
group.add_argument(
    "-f",
    dest="stdin_file",
    metavar="file",
    help="location read by the fuzzed program (stdin)",
)
group.add_argument(
    "-m",
    dest="memory_limit",
    default="none",
    metavar="megs",
    type=lambda x: x if x == "none" else int(x),
    help="memory limit for child process (default: %(default)s)",
)
group.add_argument(
    "-t",
    dest="time_limit",
    default=5000,
    metavar="msec",
    type=lambda x: x if x == "none" else int(x),
    help="timeout for each run (default: %(default)s)",
)
group.add_argument(
    "-O",
    dest="frida_mode",
    action="store_true",
    default=False,
    help="use binary-only instrumentation (FRIDA mode)",
)
group.add_argument(
    "-Q",
    dest="qemu_mode",
    action="store_true",
    default=False,
    help="use binary-only instrumentation (QEMU mode)",
)
group.add_argument(
    "-U",
    dest="unicorn_mode",
    action="store_true",
    default=False,
    help="use unicorn-based instrumentation (Unicorn mode)",
)
group.add_argument(
    "-X", dest="nyx_mode", action="store_true", default=False, help="use Nyx mode"
)

group = parser.add_argument_group("Minimization settings")
group.add_argument(
    "--crash-dir",
    dest="crash_dir",
    metavar="dir",
    default=None,
    help="move crashes to a separate dir, always deduplicated",
)
###############################################################
group.add_argument(
    "--energy-first",
    dest="energy_first",
    action="store_true",
    default=True,
    help="Pick representative by lowest energy (tie: lowest index). If energy is missing, fall back to index."
)
###############################################################

group.add_argument(
    "-A",
    dest="allow_any",
    action="store_true",
    help="allow crashes and timeouts (not recommended)",
)
group.add_argument(
    "-C",
    dest="crash_only",
    action="store_true",
    help="keep crashing inputs, reject everything else",
)
group.add_argument(
    "-e",
    dest="edge_mode",
    action="store_true",
    default=False,
    help="solve for edge coverage only, ignore hit counts",
)

group = parser.add_argument_group("Misc")
group.add_argument(
    "-T",
    dest="workers",
    type=lambda x: cpu_count if x == "all" else int(x),
    default=1,
    help="number of concurrent worker (default: %(default)d)",
)
group.add_argument(
    "--as_queue",
    action="store_true",
    help='output file name like "id:000000,hash:value"',
)
group.add_argument(
    "--no-dedup", action="store_true", help="skip deduplication step for corpus files"
)
group.add_argument("--debug", action="store_true")

parser.add_argument("exe", metavar="/path/to/target_app")
parser.add_argument("args", nargs="*")

args = parser.parse_args()
logger = None
afl_showmap_bin = None
tuple_index_type_code = "I"
file_index_type_code = None


def search_binary(name):
    searches = [
        None,
        os.path.dirname(__file__),
        os.getcwd(),
    ]
    if os.environ.get("AFL_PATH"):
        searches.append(os.environ["AFL_PATH"])

    for search in searches:
        binary = shutil.which(name, path=search)
        if binary:
            return binary
    logger.fatal(f"cannot find {name}, please set AFL_PATH")
    sys.exit(1)


def init():
    global logger
    log_level = logging.DEBUG if args.debug else logging.INFO
    logging.basicConfig(
        level=log_level, format="%(asctime)s - %(levelname)s - %(message)s"
    )
    logger = logging.getLogger(__name__)

    if args.stdin_file and args.workers > 1:
        logger.error("-f is only supported with one worker (-T 1)")
        sys.exit(1)

    if args.memory_limit != "none" and args.memory_limit < 5:
        logger.error("dangerously low memory limit")
        sys.exit(1)

    if args.time_limit != "none" and args.time_limit < 10:
        logger.error("dangerously low timeout")
        sys.exit(1)

    if not args.nyx_mode and not os.path.isfile(args.exe):
        logger.error('binary "%s" not found or not regular file', args.exe)
        sys.exit(1)

    if not os.environ.get("AFL_SKIP_BIN_CHECK") and not any(
        [args.qemu_mode, args.frida_mode, args.unicorn_mode, args.nyx_mode]
    ):
        if b"__AFL_SHM_ID" not in open(args.exe, "rb").read():
            logger.error("binary '%s' doesn't appear to be instrumented", args.exe)
            sys.exit(1)

    for dn in args.input:
        if not os.path.isdir(dn) and not glob.glob(dn):
            logger.error('directory "%s" not found', dn)
            sys.exit(1)

    global afl_showmap_bin
    afl_showmap_bin = search_binary("afl-showmap")

    trace_dir = os.path.join(args.output, ".traces")
    shutil.rmtree(trace_dir, ignore_errors=True)
    try:
        os.rmdir(args.output)
    except OSError:
        pass
    if os.path.exists(args.output):
        logger.error(
            'directory "%s" exists and is not empty - delete it first', args.output
        )
        sys.exit(1)
    if args.crash_dir and not os.path.exists(args.crash_dir):
        os.makedirs(args.crash_dir)
    os.makedirs(trace_dir)

    logger.info("use %d workers (-T)", args.workers)


def detect_type_code(size):
    for type_code in ["B", "H", "I", "L", "Q"]:
        if 256 ** array.array(type_code).itemsize > size:
            return type_code


def get_nyx_map_size(target_dir):
    libnyx_path = search_binary("libnyx.so")
    libnyx = ctypes.CDLL(libnyx_path)

    NYX_ROLE_StandAlone = 0

    target_dir_c = target_dir.encode("utf-8")

    dummy_workdir_path = "/tmp/_afl_cmin_nyx_work_dir_%s" % (str(uuid.uuid4()))
    dummy_workdir_path_c = dummy_workdir_path.encode("utf-8")

    # nyx_config_load
    libnyx.nyx_config_load.argtypes = [ctypes.c_char_p]
    libnyx.nyx_config_load.restype = ctypes.c_void_p
    nyx_config = libnyx.nyx_config_load(target_dir_c)

    # nyx_config_set_workdir_path
    libnyx.nyx_config_set_workdir_path.argtypes = [ctypes.c_void_p, ctypes.c_char_p]
    libnyx.nyx_config_set_workdir_path.restype = None
    libnyx.nyx_config_set_workdir_path(nyx_config, dummy_workdir_path_c)

    # nyx_config_set_process_role
    libnyx.nyx_config_set_process_role.argtypes = [ctypes.c_void_p, ctypes.c_int]
    libnyx.nyx_config_set_process_role.restype = None
    libnyx.nyx_config_set_process_role(nyx_config, NYX_ROLE_StandAlone)

    # nyx_new
    libnyx.nyx_new.argtypes = [ctypes.c_void_p, ctypes.c_int]
    libnyx.nyx_new.restype = ctypes.c_void_p
    nyx_runner = libnyx.nyx_new(nyx_config, 0)

    # nyx_get_bitmap_buffer_size
    libnyx.nyx_get_bitmap_buffer_size.argtypes = [ctypes.c_void_p]
    libnyx.nyx_new.restype = ctypes.c_int
    map_size = libnyx.nyx_get_bitmap_buffer_size(nyx_runner)

    # nyx_shutdown
    libnyx.nyx_shutdown.argtypes = [ctypes.c_void_p]
    libnyx.nyx_shutdown.restype = None
    libnyx.nyx_shutdown(nyx_runner)

    # nyx_remove_work_dir
    libnyx.nyx_remove_work_dir.argtypes = [ctypes.c_char_p]
    libnyx.nyx_remove_work_dir.restype = None
    libnyx.nyx_remove_work_dir(dummy_workdir_path_c)

    return map_size


def afl_showmap(input_path=None, batch=None, afl_map_size=None, first=False):
    assert input_path or batch
    
    if batch and len(batch) == 1:
        single_idx, single_path = batch[0]
        arr, crashed, energy = afl_showmap(
            input_path=single_path,
            batch=None,
            afl_map_size=afl_map_size,
            first=first,
        )
        return [(single_idx, arr, crashed, energy)]
    # yapf: disable
    cmd = [
        afl_showmap_bin,
        '-m', str(args.memory_limit),
        '-t', str(args.time_limit),
        '-Z', # cmin mode
    ]
    # yapf: enable
    found_atat = False
    for arg in args.args:
        if "@@" in arg:
            found_atat = True

    if args.stdin_file:
        assert args.workers == 1
        input_from_file = True
        stdin_file = args.stdin_file
        cmd += ["-H", stdin_file]
    elif found_atat:
        input_from_file = True
        stdin_file = os.path.join(args.output, f".input.{os.getpid()}")
        cmd += ["-H", stdin_file]
    else:
        input_from_file = False

    if batch:
        input_from_file = True
        filelist = os.path.join(args.output, f".filelist.{os.getpid()}")
        with open(filelist, "w") as f:
            for _, path in batch:
                f.write(path + "\n")
        cmd += ["-I", filelist]
        output_path = os.path.join(args.output, f".showmap.{os.getpid()}")
        cmd += ["-o", output_path]
    else:
        if input_from_file:
            shutil.copy(input_path, stdin_file)
        cmd += ["-o", "-"]

    if args.frida_mode:
        cmd += ["-O"]
    if args.qemu_mode:
        cmd += ["-Q"]
    if args.unicorn_mode:
        cmd += ["-U"]
    if args.nyx_mode:
        cmd += ["-X"]
    if args.edge_mode:
        cmd += ["-e"]
    cmd += ["--", args.exe] + args.args
    
    env = os.environ.copy()
    env["AFL_QUIET"] = "1"
    env["ASAN_OPTIONS"] = "detect_leaks=0"
    if first:
        logger.debug("run command line: %s", subprocess.list2cmdline(cmd))
        env["AFL_CMIN_ALLOW_ANY"] = "1"
    # if args.allow_any or args.no_batch:
    #     env["AFL_CMIN_ALLOW_ANY"] = "1"
    if afl_map_size:
        env["AFL_MAP_SIZE"] = str(afl_map_size)
    if args.crash_only:
        env["AFL_CMIN_CRASHES_ONLY"] = "1"
    if args.allow_any:
        env["AFL_CMIN_ALLOW_ANY"] = "1"

    lib_path = os.environ.get("GreenFuzz", "build/energy.so")

    if not os.path.isabs(lib_path) and os.path.exists(lib_path):
        lib_path = os.path.abspath(lib_path)

    if not os.path.exists(lib_path):
        logger.warning("Library %s not found, AFL_PRELOAD may fail", lib_path)
    # for seeds in ms:
    # check the best index for each tuple by getting the best energy and lowest idx
    env["AFL_PRELOAD"] = lib_path
    print(lib_path)
    
    if input_from_file:
        p = subprocess.Popen(
            cmd,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            env=env,
            bufsize=1048576,
        )
    else:
        p = subprocess.Popen(
            cmd,
            stdin=open(input_path, "rb"),
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            env=env,
            bufsize=1048576,
        )
    p.wait()
    out, err = p.communicate()
    # print('out:', out)
    # print('err:', err)
    print('returncode:', p.returncode)
    print('cmd:', subprocess.list2cmdline(cmd))
  
    
    if batch:
        energy_list = [int(m.group(1)) for m in ENERGY_RE.finditer(err or b"")]
        energy_it = iter(energy_list)
        result = []

        for idx, input_path in batch:
            basename = os.path.basename(input_path)
            energy = next(energy_it, 0)
            print('basename:', basename)
            print('energy:', energy)
            try:
                trace_file = os.path.join(output_path, basename)
                with open(trace_file, "rb") as f:
                    values = [int(line) for line in f if line.strip().isdigit()]
                    content = f.read()
                    # print(' content:', content)
                    # print(' values:', values)
                crashed = len(values) == 0
                os.unlink(trace_file)
            except FileNotFoundError:
                values = []
                crashed = True
                a = None
            values = [(t // 1000) * 9 + t % 1000 for t in values]
            a = array.array(tuple_index_type_code, values)
            result.append((idx, a, crashed, energy))
        os.unlink(filelist)
        os.rmdir(output_path)
        return result
    else:
        values = []
        energy = 0
        # split by newline to avoid issues with Nyx mode
        
        # for line in err.split(b'\n'):
        #     if b"Total energy =" in line:
        #         energy = line.split(b"Total energy = ")[1].split(b" ")[0]
        #         print('content', err.decode('utf-8', errors='ignore'))
        #         energy = int(energy)
        #         print('energy:', energy)

        m = ENERGY_RE.search(err or b"")
        energy = int(m.group(1)) if m else 0
        print('energy:', energy)

        for line in out.split(b'\n'):
            if not line.isdigit():
                continue
            values.append(int(line))    
        values = [(t // 1000) * 9 + t % 1000 for t in values]
        a = array.array(tuple_index_type_code, values)
        print('values:', values)
        crashed = p.returncode in [2, 3]
        if input_from_file and stdin_file != args.stdin_file:
            os.unlink(stdin_file)
        return a, crashed, energy


class JobDispatcher(multiprocessing.Process):

    def __init__(self, job_queue, jobs):
        super().__init__()
        self.job_queue = job_queue
        self.jobs = jobs

    def run(self):
        for job in self.jobs:
            self.job_queue.put(job)
        self.job_queue.close()


class Worker(multiprocessing.Process):

    def __init__(self, idx, afl_map_size, q_in, p_out, r_out):
        super().__init__()
        self.idx = idx
        self.afl_map_size = afl_map_size
        self.q_in = q_in
        self.p_out = p_out
        self.r_out = r_out

    def run(self):
        map_size = self.afl_map_size or 65536
        max_tuple = map_size * 9
        max_file_index = 256 ** array.array(file_index_type_code).itemsize - 1
        m = array.array(file_index_type_code, [max_file_index] * max_tuple)

        INF_EN = (1 << 64) - 1
        best_energy = array.array("Q", [INF_EN] * max_tuple)

        counter = collections.Counter()
        crashes = []
        energies = {}

        pack_name = os.path.join(args.output, ".traces", f"{self.idx}.pack")
        pack_pos = 0
        with open(pack_name, "wb") as trace_pack:
            while True:
                batch = self.q_in.get()
                if batch is None:
                    break

                for idx, r, crash, energy in afl_showmap(
                    batch=batch, afl_map_size=self.afl_map_size
                ):
                    counter.update(r)

                    used = False

                    if crash:
                        crashes.append(idx)

                    energies[idx] = energy
                    print('energy-inside:', energy)


                    # If we aren't saving crashes to a separate dir, handle them
                    # the same as other inputs. However, unless AFL_CMIN_ALLOW_ANY=1,
                    # afl_showmap will not return any coverage for crashes so they will
                    # nevbe retained.
                    if not crash or not args.crash_dir:
                        for t in r:
                            if args.energy_first and energy > 0:
                                if (energy < best_energy[t]) or (energy == best_energy[t] and idx < m[t]):
                                    print('t:', t)
                                    print('energy-inside:', energy)
                                    m[t] = idx
                                    best_energy[t] = energy
                                    used = True
                            else:
                                if idx < m[t]:
                                    m[t] = idx
                                    used = True
                    if used:
                        tuple_count = len(r)
                        r.tofile(trace_pack)
                        self.p_out.put((idx, self.idx, pack_pos, tuple_count))
                        pack_pos += tuple_count * r.itemsize
                    else:
                        self.p_out.put(None)

        self.r_out.put((self.idx, m, best_energy, counter, crashes, energies))



class CombineTraceWorker(multiprocessing.Process):

    def __init__(self, pack_name, jobs, r_out):
        super().__init__()
        self.pack_name = pack_name
        self.jobs = jobs
        self.r_out = r_out

    def run(self):
        already_have = set()
        with open(self.pack_name, "rb") as f:
            for pos, tuple_count in self.jobs:
                f.seek(pos)
                result = array.array(tuple_index_type_code)
                result.fromfile(f, tuple_count)
                already_have.update(result)
        self.r_out.put(already_have)


def hash_file(path):
    m = hashlib.sha1()
    with open(path, "rb") as f:
        m.update(f.read())
    return m.digest()


def dedup(files):
    with multiprocessing.Pool(args.workers) as pool:
        seen_hash = set()
        result = []
        hash_list = []
        # use large chunksize to reduce multiprocessing overhead
        chunksize = max(1, min(256, len(files) // args.workers))
        for i, h in enumerate(
            tqdm(
                pool.imap(hash_file, files, chunksize),
                desc="dedup",
                total=len(files),
                ncols=0,
                leave=(len(files) > 100000),
            )
        ):
            if h in seen_hash:
                continue
            seen_hash.add(h)
            result.append(files[i])
            hash_list.append(h)
        return result, hash_list


def is_afl_dir(dirnames, filenames):
    return (
        "queue" in dirnames
        and "hangs" in dirnames
        and "crashes" in dirnames
        and "fuzzer_setup" in filenames
    )


def collect_files(input_paths):
    paths = []
    for s in input_paths:
        paths += glob.glob(s)

    files = []
    with tqdm(desc="search", unit=" files", ncols=0) as pbar:
        for path in paths:
            for root, dirnames, filenames in os.walk(path, followlinks=True):
                for dirname in dirnames:
                    if dirname.startswith("."):
                        dirnames.remove(dirname)

                if not args.crash_only and is_afl_dir(dirnames, filenames):
                    continue

                for filename in filenames:
                    if filename.startswith("."):
                        continue
                    full_path = os.path.join(root, filename)
                    if not os.path.isfile(full_path):
                        continue
                    pbar.update(1)
                    files.append(full_path)
    return files


def main():
    init()

    files = collect_files(args.input)
    if len(files) == 0:
        logger.error("no inputs in the target directory - nothing to be done")
        sys.exit(1)
    logger.info("Found %d input files in %d directories", len(files), len(args.input))

    if not args.no_dedup:
        files, hash_list = dedup(files)
        logger.info("Remain %d files after dedup", len(files))
    else:
        logger.info("Skipping file deduplication.")

    global file_index_type_code
    file_index_type_code = detect_type_code(len(files))

    logger.info("Sorting files.")
    with multiprocessing.Pool(args.workers) as pool:
        chunksize = max(1, min(512, len(files) // args.workers))
        size_list = list(pool.map(os.path.getsize, files, chunksize))
    idxes = sorted(range(len(files)), key=lambda x: size_list[x])
    files = [files[idx] for idx in idxes]
    hash_list = [hash_list[idx] for idx in idxes]

    afl_map_size = None
    if "AFL_MAP_SIZE" in os.environ:
        afl_map_size = int(os.environ["AFL_MAP_SIZE"])
    elif args.nyx_mode:
        afl_map_size = get_nyx_map_size(args.exe)
        logger.info("Setting AFL_MAP_SIZE=%d", afl_map_size)
    elif b"AFL_DUMP_MAP_SIZE" in open(args.exe, "rb").read():
        output = subprocess.run(
            [args.exe],
            capture_output=True,
            env={**os.environ, "AFL_DUMP_MAP_SIZE": "1", "ASAN_OPTIONS": "detect_leaks=0"},
        ).stdout
        afl_map_size = int(output)
        logger.info("Setting AFL_MAP_SIZE=%d", afl_map_size)

    if afl_map_size:
        global tuple_index_type_code
        tuple_index_type_code = detect_type_code(afl_map_size * 9)

    logger.info("Testing the target binary")
    tuples, _ , _ = afl_showmap(files[0], afl_map_size=afl_map_size, first=True)
    if tuples:
        logger.info("ok, %d tuples recorded", len(tuples))
    else:
        logger.error("no instrumentation output detected")
        sys.exit(1)

    job_queue = multiprocessing.Queue()
    progress_queue = multiprocessing.Queue()
    result_queue = multiprocessing.Queue()

    workers = []
    for i in range(args.workers):
        p = Worker(i, afl_map_size, job_queue, progress_queue, result_queue)
        p.start()
        workers.append(p)

    #chunk = max(1, min(128, len(files) // args.workers))
    chunk = 1 if args.no_batch else max(1, min(128, len(files) // args.workers))

    jobs = list(batched(enumerate(files), chunk))
    jobs += [None] * args.workers  # sentinel

    dispatcher = JobDispatcher(job_queue, jobs)
    dispatcher.start()

    logger.info("Processing traces")
    effective = 0
    trace_info = {}
    for _ in tqdm(files, ncols=0, smoothing=0.01):
        r = progress_queue.get()
        if r is not None:
            idx, worker_idx, pos, tuple_count = r
            trace_info[idx] = worker_idx, pos, tuple_count
            effective += 1
    dispatcher.join()

    logger.info("Obtaining trace results")
    ms = [None] * args.workers
    es = [None] * args.workers
    crashes = []
    counter = collections.Counter()
    energy_maps = [None] * args.workers  # optional debug

    for _ in tqdm(range(args.workers), ncols=0):
        worker_idx, m, best_e, c, crs, energy_map = result_queue.get()
        ms[worker_idx] = m
        es[worker_idx] = best_e
        energy_maps[worker_idx] = energy_map
        counter.update(c)
        crashes.extend(crs)
        workers[worker_idx].join()

        print(worker_idx)
        print(m)
        print(c)
        print(crs)
        print(energy_map)

    # Choose best index per tuple across workers by (energy, idx)
    max_file_index = 256 ** array.array(file_index_type_code).itemsize - 1
    num_tuples = len(ms[0])
    INF_EN = (1 << 64) - 1
    best_idxes = [max_file_index] * num_tuples
    for t in range(num_tuples):
        best_pair = (INF_EN, max_file_index)  # (energy, idx)
        for i in range(args.workers):
            idx = ms[i][t]
            en  = es[i][t]
            if idx == max_file_index:
                continue
            cand = (en, idx) if en != INF_EN else (INF_EN, idx)
            if cand < best_pair:
                best_pair = cand
        if best_pair[0] == INF_EN:
            # no energy info; fall back to smallest index among workers
            best_idxes[t] = min(ms[i][t] for i in range(args.workers))
        else:
            best_idxes[t] = best_pair[1]

    if not args.crash_dir:
        logger.info(
            "Found %d unique tuples across %d files (%d effective)",
            len(counter),
            len(files),
            effective,
        )
    else:
        logger.info(
            "Found %d unique tuples across %d files (%d effective, %d crashes)",
            len(counter),
            len(files),
            effective,
            len(crashes),
        )
    all_unique = counter.most_common()

    logger.info("Processing candidates and writing output")
    already_have = set()
    count = 0

    def save_file(idx):
        input_path = files[idx]
        print('input_path:', input_path)
        fn = (
            base64.b16encode(hash_list[idx]).decode("utf8").lower()
            if not args.no_dedup
            else os.path.basename(input_path)
        )
        if args.as_queue:
            if args.no_dedup:
                fn = "id:%06d,orig:%s" % (count, fn)
            else:
                fn = "id:%06d,hash:%s" % (count, fn)
        output_path = os.path.join(args.output, fn)
        try:
            os.link(input_path, output_path)
        except OSError:
            shutil.copy(input_path, output_path)

    jobs = [[] for i in range(args.workers)]
    saved = set()
    for t, c in all_unique:
        if c != 1:
            continue
        idx = best_idxes[t]
        if idx in saved:
            continue
        save_file(idx)
        saved.add(idx)
        count += 1

        worker_idx, pos, tuple_count = trace_info[idx]
        job = (pos, tuple_count)
        jobs[worker_idx].append(job)

    trace_packs = []
    workers = []
    for i in range(args.workers):
        pack_name = os.path.join(args.output, ".traces", f"{i}.pack")
        trace_f = open(pack_name, "rb")
        trace_packs.append(trace_f)

        p = CombineTraceWorker(pack_name, jobs[i], result_queue)
        p.start()
        workers.append(p)

    for _ in range(args.workers):
        result = result_queue.get()
        already_have.update(result)

    for t, c in tqdm(list(reversed(all_unique)), ncols=0):
        if t in already_have:
            continue

        idx = best_idxes[t]
        save_file(idx)
        count += 1

        worker_idx, pos, tuple_count = trace_info[idx]
        trace_pack = trace_packs[worker_idx]
        trace_pack.seek(pos)
        result = array.array(tuple_index_type_code)
        result.fromfile(trace_pack, tuple_count)

        already_have.update(result)

    for f in trace_packs:
        f.close()

    if args.crash_dir:
        logger.info("Saving crashes to %s", args.crash_dir)
        crash_files = [files[c] for c in crashes]

        if args.no_dedup:
            # Unless we deduped previously, we have to dedup the crash files
            # now.
            crash_files, hash_list = dedup(crash_files)

        for idx, crash_path in enumerate(crash_files):
            fn = base64.b16encode(hash_list[idx]).decode("utf8").lower()
            output_path = os.path.join(args.crash_dir, fn)
            try:
                os.link(crash_path, output_path)
            except OSError:
                try:
                    shutil.copy(crash_path, output_path)
                except shutil.Error:
                    # This error happens when src and dest are hardlinks of the
                    # same file. We have nothing to do in this case, but handle
                    # it gracefully.
                    pass

    if count == 1:
        logger.warning("all test cases had the same traces, check syntax!")
    logger.info('narrowed down to %s files, saved in "%s"', count, args.output)
    if not os.environ.get("AFL_KEEP_TRACES"):
        logger.info("Deleting trace files")
        trace_dir = os.path.join(args.output, ".traces")
        shutil.rmtree(trace_dir, ignore_errors=True)


if __name__ == "__main__":
    main()

