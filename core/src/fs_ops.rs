use std::ffi::{OsStr, OsString};
use std::fs;
use std::io;
use std::path::{Path, PathBuf};
use std::time::UNIX_EPOCH;

#[derive(Debug, Clone, PartialEq)]
pub struct Entry {
    pub name: String,
    pub path: PathBuf,
    pub is_dir: bool,
    pub size: u64,
    pub modified: i64,
    pub hidden: bool,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum SortKey {
    #[default]
    Name,
    Size,
    Modified,
    Type,
}

impl SortKey {
    pub fn parse(text: &str) -> Self {
        match text {
            "size" => SortKey::Size,
            "modified" => SortKey::Modified,
            "type" => SortKey::Type,
            _ => SortKey::Name,
        }
    }
}

// a stat denied for an entry means the folder itself cannot be searched, so the list fails instead of showing empty
pub fn list_dir(dir: &Path, show_hidden: bool, key: SortKey, descending: bool) -> io::Result<Vec<Entry>> {
    let mut entries = Vec::new();
    for item in fs::read_dir(dir)?.filter_map(Result::ok) {
        if is_part_name(&item.file_name().to_string_lossy()) {
            continue;
        }
        match read_entry(&item.path()) {
            Ok(e) if show_hidden || !e.hidden => entries.push(e),
            Err(e) if e.kind() == io::ErrorKind::PermissionDenied => return Err(e),
            _ => {}
        }
    }
    sort_entries(&mut entries, key, descending);
    Ok(entries)
}

// folders always come first, so descending order flips each group on its own
pub fn sort_entries(entries: &mut [Entry], key: SortKey, descending: bool) {
    entries.sort_by_cached_key(|e| sort_key(e, key));
    if descending {
        let folders = entries.partition_point(|e| e.is_dir);
        let (dirs, files) = entries.split_at_mut(folders);
        if matches!(key, SortKey::Name | SortKey::Modified) {
            dirs.reverse();
        }
        files.reverse();
    }
}

// the raw name bytes break ties last, so names that differ only in case or in bytes that are not text keep a fixed order
fn sort_key(e: &Entry, key: SortKey) -> (bool, i64, String, String, OsString) {
    let (number, kind) = match key {
        SortKey::Name => (0, String::new()),
        SortKey::Size => (e.size as i64, String::new()),
        SortKey::Modified => (e.modified, String::new()),
        SortKey::Type if e.is_dir => (0, String::new()),
        SortKey::Type => (0, extension_of(&e.name)),
    };
    (!e.is_dir, number, kind, natural_key(&e.name), e.path.file_name().unwrap_or(e.path.as_os_str()).to_owned())
}

// a run of digits becomes a zero mark, its length and its digits, so "Level 2" sorts before "Level 10"
fn natural_key(name: &str) -> String {
    let mut key = String::with_capacity(name.len() + 8);
    let mut chars = name.chars().peekable();
    while let Some(&c) = chars.peek() {
        if !c.is_ascii_digit() {
            fold(c, &mut key);
            chars.next();
            continue;
        }
        let mut digits = String::new();
        while let Some(d) = chars.next_if(char::is_ascii_digit) {
            digits.push(d);
        }
        let value = digits.trim_start_matches('0');
        key.push('\0');
        key.push(char::from_u32(value.len() as u32).unwrap_or(char::MAX));
        key.push_str(value);
    }
    key
}

// base letters for U+00C0 to U+017F, and a zero keeps the letter as it is
const LATIN: &[u8] = concat!(
    "aaaaaaaceeeeiiii", "dnooooo\0ouuuuy\0s", "aaaaaaaceeeeiiii", "dnooooo\0ouuuuy\0y",
    "aaaaaaccccccccdd", "ddeeeeeeeeeegggg", "gggghhhhiiiiiiii", "iiiijjkkklllllll",
    "lllnnnnnnnnnoooo", "oooorrrrrrssssss", "ssttttttuuuuuuuu", "uuuuwwyyyzzzzzzs",
)
.as_bytes();
const _: () = assert!(LATIN.len() == 0x180 - 0xC0);

// lower case without accents, so "Éclair" sorts next to "eclair" and not after "z"
fn fold(c: char, out: &mut String) {
    match c as u32 {
        0x300..=0x36F => {}
        n @ 0xC0..0x180 if LATIN[(n - 0xC0) as usize] != 0 => out.push(LATIN[(n - 0xC0) as usize] as char),
        _ => out.extend(c.to_lowercase()),
    }
}

pub fn extension_of(name: &str) -> String {
    Path::new(name)
        .extension()
        .map(|e| e.to_string_lossy().to_lowercase())
        .unwrap_or_default()
}

pub fn type_label(name: &str, is_dir: bool) -> String {
    if is_dir {
        return "Folder".into();
    }
    match extension_of(name).as_str() {
        "" => "File".into(),
        ext => format!("{} file", ext.to_uppercase()),
    }
}

pub fn stat_entry(path: &Path) -> Option<Entry> {
    read_entry(path).ok()
}

fn read_entry(path: &Path) -> io::Result<Entry> {
    // fs::metadata follows symlinks so a link to a folder opens like a folder
    let meta = fs::metadata(path).or_else(|_| fs::symlink_metadata(path))?;
    let name = path.file_name().ok_or_else(|| io::Error::other("The path has no name."))?.to_string_lossy().into_owned();
    let modified = meta
        .modified()
        .ok()
        .and_then(|t| t.duration_since(UNIX_EPOCH).ok())
        .map_or(0, |d| d.as_secs() as i64);
    Ok(Entry {
        hidden: is_hidden(&name, &meta),
        is_dir: meta.is_dir(),
        size: if meta.is_dir() { 0 } else { meta.len() },
        modified,
        path: path.to_path_buf(),
        name,
    })
}

#[cfg(windows)]
fn is_hidden(name: &str, meta: &fs::Metadata) -> bool {
    use std::os::windows::fs::MetadataExt;
    const FILE_ATTRIBUTE_HIDDEN: u32 = 0x2;
    name.starts_with('.') || meta.file_attributes() & FILE_ATTRIBUTE_HIDDEN != 0
}

#[cfg(not(windows))]
fn is_hidden(name: &str, _meta: &fs::Metadata) -> bool {
    name.starts_with('.')
}

// checks the exact name, so a caller that trims must trim first
pub fn validate_name(name: &str) -> Result<(), String> {
    if name.trim().is_empty() || name == "." || name == ".." {
        return Err("The name is not valid.".into());
    }
    if name.contains(['/', '\\', '\0']) {
        return Err("The name cannot contain a slash.".into());
    }
    #[cfg(windows)]
    if name.contains(['<', '>', ':', '"', '|', '?', '*']) {
        return Err("The name cannot contain < > : \" | ? *".into());
    }
    #[cfg(windows)]
    windows_name_check(name)?;
    Ok(())
}

// Windows drops a trailing dot or space and opens a device for a name such as CON or NUL.txt, so the item would not get the typed name
#[cfg(windows)]
fn windows_name_check(name: &str) -> Result<(), String> {
    if name.ends_with(['.', ' ']) {
        return Err("The name cannot end with a dot or a space.".into());
    }
    if name.chars().any(char::is_control) {
        return Err("The name cannot contain a tab or another control character.".into());
    }
    let stem = name.split('.').next().unwrap_or_default().trim_end().to_ascii_uppercase();
    let mut chars = stem.chars();
    let port = chars.by_ref().take(3).collect::<String>();
    let numbered = (port == "COM" || port == "LPT") && matches!((chars.next(), chars.next()), (Some('0'..='9' | '\u{b9}' | '\u{b2}' | '\u{b3}'), None));
    if numbered || ["CON", "PRN", "AUX", "NUL", "CONIN$", "CONOUT$"].contains(&stem.as_str()) {
        return Err(format!("Windows keeps the name \"{stem}\" for a device."));
    }
    Ok(())
}

// the name stays exactly as given, so OK on an unedited prompt changes nothing
pub fn rename(path: &Path, new_name: impl AsRef<OsStr>) -> Result<PathBuf, String> {
    let new_name = new_name.as_ref();
    validate_name(&new_name.to_string_lossy())?;
    let dest = path.with_file_name(new_name);
    let new_name = new_name.to_string_lossy();
    let failed = |e: io::Error| format!("Could not rename \"{}\": {}.", display_name(path), reason(&e));
    if dest == path {
        return Ok(dest);
    }
    if exists_nofollow(&dest) {
        if !is_case_variant(path, &dest) {
            return Err(format!("\"{new_name}\" already exists."));
        }
        // a drive that ignores case treats a direct rename to the new case as a rename that changes nothing
        let temp = temp_path(path.parent().unwrap_or(Path::new(".")), path.file_name().unwrap_or_default());
        fs::rename(path, &temp).map_err(failed)?;
        if let Err(e) = fs::rename(&temp, &dest) {
            let _ = fs::rename(&temp, path);
            return Err(failed(e));
        }
        return Ok(dest);
    }
    fs::rename(path, &dest).map_err(failed)?;
    Ok(dest)
}

// true when dest reaches the item at path only because the drive ignores case, and no entry has the exact new name
fn is_case_variant(path: &Path, dest: &Path) -> bool {
    let exact = dest.file_name();
    let listed = path.parent().and_then(|dir| fs::read_dir(dir).ok()).is_none_or(|rd| rd.filter_map(Result::ok).any(|e| Some(e.file_name().as_os_str()) == exact));
    !listed && same_item(path, dest)
}

#[cfg(unix)]
fn same_item(a: &Path, b: &Path) -> bool {
    use std::os::unix::fs::MetadataExt;
    match (fs::symlink_metadata(a), fs::symlink_metadata(b)) {
        (Ok(x), Ok(y)) => x.dev() == y.dev() && x.ino() == y.ino(),
        _ => false,
    }
}

#[cfg(not(unix))]
fn same_item(a: &Path, b: &Path) -> bool {
    let name = |p: &Path| p.file_name().map(|n| n.to_string_lossy().to_lowercase());
    a.parent().zip(b.parent()).is_some_and(|(x, y)| same_dir(x, y)) && name(a) == name(b)
}

pub fn display_name(path: &Path) -> String {
    path.file_name().unwrap_or(path.as_os_str()).to_string_lossy().into_owned()
}

pub fn make_dir(parent: &Path, name: &str) -> Result<PathBuf, String> {
    let name = name.trim();
    validate_name(name)?;
    let dest = parent.join(name);
    fs::create_dir(&dest).map_err(|e| match e.kind() {
        io::ErrorKind::AlreadyExists => format!("\"{name}\" already exists."),
        _ => format!("Could not make the folder \"{name}\": {}.", reason(&e)),
    })?;
    Ok(dest)
}

// a byte that is not valid text travels as U+F700 plus the byte, and a real U+F7xx is sent as its escaped bytes
#[cfg(unix)]
const ESCAPE: std::ops::RangeInclusive<u32> = 0xF700..=0xF7FF;

// a valid text path comes out unchanged, so GDScript only sees escapes for names that are not valid text
#[cfg(unix)]
pub fn path_to_text(path: &Path) -> String {
    use std::os::unix::ffi::OsStrExt;
    let escape = |b: u8, out: &mut String| out.push(char::from_u32(ESCAPE.start() + u32::from(b)).unwrap_or('\u{fffd}'));
    let mut out = String::with_capacity(path.as_os_str().len());
    for chunk in path.as_os_str().as_bytes().utf8_chunks() {
        for c in chunk.valid().chars() {
            if ESCAPE.contains(&(c as u32)) {
                c.encode_utf8(&mut [0; 4]).bytes().for_each(|b| escape(b, &mut out));
            } else {
                out.push(c);
            }
        }
        chunk.invalid().iter().for_each(|&b| escape(b, &mut out));
    }
    out
}

#[cfg(unix)]
pub fn path_from_text(text: &str) -> PathBuf {
    use std::os::unix::ffi::OsStringExt;
    let mut bytes = Vec::with_capacity(text.len());
    for c in text.chars() {
        match c as u32 {
            n if ESCAPE.contains(&n) => bytes.push((n - ESCAPE.start()) as u8),
            _ => bytes.extend_from_slice(c.encode_utf8(&mut [0; 4]).as_bytes()),
        }
    }
    PathBuf::from(OsString::from_vec(bytes))
}

#[cfg(not(unix))]
pub fn path_to_text(path: &Path) -> String {
    path.to_string_lossy().into_owned()
}

#[cfg(not(unix))]
pub fn path_from_text(text: &str) -> PathBuf {
    PathBuf::from(text)
}

// one item an operation could not handle, the operation goes on with the rest
#[derive(Debug, Clone, PartialEq)]
pub struct Failure {
    pub path: PathBuf,
    pub message: String,
}

// the old single error text stays meaningful for a caller that reads no failure list
pub fn summary(failures: &[Failure]) -> Option<String> {
    let first = &failures.first()?.message;
    Some(match failures.len() {
        1 => first.clone(),
        2 => format!("{first} 1 more item also failed."),
        n => format!("{first} {} more items also failed.", n - 1),
    })
}

// one call per item, so a failed item never stops the others
pub fn trash_items(paths: &[PathBuf]) -> Vec<Failure> {
    paths
        .iter()
        .filter_map(|path| {
            let e = trash::delete(path).err()?;
            let message = format!("Could not move \"{}\" to the trash: {}.", display_name(path), trash_reason(&e));
            Some(Failure { path: path.clone(), message })
        })
        .collect()
}

// the Display text of a trash error is a debug dump, so the reason comes from the variant
fn trash_reason(e: &trash::Error) -> String {
    match e {
        #[cfg(all(unix, not(target_os = "macos"), not(target_os = "ios"), not(target_os = "android")))]
        trash::Error::FileSystem { source, .. } => reason(source),
        trash::Error::Os { code, .. } => reason(&io::Error::from_raw_os_error(*code)),
        trash::Error::CouldNotAccess { .. } | trash::Error::CanonicalizePath { .. } => reason(&io::ErrorKind::NotFound.into()),
        trash::Error::TargetedRoot => "a drive root cannot go to the trash".into(),
        _ => "the trash did not accept it".into(),
    }
}

// the reason part of a sentence such as: Could not copy "a.txt": permission denied.
pub fn reason(e: &io::Error) -> String {
    use io::ErrorKind::*;
    let text = match e.kind() {
        NotFound => "the file or folder does not exist",
        PermissionDenied => "permission denied",
        StorageFull => "the drive is full",
        ReadOnlyFilesystem => "the drive is read only",
        FileTooLarge => "the file is too large for the drive",
        InvalidFilename if name_too_long(e) => "the name is too long",
        InvalidFilename | InvalidInput => "the drive does not accept this name",
        DirectoryNotEmpty => "the folder is not empty",
        _ => {
            let raw = e.to_string();
            let raw = raw.split(" (os error").next().unwrap_or_default().trim_end_matches('.');
            let mut chars = raw.chars();
            return chars.next().map_or_else(String::new, |c| c.to_lowercase().chain(chars).collect());
        }
    };
    text.into()
}

// Windows also reports a name it refuses as an invalid file name, so only the length codes mean too long
fn name_too_long(e: &io::Error) -> bool {
    #[cfg(unix)]
    const CODES: [i32; 1] = [libc::ENAMETOOLONG];
    #[cfg(windows)]
    const CODES: [i32; 1] = [206];
    #[cfg(not(any(unix, windows)))]
    const CODES: [i32; 0] = [];
    e.raw_os_error().is_some_and(|code| CODES.contains(&code))
}

// a broken link still occupies its name, so this check never follows links
pub fn exists_nofollow(path: &Path) -> bool {
    fs::symlink_metadata(path).is_ok()
}

// identity follows links, so a folder and a link to it count as one folder
#[cfg(unix)]
pub fn same_dir(a: &Path, b: &Path) -> bool {
    use std::os::unix::fs::MetadataExt;
    match (fs::metadata(a), fs::metadata(b)) {
        (Ok(x), Ok(y)) => x.dev() == y.dev() && x.ino() == y.ino(),
        _ => false,
    }
}

#[cfg(not(unix))]
pub fn same_dir(a: &Path, b: &Path) -> bool {
    match (fs::canonicalize(a), fs::canonicalize(b)) {
        (Ok(x), Ok(y)) => x == y,
        _ => false,
    }
}

// true when path is dir itself or lies anywhere below it, whatever links the path text goes through
pub fn is_within(path: &Path, dir: &Path) -> bool {
    fs::canonicalize(path).is_ok_and(|real| real.ancestors().any(|a| same_dir(a, dir)))
}

// most drives allow 255 bytes in one name
const NAME_MAX: usize = 255;
const PART_SUFFIX: &str = ".joyfiles-part";

// a name valid as text is cut on a character boundary, because some drives refuse broken text
fn truncate(name: &OsStr, max: usize) -> OsString {
    if name.len() <= max {
        return name.to_owned();
    }
    if let Some(text) = name.to_str() {
        let end = (0..=max).rev().find(|&i| text.is_char_boundary(i)).unwrap_or(0);
        return text[..end].into();
    }
    #[cfg(unix)]
    let cut = {
        use std::os::unix::ffi::OsStrExt;
        OsStr::from_bytes(&name.as_bytes()[..max]).to_owned()
    };
    #[cfg(not(unix))]
    let cut = truncate(OsStr::new(&*name.to_string_lossy()), max);
    cut
}

// a killed copy leaves such a file behind, and the user never sees it as an item, even with hidden files shown
fn is_part_name(name: &str) -> bool {
    name.strip_prefix('.').and_then(|rest| rest.strip_suffix(PART_SUFFIX)).is_some_and(|stem| !stem.is_empty())
}

// a hidden name in the same folder, so a rename puts the finished item in place in one step
pub fn temp_path(dir: &Path, name: &OsStr) -> PathBuf {
    let stem = truncate(name, NAME_MAX - 1 - PART_SUFFIX.len() - 8);
    (1..)
        .map(|n| {
            let mut temp = OsString::from(".");
            temp.push(&stem);
            if n > 1 {
                temp.push(format!(".{n}"));
            }
            temp.push(PART_SUFFIX);
            dir.join(temp)
        })
        .find(|p| !exists_nofollow(p))
        .expect("an unused name exists")
}

// "archive.tar.gz" gives ("archive", ".tar.gz"), and a folder, a dot file or "v1.2" keeps the whole name as the stem
fn split_extension(name: &OsStr, is_dir: bool) -> (OsString, OsString) {
    let whole = (name.to_owned(), OsString::new());
    let path = Path::new(name);
    let (Some(mut stem), Some(ext)) = (path.file_stem(), path.extension()) else { return whole };
    if is_dir || !ext.to_string_lossy().chars().any(char::is_alphabetic) {
        return whole;
    }
    let mut suffix = OsString::from(".");
    suffix.push(ext);
    if let Some(tar) = Path::new(stem).extension().filter(|e| e.eq_ignore_ascii_case("tar")) {
        let mut both = OsString::from(".");
        both.push(tar);
        both.push(&suffix);
        suffix = both;
        stem = Path::new(stem).file_stem().unwrap_or(stem);
    }
    if suffix.len() > 16 {
        return whole;
    }
    (stem.to_owned(), suffix)
}

pub fn unique_dest(dir: &Path, name: &OsStr, is_dir: bool) -> PathBuf {
    let first = dir.join(name);
    if !exists_nofollow(&first) {
        return first;
    }
    let (stem, ext) = split_extension(name, is_dir);
    (2..)
        .map(|n| {
            let counter = format!(" ({n})");
            let mut out = truncate(&stem, NAME_MAX - counter.len() - ext.len());
            out.push(counter);
            out.push(&ext);
            dir.join(out)
        })
        .find(|p| !exists_nofollow(p))
        .expect("an unused name exists")
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs::File;
    use std::time::{Duration, SystemTime};

    fn names(entries: Vec<Entry>) -> Vec<String> {
        entries.into_iter().map(|e| e.name).collect()
    }

    fn write_sized(dir: &Path, name: &str, size: usize, age_secs: u64) {
        let path = dir.join(name);
        fs::write(&path, vec![b'x'; size]).unwrap();
        let when = SystemTime::now() - Duration::from_secs(age_secs);
        File::options().write(true).open(&path).unwrap().set_modified(when).unwrap();
    }

    #[test]
    fn lists_folders_first_then_case_insensitive_names() {
        let tmp = tempfile::tempdir().unwrap();
        fs::write(tmp.path().join("b.txt"), "x").unwrap();
        fs::write(tmp.path().join("A.txt"), "x").unwrap();
        fs::create_dir(tmp.path().join("zdir")).unwrap();
        fs::write(tmp.path().join(".secret"), "x").unwrap();
        let listed = list_dir(tmp.path(), false, SortKey::Name, false).unwrap();
        assert_eq!(names(listed), ["zdir", "A.txt", "b.txt"]);
        assert_eq!(list_dir(tmp.path(), true, SortKey::Name, false).unwrap().len(), 4);
    }

    #[test]
    fn a_leftover_part_file_never_shows_in_the_list() {
        let tmp = tempfile::tempdir().unwrap();
        for name in ["real.txt", ".hidden", ".joyfiles-part", ".x.joyfiles-part-not", "..joyfiles-part"] {
            fs::write(tmp.path().join(name), "x").unwrap();
        }
        let first = temp_path(tmp.path(), OsStr::new("a.txt"));
        fs::write(&first, "x").unwrap();
        fs::write(temp_path(tmp.path(), OsStr::new("a.txt")), "x").unwrap();
        fs::create_dir(temp_path(tmp.path(), OsStr::new("dir"))).unwrap();
        assert_eq!(first.file_name().unwrap(), ".a.txt.joyfiles-part");
        let shown = names(list_dir(tmp.path(), true, SortKey::Name, false).unwrap());
        assert_eq!(shown, ["..joyfiles-part", ".hidden", ".joyfiles-part", ".x.joyfiles-part-not", "real.txt"]);
        assert_eq!(names(list_dir(tmp.path(), false, SortKey::Name, false).unwrap()), ["real.txt"]);
    }

    #[cfg(unix)]
    #[test]
    fn a_path_that_is_not_valid_text_survives_the_trip_through_text() {
        use std::os::unix::ffi::OsStrExt;
        let tmp = tempfile::tempdir().unwrap();
        let e9 = tmp.path().join(OsStr::from_bytes(b"caf\xe9.txt"));
        let e8 = tmp.path().join(OsStr::from_bytes(b"caf\xe8.txt"));
        fs::write(&e9, "x").unwrap();
        fs::write(&e8, "y").unwrap();
        let listed = list_dir(tmp.path(), true, SortKey::Name, false).unwrap();
        let texts: Vec<String> = listed.iter().map(|e| path_to_text(&e.path)).collect();
        assert_ne!(texts[0], texts[1], "two names stay two keys");
        let mut back: Vec<PathBuf> = texts.iter().map(|t| path_from_text(t)).collect();
        back.sort();
        assert_eq!(back, [e8, e9]);
        assert!(listed.iter().all(|e| e.name == "caf\u{fffd}.txt"), "the display name stays readable");
        let odd = tmp.path().join("plain \u{f701} name");
        assert_eq!(path_from_text(&path_to_text(&odd)), odd);
        assert_eq!(path_to_text(&tmp.path().join("héllo wörld.txt")), format!("{}/héllo wörld.txt", tmp.path().display()));
    }

    #[cfg(unix)]
    #[test]
    fn names_that_show_the_same_text_keep_one_order_whatever_the_folder_order() {
        use std::os::unix::ffi::OsStrExt;
        let tmp = tempfile::tempdir().unwrap();
        let e8 = tmp.path().join(OsStr::from_bytes(b"caf\xe8.txt"));
        let e9 = tmp.path().join(OsStr::from_bytes(b"caf\xe9.txt"));
        fs::write(&e8, "x").unwrap();
        fs::write(&e9, "x").unwrap();
        for key in [SortKey::Name, SortKey::Size, SortKey::Modified, SortKey::Type] {
            let mut one = vec![stat_entry(&e8).unwrap(), stat_entry(&e9).unwrap()];
            let mut other = vec![stat_entry(&e9).unwrap(), stat_entry(&e8).unwrap()];
            sort_entries(&mut one, key, false);
            sort_entries(&mut other, key, false);
            assert_eq!(one, other, "{key:?} gives one order");
        }
    }

    #[test]
    fn name_sort_is_natural_and_ignores_case_and_accents() {
        let tmp = tempfile::tempdir().unwrap();
        for dir in ["Game 10", "Game 2", "game 3"] {
            fs::create_dir(tmp.path().join(dir)).unwrap();
        }
        for name in ["Level 10.txt", "level 3.txt", "Zed.txt", "Level 2.txt", "zebra.txt", "Éclair.txt", "Level 1.txt", "ecran.txt", "file007.txt", "file7b.txt"] {
            write_sized(tmp.path(), name, 1, 0);
        }
        let listed = names(list_dir(tmp.path(), false, SortKey::Name, false).unwrap());
        let want = ["Game 2", "game 3", "Game 10", "Éclair.txt", "ecran.txt", "file007.txt", "file7b.txt", "Level 1.txt", "Level 2.txt", "level 3.txt", "Level 10.txt", "zebra.txt", "Zed.txt"];
        assert_eq!(listed, want);
    }

    #[test]
    fn name_sort_descending_keeps_folders_first() {
        let tmp = tempfile::tempdir().unwrap();
        fs::create_dir(tmp.path().join("a_dir")).unwrap();
        fs::create_dir(tmp.path().join("z_dir")).unwrap();
        write_sized(tmp.path(), "a.txt", 1, 0);
        write_sized(tmp.path(), "b.txt", 1, 0);
        let listed = list_dir(tmp.path(), false, SortKey::Name, true).unwrap();
        assert_eq!(names(listed), ["z_dir", "a_dir", "b.txt", "a.txt"]);
    }

    #[test]
    fn size_sort_orders_files_and_breaks_ties_by_name() {
        let tmp = tempfile::tempdir().unwrap();
        fs::create_dir(tmp.path().join("folder")).unwrap();
        write_sized(tmp.path(), "big.bin", 900, 0);
        write_sized(tmp.path(), "small.bin", 10, 0);
        write_sized(tmp.path(), "mid_b.bin", 100, 0);
        write_sized(tmp.path(), "mid_a.bin", 100, 0);
        let up = names(list_dir(tmp.path(), false, SortKey::Size, false).unwrap());
        assert_eq!(up, ["folder", "small.bin", "mid_a.bin", "mid_b.bin", "big.bin"]);
        let down = names(list_dir(tmp.path(), false, SortKey::Size, true).unwrap());
        assert_eq!(down, ["folder", "big.bin", "mid_b.bin", "mid_a.bin", "small.bin"]);
    }

    #[test]
    fn modified_sort_puts_oldest_first_when_ascending() {
        let tmp = tempfile::tempdir().unwrap();
        write_sized(tmp.path(), "new.txt", 1, 10);
        write_sized(tmp.path(), "old.txt", 1, 5000);
        write_sized(tmp.path(), "mid.txt", 1, 600);
        let up = names(list_dir(tmp.path(), false, SortKey::Modified, false).unwrap());
        assert_eq!(up, ["old.txt", "mid.txt", "new.txt"]);
        let down = names(list_dir(tmp.path(), false, SortKey::Modified, true).unwrap());
        assert_eq!(down, ["new.txt", "mid.txt", "old.txt"]);
    }

    #[test]
    fn type_sort_groups_by_extension_then_name() {
        let tmp = tempfile::tempdir().unwrap();
        for name in ["b.png", "a.txt", "c.PNG", "a.png", "readme"] {
            write_sized(tmp.path(), name, 1, 0);
        }
        let up = names(list_dir(tmp.path(), false, SortKey::Type, false).unwrap());
        assert_eq!(up, ["readme", "a.png", "b.png", "c.PNG", "a.txt"]);
    }

    // run with: cargo test --release -- --ignored --nocapture stage_times, set JF_PERF_DIR to test another folder
    #[test]
    #[ignore]
    fn stage_times_for_a_big_folder() {
        use std::time::Instant;
        let tmp = tempfile::tempdir().unwrap();
        let dir = std::env::var("JF_PERF_DIR").map(PathBuf::from).unwrap_or_else(|_| {
            for i in 0..20000 {
                fs::write(tmp.path().join(format!("file_{i:05}.txt")), "x").unwrap();
            }
            tmp.path().to_path_buf()
        });
        for run in 0..5 {
            let t = Instant::now();
            let names = fs::read_dir(&dir).unwrap().filter_map(Result::ok).count();
            let read = t.elapsed();
            let t = Instant::now();
            let mut entries: Vec<Entry> = fs::read_dir(&dir).unwrap().filter_map(Result::ok).filter_map(|e| stat_entry(&e.path())).collect();
            let listed = t.elapsed();
            let t = Instant::now();
            sort_entries(&mut entries, SortKey::Name, false);
            let sorted = t.elapsed();
            println!("run {run}: {names} names, read_dir {read:?}, read_dir and stat {listed:?}, sort {sorted:?}");
        }
    }

    #[test]
    fn sort_key_parse_falls_back_to_name() {
        assert_eq!(SortKey::parse("size"), SortKey::Size);
        assert_eq!(SortKey::parse("modified"), SortKey::Modified);
        assert_eq!(SortKey::parse("type"), SortKey::Type);
        assert_eq!(SortKey::parse("nonsense"), SortKey::Name);
    }

    #[test]
    fn type_label_names_folders_and_extensions() {
        assert_eq!(type_label("x", true), "Folder");
        assert_eq!(type_label("photo.JPG", false), "JPG file");
        assert_eq!(type_label("Makefile", false), "File");
        assert_eq!(type_label(".bashrc", false), "File");
    }

    #[test]
    fn unique_dest_adds_a_counter_before_the_extension() {
        let tmp = tempfile::tempdir().unwrap();
        fs::write(tmp.path().join("a.txt"), "x").unwrap();
        fs::write(tmp.path().join("a (2).txt"), "x").unwrap();
        assert_eq!(unique_dest(tmp.path(), OsStr::new("a.txt"), false), tmp.path().join("a (3).txt"));
        assert_eq!(unique_dest(tmp.path(), OsStr::new("new"), false), tmp.path().join("new"));
    }

    #[test]
    fn rename_rejects_slashes_and_existing_names() {
        let tmp = tempfile::tempdir().unwrap();
        let a = tmp.path().join("a");
        fs::write(&a, "x").unwrap();
        fs::write(tmp.path().join("b"), "x").unwrap();
        assert!(rename(&a, "x/y").is_err());
        assert!(rename(&a, "b").is_err());
        assert!(rename(&a, "   ").is_err());
        assert_eq!(rename(&a, "c").unwrap(), tmp.path().join("c"));
    }

    #[test]
    fn rename_keeps_the_name_exactly_as_given() {
        let tmp = tempfile::tempdir().unwrap();
        let lead = tmp.path().join("  lead.txt");
        fs::write(&lead, "x").unwrap();
        assert_eq!(rename(&lead, "  lead.txt"), Ok(lead.clone()), "the same name changes nothing");
        #[cfg(not(windows))]
        assert_eq!(rename(&lead, "  trail  "), Ok(tmp.path().join("  trail  ")));
        #[cfg(windows)]
        assert!(rename(&lead, "  trail  ").is_err(), "Windows would drop the spaces at the end");
    }

    // the name text comes back through the same decoding as a path, so an unedited prompt changes nothing
    #[cfg(unix)]
    #[test]
    fn rename_to_the_text_of_its_own_name_changes_nothing() {
        use std::os::unix::ffi::OsStrExt;
        let tmp = tempfile::tempdir().unwrap();
        for raw in [&b"caf\xe8.txt"[..], "pua\u{f741}.txt".as_bytes()] {
            let item = tmp.path().join(OsStr::from_bytes(raw));
            fs::write(&item, "x").unwrap();
            let text = path_to_text(&item);
            let name = path_from_text(text.rsplit('/').next().unwrap());
            assert_eq!(rename(&item, &name), Ok(item.clone()));
            assert_eq!(fs::read_dir(tmp.path()).unwrap().count(), 1);
            fs::remove_file(&item).unwrap();
        }
    }

    #[cfg(unix)]
    #[test]
    fn a_folder_that_lists_but_cannot_be_searched_is_an_error_not_an_empty_list() {
        use std::os::unix::fs::PermissionsExt;
        let tmp = tempfile::tempdir().unwrap();
        let half = tmp.path().join("halfperm");
        fs::create_dir(&half).unwrap();
        fs::write(half.join("z"), "z").unwrap();
        fs::set_permissions(&half, fs::Permissions::from_mode(0o600)).unwrap();
        let searchable = fs::metadata(half.join("z")).is_ok();
        let listed = list_dir(&half, true, SortKey::Name, false);
        fs::set_permissions(&half, fs::Permissions::from_mode(0o755)).unwrap();
        if searchable {
            return;
        }
        assert_eq!(listed.map_err(|e| e.kind()), Err(io::ErrorKind::PermissionDenied));
    }

    // a child process gets its own data home on the drive of the items, so nothing reaches a real trash
    #[cfg(target_os = "linux")]
    #[test]
    fn trash_goes_on_past_a_missing_item_and_names_it() {
        let Some(home) = std::env::var_os("JF_TRASH_TEST_HOME") else {
            let base = Path::new(env!("CARGO_MANIFEST_DIR")).join("target");
            fs::create_dir_all(&base).unwrap();
            let home = tempfile::tempdir_in(&base).unwrap();
            let me = std::env::current_exe().unwrap();
            let name = "fs_ops::tests::trash_goes_on_past_a_missing_item_and_names_it";
            let out = std::process::Command::new(me).args(["--exact", name, "--test-threads=1"]).env("JF_TRASH_TEST_HOME", home.path()).env("XDG_DATA_HOME", home.path()).output().unwrap();
            assert!(out.status.success(), "{}", String::from_utf8_lossy(&out.stdout));
            assert!(fs::read_dir(home.path().join("Trash/files")).unwrap().next().is_none(), "the child emptied its trash");
            return;
        };
        let tmp = tempfile::tempdir_in(&home).unwrap();
        let (x1, missing, x2) = (tmp.path().join("x1"), tmp.path().join("missing"), tmp.path().join("x2"));
        fs::write(&x1, "1").unwrap();
        fs::write(&x2, "2").unwrap();
        let failures = trash_items(&[x1.clone(), missing.clone(), x2.clone()]);
        let ours: Vec<_> = trash::os_limited::list().unwrap().into_iter().filter(|i| i.original_parent == tmp.path()).collect();
        trash::os_limited::purge_all(&ours).unwrap();
        assert!(Path::new(&home).join("Trash/files").is_dir(), "the items went to the trash in the test data home");
        assert!(!x1.exists() && !x2.exists(), "both real items went to the trash");
        assert_eq!(failures.len(), 1);
        assert_eq!(failures[0].path, missing);
        assert_eq!(failures[0].message, "Could not move \"missing\" to the trash: the file or folder does not exist.");
    }

    #[test]
    fn a_name_the_drive_refuses_is_not_called_too_long() {
        assert_eq!(reason(&io::ErrorKind::InvalidFilename.into()), "the drive does not accept this name");
        #[cfg(unix)]
        assert_eq!(reason(&io::Error::from_raw_os_error(libc::ENAMETOOLONG)), "the name is too long");
        #[cfg(windows)]
        assert_eq!(reason(&io::Error::from_raw_os_error(123)), "the drive does not accept this name");
    }

    #[cfg(windows)]
    #[test]
    fn names_that_windows_would_change_are_refused() {
        let tmp = tempfile::tempdir().unwrap();
        for bad in ["x.", "con", "NUL.txt", "com1", "LPT9.log", "a\tb", "a\u{1}b", "COM0", "lpt0.txt", "COM\u{b9}", "LPT\u{b3}.log"] {
            assert!(make_dir(tmp.path(), bad).is_err(), "{bad:?} is refused");
        }
        assert!(names(list_dir(tmp.path(), true, SortKey::Name, false).unwrap()).is_empty());
        assert!(make_dir(tmp.path(), "console").is_ok());
    }

    #[cfg(unix)]
    #[test]
    fn rename_never_replaces_a_broken_link() {
        let tmp = tempfile::tempdir().unwrap();
        let a = tmp.path().join("a.txt");
        fs::write(&a, "x").unwrap();
        std::os::unix::fs::symlink("nowhere", tmp.path().join("dangling")).unwrap();
        assert_eq!(rename(&a, "dangling"), Err("\"dangling\" already exists.".into()));
        assert!(fs::symlink_metadata(tmp.path().join("dangling")).unwrap().file_type().is_symlink());
        assert_eq!(read_to(&a), "x");
    }

    fn read_to(path: &Path) -> String {
        fs::read_to_string(path).unwrap()
    }

    #[test]
    fn rename_to_the_same_name_or_a_new_case_works() {
        let tmp = tempfile::tempdir().unwrap();
        let a = tmp.path().join("a.txt");
        fs::write(&a, "x").unwrap();
        assert_eq!(rename(&a, "a.txt"), Ok(a.clone()));
        let upper = rename(&a, "A.txt").unwrap();
        assert_eq!(names(list_dir(tmp.path(), true, SortKey::Name, false).unwrap()), ["A.txt"]);
        assert_eq!(read_to(&upper), "x");
    }

    // set JF_CASELESS_DIR to a folder on a drive that ignores case, such as exFAT, to run this
    #[test]
    fn a_case_only_rename_works_on_a_drive_that_ignores_case() {
        let Ok(dir) = std::env::var("JF_CASELESS_DIR") else { return };
        let tmp = tempfile::tempdir_in(dir).unwrap();
        let a = tmp.path().join("a.txt");
        fs::write(&a, "x").unwrap();
        fs::write(tmp.path().join("b.txt"), "y").unwrap();
        let upper = rename(&a, "A.txt").unwrap();
        assert_eq!(names(list_dir(tmp.path(), true, SortKey::Name, false).unwrap()), ["A.txt", "b.txt"]);
        assert_eq!(read_to(&upper), "x");
        assert_eq!(rename(&upper, "B.txt"), Err("\"B.txt\" already exists.".into()), "another file that differs in case stays");
        assert_eq!(read_to(&tmp.path().join("b.txt")), "y");
    }
}
