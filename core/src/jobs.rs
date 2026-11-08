use std::fs::{self, File};
use std::io::{self, Read, Write};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Condvar, Mutex};
use std::thread;

use crate::fs_ops::{Entry, Failure, exists_nofollow, summary, is_within, reason, same_dir, stat_entry, temp_path, unique_dest};

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

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Resolution {
    Replace,
    KeepBoth,
    Skip,
}

impl Resolution {
    pub fn parse(text: &str) -> Option<Self> {
        match text {
            "replace" => Some(Resolution::Replace),
            "keep_both" => Some(Resolution::KeepBoth),
            "skip" => Some(Resolution::Skip),
            _ => None,
        }
    }
}

// with Ask the worker pauses on each name clash until a caller answers
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Policy {
    Ask,
    Always(Resolution),
}

#[derive(Debug, Clone, PartialEq)]
pub struct Conflict {
    pub name: String,
    pub src: Entry,
    pub dest: Entry,
}

#[derive(Debug, Default)]
struct Gate {
    question: Option<Conflict>,
    answer: Option<(Resolution, bool)>,
}

#[derive(Debug)]
pub struct Progress {
    pub kind: JobKind,
    pub done_bytes: AtomicU64,
    pub total_bytes: AtomicU64,
    pub cancel: AtomicBool,
    pub state: Mutex<JobState>,
    pub current: Mutex<String>,
    failures: Mutex<Vec<Failure>>,
    gate: Mutex<Gate>,
    wake: Condvar,
}

impl Progress {
    pub fn state(&self) -> JobState {
        self.state.lock().unwrap().clone()
    }

    pub fn failures(&self) -> Vec<Failure> {
        self.failures.lock().unwrap().clone()
    }

    // taking the gate lock before the notify means a worker never misses the flag
    pub fn request_cancel(&self) {
        self.cancel.store(true, Ordering::Relaxed);
        let _gate = self.gate.lock().unwrap();
        self.wake.notify_all();
    }

    pub fn pending_conflict(&self) -> Option<Conflict> {
        self.gate.lock().unwrap().question.clone()
    }

    // returns false when no question waits, so a late answer does nothing
    pub fn answer(&self, choice: Resolution, apply_all: bool) -> bool {
        let mut gate = self.gate.lock().unwrap();
        if gate.question.take().is_none() {
            return false;
        }
        gate.answer = Some((choice, apply_all));
        self.wake.notify_all();
        true
    }

    fn ask(&self, conflict: Conflict) -> io::Result<(Resolution, bool)> {
        let mut gate = self.gate.lock().unwrap();
        gate.question = Some(conflict);
        loop {
            if self.cancel.load(Ordering::Relaxed) {
                gate.question = None;
                return Err(io::Error::other("Cancelled."));
            }
            if let Some(reply) = gate.answer.take() {
                return Ok(reply);
            }
            gate = self.wake.wait(gate).unwrap();
        }
    }

    fn add_done(&self, bytes: u64) {
        self.done_bytes.fetch_add(bytes, Ordering::Relaxed);
    }
}

pub fn spawn(kind: JobKind, sources: Vec<PathBuf>, dest_dir: PathBuf, policy: Policy) -> Arc<Progress> {
    let progress = Arc::new(Progress {
        kind,
        done_bytes: AtomicU64::new(0),
        total_bytes: AtomicU64::new(0),
        cancel: AtomicBool::new(false),
        state: Mutex::new(JobState::Running),
        current: Mutex::new(String::new()),
        failures: Mutex::new(Vec::new()),
        gate: Mutex::new(Gate::default()),
        wake: Condvar::new(),
    });
    let worker = Arc::clone(&progress);
    thread::spawn(move || {
        let end = match run(&worker, &sources, &dest_dir, policy) {
            Ok(()) => summary(&worker.failures()).map_or(JobState::Done, JobState::Failed),
            Err(_) if worker.cancel.load(Ordering::Relaxed) => JobState::Cancelled,
            Err(e) => JobState::Failed(e.to_string()),
        };
        *worker.state.lock().unwrap() = end;
    });
    progress
}

struct Worker<'a> {
    p: &'a Progress,
    sticky: Option<Resolution>,
    // an explicit stack, so a deep merge cannot overflow the thread stack
    tasks: Vec<Task>,
}

enum Task {
    Transfer { src: PathBuf, dest_dir: PathBuf },
    // a move removes a merged source folder once its children are gone
    EndMerge(PathBuf),
}

fn run(p: &Progress, sources: &[PathBuf], dest_dir: &Path, policy: Policy) -> io::Result<()> {
    if !dest_dir.is_dir() {
        return Err(io::Error::other("The destination folder does not exist."));
    }
    for src in sources {
        if is_real_dir(src) && is_within(dest_dir, src) {
            return Err(io::Error::other("Cannot put a folder inside itself."));
        }
    }
    let total = sources.iter().map(|s| tree_size(s)).sum();
    p.total_bytes.store(total, Ordering::Relaxed);
    let sticky = match policy {
        Policy::Ask => None,
        Policy::Always(choice) => Some(choice),
    };
    let tasks = sources.iter().rev().map(|src| Task::Transfer { src: src.clone(), dest_dir: dest_dir.to_path_buf() }).collect();
    let mut worker = Worker { p, sticky, tasks };
    while let Some(task) = worker.tasks.pop() {
        match task {
            Task::Transfer { src, dest_dir } => {
                if let Err(e) = worker.transfer(&src, &dest_dir) {
                    worker.fail(&src, &e)?;
                }
            }
            Task::EndMerge(src) => {
                // the folder stays when a child was skipped
                let _ = fs::remove_dir(src);
            }
        }
    }
    Ok(())
}

