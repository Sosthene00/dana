// B2.7 golden manifest test (Rust side): the exported Rust API surface is
// FROZEN. Every `pub fn` / `pub async fn` reachable from the bridge API tree
// (`src/api/**`, the flutter_rust_bridge-exposed module) must match the
// checked-in manifest `surface_golden_manifest.txt` exactly.
//
// Any addition to the Rust surface (a new free function or an added method on
// an API type) FAILS this test naming the unexpected item — surface growth
// must be a deliberate, reviewed manifest update (BEHAVIOR.md §11 B2.7).
//
// Note: FRB also derives auto-accessors for public struct fields and Default
// impls at codegen time; those never appear as source items, so they are
// pinned on the generated-Dart side by
// `test/services/rust_surface_golden_test.dart` instead.
use std::collections::BTreeSet;
use std::fs;
use std::path::{Path, PathBuf};

const MANIFEST_PATH: &str = "tests/surface_golden_manifest.txt";

/// Collect every `*.rs` file under `dir` (recursively), except `mod.rs`.
fn collect_api_files(dir: &Path, out: &mut Vec<PathBuf>) {
    let entries =
        fs::read_dir(dir).unwrap_or_else(|e| panic!("cannot list {}: {e}", dir.display()));
    for entry in entries {
        let path = entry.unwrap().path();
        if path.is_dir() {
            collect_api_files(&path, out);
        } else if path.extension().is_some_and(|e| e == "rs")
            && path.file_name().is_some_and(|n| n != "mod.rs")
        {
            out.push(path);
        }
    }
    out.sort();
}

/// A trait impl (`From<..>`, `TryFrom<..>`, `Display`, ..) is never bridge-
/// exposed; only inherent impls of API types are.
fn inherent_impl_type(line: &str) -> Option<String> {
    let head = line.strip_prefix("impl ")?;
    let head = head.trim_end_matches(['{', ' ']).trim();
    if head.contains(" for ") {
        return None;
    }
    // `impl Type` or `impl Generic<T>` — take the type, generic args dropped.
    let name = head.split('<').next()?.trim();
    if name.is_empty() {
        None
    } else {
        Some(name.to_string())
    }
}

/// Extract the bridge-exposed items of one api source file as
/// `<relative-path>::<name>` (free functions) or
/// `<relative-path>::<Type>::<name>` (inherent-impl methods).
fn exposed_items(rel: &str, source: &str) -> Vec<String> {
    let mut items = Vec::new();
    let mut impl_type: Option<String> = None;
    for line in source.lines() {
        let trimmed = line.trim_start();
        if let Some(ty) = inherent_impl_type(trimmed) {
            impl_type = Some(ty);
            continue;
        }
        // Only a top-level closing brace ends the current inherent impl.
        if line == "}" {
            impl_type = None;
            continue;
        }
        let fn_name = trimmed
            .strip_prefix("pub async fn ")
            .or_else(|| trimmed.strip_prefix("pub fn "));
        let Some(rest) = fn_name else { continue };
        let name: String = rest
            .chars()
            .take_while(|c| c.is_alphanumeric() || *c == '_')
            .collect();
        if name.is_empty() {
            continue;
        }
        match &impl_type {
            Some(ty) => items.push(format!("{rel}::{ty}::{name}")),
            None => items.push(format!("{rel}::{name}")),
        }
    }
    items
}

fn live_surface() -> BTreeSet<String> {
    let api_dir = Path::new(env!("CARGO_MANIFEST_DIR")).join("src/api");
    let mut files = Vec::new();
    collect_api_files(&api_dir, &mut files);
    let mut live = BTreeSet::new();
    for path in files {
        let rel = path
            .strip_prefix(&api_dir)
            .expect("api file under src/api")
            .to_string_lossy()
            .replace('\\', "/");
        let source = fs::read_to_string(&path)
            .unwrap_or_else(|e| panic!("cannot read {}: {e}", path.display()));
        live.extend(exposed_items(&rel, &source));
    }
    live
}

fn manifest_surface() -> BTreeSet<String> {
    let path = Path::new(env!("CARGO_MANIFEST_DIR")).join(MANIFEST_PATH);
    let text = fs::read_to_string(&path).unwrap_or_else(|e| {
        panic!(
            "B2.7 golden manifest missing at {} ({e}) — the fixed Rust \
             surface is asserted nowhere",
            path.display()
        )
    });
    text.lines()
        .map(str::trim)
        .filter(|l| !l.is_empty() && !l.starts_with('#'))
        .map(str::to_string)
        .collect()
}

#[test]
fn b27_rust_surface_matches_the_golden_manifest_exactly() {
    let live = live_surface();
    assert!(!live.is_empty(), "no pub fns found under src/api — the surface extractor is broken");
    let manifest = manifest_surface();
    assert!(!manifest.is_empty(), "surface_golden_manifest.txt has no entries — the B2.7 golden manifest is missing or empty");

    let unexpected: Vec<&String> = live.difference(&manifest).collect();
    let missing: Vec<&String> = manifest.difference(&live).collect();

    if !unexpected.is_empty() || !missing.is_empty() {
        let mut problems = Vec::new();
        if !unexpected.is_empty() {
            let listed: Vec<String> = unexpected.iter().map(|s| s.to_string()).collect();
            problems.push(format!(
                "UNEXPECTED Rust surface (not in the B2.7 manifest) — the Rust \
                 surface grew. If this growth is intended and reviewed, add the \
                 entries to rust/tests/surface_golden_manifest.txt deliberately:\n  {}",
                listed.join("\n  ")
            ));
        }
        if !missing.is_empty() {
            let listed: Vec<String> = missing.iter().map(|s| s.to_string()).collect();
            problems.push(format!(
                "MANIFEST ENTRIES with no live surface (stale manifest):\n  {}",
                listed.join("\n  ")
            ));
        }
        panic!("{}", problems.join("\n\n"));
    }
}
