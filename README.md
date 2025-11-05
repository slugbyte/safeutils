# safeutils
> coreutil replacements that aim to protect me from overwriting work.

## about
I lost work one too many times, by accidently overwriting data with coreutils. I made these utils to
reduce the chances that would happen again. They provide much less dangerous clobber strats.
 
### trash clobber strategy
* move files to trash but rename them so they dont confict
* if on `linux` it also adds a `.trashinfo` file so that you can undo using a file browser
* files become `$trash/(basename)__(url_safe_base64_hash).trash`
* dirs and links become `$trash/(basename)__(timestamp).trash` or `$trash/(basename)__(timestap)_(random).trash` if there is a conflict.

### backup clobber strategy
* rename file `(original_path).backup~`
* if a backup allready exists it will be moved to trash

## move (mv replacement)
```
Usage: move src.. dest (--flags)
  Move or rename a file, or move multiple files into a directory.
  When moveing files into a directory dest must have '/' at the end.
  When moving multiple files last path must be a directory and have a '/' at the end.

  Move will not partially move src.. paths. Everyting must move or nothing will move.

  Clobber Style:
    (default)  error with warning
    -t --trash    move to $trash
    -b --backup   rename the dest file

    If mulitiple clober flags the presidence is (backup > trash > no clobber).
  
  Other Flags:
    --version     print version
    -r --rename   just replace the basename with dest
    -s --silent   only print errors
    -h --help     print this help
```

## trash (rm replacement)
trash can revert and fetch files using fzf with a custom preview that shows `revert_path`, `stat_kind`, `file_size` and `content`.
if you have [viu](https://github.com/atanunq/viu) installed you can also pass a `--viu` flag so that you can see image previews (in block form).
```
USAGE: trash files.. (--flags)
  Move files to the trash.
  Revert trash fetch back to where they came from. 
  Fetch trash files to current dir.

  --version                 print version
  -r --revert trash_file    (linux-only) revert a file from trash back to where it came from
  -R --revert-fzf           (linux-only) use fzf to revert a trash file
  -F --fetch-fzf            (linux-only) use fzf to fetch a trash_file to the current dir
     --viu                  add support for viu block image display in fzf preview
  -s --silent               only print errors
  -h --help                 display help
```