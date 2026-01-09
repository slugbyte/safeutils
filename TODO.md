# TODO 
* `copy` should have verbose output
* `copy` should stat dest not statNoFollow on `--merge`
  * or maby there should be a -S --symlink or something
* `copy` --progress display a progress bar instead of normal verbose

* patch move across mount points error (trash and move) --multi-disk -m
```

thread 355486 panic: unexpected error: RenameAcrossMountPoints
/home/slugbyte/workspace/code/safeutils/src/util/Reporter.zig:34:20: 0x102089a in PANIC_WITH_REPORT__anon_3264 (trash)
    std.debug.panic(format, args);
                   ^
/home/slugbyte/workspace/code/safeutils/src/exec/trash.zig:116:51: 0x1020481 in main (trash)
            else => ctx.reporter.PANIC_WITH_REPORT("unexpected error: {t}", .{err}),
                                                  ^
/home/slugbyte/Dropbox/exec/share/zig/zig-x86_64-linux-0.15.1/lib/std/start.zig:627:37: 0x1011eca in posixCallMainAndExit (trash)
            const result = root.main() catch |err| {
                                    ^
/home/slugbyte/Dropbox/exec/share/zig/zig-x86_64-linux-0.15.1/lib/std/start.zig:232:5: 0x1011a6d in _start (trash)
    asm volatile (switch (native_arch) {
    ^
???:?:?: 0x0 in ??? (???)
fish: Job 1, 'trash pic' terminated by signal SIGABRT (Abort)
  
```

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
