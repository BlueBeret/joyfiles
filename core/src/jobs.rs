use std::collections::{BTreeSet, HashMap, HashSet};
use std::fs::{self, File};
use std::io::{self, Read, Write};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Condvar, Mutex};
use std::thread;
use std::time::{Duration, Instant, SystemTime};

use crate::fs_ops::{Entry, Failure, display_name, exists_nofollow, holds_mount_point, is_mount_point, is_within, reason, remove_item, remove_temp_tree, rename_noreplace, same_dir, stat_entry, summary, unique_dest};
use crate::parts::{self, LiveJob, Owner, Role, SAFE_AGE};

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
    pub current: Mutex<PathBuf>,
    failures: Mutex<Vec<Failure>>,
    gate: Mutex<Gate>,
    wake: Condvar,
    thread: Mutex<Option<thread::JoinHandle<()>>>,
}

impl Progress {
    pub fn state(&self) -> JobState {
        self.state.lock().unwrap().clone()
    }

    // returns false when the worker still runs at the deadline, for example on a drive that stopped answering
    pub fn wait_finished(&self, deadline: Instant) -> bool {
        while self.state() == JobState::Running {
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
        current: Mutex::new(PathBuf::new()),
        failures: Mutex::new(Vec::new()),
        gate: Mutex::new(Gate::default()),
        wake: Condvar::new(),
        thread: Mutex::new(None),
    });
    let worker = Arc::clone(&progress);
    let live = LiveJob::start();
    let handle = thread::spawn(move || {
        let end = match run(&worker, &sources, &dest_dir, policy, live.owner()) {
            Ok(()) => summary(&worker.failures()).map_or(JobState::Done, JobState::Failed),
            Err(_) if worker.cancel.load(Ordering::Relaxed) => JobState::Cancelled,
            Err(e) => JobState::Failed(e.to_string()),
        };
        drop(live);
        *worker.state.lock().unwrap() = end;
    });
    *progress.thread.lock().unwrap() = Some(handle);
    progress
}

struct Worker<'a> {
    p: &'a Progress,
    owner: Owner,
    sticky: Option<Resolution>,
    // an explicit stack, so a deep merge cannot overflow the thread stack
    tasks: Vec<Task>,
    unsettled: Vec<Unsettled>,
    unsettled_bytes: u64,
    // merged source folders of a move, removed after the last batch settled
    merged: Vec<PathBuf>,
    // what this job placed, so a later item with a name that clashes on a drive that ignores case never replaces it
    created: HashSet<ItemKey>,
    // folders this job merged into, so a later item of that name never replaces them
    merged_into: HashSet<ItemKey>,
    // an open handle of each destination folder with a part inside, so a part stays reachable when the folder moves
    homes: HashMap<(u64, u64), File>,
}

#[cfg(unix)]
type ItemKey = (u64, u64);

#[cfg(unix)]
fn item_key(path: &Path) -> Option<ItemKey> {
    use std::os::unix::fs::MetadataExt;
    fs::symlink_metadata(path).ok().map(|m| (m.dev(), m.ino()))
}

// every path of a job starts at its destination, and Windows ignores case, so the lower case path names one item
#[cfg(not(unix))]
type ItemKey = String;

#[cfg(not(unix))]
fn item_key(path: &Path) -> Option<ItemKey> {
    Some(path.to_string_lossy().to_lowercase())
}

// a plain copy promises nothing on power loss, a durable copy is on the drive before an old item goes, and a move removes each source only after that
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Copying {
    Plain,
    Durable,
    Moving,
}

// what a source file looked like when its copy began, so a move keeps a source that changed after that
#[derive(Debug, Clone, PartialEq, Eq)]
struct Stamp {
    len: u64,
    modified: Option<SystemTime>,
    inode: Option<(u64, u64)>,
}

impl Stamp {
    fn of(meta: &fs::Metadata) -> Self {
        Stamp { len: meta.len(), modified: meta.modified().ok(), inode: inode_of(meta) }
    }

    fn holds_for(&self, path: &Path) -> bool {
        fs::symlink_metadata(path).is_ok_and(|meta| Stamp::of(&meta) == *self)
    }
}

// what a source was when the job copied it, so a move removes only that same item and never one that took its name
enum Original {
    File(Stamp),
    Folder(Option<(u64, u64)>),
}

impl Original {
    fn of(meta: &fs::Metadata) -> Self {
        if meta.is_dir() { Original::Folder(inode_of(meta)) } else { Original::File(Stamp::of(meta)) }
    }

    fn is_at(&self, path: &Path) -> bool {
        match self {
            Original::File(stamp) => stamp.holds_for(path),
            Original::Folder(inode) => fs::symlink_metadata(path).is_ok_and(|meta| meta.is_dir() && inode_of(&meta) == *inode),
        }
    }

    // a folder goes only when it is empty
    fn remove(&self, path: &Path) -> io::Result<()> {
        match self {
            Original::File(_) => remove_item(path),
            Original::Folder(_) => fs::remove_dir(path),
        }
    }
}

#[cfg(unix)]
fn inode_of(meta: &fs::Metadata) -> Option<(u64, u64)> {
    use std::os::unix::fs::MetadataExt;
    Some((meta.dev(), meta.ino()))
}

#[cfg(not(unix))]
fn inode_of(_meta: &fs::Metadata) -> Option<(u64, u64)> {
    None
}

// an error of a part whose folder is gone or is no longer a folder names that cause, since the source is there
fn folder_moved(e: io::Error, part: &Path) -> io::Error {
    match part.parent() {
        Some(dir) if matches!(e.kind(), io::ErrorKind::NotFound | io::ErrorKind::NotADirectory) && !dir.is_dir() => io::Error::other("the destination folder moved or went away while it was copied"),
        _ => e,
    }
}

fn changed_error() -> io::Error {
    io::Error::other("it changed while it was copied, so the original stays")
}

// a durable copy settles in batches, so a whole batch reaches the drive with one sync before any name or source changes
enum Unsettled {
    File { src: PathBuf, part: PathBuf, dest: PathBuf, stamp: Stamp, home: Option<(u64, u64)> },
    Link { src: PathBuf, dest: PathBuf, stamp: Stamp },
    // runs after the files of the folder took their names, so a read only folder gets its mode only once it is full
    Close { src: PathBuf, dest: PathBuf, meta: fs::Metadata },
}

impl Unsettled {
    fn dest(&self) -> &Path {
        match self {
            Unsettled::File { dest, .. } | Unsettled::Link { dest, .. } | Unsettled::Close { dest, .. } => dest,
        }
    }
}

// a batch ends at this many items or bytes, so a big move needs few syncs and frees source space as it goes
const SETTLE_ITEMS: usize = 1000;
const SETTLE_BYTES: u64 = 512 << 20;

// each destination folder with a part inside keeps one open handle, so a batch ends before it needs many
const MAX_HOMES: usize = 128;

const SWAP_TRIES: usize = 4;

enum Task {
    Transfer { src: PathBuf, dest_dir: PathBuf },
    // a move removes a merged source folder once its children are gone
    EndMerge(PathBuf),
}

fn run(p: &Progress, sources: &[PathBuf], dest_dir: &Path, policy: Policy, owner: Owner) -> io::Result<()> {
    if !dest_dir.is_dir() {
        return Err(io::Error::other("The destination folder does not exist."));
    }
    for src in sources {
        if is_real_dir(src) && is_within(dest_dir, src) {
            return Err(io::Error::other("Cannot put a folder inside itself."));
        }
    }
    parts::sweep(dest_dir, SAFE_AGE, &p.cancel);
    let (sources, reserved): (Vec<&PathBuf>, Vec<&PathBuf>) = sources.iter().partition(|s| !s.file_name().is_some_and(parts::is_temp_name));
    let total = sources.iter().map(|s| tree_size(s)).sum();
    p.total_bytes.store(total, Ordering::Relaxed);
    let sticky = match policy {
        Policy::Ask => None,
        Policy::Always(choice) => Some(choice),
    };
    let tasks = sources.iter().rev().map(|src| Task::Transfer { src: (*src).clone(), dest_dir: dest_dir.to_path_buf() }).collect();
    let mut worker = Worker { p, owner, sticky, tasks, unsettled: Vec::new(), unsettled_bytes: 0, merged: Vec::new(), created: HashSet::new(), merged_into: HashSet::new(), homes: HashMap::new() };
    for src in reserved {
        worker.note(src, &io::Error::other("its name is one that Joyfiles keeps for temporary items"));
    }
    let result = worker.run_tasks();
    worker.finish();
    result
}

