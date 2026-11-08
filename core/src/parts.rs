use std::collections::BTreeSet;
use std::ffi::{OsStr, OsString};
use std::fs;
use std::io;
use std::path::{Path, PathBuf};
use std::sync::{Mutex, OnceLock};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::time::{Duration, SystemTime};

use crate::fs_ops::{NAME_MAX, exists_nofollow, holds_mount_point, remove_temp_tree, rename_noreplace, truncate};

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
    // the start time of the process, so a new process that took the pid of a dead one is not taken for it
    start: Option<u64>,
}

impl Owner {
    // job 0 stands for a rename, which never outlives its call
    pub fn rename() -> Self {
        Owner { pid: std::process::id(), job: 0, start: own_start() }
    }

    fn is_this_process(self) -> bool {
        self.pid == std::process::id() && self.start.is_none_or(|start| Some(start) == own_start())
    }

    fn is_live(self) -> bool {
        if !self.is_this_process() {
            return process_alive(self);
        }
        self.job == 0 || LIVE.lock().unwrap().contains(&self.job)
    }

    // true only when a check proves the owner ended, and a system with no cheap check never proves it
    fn has_ended(self) -> bool {
        if !self.is_this_process() {
            return cfg!(target_os = "linux") && !process_alive(self);
        }
        !self.is_live()
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
        Owner { pid: std::process::id(), job: self.0, start: own_start() }
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
            let tag = tag(owner, role, n);
            let mut temp = OsString::from(".");
            temp.push(truncate(name, NAME_MAX - 1 - tag.len()));
            temp.push(tag);
            dir.join(temp)
        })
        .find(|p| !exists_nofollow(p))
        .expect("an unused name exists")
}

fn tag(owner: Owner, role: Role, n: u64) -> String {
    let start = owner.start.map_or(String::new(), |start| format!("-{start}"));
    format!(".{}-{}-{n}{start}{}", owner.pid, owner.job, role.suffix())
}

// the old item keeps its whole name, so a name too long for the tag goes into a hidden folder with a short name
pub fn park_path(dir: &Path, name: &OsStr, owner: Owner) -> io::Result<PathBuf> {
    let room = |n| 1 + name.len() + tag(owner, Role::Old, n).len() <= NAME_MAX;
    for n in (1u64..).take_while(|&n| room(n)) {
        let whole = temp_path_numbered(dir, name, owner, n);
        if !exists_nofollow(&whole) {
            return Ok(whole);
        }
    }
    let hold = temp_path(dir, OsStr::new(""), owner, Role::Old);
    fs::create_dir(&hold)?;
    Ok(hold.join(name))
}

// the hidden folder of a long name goes once its item left, and it stays when something else is inside
pub fn clear_hold(parked: &Path, home: &Path) {
    if let Some(hold) = parked.parent().filter(|hold| Some(*hold) != home.parent()) {
        let _ = fs::remove_dir(hold);
    }
}

fn temp_path_numbered(dir: &Path, name: &OsStr, owner: Owner, n: u64) -> PathBuf {
    let mut temp = OsString::from(".");
    temp.push(name);
    temp.push(tag(owner, Role::Old, n));
    dir.join(temp)
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
    // an older version wrote no start time, so such an owner is known by its pid alone
    let start = match parts.next() {
        Some(text) => Some(text.parse().ok()?),
        None => None,
    };
    parts.next().is_none().then_some(Owner { pid, job, start })
}

// the list never shows such an item, even with hidden files shown
pub fn is_temp_name(name: &OsStr) -> bool {
    parse(name).is_some()
}

// the start time in clock ticks since boot, which is field 22 of the stat line and follows the name in parentheses
#[cfg(target_os = "linux")]
fn start_of(pid: u32) -> Option<u64> {
    let stat = fs::read_to_string(format!("/proc/{pid}/stat")).ok()?;
    let mut fields = stat[stat.rfind(')')? + 1..].split_whitespace();
    fields.nth(19)?.parse().ok()
}

// a zombie has ended, and a pid with another start time belongs to a new process
#[cfg(target_os = "linux")]
fn process_alive(owner: Owner) -> bool {
    let pid = owner.pid;
    if !Path::new("/proc").join(pid.to_string()).exists() {
        return false;
    }
    let zombie = fs::read_to_string(format!("/proc/{pid}/stat")).is_ok_and(|stat| stat.rfind(')').is_some_and(|at| stat[at + 1..].trim_start().starts_with('Z')));
    if zombie {
        return false;
    }
    match (owner.start, start_of(pid)) {
        (Some(was), Some(now)) => was == now,
        _ => true,
    }
}

#[cfg(target_os = "linux")]
fn own_start() -> Option<u64> {
    static START: OnceLock<Option<u64>> = OnceLock::new();
    *START.get_or_init(|| start_of(std::process::id()))
}

// without a cheap check the age alone decides
#[cfg(not(target_os = "linux"))]
fn process_alive(_owner: Owner) -> bool {
    false
}

#[cfg(not(target_os = "linux"))]
fn own_start() -> Option<u64> {
    None
}

