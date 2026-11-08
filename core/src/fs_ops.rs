use std::ffi::OsStr;
use std::fs;
use std::io;
use std::path::{Path, PathBuf};
use std::time::UNIX_EPOCH;

#[derive(Debug, Clone, PartialEq)]
pub struct Entry {
    pub name: String,
    pub path: PathBuf,
    pub is_dir: bool,
    pub size: u64,
    pub modified: i64,
    pub hidden: bool,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum SortKey {
    #[default]
    Name,
    Size,
    Modified,
    Type,
}

impl SortKey {
    pub fn parse(text: &str) -> Self {
        match text {
            "size" => SortKey::Size,
            "modified" => SortKey::Modified,
            "type" => SortKey::Type,
            _ => SortKey::Name,
        }
    }
}

pub fn list_dir(dir: &Path, show_hidden: bool, key: SortKey, descending: bool) -> io::Result<Vec<Entry>> {
    let mut entries: Vec<Entry> = fs::read_dir(dir)?
        .filter_map(Result::ok)
        .filter_map(|e| stat_entry(&e.path()))
        .filter(|e| show_hidden || !e.hidden)
        .collect();
    sort_entries(&mut entries, key, descending);
    Ok(entries)
}

// folders always come first, so descending order flips each group on its own
pub fn sort_entries(entries: &mut [Entry], key: SortKey, descending: bool) {
    entries.sort_by_cached_key(|e| sort_key(e, key));
    if descending {
        let folders = entries.partition_point(|e| e.is_dir);
        let (dirs, files) = entries.split_at_mut(folders);
        if matches!(key, SortKey::Name | SortKey::Modified) {
            dirs.reverse();
        }
        files.reverse();
    }
}

fn sort_key(e: &Entry, key: SortKey) -> (bool, i64, String, String) {
    let (number, kind) = match key {
        SortKey::Name => (0, String::new()),
        SortKey::Size => (e.size as i64, String::new()),
        SortKey::Modified => (e.modified, String::new()),
        SortKey::Type if e.is_dir => (0, String::new()),
        SortKey::Type => (0, extension_of(&e.name)),
    };
    (!e.is_dir, number, kind, e.name.to_lowercase())
}

pub fn extension_of(name: &str) -> String {
    Path::new(name)
        .extension()
        .map(|e| e.to_string_lossy().to_lowercase())
        .unwrap_or_default()
}

pub fn type_label(name: &str, is_dir: bool) -> String {
    if is_dir {
        return "Folder".into();
    }
    match extension_of(name).as_str() {
        "" => "File".into(),
        ext => format!("{} file", ext.to_uppercase()),
    }
}

pub fn stat_entry(path: &Path) -> Option<Entry> {
    // fs::metadata follows symlinks so a link to a folder opens like a folder
    let meta = fs::metadata(path).or_else(|_| fs::symlink_metadata(path)).ok()?;
    let name = path.file_name()?.to_string_lossy().into_owned();
    let modified = meta
        .modified()
        .ok()
        .and_then(|t| t.duration_since(UNIX_EPOCH).ok())
        .map_or(0, |d| d.as_secs() as i64);
    Some(Entry {
        hidden: is_hidden(&name, &meta),
        is_dir: meta.is_dir(),
        size: if meta.is_dir() { 0 } else { meta.len() },
        modified,
        path: path.to_path_buf(),
        name,
    })
}

#[cfg(windows)]
fn is_hidden(name: &str, meta: &fs::Metadata) -> bool {
    use std::os::windows::fs::MetadataExt;
    const FILE_ATTRIBUTE_HIDDEN: u32 = 0x2;
    name.starts_with('.') || meta.file_attributes() & FILE_ATTRIBUTE_HIDDEN != 0
}

#[cfg(not(windows))]
fn is_hidden(name: &str, _meta: &fs::Metadata) -> bool {
    name.starts_with('.')
}

pub fn validate_name(name: &str) -> Result<(), String> {
    let trimmed = name.trim();
    if trimmed.is_empty() || trimmed == "." || trimmed == ".." {
        return Err("The name is not valid.".into());
    }
    if trimmed.contains(['/', '\\', '\0']) {
        return Err("The name cannot contain a slash.".into());
    }
    #[cfg(windows)]
    if trimmed.contains(['<', '>', ':', '"', '|', '?', '*']) {
        return Err("The name cannot contain < > : \" | ? *".into());
    }
    Ok(())
}

pub fn rename(path: &Path, new_name: &str) -> Result<PathBuf, String> {
    validate_name(new_name)?;
    let dest = path.with_file_name(new_name.trim());
    if dest.exists() {
        return Err(format!("\"{}\" already exists.", new_name.trim()));
    }
    fs::rename(path, &dest).map_err(|e| e.to_string())?;
    Ok(dest)
}

pub fn make_dir(parent: &Path, name: &str) -> Result<PathBuf, String> {
    validate_name(name)?;
    let dest = parent.join(name.trim());
    fs::create_dir(&dest).map_err(|e| e.to_string())?;
    Ok(dest)
}

// a broken link still occupies its name, so this check never follows links
pub fn exists_nofollow(path: &Path) -> bool {
    fs::symlink_metadata(path).is_ok()
}

pub fn unique_dest(dir: &Path, name: &OsStr) -> PathBuf {
    let first = dir.join(name);
    if !exists_nofollow(&first) {
        return first;
    }
    let as_path = Path::new(name);
    let stem = as_path.file_stem().unwrap_or(name).to_string_lossy();
    let ext = as_path
        .extension()
        .map(|e| format!(".{}", e.to_string_lossy()))
        .unwrap_or_default();
    (2..)
        .map(|n| dir.join(format!("{stem} ({n}){ext}")))
        .find(|p| !exists_nofollow(p))
        .expect("an unused name exists")
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs::File;
    use std::time::{Duration, SystemTime};

    fn names(entries: Vec<Entry>) -> Vec<String> {
        entries.into_iter().map(|e| e.name).collect()
    }

    fn write_sized(dir: &Path, name: &str, size: usize, age_secs: u64) {
        let path = dir.join(name);
        fs::write(&path, vec![b'x'; size]).unwrap();
        let when = SystemTime::now() - Duration::from_secs(age_secs);
        File::options().write(true).open(&path).unwrap().set_modified(when).unwrap();
    }

    #[test]
    fn lists_folders_first_then_case_insensitive_names() {
        let tmp = tempfile::tempdir().unwrap();
        fs::write(tmp.path().join("b.txt"), "x").unwrap();
        fs::write(tmp.path().join("A.txt"), "x").unwrap();
        fs::create_dir(tmp.path().join("zdir")).unwrap();
        fs::write(tmp.path().join(".secret"), "x").unwrap();
        let listed = list_dir(tmp.path(), false, SortKey::Name, false).unwrap();
        assert_eq!(names(listed), ["zdir", "A.txt", "b.txt"]);
        assert_eq!(list_dir(tmp.path(), true, SortKey::Name, false).unwrap().len(), 4);
    }

    #[test]
    fn name_sort_descending_keeps_folders_first() {
        let tmp = tempfile::tempdir().unwrap();
        fs::create_dir(tmp.path().join("a_dir")).unwrap();
        fs::create_dir(tmp.path().join("z_dir")).unwrap();
        write_sized(tmp.path(), "a.txt", 1, 0);
        write_sized(tmp.path(), "b.txt", 1, 0);
        let listed = list_dir(tmp.path(), false, SortKey::Name, true).unwrap();
        assert_eq!(names(listed), ["z_dir", "a_dir", "b.txt", "a.txt"]);
    }

    #[test]
    fn size_sort_orders_files_and_breaks_ties_by_name() {
        let tmp = tempfile::tempdir().unwrap();
        fs::create_dir(tmp.path().join("folder")).unwrap();
        write_sized(tmp.path(), "big.bin", 900, 0);
        write_sized(tmp.path(), "small.bin", 10, 0);
        write_sized(tmp.path(), "mid_b.bin", 100, 0);
        write_sized(tmp.path(), "mid_a.bin", 100, 0);
        let up = names(list_dir(tmp.path(), false, SortKey::Size, false).unwrap());
        assert_eq!(up, ["folder", "small.bin", "mid_a.bin", "mid_b.bin", "big.bin"]);
        let down = names(list_dir(tmp.path(), false, SortKey::Size, true).unwrap());
        assert_eq!(down, ["folder", "big.bin", "mid_b.bin", "mid_a.bin", "small.bin"]);
    }

    #[test]
    fn modified_sort_puts_oldest_first_when_ascending() {
        let tmp = tempfile::tempdir().unwrap();
        write_sized(tmp.path(), "new.txt", 1, 10);
        write_sized(tmp.path(), "old.txt", 1, 5000);
        write_sized(tmp.path(), "mid.txt", 1, 600);
        let up = names(list_dir(tmp.path(), false, SortKey::Modified, false).unwrap());
        assert_eq!(up, ["old.txt", "mid.txt", "new.txt"]);
        let down = names(list_dir(tmp.path(), false, SortKey::Modified, true).unwrap());
        assert_eq!(down, ["new.txt", "mid.txt", "old.txt"]);
    }

    #[test]
    fn type_sort_groups_by_extension_then_name() {
        let tmp = tempfile::tempdir().unwrap();
        for name in ["b.png", "a.txt", "c.PNG", "a.png", "readme"] {
            write_sized(tmp.path(), name, 1, 0);
        }
        let up = names(list_dir(tmp.path(), false, SortKey::Type, false).unwrap());
        assert_eq!(up, ["readme", "a.png", "b.png", "c.PNG", "a.txt"]);
    }

    // run with: cargo test --release -- --ignored --nocapture stage_times, set JF_PERF_DIR to test another folder
    #[test]
    #[ignore]
    fn stage_times_for_a_big_folder() {
        use std::time::Instant;
        let tmp = tempfile::tempdir().unwrap();
        let dir = std::env::var("JF_PERF_DIR").map(PathBuf::from).unwrap_or_else(|_| {
            for i in 0..20000 {
                fs::write(tmp.path().join(format!("file_{i:05}.txt")), "x").unwrap();
            }
            tmp.path().to_path_buf()
        });
        for run in 0..5 {
            let t = Instant::now();
            let names = fs::read_dir(&dir).unwrap().filter_map(Result::ok).count();
            let read = t.elapsed();
            let t = Instant::now();
            let mut entries: Vec<Entry> = fs::read_dir(&dir).unwrap().filter_map(Result::ok).filter_map(|e| stat_entry(&e.path())).collect();
            let listed = t.elapsed();
            let t = Instant::now();
            sort_entries(&mut entries, SortKey::Name, false);
            let sorted = t.elapsed();
            println!("run {run}: {names} names, read_dir {read:?}, read_dir and stat {listed:?}, sort {sorted:?}");
        }
    }

    #[test]
    fn sort_key_parse_falls_back_to_name() {
        assert_eq!(SortKey::parse("size"), SortKey::Size);
        assert_eq!(SortKey::parse("modified"), SortKey::Modified);
        assert_eq!(SortKey::parse("type"), SortKey::Type);
        assert_eq!(SortKey::parse("nonsense"), SortKey::Name);
    }

    #[test]
    fn type_label_names_folders_and_extensions() {
        assert_eq!(type_label("x", true), "Folder");
        assert_eq!(type_label("photo.JPG", false), "JPG file");
        assert_eq!(type_label("Makefile", false), "File");
        assert_eq!(type_label(".bashrc", false), "File");
    }

    #[test]
    fn unique_dest_adds_a_counter_before_the_extension() {
        let tmp = tempfile::tempdir().unwrap();
        fs::write(tmp.path().join("a.txt"), "x").unwrap();
        fs::write(tmp.path().join("a (2).txt"), "x").unwrap();
        assert_eq!(unique_dest(tmp.path(), OsStr::new("a.txt")), tmp.path().join("a (3).txt"));
        assert_eq!(unique_dest(tmp.path(), OsStr::new("new")), tmp.path().join("new"));
    }

    #[test]
    fn rename_rejects_slashes_and_existing_names() {
        let tmp = tempfile::tempdir().unwrap();
        let a = tmp.path().join("a");
        fs::write(&a, "x").unwrap();
        fs::write(tmp.path().join("b"), "x").unwrap();
        assert!(rename(&a, "x/y").is_err());
        assert!(rename(&a, "b").is_err());
        assert_eq!(rename(&a, " c ").unwrap(), tmp.path().join("c"));
    }
}
