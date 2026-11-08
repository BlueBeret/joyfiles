use std::fs;
use std::path::{Path, PathBuf};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PlaceKind {
    Home,
    Folder,
    Drive,
}

impl PlaceKind {
    pub fn as_str(self) -> &'static str {
        match self {
            PlaceKind::Home => "home",
            PlaceKind::Folder => "folder",
            PlaceKind::Drive => "drive",
        }
    }
}

#[derive(Debug, Clone, PartialEq)]
pub struct Place {
    pub label: String,
    pub path: PathBuf,
    pub kind: PlaceKind,
}

pub fn places() -> Vec<Place> {
    let mut out = Vec::new();
    if let Some(home) = dirs::home_dir() {
        out.push(Place { label: "Home".into(), path: home, kind: PlaceKind::Home });
    }
    let folders = [
        ("Downloads", dirs::download_dir()),
        ("Documents", dirs::document_dir()),
        ("Pictures", dirs::picture_dir()),
        ("Videos", dirs::video_dir()),
        ("Music", dirs::audio_dir()),
        ("Desktop", dirs::desktop_dir()),
    ];
    for (label, dir) in folders {
        if let Some(path) = dir.filter(|p| p.is_dir() && out.iter().all(|o: &Place| &o.path != p)) {
            out.push(Place { label: label.into(), path, kind: PlaceKind::Folder });
        }
    }
    out.extend(drives());
    out
}

#[cfg(windows)]
fn drives() -> Vec<Place> {
    (b'A'..=b'Z')
        .map(|c| PathBuf::from(format!("{}:\\", c as char)))
        .filter(|p| p.is_dir())
        .map(|path| Place { label: path.display().to_string(), path, kind: PlaceKind::Drive })
        .collect()
}

// the Steam Linux Runtime container shows a runtime /usr at "/", so list mount folders and never "/"
#[cfg(not(windows))]
fn drives() -> Vec<Place> {
    let user = user_name(std::env::var("USER").ok(), std::env::var("LOGNAME").ok(), dirs::home_dir());
    drives_under(Path::new("/"), user.as_deref())
}

// an empty user name would make the shared media folder list each user as a drive
#[cfg(not(windows))]
fn user_name(user: Option<String>, logname: Option<String>, home: Option<PathBuf>) -> Option<String> {
    let from_home = home.and_then(|h| h.file_name().map(|n| n.to_string_lossy().into_owned()));
    [user, logname, from_home].into_iter().flatten().find(|name| !name.is_empty())
}

#[cfg(not(windows))]
fn drives_under(base: &Path, user: Option<&str>) -> Vec<Place> {
    let mut roots = Vec::new();
    if let Some(user) = user {
        roots.push(base.join("run/media").join(user));
        roots.push(base.join("media").join(user));
    }
    roots.push(base.join("media"));
    roots.push(base.join("mnt"));
    let own_media = user.map(|u| base.join("media").join(u));
    let mut out: Vec<Place> = Vec::new();
    for root in roots {
        for path in child_dirs(&root) {
            if out.iter().all(|o| o.path != path) && Some(&path) != own_media.as_ref() {
                let label = path.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default();
                out.push(Place { label, path, kind: PlaceKind::Drive });
            }
        }
    }
    out
}

#[cfg(not(windows))]
fn child_dirs(root: &Path) -> Vec<PathBuf> {
    let Ok(rd) = fs::read_dir(root) else { return Vec::new() };
    let mut dirs: Vec<PathBuf> = rd.filter_map(Result::ok).map(|e| e.path()).filter(|p| p.is_dir()).collect();
    dirs.sort();
    dirs
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn home_comes_first_and_root_is_never_listed() {
        let list = places();
        assert_eq!(list[0].kind, PlaceKind::Home);
        assert!(list.iter().all(|p| p.path != Path::new("/")));
    }

    #[cfg(not(windows))]
    #[test]
    fn without_user_the_drives_still_come_from_the_home_folder_name() {
        let tmp = tempfile::tempdir().unwrap();
        for dir in ["run/media/alice/CARD", "media/alice/USB", "media/STICK", "mnt/disk"] {
            fs::create_dir_all(tmp.path().join(dir)).unwrap();
        }
        let user = user_name(None, None, Some(PathBuf::from("/home/alice")));
        let labels: Vec<String> = drives_under(tmp.path(), user.as_deref()).into_iter().map(|p| p.label).collect();
        assert_eq!(labels, ["CARD", "USB", "STICK", "disk"]);
        let unknown = user_name(None, Some(String::new()), None);
        let paths: Vec<PathBuf> = drives_under(tmp.path(), unknown.as_deref()).into_iter().map(|p| p.path).collect();
        assert!(!paths.contains(&tmp.path().join("run/media/alice")), "a user folder in run/media never shows as a drive");
    }
}