// an old item is user data that waits for a replace, so an owner that ended frees it at once, whatever the date of the data
fn is_stale(path: &Path, owner: Option<Owner>, role: Role, min_age: Duration) -> bool {
    if owner.is_some_and(Owner::is_live) {
        return false;
    }
    if role == Role::Old && owner.is_some_and(Owner::has_ended) {
        return true;
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
        if !is_stale(&path, temp.owner, temp.role, min_age) || (entry.file_type().is_ok_and(|t| t.is_dir()) && holds_mount_point(&path)) {
            continue;
        }
        if temp.role == Role::Old && temp.owner.is_some() && temp.stem.is_empty() {
            release_hold(&path, dir);
            continue;
        }
        let home = dir.join(&temp.stem);
        let restored = temp.role == Role::Old && rename_noreplace(&path, &home).is_ok();
        if !restored {
            let _ = remove_temp_tree(&path);
        }
    }
}

// the item inside gets its name back, or goes when a new item took that name
fn release_hold(hold: &Path, dir: &Path) {
    let Ok(inside) = fs::read_dir(hold) else { return };
    for entry in inside.filter_map(Result::ok) {
        if rename_noreplace(&entry.path(), &dir.join(entry.file_name())).is_err() {
            let _ = remove_temp_tree(&entry.path());
        }
    }
    let _ = fs::remove_dir(hold);
}

#[cfg(test)]
mod tests {
    use super::*;
    #[cfg(unix)]
    use std::fs::File;

    #[cfg(unix)]
    fn names_in(dir: &Path) -> Vec<String> {
        let mut out: Vec<String> = fs::read_dir(dir).unwrap().map(|e| e.unwrap().file_name().to_string_lossy().into_owned()).collect();
        out.sort();
        out
    }

    #[cfg(unix)]
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

    #[cfg(unix)]
    #[test]
    fn a_sweep_gives_a_parked_item_with_the_longest_name_its_whole_name_back() {
        let tmp = tempfile::tempdir().unwrap();
        let dir = tmp.path();
        let ended = LiveJob::start().owner();
        let long = "n".repeat(251) + ".txt";
        for name in [long.as_str(), "short.txt"] {
            fs::write(dir.join(name), "old data").unwrap();
            let parked = park_path(dir, OsStr::new(name), ended).unwrap();
            let top = parked.strip_prefix(dir).unwrap().components().next().unwrap().as_os_str().to_owned();
            assert!(is_temp_name(&top), "the list never shows the parked item");
            fs::rename(dir.join(name), &parked).unwrap();
        }
        sweep(dir, SAFE_AGE, &AtomicBool::new(false));
        let mut want = vec![long.clone(), "short.txt".to_string()];
        want.sort();
        assert_eq!(names_in(dir), want);
        assert_eq!(fs::read_to_string(dir.join(&long)).unwrap(), "old data");
    }

    #[cfg(unix)]
    #[test]
    fn a_sweep_frees_an_old_item_of_an_ended_job_at_once_and_keeps_that_of_a_live_job() {
        let tmp = tempfile::tempdir().unwrap();
        let dir = tmp.path();
        let live = LiveJob::start();
        let ended = LiveJob::start().owner();
        let gone = temp_path(dir, OsStr::new("edited.txt"), ended, Role::Old);
        let kept = temp_path(dir, OsStr::new("busy.txt"), live.owner(), Role::Old);
        fs::write(&gone, "edited a minute ago").unwrap();
        fs::write(&kept, "x").unwrap();
        sweep(dir, SAFE_AGE, &AtomicBool::new(false));
        assert_eq!(fs::read_to_string(dir.join("edited.txt")).unwrap(), "edited a minute ago");
        assert!(kept.exists(), "the live job keeps its old item");
    }

    #[cfg(target_os = "linux")]
    #[test]
    fn a_sweep_frees_items_of_a_pid_that_another_process_reuses() {
        let tmp = tempfile::tempdir().unwrap();
        let dir = tmp.path();
        let me = std::process::id();
        let start = own_start().unwrap();
        let reused = |name: &str, role: Role, start: u64| {
            let path = dir.join(format!(".{name}.{me}-5-1-{start}{}", role.suffix()));
            fs::write(&path, "data").unwrap();
            backdate(&path);
            path
        };
        let old = reused("report.txt", Role::Old, start + 1);
        let part = reused("big.bin", Role::Part, start + 1);
        let live = LiveJob::start();
        let own_part = temp_path(dir, OsStr::new("mine.bin"), live.owner(), Role::Part);
        fs::write(&own_part, "data").unwrap();
        backdate(&own_part);
        sweep(dir, SAFE_AGE, &AtomicBool::new(false));
        assert_eq!(fs::read_to_string(dir.join("report.txt")).unwrap(), "data", "the old item got its name back");
        assert!(!old.exists() && !part.exists(), "a pid with another start time is not the owner");
        assert!(own_part.exists(), "the same pid with the same start time keeps its item");
    }
}