impl Worker<'_> {
    // records the error and lets the job go on, unless the user cancelled
    fn fail(&self, path: &Path, err: &io::Error) -> io::Result<()> {
        if self.p.cancel.load(Ordering::Relaxed) {
            return Err(io::Error::other("Cancelled."));
        }
        let verb = if self.p.kind == JobKind::Move { "move" } else { "copy" };
        let name = path.file_name().unwrap_or(path.as_os_str()).to_string_lossy();
        let message = format!("Could not {verb} \"{name}\": {}.", reason(err));
        self.p.failures.lock().unwrap().push(Failure { path: path.to_path_buf(), message });
        Ok(())
    }

    fn transfer(&mut self, src: &Path, dest_dir: &Path) -> io::Result<()> {
        if self.p.cancel.load(Ordering::Relaxed) {
            return Err(io::Error::other("Cancelled."));
        }
        let name = src.file_name().ok_or_else(|| io::Error::other("The source has no name."))?;
        *self.p.current.lock().unwrap() = name.to_string_lossy().into_owned();
        let mut target = dest_dir.join(name);
        if exists_nofollow(&target) {
            if src.parent().is_some_and(|dir| same_dir(dir, dest_dir)) {
                if self.p.kind == JobKind::Move {
                    self.p.add_done(tree_size(src));
                    return Ok(());
                }
                target = unique_dest(dest_dir, name, is_real_dir(src));
            } else if is_real_dir(src) && is_real_dir(&target) {
                return self.merge(src, &target);
            } else {
                match self.resolve(src, &target)? {
                    Resolution::Skip => {
                        self.p.add_done(tree_size(src));
                        return Ok(());
                    }
                    Resolution::KeepBoth => target = unique_dest(dest_dir, name, is_real_dir(src)),
                    Resolution::Replace => return self.replace(src, &target),
                }
            }
        }
        self.place(src, &target)
    }

    // two folders with one name join, and only files that clash are asked about
    fn merge(&mut self, src: &Path, target: &Path) -> io::Result<()> {
        let children = fs::read_dir(src)?.collect::<io::Result<Vec<_>>>()?;
        if self.p.kind == JobKind::Move {
            self.tasks.push(Task::EndMerge(src.to_path_buf()));
        }
        for entry in children.into_iter().rev() {
            self.tasks.push(Task::Transfer { src: entry.path(), dest_dir: target.to_path_buf() });
        }
        Ok(())
    }

    // the new item lands under a staging name first, and each failure path undoes the staging
    fn replace(&mut self, src: &Path, target: &Path) -> io::Result<()> {
        if is_real_dir(target) && src.parent().is_some_and(|dir| is_within(dir, target)) {
            return Err(io::Error::other("Cannot replace a folder with something inside it."));
        }
        let staging = temp_path(target.parent().unwrap_or(Path::new(".")), target.file_name().unwrap_or_default());
        let renamed = self.p.kind == JobKind::Move && fs::rename(src, &staging).is_ok();
        if !renamed {
            let failed_before = self.p.failures.lock().unwrap().len();
            let copied = self.copy_tree(src, &staging, false);
            if copied.is_err() || self.p.failures.lock().unwrap().len() > failed_before {
                let _ = remove_tree(&staging);
                copied?;
                return Err(io::Error::other("part of it could not be copied, so the old item stays"));
            }
        }
        if let Err(e) = remove_tree(target).and_then(|()| fs::rename(&staging, target)) {
            let _ = if renamed { fs::rename(&staging, src) } else { remove_tree(&staging) };
            return Err(e);
        }
        if renamed {
            self.p.add_done(tree_size(target));
        } else if self.p.kind == JobKind::Move {
            remove_tree(src)?;
        }
        Ok(())
    }

    fn resolve(&mut self, src: &Path, target: &Path) -> io::Result<Resolution> {
        if let Some(choice) = self.sticky {
            return Ok(choice);
        }
        let (Some(from), Some(to)) = (stat_entry(src), stat_entry(target)) else {
            return Ok(Resolution::KeepBoth);
        };
        let conflict = Conflict { name: from.name.clone(), src: from, dest: to };
        let (choice, apply_all) = self.p.ask(conflict)?;
        if apply_all {
            self.sticky = Some(choice);
        }
        Ok(choice)
    }

    fn place(&mut self, src: &Path, target: &Path) -> io::Result<()> {
        if self.p.kind == JobKind::Move && fs::rename(src, target).is_ok() {
            self.p.add_done(tree_size(target));
            return Ok(());
        }
        self.copy_tree(src, target, self.p.kind == JobKind::Move)
    }

    // a move deletes each source item right after its copy, so an item that failed keeps its source
    fn copy_tree(&mut self, src: &Path, dest: &Path, delete_source: bool) -> io::Result<()> {
        let mut pending = vec![Step::Copy(src.to_path_buf(), dest.to_path_buf())];
        while let Some(step) = pending.pop() {
            match step {
                Step::Copy(src, dest) => {
                    if let Err(e) = self.copy_one(&src, &dest, delete_source, &mut pending) {
                        self.fail(&src, &e)?;
                    }
                }
                Step::Close { src, dest, meta } => {
                    keep_metadata(&dest, &meta);
                    if delete_source {
                        match fs::remove_dir(&src) {
                            Err(e) if e.kind() != io::ErrorKind::DirectoryNotEmpty => self.fail(&src, &e)?,
                            _ => {}
                        }
                    }
                }
            }
        }
        Ok(())
    }

    fn copy_one(&mut self, src: &Path, dest: &Path, delete_source: bool, pending: &mut Vec<Step>) -> io::Result<()> {
        let meta = fs::symlink_metadata(src)?;
        if meta.is_dir() {
            fs::create_dir(dest)?;
            pending.push(Step::Close { src: src.to_path_buf(), dest: dest.to_path_buf(), meta });
            let children = fs::read_dir(src)?.collect::<io::Result<Vec<_>>>()?;
            for entry in children.into_iter().rev() {
                pending.push(Step::Copy(entry.path(), dest.join(entry.file_name())));
            }
            return Ok(());
        }
        if meta.file_type().is_symlink() {
            copy_symlink(src, dest)?;
            self.p.add_done(meta.len());
        } else if meta.is_file() {
            copy_file(self.p, src, dest)?;
        } else {
            // opening a pipe for reading blocks until a writer comes, so pipes, sockets and devices are skipped
            return Err(io::Error::new(io::ErrorKind::Unsupported, "it is not a regular file"));
        }
        if delete_source {
            fs::remove_file(src)?;
        }
        Ok(())
    }
}

