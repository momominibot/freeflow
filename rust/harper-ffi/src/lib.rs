//! A C interface to Harper's grammar checker, for the FreeFlow Mac and iPhone apps.
//!
//! Everything crosses the boundary as UTF-8 JSON in C strings, so the Swift side needs no generated header:
//!   harper_set_dialect(int)          0 American, 1 British, 2 Canadian, 3 Australian, 4 Indian
//!   harper_set_words(const char*)    a JSON array of words that are never misspellings (names, product words)
//!   harper_lint(const char*, int)    a JSON array of problems; offsets count Unicode scalars (not bytes, not UTF-16).
//!                                    The second argument is 1 when only the English parts of mixed text should be checked.
//!   harper_synonyms(const char*)     a JSON array of words that mean about the same, most common first (at most 12)
//!   harper_free(char*)               gives a returned string back
//!
//! Harper itself is Apache-2.0 (c) Automattic. The checker runs on the device; nothing is sent anywhere.

use std::ffi::{CStr, CString};
use std::os::raw::{c_char, c_int};
use std::panic::{AssertUnwindSafe, catch_unwind};
use std::sync::{Arc, Mutex};

use harper_core::linting::{LintGroup, Linter as _, Suggestion};
use harper_core::parsers::{IsolateEnglish, Parser, PlainEnglish};
use harper_core::spell::{Dictionary, FstDictionary, MergedDictionary, MutableDictionary};
use harper_core::{CharString, DialectFlags, DictWordMetadata, Document, Lrc, remove_overlaps};
use serde::Serialize;

/// Longest text checked in one go; longer text is cut so a pasted book cannot freeze the app.
const MAX_CHARS: usize = 60_000;

struct State {
    dialect: harper_core::Dialect,
    words: MutableDictionary,
    dictionary: Arc<MergedDictionary>,
    group: LintGroup,
}

impl State {
    fn new(dialect: harper_core::Dialect, words: MutableDictionary) -> Self {
        let mut merged = MergedDictionary::new();
        merged.add_dictionary(FstDictionary::curated());
        merged.add_dictionary(Arc::new(words.clone()));
        let dictionary = Arc::new(merged);
        let mut group = LintGroup::new_curated_empty_config(dictionary.clone(), dialect);
        group.config.fill_with_curated();
        State { dialect, words, dictionary, group }
    }
}

static STATE: Mutex<Option<State>> = Mutex::new(None);

fn dialect_from(n: c_int) -> harper_core::Dialect {
    match n {
        1 => harper_core::Dialect::British,
        2 => harper_core::Dialect::Canadian,
        3 => harper_core::Dialect::Australian,
        4 => harper_core::Dialect::Indian,
        _ => harper_core::Dialect::American,
    }
}

#[derive(Serialize)]
struct Fix {
    kind: &'static str,
    text: String,
}

#[derive(Serialize)]
struct Problem {
    start: usize,
    end: usize,
    kind: String,
    message: String,
    priority: u8,
    fixes: Vec<Fix>,
}

fn to_c(s: String) -> *mut c_char {
    CString::new(s.replace('\0', "")).map(CString::into_raw).unwrap_or(std::ptr::null_mut())
}

fn read(ptr: *const c_char) -> Option<String> {
    if ptr.is_null() {
        return None;
    }
    // SAFETY: the caller passes a NUL-terminated string that stays alive for this call.
    unsafe { CStr::from_ptr(ptr) }.to_str().ok().map(str::to_owned)
}

/// Chooses the spelling variety. Rebuilds the checker, so call it when the setting changes, not per check.
#[unsafe(no_mangle)]
pub extern "C" fn harper_set_dialect(dialect: c_int) {
    let _ = catch_unwind(AssertUnwindSafe(|| {
        let d = dialect_from(dialect);
        let mut guard = STATE.lock().unwrap_or_else(|e| e.into_inner());
        let words = guard.as_ref().map(|s| s.words.clone()).unwrap_or_else(MutableDictionary::new);
        *guard = Some(State::new(d, words));
    }));
}