impl Worker<'_> {
    fn run_tasks(&mut self) -> io::Result<()> {
        while let Some(task) = self.tasks.pop() {
            match task {
                Task::Transfer { src, dest_dir } => {
                    if let Err(e) = self.transfer(&src, &dest_dir) {
                        self.fail(&src, &e)?;
                    }
                }
                Task::EndMerge(src) => self.merged.push(src),
            }
            if self.batch_is_full() {
                self.settle(Copying::Moving);
            }
        }
        Ok(())
    }

    fn batch_is_full(&self) -> bool {
        self.unsettled.len() >= SETTLE_ITEMS || self.unsettled_bytes >= SETTLE_BYTES || self.homes.len() >= MAX_HOMES
    }

    // one settle covers the items of all top level items, and a merged folder goes only once its children are gone
    fn finish(&mut self) {
        if !self.unsettled.is_empty() {
            self.settle(Copying::Moving);
        }
        for src in std::mem::take(&mut self.merged) {
            // the folder stays when a child was skipped
            let _ = fs::remove_dir(src);
        }
    }

    // records the error and lets the job go on, unless the user cancelled
    fn fail(&self, path: &Path, err: &io::Error) -> io::Result<()> {
        if self.p.cancel.load(Ordering::Relaxed) {
            return Err(io::Error::other("Cancelled."));
        }
        self.note(path, err);
        Ok(())
    }

    fn note(&self, path: &Path, err: &io::Error) {
        let verb = if self.p.kind == JobKind::Move { "move" } else { "copy" };
        let message = format!("Could not {verb} \"{}\": {}.", display_name(path), reason(err));
        self.p.failures.lock().unwrap().push(Failure { path: path.to_path_buf(), message });
    }

    // the bytes of the parts reach the drive, the parts take their names, the names reach the drive, and only then does a moved source go
    fn settle(&mut self, how: Copying) {
        self.settle_batch(how);
        self.homes.clear();
    }

    fn settle_batch(&mut self, how: Copying) {
        let batch = std::mem::take(&mut self.unsettled);
        self.unsettled_bytes = 0;
        let dirs: BTreeSet<PathBuf> = batch.iter().filter_map(|u| u.dest().parent()).map(Path::to_path_buf).collect();
        if let Err(e) = sync_drives(&dirs, false) {
            for item in batch {
                match item {
                    Unsettled::File { src, part, home, .. } => {
                        self.drop_part(&part, home);
                        self.note(&src, &folder_moved(io::Error::new(e.kind(), e.to_string()), &part));
                    }
                    Unsettled::Close { dest, meta, .. } => keep_metadata(&dest, &meta),
                    Unsettled::Link { .. } => {}
                }
            }
            return;
        }
        let mut leaving = Vec::new();
        for item in batch {
            match item {
                Unsettled::File { src, part, dest, stamp, home } => match self.commit(&src, &part, &dest, home) {
                    Ok(Some(_)) => leaving.push((src, Original::File(stamp))),
                    Ok(None) => {}
                    Err(_) if self.p.cancel.load(Ordering::Relaxed) => {}
                    Err(e) => self.note(&src, &e),
                },
                Unsettled::Link { src, stamp, .. } => leaving.push((src, Original::File(stamp))),
                Unsettled::Close { src, dest, meta } => {
                    keep_metadata(&dest, &meta);
                    leaving.push((src, Original::Folder(inode_of(&meta))));
                }
            }
        }
        if let Err(e) = sync_drives(&dirs, true) {
            for (src, _) in &leaving {
                self.note(src, &e);
            }
            return;
        }
        if how != Copying::Moving {
            return;
        }
        for (src, original) in leaving {
            if !original.is_at(&src) {
                self.note(&src, &changed_error());
                continue;
            }
            // a source folder stays when a child of it was skipped or failed
            match original.remove(&src) {
                Err(e) if e.kind() != io::ErrorKind::DirectoryNotEmpty => self.note(&src, &e),
                _ => {}
            }
        }
    }

    fn transfer(&mut self, src: &Path, dest_dir: &Path) -> io::Result<()> {
        if self.p.cancel.load(Ordering::Relaxed) {
            return Err(io::Error::other("Cancelled."));
        }
        let name = src.file_name().ok_or_else(|| io::Error::other("The source has no name."))?;
        *self.p.current.lock().unwrap() = PathBuf::from(name);
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
            } else if let Some(choice) = self.held_choice(&target) {
                if choice == Resolution::Skip {
                    self.p.add_done(tree_size(src));
                    return Ok(());
                }
                target = unique_dest(dest_dir, name, is_real_dir(src));
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
        if self.p.kind == JobKind::Move && is_mount_point(src) {
            return Err(mount_point_error());
        }
        let children = fs::read_dir(src)?.collect::<io::Result<Vec<_>>>()?;
        if self.p.kind == JobKind::Move {
            self.tasks.push(Task::EndMerge(src.to_path_buf()));
        }
        if let Some(key) = item_key(target) {
            self.merged_into.insert(key);
        }
        for entry in children.into_iter().rev().filter(|e| !parts::is_temp_name(&e.file_name())) {
            self.tasks.push(Task::Transfer { src: entry.path(), dest_dir: target.to_path_buf() });
        }
        Ok(())
    }

    // the old item moves aside and goes only once the new item stands in its place, so a failure before that puts it back
    fn replace(&mut self, src: &Path, target: &Path) -> io::Result<()> {
        if is_real_dir(target) && src.parent().is_some_and(|dir| is_within(dir, target)) {
            return Err(io::Error::other("Cannot replace a folder with something inside it."));
        }
        if is_real_dir(target) && holds_mount_point(target) {
            return Err(io::Error::other("it holds a drive or a mount point, so it cannot be replaced"));
        }
        if self.p.kind == JobKind::Move {
            match self.swap_in(src, target) {
                Ok(()) => {
                    self.p.add_done(tree_size(target));
                    self.record(target);
                    return Ok(());
                }
                Err(e) => {
                    copy_instead_of_rename(src, e)?;
                    if is_real_dir(src) && holds_mount_point(src) {
                        return Err(mount_point_error());
                    }
                }
            }
        }
        // a staged copy settles on its own, so the open batch of a move settles first and keeps its meaning
        if !self.unsettled.is_empty() {
            self.settle(Copying::Moving);
        }
        let before = if self.p.kind == JobKind::Move { snapshot(src) } else { Vec::new() };
        let staging = temp_beside(target, self.owner, Role::Part);
        let failed_before = self.p.failures.lock().unwrap().len();
        let copied = self.copy_tree(src, &staging, Copying::Durable, false);
        if copied.is_err() || self.p.failures.lock().unwrap().len() > failed_before {
            let _ = remove_temp_tree(&staging);
            copied?;
            return Err(io::Error::other("part of it could not be copied, so the old item stays"));
        }
        if let Err(e) = self.swap_in(&staging, target) {
            let _ = remove_temp_tree(&staging);
            return Err(e);
        }
        self.record(target);
        self.remove_copied(before);
        Ok(())
    }

    // only what the job copied goes, and an item that changed or came new since stays, so a move never deletes data it did not copy
    fn remove_copied(&self, copied: Vec<(PathBuf, Original)>) {
        for (path, original) in copied.into_iter().rev() {
            if !original.is_at(&path) {
                // a folder that went or changed stays quiet, as it holds no bytes of its own
                if let Original::File(_) = original {
                    self.note(&path, &changed_error());
                }
                continue;
            }
            match original.remove(&path) {
                Err(e) if !matches!(e.kind(), io::ErrorKind::DirectoryNotEmpty | io::ErrorKind::NotFound) => self.note(&path, &e),
                _ => {}
            }
        }
    }

    // the old item moves aside, the new one takes its name, and the old one goes only once that name is on the drive
    fn swap_in(&self, new: &Path, target: &Path) -> io::Result<()> {
        let aside = parts::park_path(target.parent().unwrap_or(Path::new(".")), target.file_name().unwrap_or_default(), self.owner)?;
        let done = self.swap_with(new, target, &aside);
        parts::clear_hold(&aside, target);
        done
    }

    fn swap_with(&self, new: &Path, target: &Path, aside: &Path) -> io::Result<()> {
        // another job may park or remove the old item first, and then the name is free for the new item
        for _ in 0..SWAP_TRIES {
            match rename_noreplace(target, aside) {
                Ok(()) => return self.finish_swap(new, target, aside),
                Err(e) if e.kind() == io::ErrorKind::NotFound => match rename_noreplace(new, target) {
                    Ok(()) => {
                        let _ = sync_dir(target.parent().unwrap_or(Path::new(".")));
                        return Ok(());
                    }
                    Err(e) if e.kind() == io::ErrorKind::AlreadyExists => {}
                    Err(e) => return Err(e),
                },
                Err(e) => return Err(e),
            }
        }
        Err(io::Error::other("another job keeps taking the name"))
    }

    fn finish_swap(&self, new: &Path, target: &Path, aside: &Path) -> io::Result<()> {
        if let Err(e) = rename_noreplace(new, target) {
            if let Err(back) = rename_noreplace(aside, target) {
                self.surface(aside, target, "Could not put back the old", &back);
            }
            return Err(e);
        }
        let dir = target.parent().unwrap_or(Path::new("."));
        if let Err(e) = sync_dir(dir).and_then(|()| remove_temp_tree(aside)) {
            self.surface(aside, target, "Could not remove all of the old", &e);
        }
        Ok(())
    }

    // an old item that can neither go back nor go away comes back under a visible name, so it never hides on the drive
    fn surface(&self, aside: &Path, target: &Path, what: &str, err: &io::Error) {
        let rest = unique_dest(target.parent().unwrap_or(Path::new(".")), target.file_name().unwrap_or_default(), is_real_dir(aside));
        let left = if rename_noreplace(aside, &rest).is_ok() { rest } else { aside.to_path_buf() };
        let message = format!("{what} \"{}\": {}. It is now \"{}\".", display_name(target), reason(err), display_name(&left));
        self.p.failures.lock().unwrap().push(Failure { path: left, message });
    }

    // an item counts as placed by this job when it or a folder above it was, so a merge into such a folder never replaces either
    fn made_here(&self, path: &Path) -> bool {
        !self.created.is_empty() && path.ancestors().filter_map(item_key).any(|key| self.created.contains(&key))
    }

    // an item that holds data of this job is never replaced, so only Skip or a new name is left for a clash with it
    fn held_choice(&self, path: &Path) -> Option<Resolution> {
        if self.made_here(path) {
            return Some(Resolution::KeepBoth);
        }
        let merged = item_key(path).is_some_and(|key| self.merged_into.contains(&key));
        merged.then(|| if self.sticky == Some(Resolution::Skip) { Resolution::Skip } else { Resolution::KeepBoth })
    }

    fn record(&mut self, path: &Path) {
        if let Some(key) = item_key(path) {
            self.created.insert(key);
        }
    }

    // the finished part takes its name, and a name that something else took meanwhile raises the usual question
    fn commit(&mut self, src: &Path, part: &Path, dest: &Path, home: Option<(u64, u64)>) -> io::Result<Option<PathBuf>> {
        let placed = self.place_part(src, part, dest).map_err(|e| folder_moved(e, part));
        match &placed {
            Ok(Some(path)) => self.record(path),
            _ => self.drop_part(part, home),
        }
        placed
    }

    // a part goes through the open handle of its folder, which reaches it wherever that folder moved, and by its path only when no handle is known
    fn drop_part(&self, part: &Path, home: Option<(u64, u64)>) {
        match (home.and_then(|key| self.homes.get(&key)), part.file_name()) {
            (Some(folder), Some(name)) => unlink_in(folder, name),
            _ => {
                let _ = fs::remove_file(part);
            }
        }
    }

    // the handle is kept by the identity of the folder, so a new folder under the same path never takes the place of the old one
    fn keep_home(&mut self, folder: Option<File>) -> Option<(u64, u64)> {
        let folder = folder?;
        let key = inode_of(&folder.metadata().ok()?)?;
        self.homes.entry(key).or_insert(folder);
        Some(key)
    }

    fn place_part(&mut self, src: &Path, part: &Path, dest: &Path) -> io::Result<Option<PathBuf>> {
        match rename_noreplace(part, dest) {
            Err(e) if e.kind() == io::ErrorKind::AlreadyExists => {}
            done => return done.map(|()| Some(dest.to_path_buf())),
        }
        let beside = self.p.kind == JobKind::Copy && src.parent().zip(dest.parent()).is_some_and(|(a, b)| same_dir(a, b));
        let choice = match self.held_choice(dest) {
            Some(choice) => choice,
            // a copy beside its source never asks, so it takes the next free name
            None if beside => Resolution::KeepBoth,
            None => self.resolve(src, dest)?,
        };
        match choice {
            Resolution::Skip => Ok(None),
            Resolution::KeepBoth => {
                let other = unique_dest(dest.parent().unwrap_or(Path::new(".")), dest.file_name().unwrap_or_default(), false);
                rename_noreplace(part, &other).map(|()| Some(other))
            }
            Resolution::Replace => {
                // a plain copy never synced its part, and a read only part still opens for a sync
                fs::OpenOptions::new().write(true).open(part).or_else(|_| File::open(part)).and_then(|f| f.sync_all())?;
                self.swap_in(part, dest).map(|()| Some(dest.to_path_buf()))
            }
        }
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
        if self.p.kind == JobKind::Move {
            match rename_noreplace(src, target) {
                Ok(()) => {
                    self.p.add_done(tree_size(target));
                    self.record(target);
                    return Ok(());
                }
                // something took the name since the check, so the item meets the clash question again
                Err(e) if e.kind() == io::ErrorKind::AlreadyExists => {
                    let dest_dir = target.parent().unwrap_or(Path::new(".")).to_path_buf();
                    self.tasks.push(Task::Transfer { src: src.to_path_buf(), dest_dir });
                    return Ok(());
                }
                Err(e) => copy_instead_of_rename(src, e)?,
            }
        }
        self.copy_tree(src, target, if self.p.kind == JobKind::Move { Copying::Moving } else { Copying::Plain }, true)
    }

    // a move removes each source item only after its copy is on the drive, and retry sends a folder that another job made under the chosen name back to the clash rules
    fn copy_tree(&mut self, src: &Path, dest: &Path, how: Copying, retry: bool) -> io::Result<()> {
        let mut pending = vec![Step::Copy(src.to_path_buf(), dest.to_path_buf(), retry)];
        let result = self.run_steps(&mut pending, how);
        // a move leaves its batch open, so the next top level item joins it
        if how != Copying::Moving {
            self.settle(how);
        }
        // a cancel still gives each folder made so far the rights and times of its source
        for step in pending.into_iter().rev() {
            if let Step::Close { dest, meta, .. } = step {
                keep_metadata(&dest, &meta);
            }
        }
        result
    }

    fn run_steps(&mut self, pending: &mut Vec<Step>, how: Copying) -> io::Result<()> {
        while let Some(step) = pending.pop() {
            match step {
                Step::Copy(src, dest, retry) => {
                    if let Err(e) = self.copy_one(&src, &dest, how, retry, pending) {
                        self.fail(&src, &e)?;
                    }
                }
                Step::Close { src, dest, meta } => match how {
                    Copying::Plain => keep_metadata(&dest, &meta),
                    _ => self.unsettled.push(Unsettled::Close { src, dest, meta }),
                },
            }
            if self.batch_is_full() {
                self.settle(how);
            }
        }
        Ok(())
    }

    fn copy_one(&mut self, src: &Path, dest: &Path, how: Copying, retry: bool, pending: &mut Vec<Step>) -> io::Result<()> {
        let meta = fs::symlink_metadata(src)?;
        if meta.is_dir() {
            if how == Copying::Moving && is_mount_point(src) {
                return Err(mount_point_error());
            }
            match create_private_dir(dest, &meta) {
                Err(e) if retry && e.kind() == io::ErrorKind::AlreadyExists => {
                    let dest_dir = dest.parent().unwrap_or(Path::new(".")).to_path_buf();
                    self.tasks.push(Task::Transfer { src: src.to_path_buf(), dest_dir });
                    return Ok(());
                }
                made => made?,
            }
            self.record(dest);
            pending.push(Step::Close { src: src.to_path_buf(), dest: dest.to_path_buf(), meta });
            let children = fs::read_dir(src)?.collect::<io::Result<Vec<_>>>()?;
            for entry in children.into_iter().rev().filter(|e| !parts::is_temp_name(&e.file_name())) {
                pending.push(Step::Copy(entry.path(), dest.join(entry.file_name()), false));
            }
        } else if meta.file_type().is_symlink() {
            copy_symlink(src, dest)?;
            keep_link_times(dest, &meta);
            self.record(dest);
            self.p.add_done(meta.len());
            if how != Copying::Plain {
                self.unsettled.push(Unsettled::Link { src: src.to_path_buf(), dest: dest.to_path_buf(), stamp: Stamp::of(&meta) });
            }
        } else if meta.is_file() {
            let part = temp_beside(dest, self.owner, Role::Part);
            let mut folder = None;
            let written = write_copy(self.p, src, &part, how != Copying::Plain, &mut folder);
            let home = self.keep_home(folder);
            let stamp = match written {
                Ok(stamp) => stamp,
                Err(e) => {
                    self.drop_part(&part, home);
                    return Err(e);
                }
            };
            if how == Copying::Plain {
                self.commit(src, &part, dest, home)?;
            } else {
                self.unsettled_bytes += meta.len();
                self.unsettled.push(Unsettled::File { src: src.to_path_buf(), part, dest: dest.to_path_buf(), stamp, home });
            }
        } else {
            // opening a pipe for reading blocks until a writer comes, so pipes, sockets and devices are skipped
            return Err(io::Error::new(io::ErrorKind::Unsupported, "it is not a regular file"));
        }
        Ok(())
    }
}

