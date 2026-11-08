pub mod fs_ops;
pub mod jobs;
pub mod parts;
pub mod places;
pub mod props;

use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::thread;
use std::time::{Duration, Instant};

use godot::prelude::*;

use fs_ops::SortKey;
use fs_ops::Failure;
use jobs::{Conflict, JobKind, JobState, Policy, Progress, Resolution};
use props::SizeScan;

struct JoyfilesExtension;

#[gdextension]
unsafe impl ExtensionLibrary for JoyfilesExtension {}

#[derive(GodotClass)]
#[class(base = RefCounted, init)]
pub struct JoyCore {
    jobs: HashMap<i64, Arc<Progress>>,
    next_job: i64,
    scans: HashMap<i64, Arc<SizeScan>>,
    next_scan: i64,
    sweeper: Option<thread::JoinHandle<()>>,
    stop_sweep: Arc<AtomicBool>,
}

// a worker thread runs code from this library, so it must end before Godot unloads the library at exit
impl Drop for JoyCore {
    fn drop(&mut self) {
        let deadline = Instant::now() + Duration::from_secs(10);
        for p in self.jobs.values() {
            p.request_cancel();
        }
        for s in self.scans.values() {
            s.cancel.store(true, Ordering::Relaxed);
        }
        for p in self.jobs.values() {
            p.wait_finished(deadline);
        }
        for s in self.scans.values() {
            s.wait_finished(deadline);
        }
        self.stop_sweep.store(true, Ordering::Relaxed);
        if let Some(sweeper) = self.sweeper.take() {
            while !sweeper.is_finished() && Instant::now() < deadline {
                thread::sleep(Duration::from_millis(5));
            }
            if sweeper.is_finished() {
                let _ = sweeper.join();
            }
        }
    }
}

impl JoyCore {
    // one pass at a time, so a refresh while a big leftover is removed starts nothing new
    fn sweep_later(&mut self, dir: PathBuf) {
        if self.sweeper.as_ref().is_some_and(|s| !s.is_finished()) {
            return;
        }
        let stop = Arc::clone(&self.stop_sweep);
        self.sweeper = Some(thread::spawn(move || parts::sweep(&dir, parts::SAFE_AGE, &stop)));
    }
}

// every path crosses the binding in this form, so a name that is not valid text still names one file
fn path_of(p: &GString) -> PathBuf {
    fs_ops::path_from_text(&p.to_string())
}

fn gstr(p: &Path) -> GString {
    GString::from(fs_ops::path_to_text(p).as_str())
}

fn result_dict(r: Result<PathBuf, String>) -> VarDictionary {
    match r {
        Ok(path) => vdict! { "ok" => true, "path" => &gstr(&path), "error" => "" },
        Err(e) => vdict! { "ok" => false, "path" => "", "error" => e.as_str() },
    }
}

fn conflict_dict(c: &Conflict) -> VarDictionary {
    vdict! {
        "name" => c.name.as_str(),
        "src_is_dir" => c.src.is_dir,
        "dest_is_dir" => c.dest.is_dir,
        "src_size" => c.src.size as i64,
        "dest_size" => c.dest.size as i64,
        "src_modified" => c.src.modified,
        "dest_modified" => c.dest.modified,
    }
}

fn failures_array(failures: &[Failure]) -> VarArray {
    let mut arr = VarArray::new();
    for f in failures {
        let name = f.path.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default();
        arr.push(&vdict! { "path" => &gstr(&f.path), "name" => name.as_str(), "error" => f.message.as_str() }.to_variant());
    }
    arr
}

#[godot_api]
impl JoyCore {
    // an opened folder also gets a background pass that clears what a crash left behind
    #[func]
    fn list_dir(&mut self, path: GString, show_hidden: bool, sort: GString, descending: bool) -> VarDictionary {
        match fs_ops::list_dir(&path_of(&path), show_hidden, SortKey::parse(&sort.to_string()), descending) {
            Ok(entries) => {
                self.sweep_later(path_of(&path));
                let mut arr = VarArray::new();
                for e in entries {
                    arr.push(&vdict! {
                        "name" => e.name.as_str(),
                        "path" => &gstr(&e.path),
                        "is_dir" => e.is_dir,
                        "size" => e.size as i64,
                        "modified" => e.modified,
                        "hidden" => e.hidden,
                    }.to_variant());
                }
                vdict! { "ok" => true, "entries" => &arr, "error" => "" }
            }
            Err(e) => {
                let error = format!("Could not open \"{}\": {}.", fs_ops::display_name(&path_of(&path)), fs_ops::reason(&e));
                vdict! { "ok" => false, "entries" => &VarArray::new(), "error" => error.as_str() }
            }
        }
    }

    #[func]
    fn places(&self) -> VarArray {
        let mut arr = VarArray::new();
        for p in places::places() {
            arr.push(&vdict! { "label" => p.label.as_str(), "path" => &gstr(&p.path), "kind" => p.kind.as_str() }.to_variant());
        }
        arr
    }

    #[func]
    fn parent_dir(&self, path: GString) -> GString {
        path_of(&path).parent().map(gstr).unwrap_or_default()
    }

    #[func]
    fn join(&self, dir: GString, name: GString) -> GString {
        gstr(&path_of(&dir).join(name.to_string()))
    }

    // new_name is in the same text form as a path, so the last part of a listed path renames to itself
    #[func]
    fn rename(&self, path: GString, new_name: GString) -> VarDictionary {
        result_dict(fs_ops::rename(&path_of(&path), path_of(&new_name)))
    }