enum Step {
    Copy(PathBuf, PathBuf),
    // runs after the children, so a read only folder gets its mode only once it is full
    Close { src: PathBuf, dest: PathBuf, meta: fs::Metadata },
}

// a drive that cannot hold modes or times still gets the data, so errors here are ignored
fn keep_metadata(dest: &Path, meta: &fs::Metadata) {
    if let Ok(times) = file_times(meta) {
        let _ = open_for_times(dest).and_then(|f| f.set_times(times));
    }
    let _ = fs::set_permissions(dest, meta.permissions());
}

fn file_times(meta: &fs::Metadata) -> io::Result<fs::FileTimes> {
    let times = fs::FileTimes::new().set_modified(meta.modified()?);
    Ok(match meta.accessed() {
        Ok(at) => times.set_accessed(at),
        Err(_) => times,
    })
}

#[cfg(windows)]
fn open_for_times(path: &Path) -> io::Result<File> {
    use std::os::windows::fs::OpenOptionsExt;
    const FILE_WRITE_ATTRIBUTES: u32 = 0x100;
    const FILE_FLAG_BACKUP_SEMANTICS: u32 = 0x0200_0000;
    fs::OpenOptions::new().access_mode(FILE_WRITE_ATTRIBUTES).custom_flags(FILE_FLAG_BACKUP_SEMANTICS).open(path)
}

#[cfg(not(windows))]
fn open_for_times(path: &Path) -> io::Result<File> {
    File::open(path)
}

fn is_real_dir(path: &Path) -> bool {
    fs::symlink_metadata(path).is_ok_and(|m| m.is_dir())
}

fn tree_size(path: &Path) -> u64 {
    let mut total = 0;
    let mut pending = vec![path.to_path_buf()];
    while let Some(path) = pending.pop() {
        match fs::symlink_metadata(&path) {
            Ok(m) if m.is_dir() => {
                if let Ok(rd) = fs::read_dir(&path) {
                    pending.extend(rd.filter_map(Result::ok).map(|e| e.path()));
                }
            }
            Ok(m) => total += m.len(),
            Err(_) => {}
        }
    }
    total
}

#[cfg(unix)]
fn copy_symlink(src: &Path, dest: &Path) -> io::Result<()> {
    const EPERM: i32 = 1;
    std::os::unix::fs::symlink(fs::read_link(src)?, dest).map_err(|e| match e.raw_os_error() {
        Some(EPERM) => io::Error::new(io::ErrorKind::Unsupported, "the drive cannot hold links"),
        _ => e,
    })
}

#[cfg(not(unix))]
fn copy_symlink(src: &Path, dest: &Path) -> io::Result<()> {
    fs::copy(src, dest).map(|_| ())
}

// the bytes go to a temporary name first, so a crash or an error never leaves a short file under the real name
fn copy_file(p: &Progress, src: &Path, dest: &Path) -> io::Result<()> {
    let mut input = File::open(src)?;
    let part = temp_path(dest.parent().unwrap_or(Path::new(".")), dest.file_name().unwrap_or_default());
    let result = write_part(p, &mut input, &part).and_then(|()| {
        if exists_nofollow(dest) {
            return Err(io::Error::from(io::ErrorKind::AlreadyExists));
        }
        fs::rename(&part, dest)
    });
    if result.is_err() {
        let _ = fs::remove_file(&part);
    }
    result
}

