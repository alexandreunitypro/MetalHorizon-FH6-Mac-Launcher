#!/usr/bin/env python3
"""Make xodus keep the decrypted image's name on macOS (patches/xodus-cli/0001), editing
crates/xodus-cli/src/commands/run.rs whatever its surrounding text looks like."""
import re
import sys

path = sys.argv[1]
src = open(path).read()
if "xodus-image-" in src:
    print("already applied"); sys.exit(0)

# variant seen on the Blackwell Mac: a macOS-only make_temp_file that calls tempfile()
mac = re.search(r'#\[cfg\(target_os = "macos"\)\]\nfn make_temp_file\((?P<args>[^)]*)\) -> std::io::Result<std::fs::File> \{\n    tempfile\(\)\n\}\n', src)
if mac:
    args = mac.group("args")
    folder = "folder" if re.search(r'(^|[ ,(])folder:', args) else None
    args_named = re.sub(r'(^|[ ,(])_folder:', r'\1folder:', args)
    new = f'''/// macOS: the decrypted image keeps its name while the game runs, so Wine can reopen it and
/// give every handle its own file position (no /proc on macOS). The file is created 0600 and
/// removed by remove_kept_images() when Wine exits.
static KEPT_IMAGES: std::sync::Mutex<Vec<std::path::PathBuf>> = std::sync::Mutex::new(Vec::new());

#[cfg(target_os = "macos")]
fn make_temp_file({args_named}) -> std::io::Result<std::fs::File> {{
    let dir = if folder.is_empty() {{ std::env::temp_dir() }} else {{ std::path::PathBuf::from(folder) }};
    let (file, path) = tempfile::Builder::new()
        .prefix("xodus-image-")
        .tempfile_in(dir)?
        .keep()
        .map_err(|e| e.error)?;
    KEPT_IMAGES.lock().unwrap().push(path);
    Ok(file)
}}

fn remove_kept_images() {{
    for path in KEPT_IMAGES.lock().unwrap().drain(..) {{
        let _ = std::fs::remove_file(path);
    }}
}}
'''
    src = src[:mac.start()] + new + src[mac.end():]
    # call the cleanup once Wine has exited
    w = re.search(r'\n(\s*)let status = [^\n]*\.wait\(\)\.await[^\n]*;\n', src)
    if w:
        src = src[:w.end()] + w.group(1) + "remove_kept_images();\n" + src[w.end():]
    else:
        print("warning: wait() not found; kept images are not removed at exit")
    src = src.replace('#[cfg(target_os = "macos")]\nuse tempfile::tempfile;\n', '')
    open(path, "w").write(src)
    print("run.rs updated (Blackwell variant)")
    sys.exit(0)

# the non-Linux make_temp_file, with or without Ferestre's extra `name` parameter
m = re.search(r'#\[cfg\(not\(target_os = "linux"\)\)\]\nfn make_temp_file\((?P<args>[^)]*)\) -> std::io::Result<std::fs::File> \{\n'
              r'    if folder\.is_empty\(\) \{\n        tempfile\(\)\n    \} else \{\n        tempfile_in\(folder\)\n    \}\n\}\n', src)
if not m:
    print("non-Linux make_temp_file not found; nothing changed"); sys.exit(1)
args = m.group("args")
new = f'''/// macOS: keep the decrypted image's name on the private RAM disk (detached at exit) so Wine
/// can reopen it and give every handle its own file position (no /proc on macOS).
#[cfg(target_os = "macos")]
fn make_temp_file({args}) -> std::io::Result<std::fs::File> {{
    if folder.is_empty() {{
        return tempfile::tempfile();
    }}
    let (file, _path) = tempfile::Builder::new()
        .prefix("xodus-image-")
        .tempfile_in(folder)?
        .keep()
        .map_err(|e| e.error)?;
    Ok(file)
}}

#[cfg(not(any(target_os = "linux", target_os = "macos")))]
fn make_temp_file({args}) -> std::io::Result<std::fs::File> {{
    if folder.is_empty() {{
        tempfile()
    }} else {{
        tempfile_in(folder)
    }}
}}
'''
src = src[:m.start()] + new + src[m.end():]
# tempfile/tempfile_in are now only used off macOS; keep tempdir for macOS's prepare()
src = src.replace('#[cfg(not(target_os = "linux"))]\nuse tempfile::{tempdir, tempfile, tempfile_in};',
                  '#[cfg(target_os = "macos")]\nuse tempfile::tempdir;\n'
                  '#[cfg(not(any(target_os = "linux", target_os = "macos")))]\nuse tempfile::{tempfile, tempfile_in};')
open(path, "w").write(src)
print("run.rs updated")