    #[func]
    fn make_dir(&self, parent: GString, name: GString) -> VarDictionary {
        result_dict(fs_ops::make_dir(&path_of(&parent), &name.to_string()))
    }

    // ok is true only when every item went to the trash, and trashed counts the items that did
    #[func]
    fn trash(&self, paths: PackedStringArray) -> VarDictionary {
        let list: Vec<PathBuf> = paths.as_slice().iter().map(path_of).collect();
        let failures = fs_ops::trash_items(&list);
        vdict! {
            "ok" => failures.is_empty(),
            "path" => "",
            "error" => fs_ops::summary(&failures).unwrap_or_default().as_str(),
            "trashed" => (list.len() - failures.len()) as i64,
            "failures" => &failures_array(&failures),
        }
    }

    #[func]
    fn start_job(&mut self, is_move: bool, sources: PackedStringArray, dest_dir: GString) -> i64 {
        let kind = if is_move { JobKind::Move } else { JobKind::Copy };
        let list = sources.as_slice().iter().map(path_of).collect();
        self.next_job += 1;
        self.jobs.insert(self.next_job, jobs::spawn(kind, list, path_of(&dest_dir), Policy::Ask));
        self.next_job
    }

    #[func]
    fn cancel_job(&self, id: i64) {
        if let Some(p) = self.jobs.get(&id) {
            p.request_cancel();
        }
    }

    // choice is "replace", "keep_both" or "skip", and the result says whether a question was waiting
    #[func]
    fn answer_conflict(&self, id: i64, choice: GString, apply_all: bool) -> bool {
        let Some(choice) = Resolution::parse(&choice.to_string()) else { return false };
        self.jobs.get(&id).is_some_and(|p| p.answer(choice, apply_all))
    }

    // items is -1 for a file and for a folder that cannot be read, and items_error then gives the reason
    #[func]
    fn props(&self, path: GString) -> VarDictionary {
        match props::props(&path_of(&path)) {
            Ok(p) => vdict! {
                "ok" => true,
                "error" => "",
                "name" => p.name.as_str(),
                "path" => &gstr(&p.path),
                "type" => p.type_label.as_str(),
                "is_dir" => p.is_dir,
                "is_symlink" => p.is_symlink,
                "size" => p.size as i64,
                "modified" => p.modified,
                "items" => p.items.clone().and_then(Result::ok).map_or(-1, |n| n as i64),
                "items_error" => p.items.and_then(Result::err).unwrap_or_default().as_str(),
            },
            Err(e) => {
                let error = format!("Could not read \"{}\": {}.", fs_ops::display_name(&path_of(&path)), fs_ops::reason(&e));
                vdict! { "ok" => false, "error" => error.as_str() }
            }
        }
    }

    // a scan the panel cancelled is never polled again, so each new scan drops cancelled scans that ended
    #[func]
    fn start_size_scan(&mut self, path: GString) -> i64 {
        self.scans.retain(|_, s| !(s.cancel.load(Ordering::Relaxed) && s.done.load(Ordering::Relaxed)));
        self.next_scan += 1;
        self.scans.insert(self.next_scan, props::spawn_size_scan(path_of(&path)));
        self.next_scan
    }

    // a scan leaves the table once the poll has reported it done
    #[func]
    fn poll_size_scan(&mut self, id: i64) -> VarDictionary {
        let Some(scan) = self.scans.get(&id) else {
            return vdict! { "known" => false, "done" => true, "bytes" => 0, "files" => 0, "folders" => 0 };
        };
        let done = scan.done.load(Ordering::Relaxed);
        let out = vdict! {
            "known" => true,
            "done" => done,
            "bytes" => scan.bytes.load(Ordering::Relaxed) as i64,
            "files" => scan.files.load(Ordering::Relaxed) as i64,
            "folders" => scan.folders.load(Ordering::Relaxed) as i64,
        };
        if done {
            self.scans.remove(&id);
        }
        out
    }

    #[func]
    fn cancel_size_scan(&self, id: i64) {
        if let Some(scan) = self.scans.get(&id) {
            scan.cancel.store(true, Ordering::Relaxed);
        }
    }

    // finished jobs leave the table after one poll so the UI sees each end state and failure list once
    #[func]
    fn poll_jobs(&mut self) -> VarArray {
        let mut arr = VarArray::new();
        let mut finished = Vec::new();
        for (id, p) in &self.jobs {
            let (state, error) = match p.state() {
                JobState::Running => ("running", String::new()),
                JobState::Done => ("done", String::new()),
                JobState::Cancelled => ("cancelled", String::new()),
                JobState::Failed(e) => ("failed", e),
            };
            if state != "running" {
                finished.push(*id);
            }
            arr.push(&vdict! {
                "id" => *id,
                "kind" => if p.kind == JobKind::Move { "move" } else { "copy" },
                "state" => state,
                "error" => error.as_str(),
                "failures" => &failures_array(&p.failures()),
                "current" => p.current.lock().unwrap().as_str(),
                "conflict" => &p.pending_conflict().map_or_else(VarDictionary::new, |c| conflict_dict(&c)),
                "done_bytes" => p.done_bytes.load(Ordering::Relaxed) as i64,
                "total_bytes" => p.total_bytes.load(Ordering::Relaxed) as i64,
            }.to_variant());
        }
        for id in finished {
            self.jobs.remove(&id);
        }
        arr
    }
}
