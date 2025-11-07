# safeutils
> coreutil replacements that aim to protect me from overwriting work.

## about
I lost work one too many times, by accidently overwriting data with coreutils. I made these utils to
reduce the chances that would happen again. They provide much less dangerous clobber strats.
 
### clobber strats
* `trash` - move files to trash but rename them so they dont confict `_00.ext, _01.ext, _02.ext ..`
* `backup` -  move original file to `(original_path).backup~`
   * if a backup allready exists it will be moved to trash

## trash (rm replacement)
'--revert-fzf' and '--fetch-fzf' have a custom [fzf](https://github.com/junegunn/fzf) preview for displaying:
* A header with the original path, file type, and file size.
* File content: text is printed, non-text prints `binary data` except images can optionaly be displayed with [viu](https://github.com/atanunq/viu)
```
USAGE: trash files.. (--flags)
  Move files to the trash.
  Revert trash fetch back to where they came from. 
  Fetch trash files to current dir.

  REVERT/FETCH: (linux-only)
  -r --revert trashfile     Revert a file from trash back to where it came from
  -R --revert-fzf           Use fzf to revert a trash file
  -F --fetch-fzf            Use fzf to fetch a trash_file to the current dir
 
  FZF PREVIEW OPTIONS: (combine with --revert-fzf --fetch-fzf)
  --viu                  Add support for viu block image display in fzf preview.
  --viu-width            Overwrite the width viu images are displated at.
  --fzf-preview-window   Overwrite the --preview-window fzf flag. (see fzf --help)

  -s --silent               Only print errors.
  -V --version              Print version.
  -h --help                 Display this help.
 
  OPTIONAL DEPS:
  fzf: https://github.com/junegunn/fzf (fuzzy find)
  viu: https://github.com/atanunq/viu  (image preview)
```

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