fn write_part(p: &Progress, input: &mut File, part: &Path) -> io::Result<()> {
    let mut output = File::create_new(part)?;
    let mut buf = vec![0u8; 1 << 20];
    loop {
        if p.cancel.load(Ordering::Relaxed) {
            return Err(io::Error::other("Cancelled."));
        }
        let n = input.read(&mut buf)?;
        if n == 0 {
            break;
        }
        output.write_all(&buf[..n])?;
        p.add_done(n as u64);
    }
    let meta = input.metadata()?;
    if let Ok(times) = file_times(&meta) {
        let _ = output.set_times(times);
    }
    let _ = output.set_permissions(meta.permissions());
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

    const ASK: Policy = Policy::Ask;

    fn wait(p: &Progress) -> JobState {
        let start = Instant::now();
        while p.state() == JobState::Running {
            assert!(start.elapsed() < Duration::from_secs(10), "job finished in time");
            thread::sleep(Duration::from_millis(5));
        }
        p.state()
    }

    fn wait_for_conflict(p: &Progress) -> Conflict {
        let start = Instant::now();
        loop {
            if let Some(c) = p.pending_conflict() {
                return c;
            }
            assert_ne!(p.state(), JobState::Done, "job ended without asking");
            assert!(start.elapsed() < Duration::from_secs(10), "conflict arrived in time");
            thread::sleep(Duration::from_millis(5));
        }
    }

    fn read(path: impl AsRef<Path>) -> String {
        fs::read_to_string(path).unwrap()
    }

    fn names_in(dir: &Path) -> Vec<String> {
        let mut out: Vec<String> = fs::read_dir(dir).unwrap().map(|e| e.unwrap().file_name().to_string_lossy().into_owned()).collect();
        out.sort();
        out
    }

    // src/a.txt holds "new" and out/a.txt holds "old"
    fn clash() -> (tempfile::TempDir, PathBuf, PathBuf) {
        let tmp = tempfile::tempdir().unwrap();
        let src = tmp.path().join("src");
        let out = tmp.path().join("out");
        fs::create_dir_all(&src).unwrap();
        fs::create_dir_all(&out).unwrap();
        fs::write(src.join("a.txt"), "new").unwrap();
        fs::write(out.join("a.txt"), "old").unwrap();
        (tmp, src, out)
    }

    // returns None when this user can read a mode 000 file anyway
    #[cfg(unix)]
    fn unreadable(path: &Path) -> Option<()> {
        use std::os::unix::fs::PermissionsExt;
        fs::write(path, "secret").unwrap();
        fs::set_permissions(path, fs::Permissions::from_mode(0o000)).unwrap();
        File::open(path).is_err().then_some(())
    }

    #[cfg(unix)]
    #[test]
    fn one_failing_item_does_not_stop_the_job_and_is_named() {
        let tmp = tempfile::tempdir().unwrap();
        let src = tmp.path().join("src");
        fs::create_dir_all(src.join("sub")).unwrap();
        fs::write(src.join("ok.txt"), "ok").unwrap();
        let Some(()) = unreadable(&src.join("sub/locked.txt")) else { return };
        fs::write(src.join("sub/later.txt"), "later").unwrap();
        fs::write(src.join("zz_last.txt"), "last").unwrap();
        let out = tmp.path().join("out");
        fs::create_dir(&out).unwrap();
        let list = vec![src.join("ok.txt"), src.join("sub"), src.join("zz_last.txt")];
        let p = spawn(JobKind::Copy, list, out.clone(), ASK);
        let JobState::Failed(text) = wait(&p) else { panic!("the job reports the failure") };
        assert!(text.contains("\"locked.txt\""), "the error names the file: {text}");
        assert_eq!(names_in(&out), ["ok.txt", "sub", "zz_last.txt"]);
        assert_eq!(names_in(&out.join("sub")), ["later.txt"]);
        let failed: Vec<PathBuf> = p.failures().into_iter().map(|f| f.path).collect();
        assert_eq!(failed, [src.join("sub/locked.txt")]);
    }

    // a temp folder on another drive than the default one, or None when the machine has one drive
    #[cfg(unix)]
    fn other_drive(here: &Path) -> Option<tempfile::TempDir> {
        use std::os::unix::fs::MetadataExt;
        let base = Path::new(env!("CARGO_MANIFEST_DIR")).join("target");
        fs::create_dir_all(&base).unwrap();
        let there = tempfile::tempdir_in(&base).unwrap();
        let dev = |p: &Path| fs::metadata(p).unwrap().dev();
        if dev(here) == dev(there.path()) {
            eprintln!("skipped a case: the two temp folders are on one drive");
            return None;
        }
        Some(there)
    }

    #[cfg(unix)]
    #[test]
    fn a_replace_that_cannot_remove_the_old_item_keeps_the_source_and_leaves_no_hidden_item() {
        use std::os::unix::fs::PermissionsExt;
        let set_mode = |p: &Path, m| fs::set_permissions(p, fs::Permissions::from_mode(m)).unwrap();
        for (kind, far) in [(JobKind::Copy, false), (JobKind::Move, false), (JobKind::Move, true)] {
            let here = tempfile::tempdir().unwrap();
            let far_dir = if far { other_drive(here.path()) } else { None };
            if far && far_dir.is_none() {
                continue;
            }
            let src = here.path().join("src");
            fs::create_dir(&src).unwrap();
            fs::write(src.join("a"), "new").unwrap();
            let out = far_dir.as_ref().map_or(here.path(), |d| d.path()).join("out");
            fs::create_dir_all(out.join("a/ro")).unwrap();
            fs::write(out.join("a/ro/f"), "old").unwrap();
            set_mode(&out.join("a/ro"), 0o555);
            if fs::write(out.join("a/ro/probe"), "").is_ok() {
                return;
            }
            let p = spawn(kind, vec![src.join("a")], out.clone(), Policy::Always(Resolution::Replace));
            let JobState::Failed(text) = wait(&p) else { panic!("the replace fails") };
            assert!(text.contains("\"a\""), "the error names the item: {text}");
            assert_eq!(read(src.join("a")), "new", "{kind:?} keeps the source");
            assert_eq!(names_in(&out), ["a"], "no hidden staging item stays");
            set_mode(&out.join("a/ro"), 0o755);
        }
    }

    #[cfg(unix)]
    #[test]
    fn a_move_to_another_drive_keeps_each_source_item_it_could_not_copy() {
        let here = tempfile::tempdir().unwrap();
        let Some(there) = other_drive(here.path()) else { return };
        let src = here.path().join("d");
        fs::create_dir_all(src.join("sub")).unwrap();
        fs::write(src.join("a.txt"), "a").unwrap();
        fs::write(src.join("sub/b.txt"), "b").unwrap();
        let Some(()) = unreadable(&src.join("sub/locked.txt")) else { return };
        let p = spawn(JobKind::Move, vec![src.clone()], there.path().to_path_buf(), ASK);
        assert!(matches!(wait(&p), JobState::Failed(_)));
        assert_eq!(names_in(&src), ["sub"], "only the folder that holds the failed file stays");
        assert_eq!(names_in(&src.join("sub")), ["locked.txt"]);
        assert_eq!(read(there.path().join("d/a.txt")), "a");
        assert_eq!(read(there.path().join("d/sub/b.txt")), "b");
    }

    #[cfg(unix)]
    #[test]
    fn a_pipe_or_socket_is_skipped_and_reported_without_a_hang() {
        let tmp = tempfile::tempdir().unwrap();
        let src = tmp.path().join("src");
        fs::create_dir(&src).unwrap();
        fs::write(src.join("a.txt"), "a").unwrap();
        let made = std::process::Command::new("mkfifo").arg(src.join("pipe")).status().unwrap();
        assert!(made.success());
        let _socket = std::os::unix::net::UnixListener::bind(src.join("sock")).unwrap();
        fs::write(src.join("z.txt"), "z").unwrap();
        let out = tmp.path().join("out");
        fs::create_dir(&out).unwrap();
        let p = spawn(JobKind::Copy, vec![src.clone()], out.clone(), ASK);
        assert!(matches!(wait(&p), JobState::Failed(_)));
        assert_eq!(names_in(&out.join("src")), ["a.txt", "z.txt"]);
        let mut failed: Vec<PathBuf> = p.failures().into_iter().map(|f| f.path).collect();
        failed.sort();
        assert_eq!(failed, [src.join("pipe"), src.join("sock")]);
    }

    // reading /proc/self/mem at offset 0 fails, so it stands in for a disk error in the middle of a copy
    #[cfg(target_os = "linux")]
    #[test]
    fn a_copy_that_fails_midway_leaves_no_file_under_the_final_name() {
        let tmp = tempfile::tempdir().unwrap();
        let p = spawn(JobKind::Copy, vec![PathBuf::from("/proc/self/mem")], tmp.path().to_path_buf(), ASK);
        assert!(matches!(wait(&p), JobState::Failed(_)));
        assert!(names_in(tmp.path()).is_empty(), "no partial file and no temporary file stays");
    }

    #[cfg(unix)]
    #[test]
    fn a_copy_keeps_folder_and_file_modes_and_times() {
        use std::os::unix::fs::PermissionsExt;
        let mode = |p: &Path| fs::metadata(p).unwrap().permissions().mode() & 0o777;
        let mtime = |p: &Path| fs::metadata(p).unwrap().modified().unwrap();
        let old = std::time::UNIX_EPOCH + Duration::from_secs(1_577_934_245);
        let tmp = tempfile::tempdir().unwrap();
        let src = tmp.path().join("src");
        fs::create_dir_all(src.join("priv")).unwrap();
        fs::create_dir_all(src.join("ro")).unwrap();
        fs::write(src.join("priv/s.txt"), "secret").unwrap();
        fs::write(src.join("ro/f.txt"), "f").unwrap();
        File::options().write(true).open(src.join("priv/s.txt")).unwrap().set_modified(old).unwrap();
        fs::set_permissions(src.join("priv/s.txt"), fs::Permissions::from_mode(0o600)).unwrap();
        File::open(src.join("priv")).unwrap().set_modified(old).unwrap();
        fs::set_permissions(src.join("priv"), fs::Permissions::from_mode(0o700)).unwrap();
        fs::set_permissions(src.join("ro"), fs::Permissions::from_mode(0o555)).unwrap();
        let out = tmp.path().join("out");
        fs::create_dir(&out).unwrap();
        let p = spawn(JobKind::Copy, vec![src.join("priv"), src.join("ro")], out.clone(), ASK);
        assert_eq!(wait(&p), JobState::Done);
        assert_eq!((mode(&out.join("priv")), mode(&out.join("priv/s.txt"))), (0o700, 0o600));
        assert_eq!((mtime(&out.join("priv")), mtime(&out.join("priv/s.txt"))), (old, old));
        assert_eq!(mode(&out.join("ro")), 0o555);
        assert_eq!(read(out.join("ro/f.txt")), "f");
        fs::set_permissions(out.join("ro"), fs::Permissions::from_mode(0o755)).unwrap();
        fs::set_permissions(src.join("ro"), fs::Permissions::from_mode(0o755)).unwrap();
    }

    #[test]
    fn a_missing_destination_fails_the_job_before_it_touches_anything() {
        let (tmp, src, _out) = clash();
        let p = spawn(JobKind::Move, vec![src.join("a.txt")], tmp.path().join("gone"), ASK);
        assert_eq!(wait(&p), JobState::Failed("The destination folder does not exist.".into()));
        assert_eq!(read(src.join("a.txt")), "new");
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
        let p = spawn(JobKind::Copy, vec![src.clone()], out.clone(), ASK);
        assert_eq!(wait(&p), JobState::Done);
        assert_eq!(fs::read(out.join("src/sub/b.bin")).unwrap(), vec![2u8; 500]);
        assert_eq!(p.done_bytes.load(Ordering::Relaxed), 3500);
        assert_eq!(p.total_bytes.load(Ordering::Relaxed), 3500);
        assert!(src.exists());
    }

    #[cfg(unix)]
    #[test]
    fn progress_reaches_the_total_when_the_tree_holds_links() {
        let tmp = tempfile::tempdir().unwrap();
        let src = tmp.path().join("src");
        fs::create_dir(&src).unwrap();
        fs::write(src.join("a.bin"), vec![1u8; 100]).unwrap();
        std::os::unix::fs::symlink("a.bin", src.join("link")).unwrap();
        std::os::unix::fs::symlink("nowhere/at/all", src.join("broken")).unwrap();
        let out = tmp.path().join("out");
        fs::create_dir(&out).unwrap();
        let p = spawn(JobKind::Copy, vec![src], out, ASK);
        assert_eq!(wait(&p), JobState::Done);
        assert_eq!(p.done_bytes.load(Ordering::Relaxed), p.total_bytes.load(Ordering::Relaxed));
    }

    #[test]
    fn copies_merges_and_replaces_a_very_deep_tree() {
        const DEPTH: usize = 2000;
        let tmp = tempfile::tempdir().unwrap();
        let chain = "a/".repeat(DEPTH);
        let src = tmp.path().join("s");
        fs::create_dir_all(src.join(&chain)).unwrap();
        fs::write(src.join(&chain).join("leaf.txt"), "deep").unwrap();
        let out = tmp.path().join("o");
        fs::create_dir(&out).unwrap();
        let p = spawn(JobKind::Copy, vec![src.clone()], out.clone(), ASK);
        assert_eq!(wait(&p), JobState::Done);
        assert_eq!(read(out.join("s").join(&chain).join("leaf.txt")), "deep");
        let p = spawn(JobKind::Copy, vec![src.clone()], out.clone(), Policy::Always(Resolution::Skip));
        assert_eq!(wait(&p), JobState::Done, "every folder merges");
        let flat = tmp.path().join("f");
        fs::create_dir(&flat).unwrap();
        fs::write(flat.join("s"), "flat").unwrap();
        let p = spawn(JobKind::Copy, vec![flat.join("s")], out.clone(), Policy::Always(Resolution::Replace));
        assert_eq!(wait(&p), JobState::Done);
        assert_eq!(read(out.join("s")), "flat");
    }

    #[test]
    fn keep_both_names_keep_the_whole_extension_and_fit_the_name_limit() {
        let tmp = tempfile::tempdir().unwrap();
        let long = format!("{}.txt", "n".repeat(250));
        fs::create_dir(tmp.path().join("v1.2")).unwrap();
        for name in ["archive.tar.gz", ".bashrc", "photo.JPG", "notes.v2", &long] {
            fs::write(tmp.path().join(name), "x").unwrap();
        }
        let list = ["v1.2", "archive.tar.gz", ".bashrc", "photo.JPG", "notes.v2", &long].iter().map(|n| tmp.path().join(n)).collect();
        let p = spawn(JobKind::Copy, list, tmp.path().to_path_buf(), ASK);
        assert_eq!(wait(&p), JobState::Done);
        let names = names_in(tmp.path());
        for want in ["v1.2 (2)", "archive (2).tar.gz", ".bashrc (2)", "photo (2).JPG", "notes (2).v2"] {
            assert!(names.iter().any(|n| n == want), "{want} is in {names:?}");
        }
        assert!(names.iter().any(|n| n.ends_with(" (2).txt") && n.len() <= 255), "the long name got a short copy name");
    }

    #[test]
    fn replace_works_for_a_name_at_the_length_limit() {
        let tmp = tempfile::tempdir().unwrap();
        let long = format!("{}.txt", "m".repeat(251));
        let (src, out) = (tmp.path().join("src"), tmp.path().join("out"));
        fs::create_dir(&src).unwrap();
        fs::create_dir(&out).unwrap();
        fs::write(src.join(&long), "new").unwrap();
        fs::write(out.join(&long), "old").unwrap();
        let p = spawn(JobKind::Copy, vec![src.join(&long)], out.clone(), Policy::Always(Resolution::Replace));
        assert_eq!(wait(&p), JobState::Done);
        assert_eq!(read(out.join(&long)), "new");
        assert_eq!(names_in(&out), [long]);
    }

    #[test]
    fn copy_into_the_same_folder_keeps_both_files_without_asking() {
        let tmp = tempfile::tempdir().unwrap();
        let a = tmp.path().join("a.txt");
        fs::write(&a, "x").unwrap();
        let p = spawn(JobKind::Copy, vec![a], tmp.path().to_path_buf(), ASK);
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
        let p = spawn(JobKind::Move, vec![a.clone()], out.clone(), ASK);
        assert_eq!(wait(&p), JobState::Done);
        assert!(!a.exists());
        assert_eq!(read(out.join("a.txt")), "hello");
    }

    #[test]
    fn refuses_to_copy_a_folder_into_itself() {
        let tmp = tempfile::tempdir().unwrap();
        let dir = tmp.path().join("d");
        fs::create_dir_all(dir.join("inner")).unwrap();
        let p = spawn(JobKind::Copy, vec![dir.clone()], dir.join("inner"), ASK);
        assert!(matches!(wait(&p), JobState::Failed(_)));
    }

    #[cfg(unix)]
    #[test]
    fn refuses_to_put_a_folder_inside_itself_through_a_link() {
        for kind in [JobKind::Copy, JobKind::Move] {
            let tmp = tempfile::tempdir().unwrap();
            let real = tmp.path().join("real/d");
            fs::create_dir_all(real.join("c1")).unwrap();
            fs::write(real.join("f.txt"), "x").unwrap();
            let link = tmp.path().join("link");
            std::os::unix::fs::symlink(&real, &link).unwrap();
            let p = spawn(kind, vec![real.clone()], link.join("c1"), ASK);
            assert_eq!(wait(&p), JobState::Failed("Cannot put a folder inside itself.".into()));
            assert!(names_in(&real.join("c1")).is_empty(), "nothing was copied");
            assert_eq!(names_in(&real), ["c1", "f.txt"]);
        }
    }

    #[cfg(unix)]
    #[test]
    fn a_file_pasted_into_its_own_folder_through_a_link_is_never_lost() {
        for (kind, expect) in [(JobKind::Copy, vec!["x (2).txt", "x.txt"]), (JobKind::Move, vec!["x.txt"])] {
            let tmp = tempfile::tempdir().unwrap();
            let real = tmp.path().join("real");
            fs::create_dir(&real).unwrap();
            fs::write(real.join("x.txt"), "data").unwrap();
            let alias = tmp.path().join("alias");
            std::os::unix::fs::symlink(&real, &alias).unwrap();
            let p = spawn(kind, vec![real.join("x.txt")], alias, Policy::Always(Resolution::Replace));
            assert_eq!(wait(&p), JobState::Done);
            assert_eq!(names_in(&real), expect);
            assert_eq!(read(real.join("x.txt")), "data");
        }
    }

    #[cfg(unix)]
    #[test]
    fn a_folder_moved_into_its_own_parent_through_a_link_asks_nothing() {
        let tmp = tempfile::tempdir().unwrap();
        let real = tmp.path().join("real");
        fs::create_dir_all(real.join("d")).unwrap();
        fs::write(real.join("d/f.txt"), "data").unwrap();
        let alias = tmp.path().join("alias");
        std::os::unix::fs::symlink(&real, &alias).unwrap();
        let p = spawn(JobKind::Move, vec![real.join("d")], alias, ASK);
        assert_eq!(wait(&p), JobState::Done);
        assert_eq!(read(real.join("d/f.txt")), "data");
    }

    #[test]
    fn the_worker_waits_for_an_answer_and_replace_overwrites() {
        let (_tmp, src, out) = clash();
        let p = spawn(JobKind::Copy, vec![src.join("a.txt")], out.clone(), ASK);
        let conflict = wait_for_conflict(&p);
        assert_eq!(conflict.name, "a.txt");
        assert_eq!((conflict.src.size, conflict.dest.size), (3, 3));
        thread::sleep(Duration::from_millis(100));
        assert_eq!(p.state(), JobState::Running, "the job is paused");
        assert_eq!(read(out.join("a.txt")), "old");
        assert!(p.answer(Resolution::Replace, false));
        assert!(p.pending_conflict().is_none());
        assert_eq!(wait(&p), JobState::Done);
        assert_eq!(read(out.join("a.txt")), "new");
        assert_eq!(names_in(&out), ["a.txt"], "no staging file is left");
    }

    #[test]
    fn keep_both_adds_a_numbered_copy() {
        let (_tmp, src, out) = clash();
        let p = spawn(JobKind::Copy, vec![src.join("a.txt")], out.clone(), ASK);
        wait_for_conflict(&p);
        p.answer(Resolution::KeepBoth, false);
        assert_eq!(wait(&p), JobState::Done);
        assert_eq!(read(out.join("a.txt")), "old");
        assert_eq!(read(out.join("a (2).txt")), "new");
    }

    #[test]
    fn skip_leaves_the_target_and_still_finishes_the_progress() {
        let (_tmp, src, out) = clash();
        let p = spawn(JobKind::Copy, vec![src.join("a.txt")], out.clone(), ASK);
        wait_for_conflict(&p);
        p.answer(Resolution::Skip, false);
        assert_eq!(wait(&p), JobState::Done);
        assert_eq!(read(out.join("a.txt")), "old");
        assert_eq!(p.done_bytes.load(Ordering::Relaxed), p.total_bytes.load(Ordering::Relaxed));
    }

    #[test]
    fn each_conflict_gets_its_own_question_until_apply_all() {
        let tmp = tempfile::tempdir().unwrap();
        let src = tmp.path().join("src");
        let out = tmp.path().join("out");
        fs::create_dir_all(&src).unwrap();
        fs::create_dir_all(&out).unwrap();
        for name in ["a", "b", "c", "d"] {
            fs::write(src.join(name), format!("new {name}")).unwrap();
            fs::write(out.join(name), format!("old {name}")).unwrap();
        }
        let list = ["a", "b", "c", "d"].iter().map(|n| src.join(n)).collect();
        let p = spawn(JobKind::Copy, list, out.clone(), ASK);
        assert_eq!(wait_for_conflict(&p).name, "a");
        p.answer(Resolution::Replace, false);
        assert_eq!(wait_for_conflict(&p).name, "b");
        p.answer(Resolution::Skip, false);
        assert_eq!(wait_for_conflict(&p).name, "c");
        p.answer(Resolution::Replace, true);
        assert_eq!(wait(&p), JobState::Done);
        assert_eq!(read(out.join("a")), "new a");
        assert_eq!(read(out.join("b")), "old b");
        assert_eq!(read(out.join("c")), "new c");
        assert_eq!(read(out.join("d")), "new d", "apply all covered the last clash");
    }

    #[test]
    fn cancel_wakes_a_worker_that_waits_for_an_answer() {
        let (_tmp, src, out) = clash();
        let p = spawn(JobKind::Copy, vec![src.join("a.txt")], out.clone(), ASK);
        wait_for_conflict(&p);
        p.request_cancel();
        assert_eq!(wait(&p), JobState::Cancelled);
        assert!(p.pending_conflict().is_none());
        assert_eq!(read(out.join("a.txt")), "old");
    }

    #[test]
    fn a_late_answer_with_no_question_is_ignored() {
        let (_tmp, src, out) = clash();
        let p = spawn(JobKind::Copy, vec![src.join("a.txt")], out, Policy::Always(Resolution::Skip));
        assert_eq!(wait(&p), JobState::Done);
        assert!(!p.answer(Resolution::Replace, false));
    }

    #[test]
    fn a_fixed_policy_never_asks() {
        for (choice, old, extra) in [(Resolution::Replace, "new", false), (Resolution::Skip, "old", false), (Resolution::KeepBoth, "old", true)] {
            let (_tmp, src, out) = clash();
            let p = spawn(JobKind::Copy, vec![src.join("a.txt")], out.clone(), Policy::Always(choice));
            assert_eq!(wait(&p), JobState::Done);
            assert_eq!(read(out.join("a.txt")), old);
            assert_eq!(out.join("a (2).txt").exists(), extra);
        }
    }

    #[test]
    fn two_folders_with_one_name_merge_and_only_clashing_files_are_asked() {
        let tmp = tempfile::tempdir().unwrap();
        let src = tmp.path().join("src/d");
        let out = tmp.path().join("out");
        fs::create_dir_all(&src).unwrap();
        fs::create_dir_all(out.join("d")).unwrap();
        fs::write(src.join("x"), "new x").unwrap();
        fs::write(src.join("y"), "new y").unwrap();
        fs::write(out.join("d/x"), "old x").unwrap();
        fs::write(out.join("d/z"), "old z").unwrap();
        let p = spawn(JobKind::Copy, vec![src], out.clone(), ASK);
        assert_eq!(wait_for_conflict(&p).name, "x", "the folder itself raises no question");
        p.answer(Resolution::Replace, false);
        assert_eq!(wait(&p), JobState::Done);
        assert_eq!(names_in(&out.join("d")), ["x", "y", "z"]);
        assert_eq!(read(out.join("d/x")), "new x");
        assert_eq!(read(out.join("d/z")), "old z");
    }

    #[test]
    fn a_move_with_replace_removes_the_source() {
        let (_tmp, src, out) = clash();
        let p = spawn(JobKind::Move, vec![src.join("a.txt")], out.clone(), ASK);
        wait_for_conflict(&p);
        p.answer(Resolution::Replace, false);
        assert_eq!(wait(&p), JobState::Done);
        assert!(!src.join("a.txt").exists());
        assert_eq!(read(out.join("a.txt")), "new");
    }

    #[test]
    fn a_move_with_skip_keeps_the_source() {
        let (_tmp, src, out) = clash();
        let p = spawn(JobKind::Move, vec![src.join("a.txt")], out.clone(), ASK);
        wait_for_conflict(&p);
        p.answer(Resolution::Skip, false);
        assert_eq!(wait(&p), JobState::Done);
        assert_eq!(read(src.join("a.txt")), "new");
        assert_eq!(read(out.join("a.txt")), "old");
    }

    #[test]
    fn moving_a_merged_folder_keeps_what_was_skipped() {
        let tmp = tempfile::tempdir().unwrap();
        let src = tmp.path().join("src/d");
        let out = tmp.path().join("out");
        fs::create_dir_all(&src).unwrap();
        fs::create_dir_all(out.join("d")).unwrap();
        fs::write(src.join("x"), "new x").unwrap();
        fs::write(src.join("y"), "new y").unwrap();
        fs::write(out.join("d/x"), "old x").unwrap();
        let p = spawn(JobKind::Move, vec![src.clone()], out.clone(), Policy::Always(Resolution::Skip));
        assert_eq!(wait(&p), JobState::Done);
        assert_eq!(names_in(&src), ["x"], "the skipped file stays, the moved one is gone");
        assert_eq!(names_in(&out.join("d")), ["x", "y"]);
        assert_eq!(read(out.join("d/x")), "old x");
    }

    #[test]
    fn a_file_replaces_a_folder_and_a_folder_replaces_a_file() {
        let tmp = tempfile::tempdir().unwrap();
        let src = tmp.path().join("src");
        let out = tmp.path().join("out");
        fs::create_dir_all(src.join("n/inner")).unwrap();
        fs::write(src.join("n/inner/f"), "deep").unwrap();
        fs::write(src.join("m"), "plain").unwrap();
        fs::create_dir_all(out.join("m")).unwrap();
        fs::write(out.join("m/old"), "x").unwrap();
        fs::write(out.join("n"), "was a file").unwrap();
        let list = vec![src.join("n"), src.join("m")];
        let p = spawn(JobKind::Copy, list, out.clone(), Policy::Always(Resolution::Replace));
        assert_eq!(wait(&p), JobState::Done);
        assert_eq!(read(out.join("m")), "plain");
        assert_eq!(read(out.join("n/inner/f")), "deep");
        assert_eq!(names_in(&out), ["m", "n"]);
    }

    #[test]
    fn replace_refuses_to_delete_the_folder_that_holds_the_source() {
        let tmp = tempfile::tempdir().unwrap();
        let out = tmp.path().join("out");
        fs::create_dir_all(out.join("d")).unwrap();
        fs::write(out.join("d/d"), "keep me").unwrap();
        let p = spawn(JobKind::Copy, vec![out.join("d/d")], out.clone(), Policy::Always(Resolution::Replace));
        assert!(matches!(wait(&p), JobState::Failed(_)));
        assert_eq!(read(out.join("d/d")), "keep me");
        assert_eq!(names_in(&out), ["d"]);
    }
}
