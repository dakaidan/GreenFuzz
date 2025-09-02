# GreenFuzz

Apply the energy_heuristic_afl.diff to the AFL++ submodule before building.

When running the Fuzzer we need to insert the energy preload library also with `AFL_PRELOAD`.

Create diffs for updates to afl:
```bash
git diff HEAD~1 HEAD > ../diff_name.diff 
 ```

Will create a diff of the latest commit, if you want to do more than one commit, you can get the commit hashes with `git log` and do:
```bash
git diff <commit-hash-1> <commit-hash-2> > ../diff_name.diff 
```

To apply the diff:
```bash
git apply ../diff_name.diff
```

## CPPJoules

To install:
```bash
curl https://raw.githubusercontent.com/rishalab/CPPJoules/main/installer.sh | bash
```