// only a move across drives turns into copy and delete, so a rename that failed for another reason never leaves a full copy
fn copy_instead_of_rename(src: &Path, err: io::Error) -> io::Result<()> {
    if is_mount_point(src) {
        return Err(mount_point_error());
    }
    match err.kind() {
        io::ErrorKind::CrossesDevices => Ok(()),
        _ => Err(err),
    }
}

fn mount_point_error() -> io::Error {
    io::Error::other("it is a drive or a mount point, so it cannot be moved")
}

#[cfg(all(test, unix))]
const SYNC_FAILS: &str = "sync-fails-here";

#[cfg(all(test, unix))]
const SYNC_COUNTED: &str = "sync-counted-here";

#[cfg(all(test, unix))]
static SYNC_CALLS: Mutex<std::collections::BTreeMap<PathBuf, usize>> = Mutex::new(std::collections::BTreeMap::new());

#[cfg(unix)]
fn refused_in_tests(_dir: &Path) -> io::Result<()> {
    #[cfg(test)]
    if _dir.components().any(|c| c.as_os_str() == SYNC_FAILS) {
        return Err(io::Error::other("the drive did not confirm the write"));
    }
    #[cfg(test)]
    if _dir.components().any(|c| c.as_os_str() == SYNC_COUNTED) {
        *SYNC_CALLS.lock().unwrap().entry(_dir.to_path_buf()).or_default() += 1;
    }
    Ok(())
}

// one call syncs a whole Linux drive, which costs far less than one sync per file of a big batch
const SYNC_EACH_FILE: bool = !cfg!(target_os = "linux");

#[cfg(target_os = "linux")]
fn sync_drives(dirs: &BTreeSet<PathBuf>, _names: bool) -> io::Result<()> {
    use std::os::unix::fs::MetadataExt;
    let mut synced = BTreeSet::new();
    for dir in dirs {
        refused_in_tests(dir)?;
        let dev = fs::metadata(dir)?.dev();
        if synced.insert(dev) {
            syncfs_near(dir)?;
        }
    }
    Ok(())
}

// a folder without read rights cannot be opened, so the nearest folder above it on the same drive stands in
#[cfg(target_os = "linux")]
fn syncfs_near(dir: &Path) -> io::Result<()> {
    use std::os::fd::AsRawFd;
    use std::os::unix::fs::MetadataExt;
    let dev = fs::metadata(dir)?.dev();
    let mut denied = None;
    for above in dir.ancestors().take_while(|a| fs::metadata(a).is_ok_and(|m| m.dev() == dev)) {
        match File::open(above) {
            Ok(folder) if unsafe { libc::syncfs(folder.as_raw_fd()) } == 0 => return Ok(()),
            Ok(_) => return Err(io::Error::last_os_error()),
            Err(e) if e.kind() == io::ErrorKind::PermissionDenied => denied = Some(e),
            Err(e) => return Err(e),
        }
    }
    Err(denied.unwrap_or_else(|| io::Error::from(io::ErrorKind::NotFound)))
}

// each file was synced as it was written, so only the folders that got new names remain
#[cfg(not(target_os = "linux"))]
fn sync_drives(dirs: &BTreeSet<PathBuf>, names: bool) -> io::Result<()> {
    if names {
        dirs.iter().try_for_each(|dir| sync_dir(dir))?;
    }
    Ok(())
}

// a new name is on the drive only once its folder is synced, and a drive that cannot sync a folder answers EINVAL
#[cfg(unix)]
fn sync_dir(dir: &Path) -> io::Result<()> {
    refused_in_tests(dir)?;
    match File::open(dir).and_then(|f| f.sync_all()) {
        Err(e) if matches!(e.kind(), io::ErrorKind::InvalidInput | io::ErrorKind::Unsupported) => Ok(()),
        #[cfg(target_os = "linux")]
        Err(e) if e.kind() == io::ErrorKind::PermissionDenied => syncfs_near(dir),
        done => done,
    }
}

// Windows keeps folder entries in the drive journal and cannot open a folder for a sync
#[cfg(not(unix))]
fn sync_dir(_dir: &Path) -> io::Result<()> {
    Ok(())
}

enum Step {
    Copy(PathBuf, PathBuf, bool),
    // runs after the children, so a read only folder gets its mode only once it is full
    Close { src: PathBuf, dest: PathBuf, meta: fs::Metadata },
}

// a drive that cannot hold modes or times still gets the data, so errors here are ignored
fn keep_metadata(dest: &Path, meta: &fs::Metadata) {
    if let Ok(times) = file_times(meta) {
        let _ = open_for_times(dest).and_then(|f| f.set_times(times));
    }
    let _ = fs::set_permissions(dest, copy_permissions(meta));
}

// the copy belongs to whoever runs the job, so like cp it drops setuid and setgid
#[cfg(unix)]
fn copy_permissions(meta: &fs::Metadata) -> fs::Permissions {
    use std::os::unix::fs::PermissionsExt;
    fs::Permissions::from_mode(meta.permissions().mode() & 0o1777)
}

#[cfg(not(unix))]
fn copy_permissions(meta: &fs::Metadata) -> fs::Permissions {
    meta.permissions()
}

// the new item starts with no more rights for others than the source has, and the owner can still fill it
#[cfg(unix)]
fn create_private_dir(dest: &Path, meta: &fs::Metadata) -> io::Result<()> {
    use std::os::unix::fs::{DirBuilderExt, PermissionsExt};
    fs::DirBuilder::new().mode(meta.permissions().mode() & 0o777 | 0o700).create(dest)
}

#[cfg(not(unix))]
fn create_private_dir(dest: &Path, _meta: &fs::Metadata) -> io::Result<()> {
    fs::create_dir(dest)
}

#[cfg(unix)]
fn create_private_file(path: &Path, meta: &fs::Metadata) -> io::Result<File> {
    use std::os::unix::fs::{OpenOptionsExt, PermissionsExt};
    fs::OpenOptions::new().write(true).create_new(true).mode(meta.permissions().mode() & 0o777 | 0o600).open(path)
}

#[cfg(not(unix))]
fn create_private_file(path: &Path, _meta: &fs::Metadata) -> io::Result<File> {
    File::create_new(path)
}

// the link itself gets the times, never the item it points to
#[cfg(unix)]
fn keep_link_times(dest: &Path, meta: &fs::Metadata) {
    use std::os::unix::ffi::OsStrExt;
    use std::os::unix::fs::MetadataExt;
    let Ok(path) = std::ffi::CString::new(dest.as_os_str().as_bytes()) else { return };
    let stamp = |secs: i64, nanos: i64| libc::timespec { tv_sec: secs as libc::time_t, tv_nsec: nanos as libc::c_long };
    let times = [stamp(meta.atime(), meta.atime_nsec()), stamp(meta.mtime(), meta.mtime_nsec())];
    unsafe { libc::utimensat(libc::AT_FDCWD, path.as_ptr(), times.as_ptr(), libc::AT_SYMLINK_NOFOLLOW) };
}

