use std::ffi::OsString;
use std::fs::{self, File};
use std::io::{self, Read, Write};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Condvar, Mutex};
use std::thread;

use crate::fs_ops::{Entry, exists_nofollow, is_within, same_dir, stat_entry, unique_dest};

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
    gate: Mutex<Gate>,
    wake: Condvar,
}

impl Progress {
    pub fn state(&self) -> JobState {
        self.state.lock().unwrap().clone()
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
        gate: Mutex::new(Gate::default()),
        wake: Condvar::new(),
    });
    let worker = Arc::clone(&progress);
    thread::spawn(move || {
        let end = match run(&worker, &sources, &dest_dir, policy) {
            Ok(()) => JobState::Done,
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
            Task::Transfer { src, dest_dir } => worker.transfer(&src, &dest_dir)?,
            Task::EndMerge(src) => {
                // the folder stays when a child was skipped
                let _ = fs::remove_dir(src);
            }
        }
    }
    Ok(())
}

impl Worker<'_> {
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
                target = unique_dest(dest_dir, name);
            } else if is_real_dir(src) && is_real_dir(&target) {
                return self.merge(src, &target);
            } else {
                match self.resolve(src, &target)? {
                    Resolution::Skip => {
                        self.p.add_done(tree_size(src));
                        return Ok(());
                    }
                    Resolution::KeepBoth => target = unique_dest(dest_dir, name),
                    Resolution::Replace => return self.replace(src, &target, name.to_owned()),
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

    // the new item lands under a staging name first so a failed copy never costs the old item
    fn replace(&mut self, src: &Path, target: &Path, name: OsString) -> io::Result<()> {
        if is_real_dir(target) && src.parent().is_some_and(|dir| is_within(dir, target)) {
            return Err(io::Error::other("Cannot replace a folder with something inside it."));
        }
        let mut staging_name = OsString::from(".");
        staging_name.push(&name);
        staging_name.push(".joyfiles-part");
        let dir = target.parent().unwrap_or(Path::new("."));
        let staging = unique_dest(dir, &staging_name);
        if let Err(e) = self.place(src, &staging) {
            let _ = remove_tree(&staging);
            return Err(e);
        }
        remove_tree(target)?;
        fs::rename(&staging, target)
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
        copy_tree(self.p, src, target)?;
        if self.p.kind == JobKind::Move {
            remove_tree(src)?;
        }
        Ok(())
    }
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

fn copy_tree(p: &Progress, src: &Path, dest: &Path) -> io::Result<()> {
    let mut pending = vec![(src.to_path_buf(), dest.to_path_buf())];
    while let Some((src, dest)) = pending.pop() {
        let meta = fs::symlink_metadata(&src)?;
        if meta.is_dir() {
            fs::create_dir(&dest)?;
            let children = fs::read_dir(&src)?.collect::<io::Result<Vec<_>>>()?;
            for entry in children.into_iter().rev() {
                pending.push((entry.path(), dest.join(entry.file_name())));
            }
        } else if meta.file_type().is_symlink() {
            copy_symlink(&src, &dest)?;
        } else {
            copy_file(p, &src, &dest)?;
        }
    }
    Ok(())
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
        p.add_done(n as u64);
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
