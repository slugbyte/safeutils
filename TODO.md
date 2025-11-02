# TODO
* copy cmd
* sort cmd
* remove `$trash` dependency use freedesktop.org standard
  * trash impl .trashinfo files
* move `--merge` `-m` move the contents of src\_dir into dest\_dir leaving dest_dir contents inplace
* `--undo` flag for `move` `trash` and `copy`
  * write a simple histroy log so that each command can be undo
  * `--force` writes could be copied to /tmp so they could be recoverd for a short while
* impl ~/.cache/safe/history
