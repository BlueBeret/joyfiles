pub mod fs_ops;
pub mod jobs;
pub mod places;

use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::sync::atomic::Ordering;

use godot::prelude::*;

use jobs::{JobKind, JobState, Progress};

struct JoyfilesExtension;

#[gdextension]
unsafe impl ExtensionLibrary for JoyfilesExtension {}

#[derive(GodotClass)]
#[class(base = RefCounted, init)]
pub struct JoyCore {
    jobs: HashMap<i64, Arc<Progress>>,
    next_job: i64,
}

fn path_of(p: &GString) -> PathBuf {
    PathBuf::from(p.to_string())
}

fn gstr(p: &Path) -> GString {
    GString::from(p.to_string_lossy().as_ref())
}

fn result_dict(r: Result<PathBuf, String>) -> VarDictionary {
    match r {
        Ok(path) => vdict! { "ok" => true, "path" => &gstr(&path), "error" => "" },
        Err(e) => vdict! { "ok" => false, "path" => "", "error" => e.as_str() },
    }
}

#[godot_api]
impl JoyCore {
    #[func]
    fn list_dir(&self, path: GString, show_hidden: bool) -> VarDictionary {
        match fs_ops::list_dir(&path_of(&path), show_hidden) {
            Ok(entries) => {
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
            Err(e) => vdict! { "ok" => false, "entries" => &VarArray::new(), "error" => e.to_string().as_str() },
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

    #[func]
    fn rename(&self, path: GString, new_name: GString) -> VarDictionary {
        result_dict(fs_ops::rename(&path_of(&path), &new_name.to_string()))
    }

    #[func]
    fn make_dir(&self, parent: GString, name: GString) -> VarDictionary {
        result_dict(fs_ops::make_dir(&path_of(&parent), &name.to_string()))
    }

    #[func]
    fn trash(&self, paths: PackedStringArray) -> VarDictionary {
        let list: Vec<PathBuf> = paths.as_slice().iter().map(path_of).collect();
        result_dict(trash::delete_all(&list).map(|_| PathBuf::new()).map_err(|e| e.to_string()))
    }

    #[func]
    fn start_job(&mut self, is_move: bool, sources: PackedStringArray, dest_dir: GString) -> i64 {
        let kind = if is_move { JobKind::Move } else { JobKind::Copy };
        let list = sources.as_slice().iter().map(path_of).collect();
        self.next_job += 1;
        self.jobs.insert(self.next_job, jobs::spawn(kind, list, path_of(&dest_dir)));
        self.next_job
    }

    #[func]
    fn cancel_job(&self, id: i64) {
        if let Some(p) = self.jobs.get(&id) {
            p.cancel.store(true, Ordering::Relaxed);
        }
    }

    // finished jobs leave the table after one poll so the UI sees each end state once
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
                "current" => p.current.lock().unwrap().as_str(),
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
