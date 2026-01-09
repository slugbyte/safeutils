# safeutils
> coreutil replacements that aim to protect me from overwriting work.

## About
I lost work by accident one to many times, so I decided to make some safe replacements and added
a few nice modern features for fun.

## Features
* Verbose by default
* Safe clobber strategys
  * `trash` - move files to trash but rename conflicts `(name)_00.(ext) (name)_01.(ext)...`
  * `backup` -  rename original file to `(original).backup~` and trash any previous backups.
* `trash` can use [fzf](https://github.com/junegunn/fzf) to revert and fetch trashed files, and provieds a nice trash previewer.

## trash (rm replacement)
`--revert-fzf` and `--fetch-fzf` have a custom [fzf](https://github.com/junegunn/fzf) preview with...
* A header section with the `original path`, `file type`, and `file size`.
* A content section where text is printed, non-text prints `binary data` except images can optionaly be displayed with [viu](https://github.com/atanunq/viu)
```
USAGE: trash files.. (--flags)
  Move files to the trash.
  Revert trash fetch back to where they came from. 
  Fetch trash files to current dir.

  Revert and Fetch: (linux-only)
    -r --revert trashfile     Revert a trash file to its original location.
    -f --fetch  trashfile     Fetch a trash file to the current directory.
                              Fetch and Revert also manage .trashinfo files.

    FZF: 
    -R --revert-fzf           Use fzf to revert a trash file. 
    -F --fetch-fzf            Use fzf to fetch a trash file to the current dir.

    FZF Preview Options: (Combine with --revert-fzf or --fetch-fzf)
    --viu                  Add support for viu block image display in fzf preview.
    --viu-width            Overwrite the width viu images are displated at.
    --fzf-preview-window   Overwrite the --preview-window fzf flag. (see fzf --help)

  Other Flags:
  -s --silent               Only print errors.
  -V --version              Print version.
  -h --help                 Display this help.
 
  OPTIONAL DEPS:
  fzf: https://github.com/junegunn/fzf (fuzzy find)
  viu: https://github.com/atanunq/viu  (image preview)
```

## copy (cp replacement)
```
Usage: copy src.. dest (--flags)
  Copy a files and a directories.
  
  -d --dir             dirs copy recursively, and cobber conflicts
  -m --merge           dirs copy recursively, but src_dirs dont clobber dest_dirs
  -t --trash           trash conflicting files
  -c --create          create dest dir if not exists
  -b --backup          backup conflicting files
 
  -s --silent          only print errors
  -v --version         print this version
  -h --help            print this version
 
  EXAMPLES:
  copy boom.zig bap.zig     Copy boom.zig to bap.zig
  copy -dt util src         Copy util to src (trash src if exists)
  copy -db util src/        Copy util to src/util (backup src/util if exists)
  copy -m util test src     Merge util and test dirs into src dir (error if conflicts)
  copy -mt util test src/   Copy test and util into src (src/util src/test) (trash non dir-on-dir conflicts)
  copy -c **.png img        Create img dir and put all the pngs in it.      
```

## move (mv replacement)
```
Usage: move src.. dest (--flags)
  Move or rename a file, or move multiple files into a directory.
  When moveing files into a directory dest must have '/' at the end.
  When moving multiple files last path must be a directory and have a '/' at the end.

  Move will not partially move src.. paths. Everyting must move or nothing will move.

  Clobber Style:
    (default)     Print error and exit
    -t --trash    Move original dest to trash
    -b --backup   Rename original dest (original).backup~

    If both clober flags are found it choose backup over trash.

  Rename:
    -r --rename   Replace only the src basename with dest. 
                  Only works with one src path.
    example:
      ($ move --rename /example/oldname.zig newname.zig) results in /example/newname.zig

  Other Flags:
    -s --silent   Only print errors
    -V --version  Print version
    -h --help     Print this help
```