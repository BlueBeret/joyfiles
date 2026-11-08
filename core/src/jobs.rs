use std::fs::{self, File};
use std::io::{self, Read, Write};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::thread;

use crate::fs_ops::unique_dest;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum JobKind {
    Copy,
    Move,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum JobState {
    Running,
    Done,
    Cancelled,
    Failed(String),
}

#[derive(Debug)]
pub struct Progress {
    pub kind: JobKind,
    pub done_bytes: AtomicU64,
    pub total_bytes: AtomicU64,
    pub cancel: AtomicBool,
    pub state: Mutex<JobState>,
    pub current: Mutex<String>,
}

impl Progress {
    pub fn state(&self) -> JobState {
        self.state.lock().unwrap().clone()
    }
}

pub fn spawn(kind: JobKind, sources: Vec<PathBuf>, dest_dir: PathBuf) -> Arc<Progress> {
    let progress = Arc::new(Progress {
        kind,
        done_bytes: AtomicU64::new(0),
        total_bytes: AtomicU64::new(0),
        cancel: AtomicBool::new(false),
        state: Mutex::new(JobState::Running),
        current: Mutex::new(String::new()),
    });
    let worker = Arc::clone(&progress);
    thread::spawn(move || {
        let end = match run(&worker, &sources, &dest_dir) {
            Ok(()) => JobState::Done,
            Err(_) if worker.cancel.load(Ordering::Relaxed) => JobState::Cancelled,
            Err(e) => JobState::Failed(e.to_string()),
        };
        *worker.state.lock().unwrap() = end;
    });
    progress
}

fn run(p: &Progress, sources: &[PathBuf], dest_dir: &Path) -> io::Result<()> {
    for src in sources {
        if src.is_dir() && dest_dir.starts_with(src) {
            return Err(io::Error::other("Cannot put a folder inside itself."));
        }
    }
    let total = sources.iter().map(|s| tree_size(s)).sum();
    p.total_bytes.store(total, Ordering::Relaxed);
    for src in sources {
        let name = src.file_name().ok_or_else(|| io::Error::other("The source has no name."))?;
        *p.current.lock().unwrap() = name.to_string_lossy().into_owned();
        if p.kind == JobKind::Move && src.parent() == Some(dest_dir) {
            p.done_bytes.fetch_add(tree_size(src), Ordering::Relaxed);
            continue;
        }
        let dest = unique_dest(dest_dir, name);
        if p.kind == JobKind::Move && fs::rename(src, &dest).is_ok() {
            p.done_bytes.fetch_add(tree_size(&dest), Ordering::Relaxed);
            continue;
        }
        copy_tree(p, src, &dest)?;
        if p.kind == JobKind::Move {
            remove_tree(src)?;
        }
    }
    Ok(())
}

fn tree_size(path: &Path) -> u64 {
    match fs::symlink_metadata(path) {
        Ok(m) if m.is_dir() => fs::read_dir(path)
            .map(|rd| rd.filter_map(Result::ok).map(|e| tree_size(&e.path())).sum())
            .unwrap_or(0),
        Ok(m) => m.len(),
        Err(_) => 0,
    }
}

fn copy_tree(p: &Progress, src: &Path, dest: &Path) -> io::Result<()> {
    let meta = fs::symlink_metadata(src)?;
    if meta.is_dir() {
        fs::create_dir(dest)?;
        for entry in fs::read_dir(src)? {
            let entry = entry?;
            copy_tree(p, &entry.path(), &dest.join(entry.file_name()))?;
        }
        return Ok(());
    }
    if meta.file_type().is_symlink() {
        return copy_symlink(src, dest);
    }
    copy_file(p, src, dest)
}

#[cfg(unix)]
fn copy_symlink(src: &Path, dest: &Path) -> io::Result<()> {
    std::os::unix::fs::symlink(fs::read_link(src)?, dest)
}

#[cfg(not(unix))]
fn copy_symlink(src: &Path, dest: &Path) -> io::Result<()> {
    fs::copy(src, dest).map(|_| ())
}

fn copy_file(p: &Progress, src: &Path, dest: &Path) -> io::Result<()> {
    let mut input = File::open(src)?;
    let mut output = File::create_new(dest)?;
    let mut buf = vec![0u8; 1 << 20];
    loop {
        if p.cancel.load(Ordering::Relaxed) {
            drop(output);
            let _ = fs::remove_file(dest);
            return Err(io::Error::other("Cancelled."));
        }
        let n = input.read(&mut buf)?;
        if n == 0 {
            break;
        }
        output.write_all(&buf[..n])?;
        p.done_bytes.fetch_add(n as u64, Ordering::Relaxed);
    }
    output.set_permissions(input.metadata()?.permissions())?;
    Ok(())
}

fn remove_tree(path: &Path) -> io::Result<()> {
    if fs::symlink_metadata(path)?.is_dir() {
        fs::remove_dir_all(path)
    } else {
        fs::remove_file(path)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::{Duration, Instant};

    fn wait(p: &Progress) -> JobState {
        let start = Instant::now();
        while p.state() == JobState::Running {
            assert!(start.elapsed() < Duration::from_secs(10), "job finished in time");
            thread::sleep(Duration::from_millis(5));
        }
        p.state()
    }

    #[test]
    fn copies_a_folder_tree_and_reports_all_bytes() {
        let tmp = tempfile::tempdir().unwrap();
        let src = tmp.path().join("src");
        fs::create_dir_all(src.join("sub")).unwrap();
        fs::write(src.join("a.bin"), vec![1u8; 3000]).unwrap();
        fs::write(src.join("sub/b.bin"), vec![2u8; 500]).unwrap();
        let out = tmp.path().join("out");
        fs::create_dir(&out).unwrap();
        let p = spawn(JobKind::Copy, vec![src.clone()], out.clone());
        assert_eq!(wait(&p), JobState::Done);
        assert_eq!(fs::read(out.join("src/sub/b.bin")).unwrap(), vec![2u8; 500]);
        assert_eq!(p.done_bytes.load(Ordering::Relaxed), 3500);
        assert_eq!(p.total_bytes.load(Ordering::Relaxed), 3500);
        assert!(src.exists());
    }

    #[test]
    fn copy_into_the_same_folder_keeps_both_files() {
        let tmp = tempfile::tempdir().unwrap();
        let a = tmp.path().join("a.txt");
        fs::write(&a, "x").unwrap();
        let p = spawn(JobKind::Copy, vec![a], tmp.path().to_path_buf());
        assert_eq!(wait(&p), JobState::Done);
        assert!(tmp.path().join("a (2).txt").exists());
    }

    #[test]
    fn move_removes_the_source() {
        let tmp = tempfile::tempdir().unwrap();
        let a = tmp.path().join("a.txt");
        fs::write(&a, "hello").unwrap();
        let out = tmp.path().join("out");
        fs::create_dir(&out).unwrap();
        let p = spawn(JobKind::Move, vec![a.clone()], out.clone());
        assert_eq!(wait(&p), JobState::Done);
        assert!(!a.exists());
        assert_eq!(fs::read_to_string(out.join("a.txt")).unwrap(), "hello");
    }

    #[test]
    fn refuses_to_copy_a_folder_into_itself() {
        let tmp = tempfile::tempdir().unwrap();
        let dir = tmp.path().join("d");
        fs::create_dir_all(dir.join("inner")).unwrap();
        let p = spawn(JobKind::Copy, vec![dir.clone()], dir.join("inner"));
        assert!(matches!(wait(&p), JobState::Failed(_)));
    }
}