// the new link keeps its creation time on Windows
#[cfg(not(unix))]
fn keep_link_times(_dest: &Path, _meta: &fs::Metadata) {}

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

// the folders and files of a tree in the order they were found, so each folder comes before what it holds
fn snapshot(root: &Path) -> Vec<(PathBuf, Original)> {
    let mut found = Vec::new();
    let mut pending = vec![root.to_path_buf()];
    while let Some(path) = pending.pop() {
        let Ok(meta) = fs::symlink_metadata(&path) else { continue };
        if meta.is_dir() {
            if let Ok(rd) = fs::read_dir(&path) {
                pending.extend(rd.filter_map(Result::ok).filter(|e| !parts::is_temp_name(&e.file_name())).map(|e| e.path()));
            }
        }
        found.push((path, Original::of(&meta)));
    }
    found
}

#[cfg(unix)]
fn unlink_in(home: &File, name: &std::ffi::OsStr) {
    use std::os::fd::AsRawFd;
    use std::os::unix::ffi::OsStrExt;
    if let Ok(name) = std::ffi::CString::new(name.as_bytes()) {
        unsafe { libc::unlinkat(home.as_raw_fd(), name.as_ptr(), 0) };
    }
}

// Windows keeps a folder in place while a file inside is open
#[cfg(not(unix))]
fn unlink_in(_home: &File, _name: &std::ffi::OsStr) {}

