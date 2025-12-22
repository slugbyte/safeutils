# TODO 
* `copy` should have verbose output
* `copy` should stat dest not statNoFollow on `--merge`
  * or maby there should be a -S --symlink or something
* `copy` --progress display a progress bar instead of normal verbose

* `build -Djj_ref='@-'` so you can choose jj ref build time (build/commit/desc)
* trash `--cleanup` 
  * remove borked `.trashinfo` files
  * make a `lost_home` dir for files with no `.trashinfo` files
* better trash name strat? `file.0001.ext`
* `copy` cmd - `cp` replacment (copy src.. into dest)
* `md` commadn - `mkdir` replacement
* `merge` cmd - `cp -a` replacement (merge contents of src_dir into dest_dir)
* sort cmd - sort replacement (+ --line-len -l --reverse -r)
* ?? impl ~/.cache/safe/history
