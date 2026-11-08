use std::collections::BTreeSet;
use std::ffi::{OsStr, OsString};
use std::fs;
use std::path::{Path, PathBuf};
use std::sync::Mutex;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::time::{Duration, SystemTime};

use crate::fs_ops::{NAME_MAX, exists_nofollow, holds_mount_point, remove_temp_tree, truncate};

// an item nobody changed for this long and that no live job of this process owns is a leftover of a crash
pub const SAFE_AGE: Duration = Duration::from_secs(60 * 60);

const PART: &str = ".joyfiles-part";
const OLD: &str = ".joyfiles-old";

// a part is a copy or a leftover that can go, and an old item is user data that waits for a replace or a case rename to end
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Role {
    Part,
    Old,
}

impl Role {
    fn suffix(self) -> &'static str {
        match self {
            Role::Part => PART,
            Role::Old => OLD,
        }
    }
}

// the process and the job that made a temporary item, so two jobs never pick one name and a sweep skips what is in use
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Owner {
    pid: u32,
    job: u64,
}

impl Owner {
    // job 0 stands for a rename, which never outlives its call
    pub fn rename() -> Self {
        Owner { pid: std::process::id(), job: 0 }
    }

    fn is_live(self) -> bool {
        if self.pid != std::process::id() {
            return process_alive(self.pid);
        }
        self.job == 0 || LIVE.lock().unwrap().contains(&self.job)
    }
}

static LIVE: Mutex<BTreeSet<u64>> = Mutex::new(BTreeSet::new());
static NEXT_JOB: AtomicU64 = AtomicU64::new(1);

// a job counts as live for the sweep from start until this value drops
#[derive(Debug)]
pub struct LiveJob(u64);

impl LiveJob {
    pub fn start() -> Self {
        let id = NEXT_JOB.fetch_add(1, Ordering::Relaxed);
        LIVE.lock().unwrap().insert(id);
        LiveJob(id)
    }

    pub fn owner(&self) -> Owner {
        Owner { pid: std::process::id(), job: self.0 }
    }
}

impl Drop for LiveJob {
    fn drop(&mut self) {
        LIVE.lock().unwrap().remove(&self.0);
    }
}

// a hidden name in the same folder, so a rename puts the finished item in place in one step
pub fn temp_path(dir: &Path, name: &OsStr, owner: Owner, role: Role) -> PathBuf {
    (1u64..)
        .map(|n| {
            let tag = format!(".{}-{}-{n}{}", owner.pid, owner.job, role.suffix());
            let mut temp = OsString::from(".");
            temp.push(truncate(name, NAME_MAX - 1 - tag.len()));
            temp.push(tag);
            dir.join(temp)
        })
        .find(|p| !exists_nofollow(p))
        .expect("an unused name exists")
}

struct TempName {
    role: Role,
    owner: Option<Owner>,
    stem: OsString,
}

// an older version wrote names with no owner tag, so such a name has only the stem before the suffix
fn parse(name: &OsStr) -> Option<TempName> {
    let bytes = name.as_encoded_bytes().strip_prefix(b".")?;
    let (rest, role) = match (bytes.strip_suffix(PART.as_bytes()), bytes.strip_suffix(OLD.as_bytes())) {
        (Some(rest), _) => (rest, Role::Part),
        (_, Some(rest)) => (rest, Role::Old),
        _ => return None,
    };
    if rest.is_empty() {
        return None;
    }
    let dot = rest.iter().rposition(|&b| b == b'.');
    let owner = dot.and_then(|at| parse_owner(&rest[at + 1..]));
    let stem = match (owner, dot) {
        (Some(_), Some(at)) => &rest[..at],
        _ => rest,
    };
    // the stem is cut at an ASCII dot, which the encoded bytes allow
    let stem = unsafe { OsStr::from_encoded_bytes_unchecked(stem) }.to_owned();
    Some(TempName { role, owner, stem })
}

fn parse_owner(tag: &[u8]) -> Option<Owner> {
    let text = std::str::from_utf8(tag).ok()?;
    let mut parts = text.split('-');
    let (pid, job, _n) = (parts.next()?.parse().ok()?, parts.next()?.parse().ok()?, parts.next()?.parse::<u64>().ok()?);
    parts.next().is_none().then_some(Owner { pid, job })
}

// the list never shows such an item, even with hidden files shown
pub fn is_temp_name(name: &OsStr) -> bool {
    parse(name).is_some()
}

#[cfg(target_os = "linux")]
fn process_alive(pid: u32) -> bool {
    Path::new("/proc").join(pid.to_string()).exists()
}

// without a cheap check the age alone decides
#[cfg(not(target_os = "linux"))]
fn process_alive(_pid: u32) -> bool {
    false
}

