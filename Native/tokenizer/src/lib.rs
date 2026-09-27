use serde::{Deserialize, Serialize};
use std::ffi::{c_char, CStr, CString};
use tokenizers::Tokenizer;

#[derive(Deserialize)]
struct Request {
    state: String,
    question: String,
    options: Vec<String>,
    #[serde(rename = "type")]
    kind: String,
}

#[derive(Serialize)]
struct Encoded {
    ids: Vec<u32>,
    markers: Vec<usize>,
    qtype: u32,
}

pub struct Encoder {
    tokenizer: Tokenizer,
    error: CString,
}

fn encode(tokenizer: &Tokenizer, text: &str) -> Result<Vec<u32>, String> {
    tokenizer.encode(text, false).map(|value| value.get_ids().to_vec()).map_err(|error| error.to_string())
}

fn serialize(tokenizer: &Tokenizer, request: Request, max_length: usize, head_length: usize, strict: bool) -> Result<Encoded, String> {
    let qtype = match request.kind.as_str() {
        "choice" => 0,
        "score" => 1,
        "noul" => 2,
        _ => return Err("Unsupported decision type".into()),
    };
    if !(2..=20).contains(&request.options.len()) || request.options.iter().any(String::is_empty) || (qtype == 2 && request.options.len() != 2) {
        return Err("Options must contain 2–20 nonempty descriptions".into());
    }
    if head_length + 4 >= max_length { return Err("Head length leaves no context".into()); }
    let marker = "<mask>";
    if strict && (request.state.contains(marker) || request.question.contains(marker) || request.options.iter().any(|option| option.contains(marker))) {
        return Err("Reserved model marker in request".into());
    }
    let clean = |text: &str| text.replace(marker, " ");
    let head = encode(tokenizer, &format!("{} question: {}", request.kind, clean(&request.question)))?;
    let option_ids: Vec<Vec<u32>> = request.options.iter().map(|option| encode(tokenizer, &format!(" {}", clean(option)))).collect::<Result<_, _>>()?;
    if strict && option_ids.iter().any(|option| option.len() > 48) { return Err("Option exceeds 48 tokens".into()); }
    let mut options: Vec<Vec<u32>> = option_ids.iter().map(|option| std::iter::once(4).chain(option.iter().copied().take(48)).collect()).collect();
    let mut budget = head_length as isize - options.iter().map(|option| option.len() as isize).sum::<isize>();
    if budget < 16 {
        let cap = ((head_length.saturating_sub(16)) / options.len()).max(4);
        for option in &mut options { option.truncate(cap); }
        budget = head_length as isize - options.iter().map(|option| option.len() as isize).sum::<isize>();
    }
    if strict && (head.len() as isize > budget || options.iter().zip(&option_ids).any(|(option, original)| option.len() != original.len() + 1)) {
        return Err("Question and options exceed lossless head budget".into());
    }
    let mut ids = vec![2];
    ids.extend(head.into_iter().take(budget.max(8) as usize));
    ids.push(1);
    let mut markers = Vec::with_capacity(options.len());
    for option in options { markers.push(ids.len()); ids.extend(option); }
    ids.push(1);
    let state_ids = encode(tokenizer, &clean(&request.state))?;
    let room = max_length.saturating_sub(ids.len() + 1);
    if room == 0 { return Err("Question and options exceed sequence budget".into()); }
    if strict && state_ids.len() > room { return Err("State exceeds lossless context budget".into()); }
    ids.extend(state_ids.into_iter().take(room));
    ids.push(1);
    Ok(Encoded { ids, markers, qtype })
}

#[no_mangle]
pub unsafe extern "C" fn julia_tokenizer_create_handle(path: *const c_char) -> *mut Encoder {
    if path.is_null() { return std::ptr::null_mut(); }
    let Ok(path) = CStr::from_ptr(path).to_str() else { return std::ptr::null_mut(); };
    let Ok(tokenizer) = Tokenizer::from_file(path) else { return std::ptr::null_mut(); };
    Box::into_raw(Box::new(Encoder { tokenizer, error: CString::new("").unwrap() }))
}

#[no_mangle]
pub unsafe extern "C" fn julia_tokenizer_encode_request(handle: *mut Encoder, request: *const c_char, max_length: u32, head_length: u32, strict: bool) -> *mut c_char {
    if handle.is_null() || request.is_null() { return std::ptr::null_mut(); }
    let encoder = &mut *handle;
    let result = CStr::from_ptr(request).to_str().map_err(|error| error.to_string())
        .and_then(|text| serde_json::from_str::<Request>(text).map_err(|error| error.to_string()))
        .and_then(|row| serialize(&encoder.tokenizer, row, max_length as usize, head_length as usize, strict))
        .and_then(|encoded| serde_json::to_string(&encoded).map_err(|error| error.to_string()));
    match result {
        Ok(value) => CString::new(value).unwrap().into_raw(),
        Err(error) => {
            encoder.error = CString::new(error.replace('\0', " ")).unwrap();
            std::ptr::null_mut()
        }
    }
}

#[no_mangle]
pub unsafe extern "C" fn julia_tokenizer_last_error(handle: *mut Encoder) -> *const c_char {
    if handle.is_null() { return c"Tokenizer is unavailable".as_ptr(); }
    (*handle).error.as_ptr()
}

#[no_mangle]
pub unsafe extern "C" fn julia_tokenizer_free_string(value: *mut c_char) {
    if !value.is_null() { drop(CString::from_raw(value)); }
}

#[no_mangle]
pub unsafe extern "C" fn julia_tokenizer_destroy_handle(handle: *mut Encoder) {
    if !handle.is_null() { drop(Box::from_raw(handle)); }
}
