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

pub fn list_dir(dir: &Path, show_hidden: bool) -> io::Result<Vec<Entry>> {
    let mut entries: Vec<Entry> = fs::read_dir(dir)?
        .filter_map(Result::ok)
        .filter_map(|e| entry_from(&e.path()))
        .filter(|e| show_hidden || !e.hidden)
        .collect();
    entries.sort_by(|a, b| {
        b.is_dir
            .cmp(&a.is_dir)
            .then_with(|| a.name.to_lowercase().cmp(&b.name.to_lowercase()))
    });
    Ok(entries)
}

fn entry_from(path: &Path) -> Option<Entry> {
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

pub fn unique_dest(dir: &Path, name: &OsStr) -> PathBuf {
    let first = dir.join(name);
    if !first.exists() {
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
        .find(|p| !p.exists())
        .expect("an unused name exists")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn lists_folders_first_then_case_insensitive_names() {
        let tmp = tempfile::tempdir().unwrap();
        fs::write(tmp.path().join("b.txt"), "x").unwrap();
        fs::write(tmp.path().join("A.txt"), "x").unwrap();
        fs::create_dir(tmp.path().join("zdir")).unwrap();
        fs::write(tmp.path().join(".secret"), "x").unwrap();
        let names: Vec<_> = list_dir(tmp.path(), false).unwrap().into_iter().map(|e| e.name).collect();
        assert_eq!(names, ["zdir", "A.txt", "b.txt"]);
        assert_eq!(list_dir(tmp.path(), true).unwrap().len(), 4);
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