/// Replaces the list of words that are never reported as misspelled.
#[unsafe(no_mangle)]
pub extern "C" fn harper_set_words(json: *const c_char) {
    let Some(text) = read(json) else { return };
    let Ok(list) = serde_json::from_str::<Vec<String>>(&text) else { return };
    let _ = catch_unwind(AssertUnwindSafe(|| {
        let mut guard = STATE.lock().unwrap_or_else(|e| e.into_inner());
        let dialect = guard.as_ref().map(|s| s.dialect).unwrap_or(harper_core::Dialect::American);
        let mut words = MutableDictionary::new();
        words.extend_words(list.iter().filter(|w| !w.trim().is_empty()).map(|w| {
            (
                w.trim().chars().collect::<CharString>(),
                DictWordMetadata { dialects: DialectFlags::from_dialect(dialect), ..Default::default() },
            )
        }));
        *guard = Some(State::new(dialect, words));
    }));
}

/// Checks the text. Returns a JSON array (possibly empty), or null if something went badly wrong.
#[unsafe(no_mangle)]
pub extern "C" fn harper_lint(text: *const c_char, isolate_english: c_int) -> *mut c_char {
    let Some(text) = read(text) else { return std::ptr::null_mut() };
    let result = catch_unwind(AssertUnwindSafe(|| {
        let mut guard = STATE.lock().unwrap_or_else(|e| e.into_inner());
        let state = guard.get_or_insert_with(|| State::new(harper_core::Dialect::American, MutableDictionary::new()));

        let source: Lrc<_> = text.chars().take(MAX_CHARS).collect();
        let mut parser: Box<dyn Parser> = Box::new(PlainEnglish);
        if isolate_english != 0 {
            parser = Box::new(IsolateEnglish::new(parser, state.dictionary.clone()));
        }
        let document = Document::new_from_chars(source.clone(), &parser, &state.dictionary);
        let mut lints = state.group.lint(&document);
        remove_overlaps(&mut lints);

        let out: Vec<Problem> = lints
            .into_iter()
            .map(|l| Problem {
                start: l.span.start,
                end: l.span.end,
                kind: l.lint_kind.to_string_key(),
                message: l.message,
                priority: l.priority,
                fixes: l
                    .suggestions
                    .iter()
                    .map(|s| match s {
                        Suggestion::Remove => Fix { kind: "remove", text: String::new() },
                        Suggestion::ReplaceWith(c) => Fix { kind: "replace", text: c.iter().collect() },
                        Suggestion::InsertAfter(c) => Fix { kind: "insert", text: c.iter().collect() },
                    })
                    .collect(),
            })
            .collect();
        serde_json::to_string(&out).unwrap_or_else(|_| "[]".to_string())
    }));
    match result {
        Ok(json) => to_c(json),
        Err(_) => std::ptr::null_mut(),
    }
}

/// Words that mean about the same as `word`, most common first, as a JSON array of strings (possibly empty).
#[unsafe(no_mangle)]
pub extern "C" fn harper_synonyms(word: *const c_char) -> *mut c_char {
    let Some(word) = read(word) else { return std::ptr::null_mut() };
    let result = catch_unwind(AssertUnwindSafe(|| {
        let found: Vec<&str> = harper_thesaurus::thesaurus()
            .get_synonyms_freq_sorted(&word.to_lowercase())
            .unwrap_or_default()
            .into_iter()
            .take(12)
            .collect();
        serde_json::to_string(&found).unwrap_or_else(|_| "[]".to_string())
    }));
    match result {
        Ok(json) => to_c(json),
        Err(_) => std::ptr::null_mut(),
    }
}

/// Gives back a string returned by `harper_lint` or `harper_synonyms`.
#[unsafe(no_mangle)]
pub extern "C" fn harper_free(ptr: *mut c_char) {
    if !ptr.is_null() {
        // SAFETY: the pointer came from `CString::into_raw` in this library.
        drop(unsafe { CString::from_raw(ptr) });
    }
}
