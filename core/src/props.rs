use std::fs;
use std::io;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::thread;
use std::time::{Duration, Instant};

use crate::fs_ops::{reason, stat_entry, type_label};

#[derive(Debug, Clone, PartialEq)]
pub struct Props {
    pub name: String,
    pub path: PathBuf,
    pub type_label: String,
    pub is_dir: bool,
    pub is_symlink: bool,
    pub size: u64,
    pub modified: i64,
    // empty for a file, and the reason as an error when a folder cannot be read
    pub items: Option<Result<u64, String>>,
}

pub fn props(path: &Path) -> io::Result<Props> {
    let link = fs::symlink_metadata(path)?;
    let entry = stat_entry(path).ok_or_else(|| io::Error::other("The item cannot be read."))?;
    let items = entry.is_dir.then(|| fs::read_dir(path).map(|rd| rd.filter_map(Result::ok).count() as u64).map_err(|e| reason(&e)));
    Ok(Props {
        type_label: type_label(&entry.name, entry.is_dir),
        is_symlink: link.file_type().is_symlink(),
        name: entry.name,
        path: entry.path,
        is_dir: entry.is_dir,
        size: entry.size,
        modified: entry.modified,
        items,
    })
}

#[derive(Debug, Default)]
pub struct SizeScan {
    pub bytes: AtomicU64,
    pub files: AtomicU64,
    pub folders: AtomicU64,
    pub done: AtomicBool,
    pub cancel: AtomicBool,
    thread: Mutex<Option<thread::JoinHandle<()>>>,
}

impl SizeScan {
    // returns false when the scan still runs at the deadline
    pub fn wait_finished(&self, deadline: Instant) -> bool {
        while !self.done.load(Ordering::Relaxed) {
            if Instant::now() >= deadline {
                return false;
            }
            thread::sleep(Duration::from_millis(5));
        }
        if let Some(handle) = self.thread.lock().unwrap().take() {
            let _ = handle.join();
        }
        true
    }
}

pub fn spawn_size_scan(path: PathBuf) -> Arc<SizeScan> {
    let scan = Arc::new(SizeScan::default());
    let worker = Arc::clone(&scan);
    let handle = thread::spawn(move || {
        scan_tree(&worker, &path);
        worker.done.store(true, Ordering::Relaxed);
    });
    *scan.thread.lock().unwrap() = Some(handle);
    scan
}

// links count as one small file, so a link cycle cannot loop
fn scan_tree(scan: &SizeScan, root: &Path) {
    let mut pending = vec![root.to_path_buf()];
    while let Some(dir) = pending.pop() {
        if scan.cancel.load(Ordering::Relaxed) {
            return;
        }
        let Ok(read) = fs::read_dir(&dir) else { continue };
        for entry in read.filter_map(Result::ok) {
            let Ok(kind) = entry.file_type() else { continue };
            if kind.is_dir() {
                scan.folders.fetch_add(1, Ordering::Relaxed);
                pending.push(entry.path());
            } else {
                scan.files.fetch_add(1, Ordering::Relaxed);
                let len = entry.metadata().map_or(0, |m| m.len());
                scan.bytes.fetch_add(len, Ordering::Relaxed);
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::{Duration, Instant};

    fn tree() -> tempfile::TempDir {
        let tmp = tempfile::tempdir().unwrap();
        fs::create_dir_all(tmp.path().join("d/sub/deeper")).unwrap();
        fs::write(tmp.path().join("d/a.bin"), vec![0u8; 1000]).unwrap();
        fs::write(tmp.path().join("d/sub/b.bin"), vec![0u8; 500]).unwrap();
        fs::write(tmp.path().join("d/sub/deeper/c.bin"), vec![0u8; 25]).unwrap();
        tmp
    }

    #[test]
    fn props_of_a_file_report_name_type_size_and_no_item_count() {
        let tmp = tree();
        let p = props(&tmp.path().join("d/a.bin")).unwrap();
        assert_eq!((p.name.as_str(), p.type_label.as_str()), ("a.bin", "BIN file"));
        assert_eq!((p.size, p.is_dir, p.items), (1000, false, None));
        assert!(p.modified > 0);
    }

    #[test]
    fn props_of_a_folder_count_direct_children_only() {
        let tmp = tree();
        let p = props(&tmp.path().join("d")).unwrap();
        assert_eq!((p.type_label.as_str(), p.is_dir, p.items), ("Folder", true, Some(Ok(2))));
    }

    #[test]
    fn props_of_a_missing_path_is_an_error() {
        let tmp = tree();
        assert!(props(&tmp.path().join("nope")).is_err());
    }

    #[cfg(unix)]
    #[test]
    fn props_of_a_folder_that_cannot_be_read_give_no_item_count() {
        use std::os::unix::fs::PermissionsExt;
        let tmp = tree();
        let d = tmp.path().join("d");
        fs::set_permissions(&d, fs::Permissions::from_mode(0o000)).unwrap();
        let readable = fs::read_dir(&d).is_ok();
        let p = props(&d);
        fs::set_permissions(&d, fs::Permissions::from_mode(0o755)).unwrap();
        if readable {
            return;
        }
        let p = p.unwrap();
        assert!(p.is_dir);
        assert_eq!(p.items, Some(Err("permission denied".into())));
    }

    #[cfg(unix)]
    #[test]
    fn props_flag_a_symlink() {
        let tmp = tree();
        let link = tmp.path().join("link");
        std::os::unix::fs::symlink(tmp.path().join("d"), &link).unwrap();
        let p = props(&link).unwrap();
        assert!(p.is_symlink && p.is_dir);
    }

    #[test]
    fn the_size_scan_sums_bytes_files_and_folders() {
        let tmp = tree();
        let scan = spawn_size_scan(tmp.path().join("d"));
        let start = Instant::now();
        while !scan.done.load(Ordering::Relaxed) {
            assert!(start.elapsed() < Duration::from_secs(10), "scan finished in time");
            thread::sleep(Duration::from_millis(2));
        }
        assert_eq!(scan.bytes.load(Ordering::Relaxed), 1525);
        assert_eq!(scan.files.load(Ordering::Relaxed), 3);
        assert_eq!(scan.folders.load(Ordering::Relaxed), 2);
    }

    #[test]
    fn a_cancelled_scan_stops_before_it_reads_anything() {
        let tmp = tree();
        let scan = SizeScan::default();
        scan.cancel.store(true, Ordering::Relaxed);
        scan_tree(&scan, &tmp.path().join("d"));
        assert_eq!(scan.files.load(Ordering::Relaxed), 0);
    }
}
