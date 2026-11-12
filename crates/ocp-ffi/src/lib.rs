//! C ABI for Swift, C#, and other platform adapters.

#![allow(clippy::missing_safety_doc, clippy::not_unsafe_ptr_arg_deref)]

use std::ffi::{c_char, CStr, CString};
use std::ptr;
use std::sync::{Mutex, OnceLock};

use ocp_core::Core;
use ocp_model::ABI_VERSION;

#[repr(C)]
pub struct OcpCore {
    _private: [u8; 0],
}

fn last_error() -> &'static Mutex<Option<CString>> {
    static LAST_ERROR: OnceLock<Mutex<Option<CString>>> = OnceLock::new();
    LAST_ERROR.get_or_init(|| Mutex::new(None))
}

fn set_last_error(message: impl Into<String>) {
    let message = message.into().replace('\0', " ");
    if let Ok(mut slot) = last_error().lock() {
        *slot = CString::new(message).ok();
    }
}

fn clear_last_error() {
    if let Ok(mut slot) = last_error().lock() {
        *slot = None;
    }
}

fn copy_string(value: String) -> *mut c_char {
    CString::new(value)
        .map(CString::into_raw)
        .unwrap_or(ptr::null_mut())
}

unsafe fn read_utf8(value: *const c_char) -> Result<&'static str, String> {
    if value.is_null() {
        return Ok("");
    }
    let bytes = CStr::from_ptr(value).to_bytes();
    std::str::from_utf8(bytes).map_err(|error| error.to_string())
}

unsafe fn core_ref<'a>(core: *mut OcpCore) -> Result<&'a Core, String> {
    if core.is_null() {
        return Err("core handle is null".to_string());
    }
    Ok(&*(core as *mut Core))
}

#[no_mangle]
pub extern "C" fn ocp_core_create(config_json: *const c_char) -> *mut OcpCore {
    clear_last_error();
    let config = match unsafe { read_utf8(config_json) } {
        Ok(value) => value,
        Err(error) => {
            set_last_error(error);
            return ptr::null_mut();
        }
    };
    match Core::new(config) {
        Ok(core) => Box::into_raw(Box::new(core)) as *mut OcpCore,
        Err(error) => {
            set_last_error(error.to_string());
            ptr::null_mut()
        }
    }
}

#[no_mangle]
pub unsafe extern "C" fn ocp_core_destroy(core: *mut OcpCore) {
    if !core.is_null() {
        drop(Box::from_raw(core as *mut Core));
    }
}

#[no_mangle]
pub extern "C" fn ocp_core_abi_version() -> u32 {
    ABI_VERSION
}

#[no_mangle]
pub unsafe extern "C" fn ocp_call(
    core: *mut OcpCore,
    method: *const c_char,
    arguments_json: *const c_char,
) -> *mut c_char {
    clear_last_error();
    let core = match core_ref(core) {
        Ok(core) => core,
        Err(error) => {
            set_last_error(error);
            return ptr::null_mut();
        }
    };
    let method = match read_utf8(method) {
        Ok(value) if !value.is_empty() => value,
        Ok(_) => {
            set_last_error("method is empty");
            return ptr::null_mut();
        }
        Err(error) => {
            set_last_error(error);
            return ptr::null_mut();
        }
    };
    let arguments = match read_utf8(arguments_json) {
        Ok(value) => value,
        Err(error) => {
            set_last_error(error);
            return ptr::null_mut();
        }
    };
    match core.call(method, arguments) {
        Ok(response) => copy_string(response),
        Err(error) => {
            set_last_error(error.to_string());
            ptr::null_mut()
        }
    }
}

#[no_mangle]
pub unsafe extern "C" fn ocp_snapshot(
    core: *mut OcpCore,
    snapshot_kind: *const c_char,
) -> *mut c_char {
    clear_last_error();
    let core = match core_ref(core) {
        Ok(core) => core,
        Err(error) => {
            set_last_error(error);
            return ptr::null_mut();
        }
    };
    let kind = match read_utf8(snapshot_kind) {
        Ok(value) => value,
        Err(error) => {
            set_last_error(error);
            return ptr::null_mut();
        }
    };
    match core.snapshot(kind) {
        Ok(snapshot) => copy_string(snapshot),
        Err(error) => {
            set_last_error(error.to_string());
            ptr::null_mut()
        }
    }
}