fn tree_size(path: &Path) -> u64 {
    let mut total = 0;
    let mut pending = vec![path.to_path_buf()];
    while let Some(path) = pending.pop() {
        match fs::symlink_metadata(&path) {
            Ok(m) if m.is_dir() => {
                if let Ok(rd) = fs::read_dir(&path) {
                    pending.extend(rd.filter_map(Result::ok).filter(|e| !parts::is_temp_name(&e.file_name())).map(|e| e.path()));
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

// Windows keeps file links and folder links apart, so the copy makes the same kind
#[cfg(windows)]
fn copy_symlink(src: &Path, dest: &Path) -> io::Result<()> {
    use std::os::windows::fs::{FileTypeExt, symlink_dir, symlink_file};
    let target = fs::read_link(src)?;
    if fs::symlink_metadata(src)?.file_type().is_symlink_dir() {
        symlink_dir(target, dest)
    } else {
        symlink_file(target, dest)
    }
}

fn temp_beside(item: &Path, owner: Owner, role: Role) -> PathBuf {
    parts::temp_path(item.parent().unwrap_or(Path::new(".")), item.file_name().unwrap_or_default(), owner, role)
}

// the bytes go to a part name first, so a crash or an error never leaves a short file under the real name
fn write_copy(p: &Progress, src: &Path, part: &Path, durable: bool, folder: &mut Option<File>) -> io::Result<Stamp> {
    let mut input = File::open(src)?;
    let stamp = Stamp::of(&input.metadata()?);
    write_part(p, &mut input, part, durable && SYNC_EACH_FILE, folder)?;
    Ok(stamp)
}

// a handle counts only when the part is inside that folder, so it stays the right folder even when the path moves
#[cfg(unix)]
fn holds(folder: &File, name: &std::ffi::OsStr) -> bool {
    use std::os::fd::AsRawFd;
    use std::os::unix::ffi::OsStrExt;
    let Ok(name) = std::ffi::CString::new(name.as_bytes()) else { return false };
    let mut seen = std::mem::MaybeUninit::<libc::stat>::uninit();
    unsafe { libc::fstatat(folder.as_raw_fd(), name.as_ptr(), seen.as_mut_ptr(), libc::AT_SYMLINK_NOFOLLOW) == 0 }
}

#[cfg(not(unix))]
fn holds(_folder: &File, _name: &std::ffi::OsStr) -> bool {
    false
}

// the handle opened before the part was made wins, and a folder that moved in between is found again by its path
fn holder_of(part: &Path, before: Option<File>) -> Option<File> {
    let name = part.file_name()?;
    if let Some(folder) = before.filter(|f| holds(f, name)) {
        return Some(folder);
    }
    File::open(part.parent()?).ok().filter(|f| holds(f, name))
}

fn write_part(p: &Progress, input: &mut File, part: &Path, durable: bool, folder: &mut Option<File>) -> io::Result<()> {
    let meta = input.metadata()?;
    let before = part.parent().and_then(|dir| File::open(dir).ok());
    let created = create_private_file(part, &meta);
    *folder = holder_of(part, before);
    let mut output = created?;
    if !copy_sparse(p, input, &mut output, &meta)? {
        copy_range(p, input, &mut output, u64::MAX)?;
    }
    if let Ok(times) = file_times(&meta) {
        let _ = output.set_times(times);
    }
    let _ = output.set_permissions(copy_permissions(&meta));
    if durable {
        output.sync_all()?;
    }
    Ok(())
}

// copies up to count bytes from the current positions and stops early at the end of the input
fn copy_range(p: &Progress, input: &mut File, output: &mut File, count: u64) -> io::Result<()> {
    let mut buf = vec![0u8; 1 << 20];
    let mut left = count;
    while left > 0 {
        if p.cancel.load(Ordering::Relaxed) {
            return Err(io::Error::other("Cancelled."));
        }
        let n = input.read(&mut buf[..left.min(1 << 20) as usize])?;
        if n == 0 {
            break;
        }
        output.write_all(&buf[..n])?;
        p.add_done(n as u64);
        left -= n as u64;
    }
    Ok(())
}

// a file with holes keeps them, so a sparse disk image does not fill the drive, and false asks for the plain copy
#[cfg(target_os = "linux")]
fn copy_sparse(p: &Progress, input: &mut File, output: &mut File, meta: &fs::Metadata) -> io::Result<bool> {
    use std::io::{Seek, SeekFrom};
    use std::os::fd::AsRawFd;
    use std::os::unix::fs::MetadataExt;
    if meta.blocks() * 512 >= meta.len() {
        return Ok(false);
    }
    let fd = input.as_raw_fd();
    // ENXIO means no data after the offset
    let seek = |pos: u64, whence: i32| match unsafe { libc::lseek(fd, pos as libc::off_t, whence) } {
        -1 => match io::Error::last_os_error() {
            e if e.raw_os_error() == Some(libc::ENXIO) => Ok(None),
            e => Err(e),
        },
        at => Ok(Some(at as u64)),
    };
    let (mut pos, mut copied) = (0, 0);
    while pos < meta.len() {
        let data = match seek(pos, libc::SEEK_DATA) {
            Ok(Some(data)) => data,
            Ok(None) => break,
            Err(e) if pos == 0 && e.raw_os_error() == Some(libc::EINVAL) => return Ok(false),
            Err(e) => return Err(e),
        };
        let hole = seek(data, libc::SEEK_HOLE)?.unwrap_or(meta.len()).min(meta.len());
        input.seek(SeekFrom::Start(data))?;
        output.seek(SeekFrom::Start(data))?;
        copy_range(p, input, output, hole - data)?;
        copied += hole - data;
        pos = hole;
    }
    output.set_len(meta.len())?;
    p.add_done(meta.len().saturating_sub(copied));
    Ok(true)
}

#[cfg(not(target_os = "linux"))]
fn copy_sparse(_p: &Progress, _input: &mut File, _output: &mut File, _meta: &fs::Metadata) -> io::Result<bool> {
    Ok(false)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::{Duration, Instant};

    const ASK: Policy = Policy::Ask;

    fn wait(p: &Progress) -> JobState {
        wait_up_to(p, 10)
    }

    fn wait_up_to(p: &Progress, secs: u64) -> JobState {
        let start = Instant::now();
        while p.state() == JobState::Running {
            assert!(start.elapsed() < Duration::from_secs(secs), "job finished in time");
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
    fn a_replace_of_an_old_item_with_a_read_only_folder_inside_ends_with_only_the_new_item() {
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
            assert_eq!(wait(&p), JobState::Done, "{kind:?} far={far}");
            assert_eq!(read(out.join("a")), "new");
            assert_eq!(src.join("a").exists(), kind == JobKind::Copy, "{kind:?} keeps the source only for a copy");
            assert_eq!(names_in(&out), ["a"], "no hidden item stays");
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

    #[cfg(unix)]
    #[test]
    fn a_copy_drops_setuid_and_setgid_like_cp() {
        use std::os::unix::fs::PermissionsExt;
        let mode = |p: &Path| fs::metadata(p).unwrap().permissions().mode() & 0o7777;
        let tmp = tempfile::tempdir().unwrap();
        let src = tmp.path().join("src");
        fs::create_dir(&src).unwrap();
        fs::create_dir(src.join("shared")).unwrap();
        fs::write(src.join("tool"), "x").unwrap();
        fs::set_permissions(src.join("tool"), fs::Permissions::from_mode(0o4755)).unwrap();
        fs::set_permissions(src.join("shared"), fs::Permissions::from_mode(0o2775)).unwrap();
        let out = tmp.path().join("out");
        fs::create_dir(&out).unwrap();
        let p = spawn(JobKind::Copy, vec![src.join("tool"), src.join("shared")], out.clone(), ASK);
        assert_eq!(wait(&p), JobState::Done);
        assert_eq!((mode(&out.join("tool")), mode(&out.join("shared"))), (0o755, 0o775));
    }

    // the check runs while the big file is still in flight, so it sees the rights of the unfinished items
    #[cfg(unix)]
    #[test]
    fn a_private_item_is_never_readable_by_others_while_it_is_copied() {
        use std::os::unix::fs::PermissionsExt;
        let mode = |p: &Path| fs::metadata(p).unwrap().permissions().mode() & 0o777;
        let tmp = tempfile::tempdir().unwrap();
        let src = tmp.path().join("priv");
        fs::create_dir(&src).unwrap();
        fs::write(src.join("big.bin"), vec![0u8; 256 << 20]).unwrap();
        fs::set_permissions(src.join("big.bin"), fs::Permissions::from_mode(0o600)).unwrap();
        fs::set_permissions(&src, fs::Permissions::from_mode(0o700)).unwrap();
        let out = tmp.path().join("out");
        fs::create_dir(&out).unwrap();
        let p = spawn(JobKind::Copy, vec![src], out.clone(), ASK);
        while p.done_bytes.load(Ordering::Relaxed) == 0 && p.state() == JobState::Running {
            thread::yield_now();
        }
        let dir_mode = mode(&out.join("priv"));
        let part_modes: Vec<u32> = fs::read_dir(out.join("priv")).unwrap().map(|e| mode(&e.unwrap().path())).collect();
        let in_flight = p.state() == JobState::Running;
        p.request_cancel();
        assert!(p.wait_finished(Instant::now() + Duration::from_secs(10)));
        if !in_flight {
            eprintln!("skipped: the copy ended before the check");
            return;
        }
        assert_eq!(dir_mode, 0o700, "the new folder is private from the start");
        assert!(part_modes.iter().all(|m| m & 0o077 == 0), "the unfinished file is private: {part_modes:?}");
    }

    // in tests a folder sync fails inside a folder named SYNC_FAILS, which stands in for a drive that did not confirm the write
    #[cfg(unix)]
    #[test]
    fn a_move_keeps_each_source_until_its_copy_is_on_the_drive() {
        let here = tempfile::tempdir().unwrap();
        let Some(there) = other_drive(here.path()) else { return };
        let dest = there.path().join(SYNC_FAILS);
        fs::create_dir(&dest).unwrap();
        fs::create_dir_all(here.path().join("d/sub")).unwrap();
        fs::write(here.path().join("f.txt"), "f").unwrap();
        fs::write(here.path().join("d/sub/b.txt"), "b").unwrap();
        let p = spawn(JobKind::Move, vec![here.path().join("f.txt"), here.path().join("d")], dest.clone(), ASK);
        assert!(matches!(wait(&p), JobState::Failed(_)));
        assert_eq!(read(here.path().join("f.txt")), "f", "the source stays when its copy is not confirmed");
        assert_eq!(read(here.path().join("d/sub/b.txt")), "b");
        assert_eq!(names_in(&dest), ["d"], "an unconfirmed copy never takes its name and leaves no part");
        assert!(names_in(&dest.join("d/sub")).is_empty());
    }

    // on a drive that ignores case, Case.txt and case.txt clash the same way
    #[test]
    fn a_job_never_replaces_an_item_it_placed_itself() {
        for kind in [JobKind::Copy, JobKind::Move] {
            let tmp = tempfile::tempdir().unwrap();
            let out = tmp.path().join("out");
            for (dir, text) in [("one", "first"), ("two", "second")] {
                fs::create_dir(tmp.path().join(dir)).unwrap();
                fs::write(tmp.path().join(dir).join("a.txt"), text).unwrap();
            }
            fs::create_dir(&out).unwrap();
            let list = vec![tmp.path().join("one/a.txt"), tmp.path().join("two/a.txt")];
            let p = spawn(kind, list, out.clone(), Policy::Always(Resolution::Replace));
            assert_eq!(wait(&p), JobState::Done);
            assert_eq!((read(out.join("a.txt")), read(out.join("a (2).txt"))), ("first".into(), "second".into()), "{kind:?} kept both");
        }
    }

    #[test]
    fn a_name_taken_by_another_job_while_the_copy_runs_raises_the_question() {
        let tmp = tempfile::tempdir().unwrap();
        let (src, out) = (tmp.path().join("src"), tmp.path().join("out"));
        fs::create_dir(&src).unwrap();
        fs::create_dir(&out).unwrap();
        fs::write(src.join("big.bin"), vec![7u8; 256 << 20]).unwrap();
        let p = spawn(JobKind::Copy, vec![src.join("big.bin")], out.clone(), ASK);
        while p.done_bytes.load(Ordering::Relaxed) == 0 && p.state() == JobState::Running {
            thread::yield_now();
        }
        fs::write(out.join("big.bin"), "theirs").unwrap();
        if p.state() != JobState::Running || fs::metadata(out.join("big.bin")).unwrap().len() != 6 {
            eprintln!("skipped: the copy ended before the other item came");
            return;
        }
        assert_eq!(wait_for_conflict(&p).name, "big.bin");
        p.answer(Resolution::KeepBoth, false);
        assert_eq!(wait(&p), JobState::Done);
        assert_eq!(read(out.join("big.bin")), "theirs");
        assert_eq!(fs::metadata(out.join("big (2).bin")).unwrap().len(), 256 << 20);
        assert_eq!(names_in(&out), ["big (2).bin", "big.bin"], "no part file stays");
    }

    #[test]
    fn a_job_clears_stale_leftovers_in_its_destination_but_never_one_in_use() {
        let tmp = tempfile::tempdir().unwrap();
        let out = tmp.path().join("out");
        fs::create_dir(&out).unwrap();
        let leftover = out.join(".big.bin.joyfiles-part");
        let busy = LiveJob::start();
        let in_use = parts::temp_path(&out, std::ffi::OsStr::new("busy.bin"), busy.owner(), Role::Part);
        for path in [&leftover, &in_use] {
            fs::write(path, vec![0u8; 4096]).unwrap();
            File::options().write(true).open(path).unwrap().set_modified(std::time::SystemTime::now() - 2 * SAFE_AGE).unwrap();
        }
        fs::write(tmp.path().join("a.txt"), "a").unwrap();
        let p = spawn(JobKind::Copy, vec![tmp.path().join("a.txt")], out.clone(), ASK);
        assert_eq!(wait(&p), JobState::Done);
        assert_eq!(names_in(&out), [in_use.file_name().unwrap().to_string_lossy().into_owned(), "a.txt".into()]);
    }

    #[cfg(unix)]
    #[test]
    fn a_replace_puts_the_new_item_in_place_before_it_removes_any_of_the_old_one() {
        use std::os::unix::fs::PermissionsExt;
        let tmp = tempfile::tempdir().unwrap();
        let (src, out) = (tmp.path().join("src"), tmp.path().join("out"));
        fs::create_dir_all(out.join("a/ro")).unwrap();
        fs::create_dir(&src).unwrap();
        fs::write(out.join("a/ro/f"), "x").unwrap();
        fs::set_permissions(out.join("a/ro"), fs::Permissions::from_mode(0o555)).unwrap();
        fs::write(out.join("a/g1"), "1").unwrap();
        fs::write(out.join("a/g2"), "2").unwrap();
        fs::write(src.join("a"), "NEW").unwrap();
        let p = spawn(JobKind::Copy, vec![src.join("a")], out.clone(), Policy::Always(Resolution::Replace));
        let end = wait(&p);
        if out.join("a").is_dir() {
            fs::set_permissions(out.join("a/ro"), fs::Permissions::from_mode(0o755)).unwrap();
            assert_eq!(names_in(&out.join("a")), ["g1", "g2", "ro"], "a replace that failed keeps the whole old item: {end:?}");
        } else {
            assert_eq!(end, JobState::Done);
            assert_eq!(read(out.join("a")), "NEW");
        }
        assert_eq!(names_in(&out), ["a"], "no hidden item stays");
    }

    #[test]
    fn a_moved_item_is_never_hidden_while_the_old_one_is_removed() {
        let tmp = tempfile::tempdir().unwrap();
        let (src, out) = (tmp.path().join("src"), tmp.path().join("out"));
        fs::create_dir_all(out.join("a")).unwrap();
        fs::create_dir(&src).unwrap();
        for i in 0..20000 {
            fs::write(out.join("a").join(i.to_string()), "").unwrap();
        }
        fs::write(src.join("a"), "new").unwrap();
        let p = spawn(JobKind::Move, vec![src.join("a")], out.clone(), Policy::Always(Resolution::Replace));
        while exists_nofollow(&src.join("a")) {
            assert_eq!(p.state(), JobState::Running, "the job is still busy while the source is there");
        }
        assert_eq!(fs::read_to_string(out.join("a")).ok().as_deref(), Some("new"), "the moment the source name goes, the new item has its place");
        assert_eq!(wait(&p), JobState::Done);
        assert_eq!(names_in(&out), ["a"]);
    }

    #[cfg(unix)]
    #[test]
    fn a_failed_replace_leaves_no_hidden_folder_even_with_a_read_only_folder_inside() {
        use std::os::unix::fs::PermissionsExt;
        let tmp = tempfile::tempdir().unwrap();
        let (src, out) = (tmp.path().join("src"), tmp.path().join("out"));
        fs::create_dir_all(src.join("d/ro")).unwrap();
        fs::create_dir(&out).unwrap();
        fs::write(src.join("d/ro/f"), "f").unwrap();
        fs::set_permissions(src.join("d/ro"), fs::Permissions::from_mode(0o555)).unwrap();
        fs::write(out.join("d"), "old file").unwrap();
        let Some(()) = unreadable(&src.join("d/bad")) else { return };
        let p = spawn(JobKind::Copy, vec![src.join("d")], out.clone(), Policy::Always(Resolution::Replace));
        assert!(matches!(wait(&p), JobState::Failed(_)));
        assert_eq!(read(out.join("d")), "old file");
        assert_eq!(names_in(&out), ["d"], "the staging folder is gone");
        fs::set_permissions(src.join("d/ro"), fs::Permissions::from_mode(0o755)).unwrap();
    }

    #[cfg(unix)]
    #[test]
    fn a_move_that_cannot_take_the_item_away_copies_nothing() {
        use std::os::unix::fs::PermissionsExt;
        let set_mode = |p: &Path, m| fs::set_permissions(p, fs::Permissions::from_mode(m)).unwrap();
        let tmp = tempfile::tempdir().unwrap();
        let src = tmp.path().join("src");
        fs::create_dir_all(src.join("locked_dir")).unwrap();
        fs::write(src.join("locked_dir/f"), "in a read only folder").unwrap();
        fs::create_dir_all(src.join("ro")).unwrap();
        fs::write(src.join("ro/g"), "in a read only parent").unwrap();
        set_mode(&src.join("locked_dir"), 0o555);
        set_mode(&src.join("ro"), 0o555);
        let out = tmp.path().join("out");
        fs::create_dir(&out).unwrap();
        if fs::write(src.join("ro/probe"), "").is_err() {
            for item in [src.join("locked_dir"), src.join("ro/g")] {
                let p = spawn(JobKind::Move, vec![item.clone()], out.clone(), ASK);
                assert!(matches!(wait(&p), JobState::Failed(_)), "{item:?} cannot move");
                assert!(names_in(&out).is_empty(), "nothing was copied for {item:?}");
            }
            assert_eq!(read(src.join("locked_dir/f")), "in a read only folder");
            assert_eq!(read(src.join("ro/g")), "in a read only parent");
        }
        set_mode(&src.join("locked_dir"), 0o755);
        set_mode(&src.join("ro"), 0o755);
    }

    // mounts need their own mount namespace, so the test runs itself again under unshare and skips where that is not allowed
    #[cfg(target_os = "linux")]
    #[test]
    fn a_move_never_empties_a_mount_point() {
        let Some(base) = std::env::var_os("JF_MOUNT_TEST_DIR").map(PathBuf::from) else {
            let tmp = tempfile::tempdir().unwrap();
            let name = "jobs::tests::a_move_never_empties_a_mount_point";
            let me = std::env::current_exe().unwrap();
            let run = std::process::Command::new("unshare").arg("-rm").arg(me).args(["--exact", name, "--test-threads=1"]).env("JF_MOUNT_TEST_DIR", tmp.path()).output();
            match run {
                Ok(out) if out.status.code() == Some(101) => panic!("{}", String::from_utf8_lossy(&out.stdout)),
                Ok(out) if !out.status.success() => eprintln!("skipped: no mount namespace here: {}", String::from_utf8_lossy(&out.stderr)),
                Err(e) => eprintln!("skipped: unshare did not start: {e}"),
                Ok(_) => {}
            }
            return;
        };
        let mount = |what: &Path, at: &Path, kind: Option<&str>| {
            use std::os::unix::ffi::OsStrExt;
            let c = |p: &Path| std::ffi::CString::new(p.as_os_str().as_bytes()).unwrap();
            let fstype = kind.map(|k| std::ffi::CString::new(k).unwrap());
            let flags = if kind.is_none() { libc::MS_BIND } else { 0 };
            let done = unsafe { libc::mount(c(what).as_ptr(), c(at).as_ptr(), fstype.as_ref().map_or(std::ptr::null(), |f| f.as_ptr()), flags, std::ptr::null()) };
            assert_eq!(done, 0, "mount {at:?}: {}", io::Error::last_os_error());
        };
        let data = base.join("data");
        fs::create_dir_all(data.join("sub")).unwrap();
        fs::write(data.join("p1"), "precious").unwrap();
        let (card, drive, x, out, far) = (base.join("card"), base.join("drive"), base.join("x"), base.join("out"), base.join("far"));
        for dir in [&card, &drive, &x.join("m"), &out, &far] {
            fs::create_dir_all(dir).unwrap();
        }
        fs::write(x.join("f"), "plain").unwrap();
        mount(&data, &card, None);
        mount(Path::new("none"), &drive, Some("tmpfs"));
        fs::write(drive.join("d"), "on the drive").unwrap();
        mount(&data, &x.join("m"), None);
        mount(Path::new("none"), &far, Some("tmpfs"));
        for (item, dest) in [(&card, &out), (&drive, &out), (&card, &far)] {
            let p = spawn(JobKind::Move, vec![item.clone()], dest.clone(), ASK);
            let JobState::Failed(text) = wait(&p) else { panic!("moving {item:?} fails") };
            assert_eq!(names_in(&data), ["p1", "sub"], "the mounted folder keeps its content");
            assert!(names_in(dest).is_empty(), "nothing was copied from {item:?}");
            assert!(text.contains("mount point"), "the error says why: {text}");
        }
        let p = spawn(JobKind::Move, vec![x.clone()], far.clone(), ASK);
        assert!(matches!(wait(&p), JobState::Failed(_)), "the mount inside the folder stays");
        assert_eq!(read(far.join("x/f")), "plain", "the plain file still moves");
        assert_eq!(names_in(&far.join("x")), ["f"]);
        assert_eq!(names_in(&data), ["p1", "sub"]);
        assert_eq!(read(drive.join("d")), "on the drive");
        fs::write(base.join("x2"), "plain file").unwrap();
        fs::create_dir(out.join("x")).unwrap();
        fs::rename(&x, out.join("x2")).unwrap();
        for kind in [JobKind::Copy, JobKind::Move] {
            let p = spawn(kind, vec![base.join("x2")], out.clone(), Policy::Always(Resolution::Replace));
            assert!(matches!(wait(&p), JobState::Failed(_)), "{kind:?} does not replace a folder that holds a mount");
            assert_eq!(names_in(&data), ["p1", "sub"], "the mounted folder keeps its content");
            assert_eq!(names_in(&out.join("x2")), ["m"], "the old folder stays whole");
        }
    }

    #[cfg(unix)]
    fn mode_and_mtime(p: &Path) -> (u32, std::time::SystemTime) {
        use std::os::unix::fs::PermissionsExt;
        let meta = fs::metadata(p).unwrap();
        (meta.permissions().mode() & 0o777, meta.modified().unwrap())
    }

    #[cfg(unix)]
    #[test]
    fn a_cancelled_copy_still_gives_its_new_folders_the_rights_and_times_of_the_source() {
        use std::os::unix::fs::PermissionsExt;
        let tmp = tempfile::tempdir().unwrap();
        let src = tmp.path().join("ro");
        fs::create_dir(&src).unwrap();
        fs::write(src.join("big.bin"), vec![0u8; 256 << 20]).unwrap();
        File::open(&src).unwrap().set_modified(std::time::UNIX_EPOCH + Duration::from_secs(1_577_934_245)).unwrap();
        fs::set_permissions(&src, fs::Permissions::from_mode(0o555)).unwrap();
        let out = tmp.path().join("out");
        fs::create_dir(&out).unwrap();
        let p = spawn(JobKind::Copy, vec![src.clone()], out.clone(), ASK);
        while p.done_bytes.load(Ordering::Relaxed) == 0 && p.state() == JobState::Running {
            thread::yield_now();
        }
        p.request_cancel();
        assert!(p.wait_finished(Instant::now() + Duration::from_secs(10)));
        if p.state() != JobState::Cancelled {
            eprintln!("skipped: the copy ended before the cancel");
            return;
        }
        assert_eq!(mode_and_mtime(&out.join("ro")), mode_and_mtime(&src));
        fs::set_permissions(&src, fs::Permissions::from_mode(0o755)).unwrap();
    }

    #[cfg(unix)]
    #[test]
    fn a_merge_leaves_the_rights_and_the_time_of_the_existing_folder_alone() {
        use std::os::unix::fs::PermissionsExt;
        for kind in [JobKind::Copy, JobKind::Move] {
            let tmp = tempfile::tempdir().unwrap();
            let src = tmp.path().join("src/d");
            fs::create_dir_all(&src).unwrap();
            fs::write(src.join("f"), "f").unwrap();
            let long_ago = std::time::UNIX_EPOCH + Duration::from_secs(1_577_934_245);
            File::open(&src).unwrap().set_modified(long_ago).unwrap();
            fs::set_permissions(&src, fs::Permissions::from_mode(0o700)).unwrap();
            let out = tmp.path().join("out");
            fs::create_dir_all(out.join("d")).unwrap();
            fs::set_permissions(out.join("d"), fs::Permissions::from_mode(0o755)).unwrap();
            let p = spawn(kind, vec![src.clone()], out.clone(), ASK);
            assert_eq!(wait(&p), JobState::Done);
            let (mode, time) = mode_and_mtime(&out.join("d"));
            assert_eq!(mode, 0o755, "{kind:?} keeps the mode of the target");
            assert!(time > long_ago, "{kind:?} keeps the date of the target");
            assert_eq!(read(out.join("d/f")), "f");
        }
    }

    #[cfg(target_os = "linux")]
    #[test]
    fn a_move_by_merge_refuses_a_mount_root_and_keeps_its_files() {
        use crate::fs_ops::FAKE_MOUNT;
        let tmp = tempfile::tempdir().unwrap();
        let card = tmp.path().join("src").join(FAKE_MOUNT);
        fs::create_dir_all(&card).unwrap();
        fs::write(card.join("photo.jpg"), "precious").unwrap();
        let out = tmp.path().join("out");
        fs::create_dir_all(out.join(FAKE_MOUNT)).unwrap();
        let p = spawn(JobKind::Move, vec![card.clone()], out.clone(), ASK);
        let JobState::Failed(text) = wait(&p) else { panic!("the move is refused") };
        assert!(text.contains("a drive or a mount point"), "{text}");
        assert_eq!(read(card.join("photo.jpg")), "precious");
        assert!(names_in(&out.join(FAKE_MOUNT)).is_empty(), "nothing leaves the mount");
        let p = spawn(JobKind::Copy, vec![card.clone()], out.clone(), ASK);
        assert_eq!(wait(&p), JobState::Done, "a copy of a mount root stays allowed");
        assert_eq!(read(out.join(FAKE_MOUNT).join("photo.jpg")), "precious");
    }

    #[cfg(unix)]
    #[test]
    fn a_copy_gives_a_link_the_date_of_the_source_link() {
        let tmp = tempfile::tempdir().unwrap();
        let src = tmp.path().join("src");
        fs::create_dir(&src).unwrap();
        std::os::unix::fs::symlink("target", src.join("lnk")).unwrap();
        let old = std::ffi::CString::new(src.join("lnk").to_string_lossy().as_bytes()).unwrap();
        let stamp = libc::timespec { tv_sec: 1_577_934_245, tv_nsec: 0 };
        let set = unsafe { libc::utimensat(libc::AT_FDCWD, old.as_ptr(), [stamp, stamp].as_ptr(), libc::AT_SYMLINK_NOFOLLOW) };
        assert_eq!(set, 0);
        let out = tmp.path().join("out");
        fs::create_dir(&out).unwrap();
        let p = spawn(JobKind::Copy, vec![src.clone()], out.clone(), ASK);
        assert_eq!(wait(&p), JobState::Done);
        let time = |p: &Path| fs::symlink_metadata(p).unwrap().modified().unwrap();
        assert_eq!(time(&out.join("src/lnk")), time(&src.join("lnk")));
    }

    #[cfg(unix)]
    #[test]
    fn a_move_to_another_drive_works_into_a_folder_without_read_rights() {
        use std::os::unix::fs::PermissionsExt;
        let here = tempfile::tempdir().unwrap();
        let Some(there) = other_drive(here.path()) else { return };
        let drop = there.path().join("drop");
        fs::create_dir(&drop).unwrap();
        fs::set_permissions(&drop, fs::Permissions::from_mode(0o300)).unwrap();
        fs::write(here.path().join("f.txt"), "data").unwrap();
        let p = spawn(JobKind::Move, vec![here.path().join("f.txt")], drop.clone(), ASK);
        let state = wait(&p);
        fs::set_permissions(&drop, fs::Permissions::from_mode(0o700)).unwrap();
        assert_eq!(state, JobState::Done);
        assert_eq!(read(drop.join("f.txt")), "data");
        assert!(!here.path().join("f.txt").exists());
    }

    #[cfg(all(unix, target_os = "linux"))]
    #[test]
    fn a_move_across_drives_syncs_once_for_many_top_level_items() {
        let here = tempfile::tempdir().unwrap();
        let Some(there) = other_drive(here.path()) else { return };
        let out = there.path().join(SYNC_COUNTED);
        fs::create_dir(&out).unwrap();
        let list: Vec<PathBuf> = (0..60)
            .map(|i| {
                let file = here.path().join(format!("f{i}.txt"));
                fs::write(&file, format!("data {i}")).unwrap();
                file
            })
            .collect();
        let p = spawn(JobKind::Move, list, out.clone(), ASK);
        assert_eq!(wait(&p), JobState::Done);
        assert_eq!(fs::read_dir(&out).unwrap().count(), 60);
        assert!(fs::read_dir(here.path()).unwrap().next().is_none(), "every source went after its copy");
        let calls = SYNC_CALLS.lock().unwrap().get(&out).copied().unwrap_or(0);
        assert!((1..=4).contains(&calls), "the drive was synced {calls} times");
    }

    #[test]
    fn a_replace_of_a_file_with_the_longest_name_keeps_the_name_and_leaves_no_hidden_item() {
        let tmp = tempfile::tempdir().unwrap();
        let name = format!("{}.txt", "n".repeat(251));
        let src = tmp.path().join("src");
        let out = tmp.path().join("out");
        fs::create_dir_all(&src).unwrap();
        fs::create_dir_all(&out).unwrap();
        fs::write(src.join(&name), "new").unwrap();
        fs::write(out.join(&name), "old").unwrap();
        let p = spawn(JobKind::Copy, vec![src.join(&name)], out.clone(), Policy::Always(Resolution::Replace));
        assert_eq!(wait(&p), JobState::Done);
        assert_eq!(names_in(&out), [name.clone()]);
        assert_eq!(read(out.join(&name)), "new");
    }

    #[cfg(target_os = "linux")]
    #[test]
    fn a_sparse_file_stays_sparse_and_keeps_its_bytes() {
        use std::os::unix::fs::{FileExt, MetadataExt};
        let tmp = tempfile::tempdir().unwrap();
        let src = tmp.path().join("disk.img");
        let f = File::create(&src).unwrap();
        f.set_len(64 << 20).unwrap();
        f.write_all_at(b"head", 0).unwrap();
        f.write_all_at(b"middle", 32 << 20).unwrap();
        if fs::metadata(&src).unwrap().blocks() * 512 >= 64 << 20 {
            eprintln!("skipped: this drive does not keep holes");
            return;
        }
        let out = tmp.path().join("out");
        fs::create_dir(&out).unwrap();
        let p = spawn(JobKind::Copy, vec![src.clone()], out.clone(), ASK);
        assert_eq!(wait(&p), JobState::Done);
        let used = fs::metadata(out.join("disk.img")).unwrap().blocks() * 512;
        assert!(used < 4 << 20, "the copy uses {used} bytes on the drive");
        assert!(fs::read(out.join("disk.img")).unwrap() == fs::read(&src).unwrap(), "the bytes are the same");
        assert_eq!(p.done_bytes.load(Ordering::Relaxed), p.total_bytes.load(Ordering::Relaxed));
    }

    #[test]
    fn a_job_cancelled_midway_leaves_nothing_once_its_worker_has_finished() {
        let tmp = tempfile::tempdir().unwrap();
        fs::write(tmp.path().join("big.bin"), vec![0u8; 64 << 20]).unwrap();
        let out = tmp.path().join("out");
        fs::create_dir(&out).unwrap();
        let p = spawn(JobKind::Copy, vec![tmp.path().join("big.bin")], out.clone(), ASK);
        while p.done_bytes.load(Ordering::Relaxed) == 0 && p.state() == JobState::Running {
            thread::yield_now();
        }
        p.request_cancel();
        assert!(p.wait_finished(Instant::now() + Duration::from_secs(10)));
        assert_eq!(p.state(), JobState::Cancelled);
        assert!(names_in(&out).is_empty(), "the temporary file is gone");
    }

    #[cfg(windows)]
    #[test]
    fn links_copy_as_links_and_a_folder_link_can_be_replaced_on_windows() {
        use std::os::windows::fs::{symlink_dir, symlink_file};
        let tmp = tempfile::tempdir().unwrap();
        let src = tmp.path().join("src");
        fs::create_dir_all(src.join("sub")).unwrap();
        fs::write(src.join("f.txt"), "f").unwrap();
        if symlink_file("f.txt", src.join("flink")).is_err() {
            eprintln!("skipped: this user cannot make links");
            return;
        }
        symlink_dir("sub", src.join("dlink")).unwrap();
        symlink_file("nowhere.txt", src.join("broken")).unwrap();
        let out = tmp.path().join("out");
        fs::create_dir(&out).unwrap();
        let p = spawn(JobKind::Copy, vec![src.clone()], out.clone(), ASK);
        assert_eq!(wait_up_to(&p, 180), JobState::Done);
        for name in ["flink", "dlink", "broken"] {
            assert!(fs::symlink_metadata(out.join("src").join(name)).unwrap().file_type().is_symlink(), "{name} stays a link");
        }
        fs::write(tmp.path().join("dlink"), "plain").unwrap();
        let p = spawn(JobKind::Copy, vec![tmp.path().join("dlink")], out.join("src"), Policy::Always(Resolution::Replace));
        assert_eq!(wait_up_to(&p, 180), JobState::Done, "a file replaces a folder link");
        assert_eq!(read(out.join("src/dlink")), "plain");
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

    // Windows finds a folder by any case of its name, so the check must compare the folders and not their path text
    #[cfg(windows)]
    #[test]
    fn refuses_to_copy_a_folder_into_itself_through_a_path_in_other_case() {
        let tmp = tempfile::tempdir().unwrap();
        let dir = tmp.path().join("Data");
        fs::create_dir_all(dir.join("sub")).unwrap();
        let into = tmp.path().join("data").join("SUB");
        assert!(into.is_dir(), "the drive ignores case");
        let p = spawn(JobKind::Copy, vec![dir.clone()], into, ASK);
        assert_eq!(wait(&p), JobState::Failed("Cannot put a folder inside itself.".into()));
        assert!(names_in(&dir.join("sub")).is_empty(), "nothing was copied");
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

    #[test]
    fn a_copy_never_removes_an_empty_source_folder_it_merged() {
        let tmp = tempfile::tempdir().unwrap();
        let src = tmp.path().join("src");
        let out = tmp.path().join("out");
        fs::create_dir_all(src.join("empty")).unwrap();
        fs::create_dir_all(src.join("tree/inner")).unwrap();
        fs::create_dir_all(out.join("empty")).unwrap();
        fs::create_dir_all(out.join("tree/inner")).unwrap();
        let p = spawn(JobKind::Copy, vec![src.join("empty"), src.join("tree")], out.clone(), Policy::Always(Resolution::Skip));
        assert_eq!(wait(&p), JobState::Done);
        assert!(src.join("empty").is_dir() && src.join("tree/inner").is_dir());
    }

    #[test]
    fn a_folder_and_a_file_of_one_name_never_destroy_the_files_the_folder_merged() {
        for kind in [JobKind::Move, JobKind::Copy] {
            for choice in [Resolution::Replace, Resolution::KeepBoth, Resolution::Skip] {
                let tmp = tempfile::tempdir().unwrap();
                let (s0, s1, out) = (tmp.path().join("s0"), tmp.path().join("s1"), tmp.path().join("out"));
                fs::create_dir_all(s0.join("h")).unwrap();
                fs::create_dir_all(&s1).unwrap();
                fs::create_dir_all(out.join("h")).unwrap();
                fs::write(s0.join("h/photo.jpg"), "photo").unwrap();
                fs::write(s1.join("h"), "file").unwrap();
                fs::write(out.join("h/old.txt"), "old").unwrap();
                let p = spawn(kind, vec![s0.join("h"), s1.join("h")], out.clone(), Policy::Always(choice));
                assert_eq!(wait(&p), JobState::Done, "{kind:?} {choice:?}");
                assert_eq!(read(out.join("h/photo.jpg")), "photo", "{kind:?} {choice:?}");
                assert_eq!(read(out.join("h/old.txt")), "old", "{kind:?} {choice:?}");
                if choice == Resolution::Skip {
                    assert_eq!(names_in(&out), ["h"]);
                    assert_eq!(read(s1.join("h")), "file");
                } else {
                    let kept = names_in(&out).into_iter().filter(|n| n != "h").map(|n| read(out.join(n))).collect::<Vec<_>>();
                    assert_eq!(kept, ["file"], "{kind:?} {choice:?} the file stays under a new name");
                }
            }
        }
    }

    #[test]
    fn a_file_before_a_folder_of_one_name_keeps_both() {
        let tmp = tempfile::tempdir().unwrap();
        let (s0, s1, out) = (tmp.path().join("s0"), tmp.path().join("s1"), tmp.path().join("out"));
        fs::create_dir_all(s0.join("h")).unwrap();
        fs::create_dir_all(&s1).unwrap();
        fs::create_dir_all(out.join("h")).unwrap();
        fs::write(s0.join("h/photo.jpg"), "photo").unwrap();
        fs::write(s1.join("h"), "file").unwrap();
        let p = spawn(JobKind::Copy, vec![s1.join("h"), s0.join("h")], out.clone(), Policy::Always(Resolution::Replace));
        assert_eq!(wait(&p), JobState::Done);
        assert_eq!(names_in(&out).len(), 2, "the reverse order keeps both too");
    }

    #[cfg(unix)]
    #[test]
    fn a_replace_over_a_name_race_works_for_a_read_only_part() {
        use std::os::unix::fs::PermissionsExt;
        let tmp = tempfile::tempdir().unwrap();
        let out = tmp.path().join("out");
        fs::create_dir_all(&out).unwrap();
        let part = out.join(".x.joyfiles-part");
        fs::write(&part, "new").unwrap();
        fs::set_permissions(&part, fs::Permissions::from_mode(0o444)).unwrap();
        fs::write(out.join("x"), "racer").unwrap();
        let p = spawn(JobKind::Copy, vec![], out.clone(), Policy::Always(Resolution::Replace));
        assert_eq!(wait(&p), JobState::Done);
        let live = parts::LiveJob::start();
        let mut worker = Worker { p: &p, owner: live.owner(), sticky: Some(Resolution::Replace), tasks: Vec::new(), unsettled: Vec::new(), unsettled_bytes: 0, merged: Vec::new(), merged_into: HashSet::new(), created: HashSet::new(), homes: HashMap::new() };
        let placed = worker.place_part(&tmp.path().join("src"), &part, &out.join("x")).unwrap();
        assert_eq!(placed, Some(out.join("x")));
        assert_eq!(read(out.join("x")), "new");
    }

    // a worker that a test drives by hand, with a job that already ended
    #[cfg(unix)]
    fn idle_job(dir: &Path) -> (Arc<Progress>, LiveJob) {
        let p = spawn(JobKind::Copy, vec![], dir.to_path_buf(), ASK);
        assert_eq!(wait(&p), JobState::Done);
        (p, LiveJob::start())
    }

    #[cfg(unix)]
    fn hand_worker<'a>(p: &'a Progress, live: &LiveJob) -> Worker<'a> {
        Worker { p, owner: live.owner(), sticky: None, tasks: Vec::new(), unsettled: Vec::new(), unsettled_bytes: 0, merged: Vec::new(), merged_into: HashSet::new(), created: HashSet::new(), homes: HashMap::new() }
    }

    #[cfg(unix)]
    #[test]
    fn a_move_keeps_a_source_that_changed_after_its_copy() {
        let tmp = tempfile::tempdir().unwrap();
        let (src, out) = (tmp.path().join("src"), tmp.path().join("out"));
        fs::create_dir_all(&src).unwrap();
        fs::create_dir_all(&out).unwrap();
        for name in ["f0", "f1", "f2"] {
            fs::write(src.join(name), "original").unwrap();
        }
        let (p, live) = idle_job(&out);
        let mut worker = hand_worker(&p, &live);
        for name in ["f0", "f1", "f2"] {
            worker.copy_tree(&src.join(name), &out.join(name), Copying::Moving, false).unwrap();
        }
        fs::write(src.join("f0.new"), "NEWVERSION").unwrap();
        fs::rename(src.join("f0.new"), src.join("f0")).unwrap();
        fs::OpenOptions::new().append(true).open(src.join("f1")).unwrap().write_all(b"APPENDED").unwrap();
        worker.finish();
        assert_eq!(read(src.join("f0")), "NEWVERSION", "a new version saved after the copy stays");
        assert_eq!(read(src.join("f1")), "originalAPPENDED", "bytes added after the copy stay");
        assert!(!src.join("f2").exists(), "a source that did not change goes");
        let failed: Vec<String> = p.failures().into_iter().map(|f| f.message).collect();
        assert_eq!(failed.len(), 2, "{failed:?}");
        assert!(failed.iter().all(|m| m.contains("changed while it was copied")), "{failed:?}");
    }

    #[cfg(unix)]
    #[test]
    fn a_staged_move_with_replace_keeps_a_source_that_changed_and_a_hidden_temporary_item() {
        let tmp = tempfile::tempdir().unwrap();
        let (src, out) = (tmp.path().join("src"), tmp.path().join("out"));
        fs::create_dir_all(src.join("d")).unwrap();
        fs::create_dir_all(out.join("d")).unwrap();
        fs::write(src.join("d/a"), "a").unwrap();
        fs::write(src.join("d/.keep.99999999-1-1-1.joyfiles-old"), "parked").unwrap();
        let (p, live) = idle_job(&out);
        let worker = hand_worker(&p, &live);
        let before = snapshot(&src.join("d"));
        assert_eq!(before.len(), 2, "the snapshot skips the temporary item");
        fs::write(src.join("d/a"), "a changed").unwrap();
        fs::write(src.join("d/late"), "late").unwrap();
        worker.remove_copied(before);
        assert_eq!(read(src.join("d/a")), "a changed");
        assert_eq!(read(src.join("d/late")), "late");
        assert!(src.join("d/.keep.99999999-1-1-1.joyfiles-old").exists());
        assert_eq!(p.failures().len(), 1);
    }

    #[cfg(unix)]
    #[test]
    fn a_part_is_removed_when_its_destination_folder_moved_before_the_name_was_taken() {
        let tmp = tempfile::tempdir().unwrap();
        let (src, dst) = (tmp.path().join("src"), tmp.path().join("dst"));
        fs::create_dir_all(&src).unwrap();
        fs::create_dir_all(&dst).unwrap();
        fs::write(src.join("big.bin"), vec![1u8; 4096]).unwrap();
        let (p, live) = idle_job(&dst);
        let mut worker = hand_worker(&p, &live);
        worker.copy_tree(&src.join("big.bin"), &dst.join("big.bin"), Copying::Moving, false).unwrap();
        let moved = tmp.path().join("dst_renamed");
        fs::rename(&dst, &moved).unwrap();
        worker.finish();
        assert!(names_in(&moved).is_empty(), "no hidden part stays in the moved folder: {:?}", names_in(&moved));
        assert!(src.join("big.bin").exists(), "the source stays");
        let failed: Vec<String> = p.failures().into_iter().map(|f| f.message).collect();
        assert!(failed.len() == 1 && failed[0].contains("moved or went away"), "{failed:?}");
    }

    // every file below root with its text, so a test sees hidden items too
    #[cfg(unix)]
    fn files_below(root: &Path) -> Vec<(String, String)> {
        let mut found = Vec::new();
        let mut pending = vec![root.to_path_buf()];
        while let Some(dir) = pending.pop() {
            for entry in fs::read_dir(&dir).unwrap().map(Result::unwrap) {
                if entry.file_type().unwrap().is_dir() {
                    pending.push(entry.path());
                } else {
                    found.push((entry.path().strip_prefix(root).unwrap().to_string_lossy().into_owned(), read(entry.path())));
                }
            }
        }
        found.sort();
        found
    }

    #[cfg(unix)]
    #[test]
    fn a_move_never_removes_a_file_that_took_the_name_of_a_copied_source_folder() {
        let tmp = tempfile::tempdir().unwrap();
        let (src, out) = (tmp.path().join("src"), tmp.path().join("out"));
        fs::create_dir_all(src.join("b/in")).unwrap();
        fs::create_dir_all(&out).unwrap();
        fs::write(src.join("b/in/x"), "x").unwrap();
        fs::write(src.join("a"), "USER").unwrap();
        let (p, live) = idle_job(&out);
        let mut worker = hand_worker(&p, &live);
        worker.copy_tree(&src.join("b"), &out.join("b"), Copying::Moving, true).unwrap();
        fs::rename(src.join("b"), src.join("zz")).unwrap();
        fs::rename(src.join("a"), src.join("b")).unwrap();
        worker.finish();
        assert_eq!(read(src.join("b")), "USER", "a file that took the name of the source folder stays");
        assert_eq!(read(src.join("zz/in/x")), "x", "the source folder that moved away keeps its files");
    }

    #[cfg(unix)]
    #[test]
    fn a_part_is_removed_when_a_file_took_the_name_of_its_destination_folder() {
        let tmp = tempfile::tempdir().unwrap();
        let (src, out) = (tmp.path().join("src"), tmp.path().join("out"));
        fs::create_dir_all(src.join("d")).unwrap();
        fs::create_dir_all(&out).unwrap();
        fs::write(src.join("d/f"), "f").unwrap();
        let (p, live) = idle_job(&out);
        let mut worker = hand_worker(&p, &live);
        worker.copy_tree(&src.join("d"), &out.join("d"), Copying::Moving, true).unwrap();
        fs::rename(out.join("d"), out.join("moved")).unwrap();
        fs::write(out.join("d"), "USER").unwrap();
        worker.finish();
        assert_eq!(names_in(&out.join("moved")), Vec::<String>::new(), "no hidden part stays in the moved folder");
        assert_eq!(read(out.join("d")), "USER");
        assert_eq!(read(src.join("d/f")), "f", "the source stays");
    }

    #[cfg(unix)]
    #[test]
    fn a_move_never_takes_the_part_of_another_folder_when_two_destination_folders_swap() {
        let tmp = tempfile::tempdir().unwrap();
        let (src, out) = (tmp.path().join("src"), tmp.path().join("out"));
        fs::create_dir_all(src.join("a")).unwrap();
        fs::create_dir_all(src.join("b")).unwrap();
        fs::create_dir_all(&out).unwrap();
        fs::write(src.join("a/f"), "A").unwrap();
        fs::write(src.join("b/f"), "B").unwrap();
        let (p, live) = idle_job(&out);
        let mut worker = hand_worker(&p, &live);
        worker.copy_tree(&src.join("a"), &out.join("a"), Copying::Moving, true).unwrap();
        worker.copy_tree(&src.join("b"), &out.join("b"), Copying::Moving, true).unwrap();
        fs::rename(out.join("a"), out.join("x")).unwrap();
        fs::rename(out.join("b"), out.join("a")).unwrap();
        worker.finish();
        let files = files_below(tmp.path());
        assert!(files.iter().all(|(path, _)| !path.split('/').any(|n| parts::is_temp_name(std::ffi::OsStr::new(n)))), "no hidden part stays: {files:?}");
        for text in ["A", "B"] {
            assert!(files.iter().any(|(_, t)| t == text), "{text} stays under a visible name: {files:?}");
        }
    }

    #[cfg(unix)]
    #[test]
    fn a_job_never_copies_hidden_temporary_items_of_a_folder() {
        let tmp = tempfile::tempdir().unwrap();
        let (src, out) = (tmp.path().join("src"), tmp.path().join("out"));
        fs::create_dir_all(src.join("d")).unwrap();
        fs::create_dir_all(out.join("d")).unwrap();
        fs::write(src.join("d/vis.txt"), "vis").unwrap();
        fs::write(src.join("d/.big.bin.99999999-1-1-1.joyfiles-part"), "stale").unwrap();
        fs::write(src.join("d/.report.99999999-1-1-1.joyfiles-old"), "parked").unwrap();
        fs::write(out.join("d/other"), "o").unwrap();
        let other = tmp.path().join("copy");
        fs::create_dir(&other).unwrap();
        let p = spawn(JobKind::Copy, vec![src.join("d")], other.clone(), Policy::Always(Resolution::KeepBoth));
        assert_eq!(wait(&p), JobState::Done);
        assert_eq!(names_in(&other.join("d")), ["vis.txt"], "a copy takes no temporary item");
        let p = spawn(JobKind::Move, vec![src.join("d")], out.clone(), Policy::Always(Resolution::KeepBoth));
        assert_eq!(wait(&p), JobState::Done);
        assert_eq!(names_in(&out.join("d")), ["other", "vis.txt"], "a merge takes no temporary item");
        assert_eq!(p.done_bytes.load(Ordering::Relaxed), p.total_bytes.load(Ordering::Relaxed), "the temporary items are not counted");
    }

    #[cfg(unix)]
    #[test]
    fn a_source_with_a_reserved_name_is_refused_and_stays() {
        let tmp = tempfile::tempdir().unwrap();
        let (src, out) = (tmp.path().join("src"), tmp.path().join("out"));
        fs::create_dir_all(&src).unwrap();
        fs::create_dir_all(&out).unwrap();
        fs::write(src.join(".report.joyfiles-part"), "precious").unwrap();
        for kind in [JobKind::Copy, JobKind::Move] {
            fs::write(src.join("ok.txt"), "ok").unwrap();
            let p = spawn(kind, vec![src.join(".report.joyfiles-part"), src.join("ok.txt")], out.clone(), Policy::Always(Resolution::KeepBoth));
            let JobState::Failed(text) = wait(&p) else { panic!("the job reports the refused name") };
            assert!(text.contains(".report.joyfiles-part"), "{text}");
            assert_eq!(read(src.join(".report.joyfiles-part")), "precious");
            assert_eq!(names_in(&out), ["ok.txt"], "the reserved name never reaches the destination");
            fs::remove_file(out.join("ok.txt")).unwrap();
            let _ = fs::remove_file(src.join("ok.txt"));
        }
    }

    #[cfg(unix)]
    #[test]
    fn a_folder_that_another_job_made_under_the_chosen_name_gets_the_next_name() {
        let tmp = tempfile::tempdir().unwrap();
        let dir = tmp.path();
        fs::create_dir_all(dir.join("d/sub")).unwrap();
        fs::write(dir.join("d/sub/f"), "f").unwrap();
        let (p, live) = idle_job(dir);
        let mut worker = hand_worker(&p, &live);
        // the racing job made "d (2)" after this job chose that name
        fs::create_dir(dir.join("d (2)")).unwrap();
        worker.copy_tree(&dir.join("d"), &dir.join("d (2)"), Copying::Plain, true).unwrap();
        worker.run_tasks().unwrap();
        worker.finish();
        assert_eq!(read(dir.join("d (3)/sub/f")), "f");
        assert!(names_in(&dir.join("d (2)")).is_empty(), "the folder of the other job stays as it is");
        assert!(p.failures().is_empty(), "{:?}", p.failures());
    }

    #[cfg(unix)]
    #[test]
    fn a_replace_places_the_new_item_when_another_job_already_took_the_old_one_away() {
        let tmp = tempfile::tempdir().unwrap();
        let dir = tmp.path();
        fs::write(dir.join("new"), "new").unwrap();
        let (p, live) = idle_job(dir);
        let worker = hand_worker(&p, &live);
        worker.swap_in(&dir.join("new"), &dir.join("target")).unwrap();
        assert_eq!(read(dir.join("target")), "new");
        assert_eq!(names_in(dir), ["target"]);
    }
}