fn is_stale(path: &Path, owner: Option<Owner>, min_age: Duration) -> bool {
    if owner.is_some_and(Owner::is_live) {
        return false;
    }
    let changed = fs::symlink_metadata(path).and_then(|m| m.modified());
    changed.is_ok_and(|at| SystemTime::now().duration_since(at).is_ok_and(|age| age >= min_age))
}

// a stale part goes, and a stale old item gets its name back, or goes when a new item took that name
pub fn sweep(dir: &Path, min_age: Duration, stop: &AtomicBool) {
    let Ok(listing) = fs::read_dir(dir) else { return };
    for entry in listing.filter_map(Result::ok) {
        if stop.load(Ordering::Relaxed) {
            return;
        }
        let Some(temp) = parse(&entry.file_name()) else { continue };
        let path = entry.path();
        if !is_stale(&path, temp.owner, min_age) || (entry.file_type().is_ok_and(|t| t.is_dir()) && holds_mount_point(&path)) {
            continue;
        }
        let home = dir.join(&temp.stem);
        if temp.role == Role::Old && !exists_nofollow(&home) {
            let _ = fs::rename(&path, &home);
        } else {
            let _ = remove_temp_tree(&path);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs::File;

    fn names_in(dir: &Path) -> Vec<String> {
        let mut out: Vec<String> = fs::read_dir(dir).unwrap().map(|e| e.unwrap().file_name().to_string_lossy().into_owned()).collect();
        out.sort();
        out
    }

    fn backdate(path: &Path) {
        File::open(path).unwrap().set_modified(SystemTime::now() - 2 * SAFE_AGE).unwrap();
    }

    #[test]
    fn two_jobs_never_pick_one_temporary_name() {
        let tmp = tempfile::tempdir().unwrap();
        let (one, other) = (LiveJob::start(), LiveJob::start());
        let name = OsStr::new("big.bin");
        let first = temp_path(tmp.path(), name, one.owner(), Role::Part);
        assert_ne!(first, temp_path(tmp.path(), name, other.owner(), Role::Part));
        fs::write(&first, "x").unwrap();
        assert_ne!(first, temp_path(tmp.path(), name, one.owner(), Role::Part), "one job gets a new name for a second item");
        let long = OsString::from("n".repeat(255));
        let cut = temp_path(tmp.path(), &long, one.owner(), Role::Old);
        assert!(cut.file_name().unwrap().len() <= 255 && is_temp_name(cut.file_name().unwrap()));
    }

    #[cfg(unix)]
    #[test]
    fn a_sweep_clears_only_stale_items_that_no_live_job_owns() {
        use std::os::unix::fs::PermissionsExt;
        let tmp = tempfile::tempdir().unwrap();
        let dir = tmp.path();
        let live = LiveJob::start();
        let ended = LiveJob::start().owner();
        let at = |name: &str, owner, role| temp_path(dir, OsStr::new(name), owner, role);
        let stale = [
            (dir.join(".big.bin.joyfiles-part"), false),
            (at("dead.bin", ended, Role::Part), false),
            (at("tree", ended, Role::Part), true),
            (at("notes.txt", ended, Role::Old), false),
            (at("taken.txt", ended, Role::Old), false),
        ];
        for (path, is_dir) in &stale {
            if *is_dir {
                fs::create_dir_all(path.join("ro")).unwrap();
                fs::write(path.join("ro/f"), "x").unwrap();
                fs::set_permissions(path.join("ro"), fs::Permissions::from_mode(0o555)).unwrap();
            } else {
                fs::write(path, "old data").unwrap();
            }
            backdate(path);
        }
        let in_use = at("busy.bin", live.owner(), Role::Part);
        fs::write(&in_use, "x").unwrap();
        backdate(&in_use);
        let young = dir.join(".fresh.bin.joyfiles-part");
        fs::write(&young, "x").unwrap();
        fs::write(dir.join(".hidden"), "x").unwrap();
        fs::write(dir.join("taken.txt"), "new data").unwrap();
        backdate(&dir.join(".hidden"));
        sweep(dir, SAFE_AGE, &AtomicBool::new(false));
        let mut want = vec![".fresh.bin.joyfiles-part".to_string(), ".hidden".into(), "notes.txt".into(), "taken.txt".into()];
        want.push(in_use.file_name().unwrap().to_string_lossy().into_owned());
        want.sort();
        assert_eq!(names_in(dir), want);
        assert_eq!(fs::read_to_string(dir.join("notes.txt")).unwrap(), "old data", "the parked item got its name back");
        assert_eq!(fs::read_to_string(dir.join("taken.txt")).unwrap(), "new data");
    }
}