#[no_mangle]
pub unsafe extern "C" fn ocp_poll_event(core: *mut OcpCore, event_json: *mut *mut c_char) -> i32 {
    clear_last_error();
    if event_json.is_null() {
        set_last_error("event_json output pointer is null");
        return -1;
    }
    *event_json = ptr::null_mut();
    let core = match core_ref(core) {
        Ok(core) => core,
        Err(error) => {
            set_last_error(error);
            return -1;
        }
    };
    match core.poll_event() {
        Ok(Some(event)) => {
            *event_json = copy_string(event);
            1
        }
        Ok(None) => 0,
        Err(error) => {
            set_last_error(error.to_string());
            -1
        }
    }
}

#[no_mangle]
pub unsafe extern "C" fn ocp_attach_surface(
    core: *mut OcpCore,
    native_handle: u64,
    width: u32,
    height: u32,
    scale: f64,
    surface_kind: u32,
) {
    clear_last_error();
    if let Err(error) = core_ref(core).and_then(|core| {
        core.attach_surface(native_handle, width, height, scale, surface_kind)
            .map_err(|e| e.to_string())
    }) {
        set_last_error(error);
    }
}

#[no_mangle]
pub unsafe extern "C" fn ocp_resize_surface(
    core: *mut OcpCore,
    width: u32,
    height: u32,
    scale: f64,
) {
    clear_last_error();
    if let Err(error) = core_ref(core).and_then(|core| {
        core.resize_surface(width, height, scale)
            .map_err(|e| e.to_string())
    }) {
        set_last_error(error);
    }
}

#[no_mangle]
pub unsafe extern "C" fn ocp_detach_surface(core: *mut OcpCore) {
    clear_last_error();
    if let Err(error) =
        core_ref(core).and_then(|core| core.detach_surface().map_err(|e| e.to_string()))
    {
        set_last_error(error);
    }
}

#[no_mangle]
pub unsafe extern "C" fn ocp_render_tick(core: *mut OcpCore, time_seconds: f64) {
    clear_last_error();
    if let Err(error) =
        core_ref(core).and_then(|core| core.render_tick(time_seconds).map_err(|e| e.to_string()))
    {
        set_last_error(error);
    }
}

#[no_mangle]
pub unsafe extern "C" fn ocp_string_free(value: *mut c_char) {
    if !value.is_null() {
        drop(CString::from_raw(value));
    }
}

#[no_mangle]
pub extern "C" fn ocp_last_error_message() -> *mut c_char {
    match last_error().lock().ok().and_then(|slot| {
        slot.as_ref()
            .map(|value| value.to_string_lossy().into_owned())
    }) {
        Some(value) => copy_string(value),
        None => ptr::null_mut(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::ffi::CString;

    #[test]
    fn ffi_ping_and_free() {
        let config = CString::new("{}").unwrap();
        let method = CString::new("ping").unwrap();
        let args = CString::new("{}").unwrap();
        let core = ocp_core_create(config.as_ptr());
        assert!(!core.is_null());
        let result = unsafe { ocp_call(core, method.as_ptr(), args.as_ptr()) };
        assert!(!result.is_null());
        let text = unsafe { CStr::from_ptr(result) }
            .to_string_lossy()
            .into_owned();
        assert!(text.contains("\"pong\":true"));
        unsafe {
            ocp_string_free(result);
            ocp_core_destroy(core);
        }
    }

    #[test]
    fn ffi_event_polling() {
        let core = ocp_core_create(ptr::null());
        let mut event = ptr::null_mut();
        assert_eq!(unsafe { ocp_poll_event(core, &mut event) }, 1);
        assert!(!event.is_null());
        unsafe {
            ocp_string_free(event);
            ocp_core_destroy(core);
        }
    }
}
